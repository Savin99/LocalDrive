import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import LocalDrive

// Вложения чата и предложения разложить файлы. Владелец 12.10.2026: «можно в
// чат кидать, и она будет предлагать, куда положить, сортировать». Модель
// составляет предложение, человек жмёт «Выполнить» — до этого хранилище не
// меняется, а суперскрытые папки модели недоступны вовсе
@MainActor
final class ChatAttachmentsTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var inbox: ChatAttachmentInbox!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDriveAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root.appendingPathComponent("Vault"))
        inbox = ChatAttachmentInbox(directory: root.appendingPathComponent("Inbox", isDirectory: true))
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        inbox = nil
        store = nil
        root = nil
    }

    // MARK: - Данные

    private func source(_ name: String, text: String = "текст") throws -> URL {
        let folder = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func image(_ name: String, size: CGSize) throws -> URL {
        let folder = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func pdf(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            ("Справка" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @discardableResult
    private func folder(_ name: String, hidden: Bool = false, searchable: Bool = true, kind: VaultFolderKind = .files) throws -> VaultFolder {
        store.createFolder(name: name, icon: "folder.fill", color: "indigo", kind: kind, isSuperHidden: hidden, searchable: searchable)
        return try XCTUnwrap(store.folders.last)
    }

    private func attach(_ name: String, text: String = "текст") async throws -> ChatAttachment {
        let added = await inbox.add(urls: [try source(name, text: text)])
        return try XCTUnwrap(added.first)
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONValue(parsing: text)
    }

    // MARK: - Вложения

    func testInboxCopiesFileAndCleansUp() async throws {
        let original = try source("Справка.txt")
        let added = await inbox.add(urls: [original])
        let item = try XCTUnwrap(added.first)
        XCTAssertTrue(item.id.hasPrefix("a"))
        XCTAssertEqual(item.name, "Справка.txt")
        XCTAssertEqual(item.contentType, .plainText)
        XCTAssertEqual(item.byteCount, Int64("текст".utf8.count))
        XCTAssertTrue(item.url.path.hasPrefix(inbox.directory.path), "копия — во временной папке вложений")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "оригинал не трогаем")
        XCTAssertEqual(inbox.items, [item])

        inbox.remove(item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertEqual(inbox.names[item.id], "Справка.txt", "имя остаётся для карточки в переписке")

        let again = try await attach("Ещё.txt")
        inbox.clear()
        XCTAssertTrue(inbox.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.url.path))
    }

    func testLeftoversFromPreviousLaunchAreDeleted() throws {
        let directory = root.appendingPathComponent("Leftovers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("a1"), withIntermediateDirectories: true)
        let stray = directory.appendingPathComponent("a1/скан.jpg")
        try Data("x".utf8).write(to: stray)
        _ = ChatAttachmentInbox(directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        let excluded = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "временные копии не попадают в резервную копию iPhone")
    }

    func testIDsAreUniqueAcrossInboxes() async throws {
        let first = try await attach("a.txt")
        let other = ChatAttachmentInbox(directory: root.appendingPathComponent("Other", isDirectory: true))
        let others = await other.add(urls: [try source("b.txt")])
        let second = try XCTUnwrap(others.first)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testModelImageIsDownscaledJPEG() async throws {
        let photos = await inbox.add(urls: [try image("скан.png", size: CGSize(width: 3000, height: 1200))])
        let photo = try XCTUnwrap(photos.first)
        let jpeg = await inbox.modelImage(photo.id)
        let data = try XCTUnwrap(jpeg)
        let decoded = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(max(decoded.width, decoded.height), 2048)
        XCTAssertEqual(data.prefix(2), Data([0xFF, 0xD8]), "JPEG")

        let pages = await inbox.add(urls: [try pdf("справка.pdf")])
        let page = try XCTUnwrap(pages.first)
        let pageJPEG = await inbox.modelImage(page.id)
        let rendered = try XCTUnwrap(pageJPEG)
        XCTAssertLessThanOrEqual(try XCTUnwrap(UIImage(data: rendered)?.cgImage).height, 2048)

        let text = try await attach("заметка.txt")
        let none = await inbox.modelImage(text.id)
        XCTAssertNil(none)
    }

    // MARK: - Разбор предложения модели

    func testSaveIntoExistingFolder() async throws {
        let passports = try folder("Паспорта")
        let scan = try await attach("scan.jpeg")
        let proposal = try FileProposalBuilder.make(from: json("""
            {"summary": "Паспорт — в «Паспорта»", "actions": [
              {"type": "save_attachment", "attachment_id": "\(scan.id)", "folder_id": "\(passports.id.uuidString)", "name": "Паспорт.jpg"}]}
            """), store: store, inbox: inbox)
        XCTAssertEqual(proposal.summary, "Паспорт — в «Паспорта»")
        XCTAssertEqual(proposal.actions, [.saveAttachment(attachmentID: scan.id, folder: .existing(passports.id), name: "Паспорт.jpeg")],
                       "расширение — настоящее, «.jpg» модели снимается")
    }

    func testHiddenAndUnsearchableFoldersAreUnknown() async throws {
        let hidden = try folder("Секрет", hidden: true)
        let offline = try folder("Без поиска", searchable: false)
        let scan = try await attach("scan.jpeg")
        for target in [hidden, offline] {
            XCTAssertThrowsError(try FileProposalBuilder.make(from: json("""
                {"actions": [{"type": "save_attachment", "attachment_id": "\(scan.id)", "folder_id": "\(target.id.uuidString)"}]}
                """), store: store, inbox: inbox)) { error in
                XCTAssertEqual(error as? FileProposalError, .unknownFolder(target.id.uuidString))
            }
        }
        // По имени суперскрытая папка тоже не находится: будет новая видимая
        let byName = try FileProposalBuilder.make(from: json("""
            {"actions": [{"type": "save_attachment", "attachment_id": "\(scan.id)", "new_folder_name": "секрет"}]}
            """), store: store, inbox: inbox)
        XCTAssertEqual(byName.actions, [.saveAttachment(attachmentID: scan.id, folder: .new(name: "секрет"), name: nil)])
    }

    func testNewFolderNameReusesVisibleFolder() async throws {
        let work = try folder("Работа")
        let scan = try await attach("scan.jpeg")
        let proposal = try FileProposalBuilder.make(from: json("""
            {"actions": [{"save_attachment": {"attachmentId": "\(scan.id)", "newFolderName": "работа"}}]}
            """), store: store, inbox: inbox)
        XCTAssertEqual(proposal.actions, [.saveAttachment(attachmentID: scan.id, folder: .existing(work.id), name: nil)])
        XCTAssertEqual(proposal.summary, "Положить 1 файл в «Работа»", "подпись, если модель её не дала")
    }

    func testMissingAttachmentAndFilesAreRejected() async throws {
        let work = try folder("Работа")
        let archive = try folder("Архив")
        XCTAssertThrowsError(try FileProposalBuilder.make(from: json("""
            {"actions": [{"type": "save_attachment", "attachment_id": "a999", "folder_id": "\(work.id.uuidString)"}]}
            """), store: store, inbox: inbox)) { XCTAssertEqual($0 as? FileProposalError, .missingAttachment("a999")) }

        XCTAssertThrowsError(try FileProposalBuilder.make(from: json("""
            {"actions": [{"type": "move_files", "files": [{"folder_id": "\(work.id.uuidString)", "name": "нет.pdf"}], "folder_id": "\(archive.id.uuidString)"}]}
            """), store: store, inbox: inbox)) { XCTAssertEqual($0 as? FileProposalError, .missingFile("нет.pdf")) }

        store.importData(Data("x".utf8), preferredName: "договор.pdf", to: work)
        XCTAssertThrowsError(try FileProposalBuilder.make(from: json("""
            {"actions": [{"type": "move_files", "files": [{"folder_id": "\(work.id.uuidString)", "name": "договор.pdf"}], "folder_id": "\(work.id.uuidString)"}]}
            """), store: store, inbox: inbox)) { XCTAssertEqual($0 as? FileProposalError, .sameFolder) }

        let feed = try folder("Лента", kind: .feed)
        store.importData(Data("x".utf8), preferredName: "фото.jpg", to: feed)
        XCTAssertThrowsError(try FileProposalBuilder.make(from: json("""
            {"actions": [{"type": "move_files", "files": [{"folder_id": "\(feed.id.uuidString)", "name": "фото.jpg"}], "folder_id": "\(work.id.uuidString)"}]}
            """), store: store, inbox: inbox)) { XCTAssertEqual($0 as? FileProposalError, .fromFeed("Лента")) }

        XCTAssertThrowsError(try FileProposalBuilder.make(from: json(#"{"actions": [{"type": "delete_everything"}]}"#), store: store, inbox: inbox)) {
            XCTAssertEqual($0 as? FileProposalError, .unknownAction("delete_everything"))
        }
        XCTAssertThrowsError(try FileProposalBuilder.make(from: json(#"{"actions": []}"#), store: store, inbox: inbox)) {
            XCTAssertEqual($0 as? FileProposalError, .noActions)
        }
    }

    func testNamesAreSanitized() async throws {
        let work = try folder("Работа")
        store.importData(Data("x".utf8), preferredName: "old.txt", to: work)
        let proposal = try FileProposalBuilder.make(from: json("""
            {"actions": [
              {"type": "renameFile", "file": {"folder_id": "\(work.id.uuidString)", "name": "old.txt"}, "new_name": "../Отчёт v1.2.txt"},
              {"type": "create_folder", "name": "  /Счета:2026  "}]}
            """), store: store, inbox: inbox)
        guard case .renameFile(_, let newName) = proposal.actions[0], case .createFolder(let folderName) = proposal.actions[1] else {
            return XCTFail("\(proposal.actions)")
        }
        XCTAssertFalse(newName.contains("/"))
        XCTAssertFalse(newName.hasPrefix("."))
        XCTAssertTrue(newName.hasSuffix("Отчёт v1.2"), "точка в имени — не расширение: \(newName)")
        XCTAssertEqual(folderName, "-Счета-2026")
    }

    // MARK: - Выполнение

    func testExecutorSavesIntoExistingAndNewFolders() async throws {
        let passports = try folder("Паспорта")
        let first = try await attach("scan.jpeg")
        let second = try await attach("чек.txt")
        let proposal = FileProposal(summary: "Разложить", actions: [
            .saveAttachment(attachmentID: first.id, folder: .existing(passports.id), name: "Паспорт РФ — Иванов И. И.jpeg"),
            .saveAttachment(attachmentID: second.id, folder: .new(name: "Чеки"), name: nil),
        ])
        let text = try await FileProposalExecutor.apply(proposal, store: store, inbox: inbox)
        XCTAssertEqual(store.files(in: passports).map(\.name), ["Паспорт РФ — Иванов И. И.jpeg"])
        let checks = try XCTUnwrap(store.folders.first { $0.name == "Чеки" })
        XCTAssertTrue(checks.isIndexable, "новая папка — обычная и доступная для поиска")
        XCTAssertEqual(store.files(in: checks).map(\.name), ["чек.txt"])
        XCTAssertTrue(inbox.items.isEmpty, "сохранённые вложения уходят из ленты вложений")
        XCTAssertEqual(inbox.savedFolders[first.id], "Паспорта", "карточка вложения скажет, куда его положили")
        XCTAssertEqual(text, "Создал папку «Чеки», сохранил 1 файл в «Паспорта», сохранил 1 файл в «Чеки».")
    }

    func testExecutorMovesAndRenamesWithIndexEvents() async throws {
        let inboxFolder = try folder("Разное")
        let work = try folder("Работа")
        store.importData(Data("x".utf8), preferredName: "договор.pdf", to: inboxFolder)
        store.importData(Data("y".utf8), preferredName: "IMG_1.jpg", to: work)
        var events: [VaultChange] = []
        store.onChange = { events.append($0) }

        let proposal = FileProposal(summary: "Порядок", actions: [
            .moveFiles(files: [FileRef(folderID: inboxFolder.id, name: "договор.pdf")], folder: .existing(work.id)),
            .renameFile(file: FileRef(folderID: work.id, name: "IMG_1.jpg"), newName: "Счёт"),
        ])
        _ = try await FileProposalExecutor.apply(proposal, store: store, inbox: inbox)
        XCTAssertEqual(Set(store.files(in: work).map(\.name)), ["договор.pdf", "Счёт.jpg"])
        XCTAssertTrue(store.files(in: inboxFolder).isEmpty)
        XCTAssertTrue(events.contains(.fileMoved(fromFolder: inboxFolder.id, name: "договор.pdf", toFolder: work.id, newName: "договор.pdf")))
        XCTAssertTrue(events.contains(.fileRenamed(folder: work.id, from: "IMG_1.jpg", to: "Счёт.jpg")))
    }

    func testSavingIntoFeedAddsBlock() async throws {
        let feed = try folder("Ремонт", kind: .feed)
        let note = try await attach("смета.txt")
        _ = try await FileProposalExecutor.apply(
            FileProposal(summary: "В ленту", actions: [.saveAttachment(attachmentID: note.id, folder: .existing(feed.id), name: nil)]),
            store: store, inbox: inbox
        )
        XCTAssertTrue(store.feedBlocks(in: feed).contains { $0.fileNames == ["смета.txt"] }, "в ленте файл виден только блоком")
    }

    func testNothingDoneThrows() async throws {
        let work = try folder("Работа")
        do {
            _ = try await FileProposalExecutor.apply(
                FileProposal(summary: "", actions: [.saveAttachment(attachmentID: "a999", folder: .existing(work.id), name: nil)]),
                store: store, inbox: inbox
            )
            XCTFail("ждали ошибку")
        } catch {
            XCTAssertEqual(error as? FileProposalError, .nothingDone(["a999"]))
        }
    }

    func testLedgerRunsOnceAndHonoursOtherFolder() async throws {
        let first = try folder("Первая")
        let second = try folder("Вторая")
        let note = try await attach("заметка.txt")
        let proposal = FileProposal(summary: "", actions: [.saveAttachment(attachmentID: note.id, folder: .existing(first.id), name: nil)])
        let ledger = FileProposalLedger()
        ledger.retarget(proposal.id, to: second.id)
        await ledger.run(proposal, store: store, inbox: inbox)
        await ledger.run(proposal, store: store, inbox: inbox)
        XCTAssertEqual(store.files(in: second).map(\.name), ["заметка.txt"], "«Другая папка…» заменила предложенную")
        XCTAssertTrue(store.files(in: first).isEmpty)
        guard case .done = ledger.status(of: proposal.id) else { return XCTFail("\(ledger.status(of: proposal.id))") }

        let cancelled = FileProposal(summary: "", actions: [.createFolder(name: "Не нужна")])
        ledger.cancel(cancelled.id)
        await ledger.run(cancelled, store: store, inbox: inbox)
        XCTAssertFalse(store.folders.contains { $0.name == "Не нужна" }, "отменённое не выполняется")
    }

    // MARK: - Подсказка без облака

    private let passportText = """
        ПАСПОРТ
        Фамилия САВИН
        Имя ИЛЬЯ
        Отчество АНДРЕЕВИЧ
        PNRUSSAVIN<<IL98<ANDREEVI3<<<<<<<<<<<<<<<<<<
        4601234561RUS9001011M<<<<<<<1100620770120<34
        """

    func testAdvisorPutsPassportWherePassportsAre() async throws {
        let search = SearchService(store: store, databaseURL: nil)
        let passports = try folder("Паспорта")
        try folder("Работа")
        store.importData(Data(passportText.utf8), preferredName: "старый.txt", to: passports)
        search.reconcile()
        await search.waitUntilIdle()

        let scan = try await attach("scan.txt", text: passportText)
        let proposal = await FilePlacementAdvisor.suggest(for: scan, store: store, search: search)
        XCTAssertEqual(proposal.actions, [.saveAttachment(attachmentID: scan.id, folder: .existing(passports.id), name: "Паспорт РФ — Савин И. А.txt")])
        XCTAssertEqual(proposal.summary, "Похоже на паспорт РФ")
    }

    func testAdvisorMatchesFolderNameOrFallsBackToInbox() async throws {
        let search = SearchService(store: store, databaseURL: nil)
        let contracts = try folder("Договоры")
        try folder("Договоры старые", hidden: true)
        let lease = try await attach("Договор аренды.txt", text: "ДОГОВОР АРЕНДЫ КВАРТИРЫ")
        let byName = await FilePlacementAdvisor.suggest(for: lease, store: store, search: search)
        XCTAssertEqual(byName.actions, [.saveAttachment(attachmentID: lease.id, folder: .existing(contracts.id), name: nil)])

        let note = try await attach("заметка.txt", text: "купить молоко")
        let fallback = await FilePlacementAdvisor.suggest(for: note, store: store, search: search)
        XCTAssertEqual(fallback.actions, [.saveAttachment(attachmentID: note.id, folder: .new(name: "Входящие"), name: nil)])

        let reply = await FilePlacementAdvisor(store: store, search: search).localReply(for: [lease, note])
        guard case .proposal(let combined) = reply.cards.first else { return XCTFail("\(reply.cards)") }
        XCTAssertEqual(combined.actions.count, 2)
    }

    func testAdvisorNeverSuggestsHiddenFolder() async throws {
        let search = SearchService(store: store, databaseURL: nil)
        try folder("Договоры", hidden: true)
        let lease = try await attach("Договор аренды.txt", text: "ДОГОВОР АРЕНДЫ")
        let proposal = await FilePlacementAdvisor.suggest(for: lease, store: store, search: search)
        XCTAssertEqual(proposal.actions, [.saveAttachment(attachmentID: lease.id, folder: .new(name: "Входящие"), name: nil)])
    }

    // MARK: - Сессия чата

    private func waitForAnswer(_ session: ChatSession) async throws {
        var attempts = 0
        while session.isAnswering, attempts < 500 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        XCTAssertFalse(session.isAnswering, "ответ не пришёл за 5 секунд")
    }

    func testSessionWithoutCloudProposesWhereToPut() async throws {
        let search = SearchService(store: store, databaseURL: nil)
        let contracts = try folder("Договоры")
        let session = ChatSession(search: search, inbox: inbox)
        session.useFiles(store)
        let lease = try await attach("Договор аренды.txt", text: "ДОГОВОР АРЕНДЫ")
        XCTAssertEqual(inbox.draft, [lease], "брошенный файл виден над полем ввода")

        session.send("", attaching: inbox.takeDraft())
        XCTAssertTrue(inbox.draft.isEmpty, "отправленное уходит с поля ввода")
        XCTAssertEqual(inbox.items, [lease], "но файл ждёт решения в ящике")
        try await waitForAnswer(session)

        XCTAssertEqual(session.messages.first?.attachments, [lease.id])
        guard case .proposal(let proposal) = session.messages.last?.cards.first?.content else {
            return XCTFail("ждали предложение, пришло \(String(describing: session.messages.last?.cards.map(\.card)))")
        }
        XCTAssertEqual(proposal.actions, [.saveAttachment(attachmentID: lease.id, folder: .existing(contracts.id), name: nil)])
        XCTAssertTrue(store.files(in: contracts).isEmpty, "до «Выполнить» ничего не сохранено")
    }

    func testNewChatClearsAttachments() async throws {
        let session = ChatSession(search: SearchService(store: store, databaseURL: nil), inbox: inbox)
        let note = try await attach("заметка.txt")
        session.reset()
        XCTAssertTrue(inbox.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.url.path), "временная копия стёрта")
    }

    func testToolArgumentsBecomeProposalCard() async throws {
        let session = ChatSession(search: SearchService(store: store, databaseURL: nil), inbox: inbox)
        XCTAssertNil(session.proposals, "без хранилища инструмент недоступен")
        session.useFiles(store)
        let passports = try folder("Паспорта")
        let scan = try await attach("scan.jpeg")
        let arguments = #"{"summary": "Паспорт", "actions": [{"action": "save_attachment", "attachment_id": "\#(scan.id)", "folder_id": "\#(passports.id.uuidString)"}]}"#
        let card = try XCTUnwrap(session.proposals)(Data(arguments.utf8))
        guard case .proposal(let proposal) = card else { return XCTFail("\(card)") }
        XCTAssertEqual(proposal.actions, [.saveAttachment(attachmentID: scan.id, folder: .existing(passports.id), name: nil)])
    }

    // MARK: - Карточки

    func testCardsRoundTripThroughJSON() throws {
        let proposal = FileProposal(summary: "Разложить", actions: [
            .saveAttachment(attachmentID: "a1", folder: .new(name: "Входящие"), name: "Паспорт.jpg"),
            .moveFiles(files: [FileRef(folderID: UUID(), name: "a.pdf")], folder: .existing(UUID())),
            .renameFile(file: FileRef(folderID: UUID(), name: "b.txt"), newName: "Б"),
            .createFolder(name: "Счета"),
        ])
        let cards: [ChatCard] = [.proposal(proposal), .attachment(id: "a1")]
        let data = try JSONEncoder().encode(ChatCardsPayload(text: nil, cards: cards))
        XCTAssertEqual(try JSONDecoder().decode(ChatCardsPayload.self, from: data).cards, cards)
        XCTAssertEqual(cards.flatMap(\.documentIDs), [], "у вложений и предложений нет документов индекса")
    }
}
