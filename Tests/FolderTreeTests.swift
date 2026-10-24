import XCTest
@testable import LocalDrive

// Вложенные папки. Владелец: «в папке можно создавать подпапки — дерево,
// крошки, всё такое». Дерево живёт только в vault.json (`parentID`), файлы
// каждой папки — в своём `Vault/<UUID>/`. Суперскрытая папка прячет всё своё
// поддерево, «вне поиска» тоже наследуется
@MainActor
final class FolderTreeTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDriveFolderTree-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root.appendingPathComponent("Vault", isDirectory: true))
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        store = nil
        root = nil
    }

    // MARK: - Помощники

    @discardableResult
    private func folder(
        _ name: String,
        in parent: VaultFolder? = nil,
        hidden: Bool = false,
        searchable: Bool = true,
        kind: VaultFolderKind = .files
    ) throws -> VaultFolder {
        try XCTUnwrap(store.createFolder(
            name: name,
            icon: "folder.fill",
            color: "indigo",
            kind: kind,
            isSuperHidden: hidden,
            searchable: searchable,
            parentID: parent?.id
        ))
    }

    /// Документы › Паспорта › Старые и рядом Работа
    private func makeTree() throws -> (documents: VaultFolder, passports: VaultFolder, old: VaultFolder, work: VaultFolder) {
        let documents = try folder("Документы")
        let passports = try folder("Паспорта", in: documents)
        let old = try folder("Старые", in: passports)
        let work = try folder("Работа")
        return (documents, passports, old, work)
    }

    private func refreshed(_ folder: VaultFolder) throws -> VaultFolder {
        try XCTUnwrap(store.folder(by: folder.id))
    }

    // MARK: - Модель и хранение

    func testVaultJSONWithoutParentDecodesAsTopLevel() throws {
        let vault = root.appendingPathComponent("Old", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let id = UUID()
        let legacy = """
        [{"id": "\(id.uuidString)", "name": "Документы", "icon": "folder.fill", "color": "indigo",
          "createdAt": 700000000, "kind": "files", "isSuperHidden": false, "sortOrder": "addedNewest", "searchable": true}]
        """
        try Data(legacy.utf8).write(to: vault.appendingPathComponent("vault.json"))

        let old = VaultStore(rootURL: vault)
        XCTAssertEqual(old.folders.map(\.id), [id])
        XCTAssertNil(old.folders[0].parentID, "папки до вложенности — на верхнем уровне")
        XCTAssertEqual(old.rootFolders.map(\.name), ["Документы"])
    }

    func testTreeHelpersAndPersistence() throws {
        let tree = try makeTree()
        XCTAssertEqual(store.rootFolders.map(\.name), ["Документы", "Работа"])
        XCTAssertEqual(store.children(of: tree.documents.id).map(\.name), ["Паспорта"])
        XCTAssertEqual(store.ancestors(of: tree.old).map(\.name), ["Документы", "Паспорта"])
        XCTAssertEqual(store.lineage(of: tree.old).map(\.name), ["Документы", "Паспорта", "Старые"])
        XCTAssertEqual(store.path(of: tree.old), "Документы / Паспорта / Старые")
        XCTAssertEqual(store.path(of: tree.work), "Работа")
        XCTAssertEqual(store.descendants(of: tree.documents.id).map(\.name), ["Паспорта", "Старые"])
        XCTAssertTrue(store.isDescendant(tree.old.id, of: tree.documents.id))
        XCTAssertFalse(store.isDescendant(tree.documents.id, of: tree.old.id))
        XCTAssertEqual(store.tree().map { "\($0.depth)\($0.folder.name)" }, ["0Документы", "1Паспорта", "2Старые", "0Работа"])

        // Файлы вложенной папки — в её собственном каталоге
        store.importData(Data("x".utf8), preferredName: "скан.txt", to: tree.old)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.rootURL.appendingPathComponent(tree.old.id.uuidString).appendingPathComponent("скан.txt").path
        ))

        let reopened = VaultStore(rootURL: store.rootURL)
        XCTAssertEqual(reopened.folder(by: tree.old.id)?.parentID, tree.passports.id, "родитель сохраняется в vault.json")
        XCTAssertEqual(reopened.path(of: try XCTUnwrap(reopened.folder(by: tree.old.id))), "Документы / Паспорта / Старые")
    }

    func testFeedCannotHoldFolders() throws {
        let documents = try folder("Документы")
        let feed = try folder("Заметки", in: documents, kind: .feed)
        XCTAssertEqual(feed.parentID, documents.id, "лента может лежать в обычной папке")
        XCTAssertNil(store.createFolder(name: "Внутри ленты", icon: "folder.fill", color: "indigo", parentID: feed.id))
        XCTAssertNil(store.createFolder(name: "В пропавшей", icon: "folder.fill", color: "indigo", parentID: UUID()))
        XCTAssertEqual(store.folders.count, 2)
    }

    func testDamagedTreeFallsBackToTopLevel() {
        let a = UUID(), b = UUID(), feed = UUID()
        func make(_ id: UUID, parent: UUID?, kind: VaultFolderKind = .files) -> VaultFolder {
            VaultFolder(id: id, name: id.uuidString, icon: "folder.fill", color: "indigo", createdAt: Date(), kind: kind, parentID: parent)
        }
        let repaired = VaultStore.repairedTree([
            make(a, parent: b), make(b, parent: a), // цикл
            make(feed, parent: nil, kind: .feed),
            make(UUID(), parent: feed), // внутри ленты
            make(UUID(), parent: UUID()), // родителя нет
        ])
        XCTAssertEqual(repaired.filter { $0.parentID == nil }.count, 4, "\(repaired.map(\.parentID))")
        XCTAssertEqual(repaired.first { $0.id == b }?.parentID, a, "цикл разрывается в одном месте")
    }

    // MARK: - Перенос и удаление

    func testMoveFolderRejectsCyclesAndFeeds() throws {
        let tree = try makeTree()
        let feed = try folder("Лента", kind: .feed)

        XCTAssertFalse(store.moveFolder(tree.documents.id, to: tree.documents.id), "в себя")
        XCTAssertFalse(store.moveFolder(tree.documents.id, to: tree.old.id), "в своё поддерево")
        XCTAssertFalse(store.moveFolder(tree.work.id, to: feed.id), "в ленту")
        XCTAssertFalse(store.moveFolder(tree.passports.id, to: tree.documents.id), "туда, где уже лежит")
        XCTAssertFalse(store.moveFolder(tree.work.id, to: nil), "уже на верхнем уровне")

        XCTAssertTrue(store.moveFolder(tree.passports.id, to: tree.work.id))
        XCTAssertEqual(store.path(of: try refreshed(tree.old)), "Работа / Паспорта / Старые", "поддерево едет вместе")
        XCTAssertTrue(store.moveFolder(tree.old.id, to: nil))
        XCTAssertEqual(store.rootFolders.map(\.name), ["Документы", "Старые", "Работа", "Лента"], "порядок — по созданию, как был")
        XCTAssertEqual(VaultStore(rootURL: store.rootURL).folder(by: tree.passports.id)?.parentID, tree.work.id)
    }

    func testDeleteFolderTakesWholeSubtreeAndTellsIndex() throws {
        let tree = try makeTree()
        store.importData(Data("a".utf8), preferredName: "a.txt", to: tree.documents)
        store.importData(Data("b".utf8), preferredName: "b.txt", to: tree.passports)
        store.importData(Data("c".utf8), preferredName: "c.txt", to: tree.old)
        let contents = store.subtreeContents(of: tree.documents)
        XCTAssertEqual(contents.files, 3)
        XCTAssertEqual(contents.folders, 2)
        XCTAssertEqual(FolderDeletion.message(for: tree.documents, in: store), "Вместе с ней удалятся 3 файла и 2 папки. Это не отменить.")

        var events: [VaultChange] = []
        store.onChange = { events.append($0) }
        store.deleteFolder(tree.documents)

        XCTAssertEqual(store.folders.map(\.name), ["Работа"])
        XCTAssertEqual(events, [tree.documents, tree.passports, tree.old].map { .folderExcluded($0.id) })
        for id in [tree.documents.id, tree.passports.id, tree.old.id] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.rootURL.appendingPathComponent(id.uuidString).path))
        }
        XCTAssertEqual(VaultStore(rootURL: store.rootURL).folders.map(\.name), ["Работа"])
    }

    func testStatsCountSubfoldersButNotHiddenOnes() throws {
        let documents = try folder("Документы")
        try folder("Паспорта", in: documents)
        try folder("Тайное", in: documents, hidden: true)
        store.importData(Data("x".utf8), preferredName: "x.txt", to: documents)

        XCTAssertEqual(store.stats(for: documents), FolderStats(count: 1, size: 1, subfolders: 1))
        XCTAssertEqual(store.stats(for: documents, includingHidden: true).subfolders, 2)
    }

    // MARK: - Наследуемая скрытость и поиск

    func testSuperHiddenFolderHidesItsSubtree() throws {
        let secret = try folder("Тайное", hidden: true)
        let inner = try folder("Паспорта", in: secret)
        let deeper = try folder("Старые", in: inner)
        let open = try folder("Работа")
        store.importData(Data("x".utf8), preferredName: "тайный.txt", to: deeper)
        store.importData(Data("y".utf8), preferredName: "рабочий.txt", to: open)

        XCTAssertFalse(inner.isSuperHidden, "сама вложенная не помечена")
        XCTAssertTrue(store.isHidden(deeper))
        XCTAssertFalse(store.isIndexable(deeper))
        XCTAssertTrue(deeper.isIndexable, "собственный признак — без родителей")
        XCTAssertEqual(store.recentFiles().map(\.file.name), ["рабочий.txt"])
        XCTAssertEqual(Set(store.recentFiles(includingSuperHidden: true).map(\.file.name)), ["тайный.txt", "рабочий.txt"])
        XCTAssertEqual(store.tree().map(\.folder.name), ["Работа"], "лист выбора не выдаёт скрытое поддерево")
        XCTAssertEqual(store.tree(includingHidden: true).count, 4)
    }

    func testHidingOrUnsearchingParentPurgesDescendantsFromIndex() throws {
        let tree = try makeTree()
        var events: [VaultChange] = []
        store.onChange = { events.append($0) }

        store.setSuperHidden(true, for: tree.documents.id)
        XCTAssertEqual(events, [tree.documents, tree.passports, tree.old].map { .folderExcluded($0.id) })

        events = []
        store.setSuperHidden(false, for: tree.documents.id)
        XCTAssertEqual(events, [], "вернувшееся подхватит сверка")

        store.setSearchable(false, for: tree.passports.id)
        XCTAssertEqual(events, [tree.passports, tree.old].map { .folderExcluded($0.id) })
        XCTAssertTrue(store.isIndexable(try refreshed(tree.documents)), "папка выше не затронута")

        // Перенос в папку вне поиска стирает и перенесённое поддерево
        events = []
        let inside = try folder("Счета", in: tree.work)
        store.moveFolder(tree.work.id, to: tree.passports.id)
        XCTAssertEqual(events, [tree.work, inside].map { .folderExcluded($0.id) })

        // Правка папки через редактор — тот же путь
        events = []
        store.setSearchable(true, for: tree.passports.id)
        store.updateFolder(id: tree.documents.id, name: "Документы", icon: "folder.fill", color: "indigo", isSuperHidden: false, searchable: false)
        XCTAssertEqual(events, [tree.documents, tree.passports, tree.old, tree.work, inside].map { .folderExcluded($0.id) })
    }

    func testSearchSkipsSubtreeOfHiddenOrUnsearchableParent() async throws {
        let search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil })
        let documents = try folder("Документы")
        let passports = try folder("Паспорта", in: documents)
        store.importData(Data("Справка о доходах".utf8), preferredName: "доходы.txt", to: passports)
        search.reconcile()
        await search.waitUntilIdle()
        let found = await search.search("справка").map(\.file.name)
        XCTAssertEqual(found, ["доходы.txt"], "вложенная папка ищется")
        let indexed = await search.indexedFiles()
        XCTAssertEqual(indexed.map(\.folderID), [passports.id], "folder_id в индексе — UUID самой папки")

        store.setSuperHidden(true, for: documents.id)
        await search.waitUntilIdle()
        let afterHiding = await search.indexedFiles()
        XCTAssertEqual(afterHiding, [], "текст вложенной папки стёрт в момент скрытия родителя")
        XCTAssertEqual(search.searchableFolders, [])

        store.setSuperHidden(false, for: documents.id)
        store.setSearchable(false, for: documents.id)
        search.reconcile()
        await search.waitUntilIdle()
        let offline = await search.search("справка")
        XCTAssertEqual(offline.count, 0)
        XCTAssertEqual(search.searchableFolders, [])

        store.setSearchable(true, for: documents.id)
        search.reconcile()
        await search.waitUntilIdle()
        let back = await search.search("справка").map { search.path(of: $0.folder) }
        XCTAssertEqual(back, ["Документы / Паспорта"])
    }

    // MARK: - Чат

    func testListFoldersShowsTreeWithoutHiddenBranches() async throws {
        let search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil })
        let documents = try folder("Документы")
        let passports = try folder("Паспорта", in: documents)
        let secret = try folder("Тайное", hidden: true)
        try folder("Под тайным", in: secret)
        let offline = try folder("Без поиска", searchable: false)
        try folder("Под выключенным", in: offline)

        var cards: [ChatCard] = []
        let result = await CloudChatTools(search: search, proposals: nil).run("list_folders", arguments: [:], cards: &cards)
        let folders = try XCTUnwrap(result["folders"]?.array)
        XCTAssertEqual(folders.compactMap { $0["path"]?.string }, ["Документы", "Документы / Паспорта"])
        XCTAssertEqual(folders.first?["parent_id"], .null)
        XCTAssertEqual(folders.last?["parent_id"]?.string, documents.id.uuidString)
        XCTAssertEqual(folders.last?["id"]?.string, passports.id.uuidString)
        let text = String(data: result.data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("Тайное") || text.contains("Под тайным") || text.contains("Под выключенным"), text)
    }

    func testProposalCreatesFolderInsideParent() async throws {
        let inbox = ChatAttachmentInbox(directory: root.appendingPathComponent("Inbox", isDirectory: true))
        let documents = try folder("Документы")
        let proposal = try FileProposalBuilder.make(from: JSONValue(parsing: """
            {"actions": [{"action": "create_folder", "name": "Чеки", "parent_folder_id": "\(documents.id.uuidString)"}]}
            """), store: store, inbox: inbox)
        XCTAssertEqual(proposal.actions, [.createFolder(name: "Чеки")])
        XCTAssertEqual(proposal.parent(ofNewFolder: "Чеки"), documents.id)
        XCTAssertEqual(proposal.summary, "Создать папку «Чеки» в «Документы»")
        let card = try JSONDecoder().decode(FileProposal.self, from: JSONEncoder().encode(proposal))
        XCTAssertEqual(card, proposal, "родитель переживает карточку в переписке")

        let text = try await FileProposalExecutor.apply(proposal, store: store, inbox: inbox)
        let checks = try XCTUnwrap(store.folders.first { $0.name == "Чеки" })
        XCTAssertEqual(checks.parentID, documents.id)
        XCTAssertEqual(text, "Создал папку «Документы / Чеки».")

        // Повтор находит уже созданную внутри, а не заводит двойник: делать нечего
        let again = FileProposal(summary: "", actions: [.createFolder(name: "чеки")], newFolderParents: ["чеки": documents.id])
        do {
            _ = try await FileProposalExecutor.apply(again, store: store, inbox: inbox)
            XCTFail("папка уже есть — ничего не сделано")
        } catch {
            XCTAssertEqual(error as? FileProposalError, .nothingDone([]))
        }
        XCTAssertEqual(store.folders.filter { $0.name.lowercased() == "чеки" }.count, 1)
    }

    func testProposalParentMustBeVisibleRegularFolder() throws {
        let inbox = ChatAttachmentInbox(directory: root.appendingPathComponent("Inbox", isDirectory: true))
        let secret = try folder("Тайное", hidden: true)
        let inner = try folder("Внутри", in: secret)
        let feed = try folder("Лента", kind: .feed)
        for parent in [secret, inner] {
            XCTAssertThrowsError(try FileProposalBuilder.make(from: JSONValue(parsing: """
                {"actions": [{"action": "create_folder", "name": "Новая", "parent_folder_id": "\(parent.id.uuidString)"}]}
                """), store: store, inbox: inbox)) { error in
                XCTAssertEqual(error as? FileProposalError, .unknownFolder(parent.id.uuidString), "скрытое поддерево для модели не существует")
            }
        }
        XCTAssertThrowsError(try FileProposalBuilder.make(from: JSONValue(parsing: """
            {"actions": [{"action": "create_folder", "name": "Новая", "parent_folder_id": "\(feed.id.uuidString)"}]}
            """), store: store, inbox: inbox)) { error in
            XCTAssertEqual(error as? FileProposalError, .feedParent("Лента"))
        }
    }

    // MARK: - Резервная копия

    func testBackupRoundTripKeepsTree() throws {
        let tree = try makeTree()
        store.importData(Data("c".utf8), preferredName: "c.txt", to: tree.old)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let key = Data(repeating: 3, count: 32)
        let engine = EncryptedBackupEngine()

        _ = try engine.createBackup(vaultURL: store.rootURL, backupRootURL: backups, keyData: key)
        try FileManager.default.removeItem(at: store.rootURL)
        _ = try engine.restoreLatest(backupRootURL: backups, vaultURL: store.rootURL, keyData: key)

        let restored = VaultStore(rootURL: store.rootURL)
        let old = try XCTUnwrap(restored.folder(by: tree.old.id))
        XCTAssertEqual(old.parentID, tree.passports.id)
        XCTAssertEqual(restored.path(of: old), "Документы / Паспорта / Старые")
        XCTAssertEqual(restored.files(in: old).map(\.name), ["c.txt"])
    }
}
