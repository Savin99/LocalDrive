import XCTest
@testable import LocalDrive

final class VaultStoreTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDriveTests-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        store = nil
        root = nil
    }

    // MARK: - Порядок файлов

    /// Три файла с известными датами добавления, размерами и датами съёмки
    private func makeSortingFolder() throws -> VaultFolder {
        store.createFolder(name: "Порядок", icon: "folder.fill", color: "indigo")
        let folder = try XCTUnwrap(store.folders.first)
        let dir = store.folderURL(folder)
        let fm = FileManager.default

        // b добавлен раньше всех, c — позже, a — последним
        let plan: [(name: String, added: Date, size: Int)] = [
            ("b.bin", Date(timeIntervalSince1970: 1_000), 300),
            ("c.bin", Date(timeIntervalSince1970: 2_000), 100),
            ("a.bin", Date(timeIntervalSince1970: 3_000), 200),
        ]
        for item in plan {
            let url = dir.appendingPathComponent(item.name)
            try Data(repeating: 0, count: item.size).write(to: url)
            try fm.setAttributes([.creationDate: item.added], ofItemAtPath: url.path)
        }
        // Даты съёмки идут в обратном порядке к добавлению
        store.setContentDates([
            "a.bin": Date(timeIntervalSince1970: 10),
            "b.bin": Date(timeIntervalSince1970: 30),
            "c.bin": Date(timeIntervalSince1970: 20),
        ], in: folder)
        return folder
    }

    func testSortOrdersArrangeFilesAsExpected() throws {
        let folder = try makeSortingFolder()
        func names(_ order: FileSortOrder) -> [String] {
            store.files(in: folder, sortedBy: order).map(\.name)
        }

        XCTAssertEqual(names(.addedNewest), ["a.bin", "c.bin", "b.bin"])
        XCTAssertEqual(names(.addedOldest), ["b.bin", "c.bin", "a.bin"])
        XCTAssertEqual(names(.dateNewest), ["b.bin", "c.bin", "a.bin"])
        XCTAssertEqual(names(.dateOldest), ["a.bin", "c.bin", "b.bin"])
        XCTAssertEqual(names(.nameAsc), ["a.bin", "b.bin", "c.bin"])
        XCTAssertEqual(names(.sizeDesc), ["b.bin", "a.bin", "c.bin"])
    }

    /// Перестановки не должны сбиваться при перезапуске приложения
    func testManualOrderSurvivesNewStoreInstance() throws {
        let folder = try makeSortingFolder()
        store.setFileOrder(["c.bin", "a.bin", "b.bin"], in: folder)
        store.setSortOrder(.manual, for: folder)

        let reopened = VaultStore(rootURL: root)
        let sameFolder = try XCTUnwrap(reopened.folders.first)
        XCTAssertEqual(sameFolder.sortOrder, .manual, "Режим сортировки не сохранился")
        XCTAssertEqual(
            reopened.files(in: sameFolder, sortedBy: .manual).map(\.name),
            ["c.bin", "a.bin", "b.bin"],
            "Ручной порядок сбился"
        )
    }

    func testFilesAddedAfterReorderGoToTheEnd() throws {
        let folder = try makeSortingFolder()
        store.setFileOrder(["c.bin", "a.bin", "b.bin"], in: folder)

        let url = store.folderURL(folder).appendingPathComponent("d.bin")
        try Data(repeating: 1, count: 10).write(to: url)

        XCTAssertEqual(
            store.files(in: folder, sortedBy: .manual).map(\.name),
            ["c.bin", "a.bin", "b.bin", "d.bin"]
        )
    }

    func testOldFolderMetadataDefaultsToFilesKind() throws {
        let json = """
        {
          "id": "62D95803-F7B9-40B9-A948-60786D3F80CE",
          "name": "Документы",
          "icon": "folder.fill",
          "color": "indigo",
          "createdAt": 100
        }
        """

        let folder = try JSONDecoder().decode(VaultFolder.self, from: Data(json.utf8))

        XCTAssertEqual(folder.kind, .files)
        XCTAssertFalse(folder.isSuperHidden)
    }

    func testSuperHiddenFlagPersistsAndCanBeChanged() throws {
        store.createFolder(
            name: "Секреты",
            icon: "eye.slash.fill",
            color: "indigo",
            isSuperHidden: true
        )

        var reloaded = VaultStore(rootURL: root)
        let hidden = try XCTUnwrap(reloaded.folders.first)
        XCTAssertTrue(hidden.isSuperHidden)

        reloaded.updateFolder(
            id: hidden.id,
            name: hidden.name,
            icon: hidden.icon,
            color: hidden.color,
            isSuperHidden: false
        )

        reloaded = VaultStore(rootURL: root)
        XCTAssertFalse(try XCTUnwrap(reloaded.folders.first).isSuperHidden)
    }

    func testRecentFilesDoNotRevealSuperHiddenFoldersByDefault() throws {
        store.createFolder(name: "Обычная", icon: "folder.fill", color: "indigo")
        store.createFolder(
            name: "Секреты",
            icon: "eye.slash.fill",
            color: "pink",
            isSuperHidden: true
        )
        let regular = try XCTUnwrap(store.folders.first(where: { !$0.isSuperHidden }))
        let hidden = try XCTUnwrap(store.folders.first(where: \.isSuperHidden))
        store.importData(Data("public".utf8), preferredName: "public.txt", to: regular)
        store.importData(Data("secret".utf8), preferredName: "secret.txt", to: hidden)

        XCTAssertEqual(store.recentFiles().map(\.file.name), ["public.txt"])
        XCTAssertEqual(Set(store.recentFiles(includingSuperHidden: true).map(\.file.name)), ["public.txt", "secret.txt"])
    }

    func testTextBlocksPersistAndReorder() throws {
        let folder = makeFeedFolder()
        store.addTextBlock("Первый", to: folder)
        store.addTextBlock("Второй", to: folder)
        store.addTextBlock("Третий", to: folder)

        let initial = store.feedBlocks(in: folder)
        XCTAssertEqual(initial.compactMap(\.text), ["Первый", "Второй", "Третий"])

        // Вверх: блок встаёт ровно на позицию линии вставки
        store.moveFeedBlock(id: initial[2].id, toIndex: 0, in: folder)
        XCTAssertEqual(store.feedBlocks(in: folder).compactMap(\.text), ["Третий", "Первый", "Второй"])
    }

    // Движение вниз раньше клало блок ПОСЛЕ цели: индекс не корректировался
    // после удаления источника
    func testTextBlockMovesDownToExactInsertionPoint() throws {
        let folder = makeFeedFolder()
        store.addTextBlock("A", to: folder)
        store.addTextBlock("B", to: folder)
        store.addTextBlock("C", to: folder)
        let initial = store.feedBlocks(in: folder)

        // Линия вставки между B и C — индекс 2 в исходном массиве
        store.moveFeedBlock(id: initial[0].id, toIndex: 2, in: folder)

        XCTAssertEqual(store.feedBlocks(in: folder).compactMap(\.text), ["B", "A", "C"])
    }

    func testMoveFeedBlockByOffsetWorksBothDirections() throws {
        let folder = makeFeedFolder()
        store.addTextBlock("A", to: folder)
        store.addTextBlock("B", to: folder)
        store.addTextBlock("C", to: folder)

        let first = try XCTUnwrap(store.feedBlocks(in: folder).first)
        store.moveFeedBlock(id: first.id, offset: 1, in: folder)
        XCTAssertEqual(store.feedBlocks(in: folder).compactMap(\.text), ["B", "A", "C"])

        store.moveFeedBlock(id: first.id, offset: -1, in: folder)
        XCTAssertEqual(store.feedBlocks(in: folder).compactMap(\.text), ["A", "B", "C"])
    }

    func testGroupMoveKeepsRelativeOrder() throws {
        let folder = makeFeedFolder()
        for title in ["A", "B", "C", "D"] {
            store.addTextBlock(title, to: folder)
        }
        let initial = store.feedBlocks(in: folder)
        let moving: Set<UUID> = [initial[0].id, initial[2].id] // A и C

        store.moveFeedBlocks(ids: moving, toIndex: 4, in: folder)

        XCTAssertEqual(store.feedBlocks(in: folder).compactMap(\.text), ["B", "D", "A", "C"])
    }

    func testMediaSelectionBuildsRowsOfUpToThreeItems() throws {
        let folder = makeFeedFolder()

        store.addMediaBlocks(
            ["1.jpg", "2.jpg", "3.jpg", "4.jpg"],
            to: folder,
            aspects: ["1.jpg": 0.75, "4.jpg": 1.5]
        )

        let rows = store.feedBlocks(in: folder)
        XCTAssertEqual(rows.map(\.kind), [.media, .media])
        XCTAssertEqual(rows.map(\.fileNames), [["1.jpg", "2.jpg", "3.jpg"], ["4.jpg"]])

        XCTAssertEqual(store.aspect(of: "1.jpg", in: folder), 0.75)
        XCTAssertEqual(store.aspect(of: "4.jpg", in: folder), 1.5)
        // Без записи — портрет по умолчанию, пока backfill не посчитает настоящую
        XCTAssertEqual(store.aspect(of: "2.jpg", in: folder), MediaAspect.fallback)
    }

    // Ряд из пяти фото — легальная композиция, вёрстку решает justified-раскладка
    func testMediaRowsMergeWithoutLengthLimit() throws {
        let folder = makeFeedFolder()
        store.addMediaBlocks(["1.jpg", "2.jpg", "3.jpg"], to: folder)
        store.addMediaBlocks(["4.jpg", "5.jpg"], to: folder)
        let last = try XCTUnwrap(store.feedBlocks(in: folder).last)

        XCTAssertTrue(store.canMergeMediaBlockWithPrevious(last, in: folder))
        store.mergeMediaBlockWithPrevious(last, in: folder)

        XCTAssertEqual(store.feedBlocks(in: folder).count, 1)
        XCTAssertEqual(
            store.feedBlocks(in: folder).first?.fileNames,
            ["1.jpg", "2.jpg", "3.jpg", "4.jpg", "5.jpg"]
        )
    }

    func testMediaRowsCanMergeAndSplit() throws {
        let folder = makeFeedFolder()
        store.addMediaBlocks(["1.jpg", "2.jpg"], to: folder)
        store.addMediaBlocks(["3.jpg"], to: folder)
        let last = try XCTUnwrap(store.feedBlocks(in: folder).last)

        XCTAssertTrue(store.canMergeMediaBlockWithPrevious(last, in: folder))
        store.mergeMediaBlockWithPrevious(last, in: folder)
        XCTAssertEqual(store.feedBlocks(in: folder).first?.fileNames, ["1.jpg", "2.jpg", "3.jpg"])

        let merged = try XCTUnwrap(store.feedBlocks(in: folder).first)
        store.splitMediaBlock(merged, in: folder)
        XCTAssertEqual(store.feedBlocks(in: folder).map(\.fileNames), [["1.jpg"], ["2.jpg"], ["3.jpg"]])
    }

    func testSelectedAdjacentRowsMergeIntoOne() throws {
        let folder = makeFeedFolder()
        store.addMediaBlocks(["1.jpg", "2.jpg"], to: folder)
        store.addMediaBlocks(["3.jpg"], to: folder)
        store.addTextBlock("Подпись", to: folder)
        let blocks = store.feedBlocks(in: folder)
        let rows: Set<UUID> = [blocks[0].id, blocks[1].id]

        XCTAssertTrue(store.canMergeMediaBlocks(ids: rows, in: folder))
        store.mergeMediaBlocks(ids: rows, in: folder)

        let result = store.feedBlocks(in: folder)
        XCTAssertEqual(result.map(\.kind), [.media, .text])
        XCTAssertEqual(result.first?.fileNames, ["1.jpg", "2.jpg", "3.jpg"])

        // Текстовый блок в выборке делает объединение невозможным
        XCTAssertFalse(store.canMergeMediaBlocks(ids: Set(result.map(\.id)), in: folder))
    }

    func testMediaMovesBetweenRowsAndEmptiedRowDisappears() throws {
        let folder = makeFeedFolder()
        store.addMediaBlocks(["1.jpg", "2.jpg"], to: folder)
        store.addMediaBlocks(["3.jpg"], to: folder)
        let blocks = store.feedBlocks(in: folder)

        // Единственное фото второго ряда уезжает в начало первого
        store.moveFeedMedia(
            fileName: "3.jpg",
            from: blocks[1].id,
            to: blocks[0].id,
            atIndex: 0,
            in: folder
        )

        let result = store.feedBlocks(in: folder)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.fileNames, ["3.jpg", "1.jpg", "2.jpg"])
    }

    func testMediaReordersInsideItsOwnRow() throws {
        let folder = makeFeedFolder()
        store.addMediaBlocks(["1.jpg", "2.jpg", "3.jpg"], to: folder)
        let row = try XCTUnwrap(store.feedBlocks(in: folder).first)

        store.moveFeedMedia(fileName: "1.jpg", from: row.id, to: row.id, atIndex: 3, in: folder)

        XCTAssertEqual(store.feedBlocks(in: folder).first?.fileNames, ["2.jpg", "3.jpg", "1.jpg"])
    }

    func testExtractedMediaBecomesItsOwnRow() throws {
        let folder = makeFeedFolder()
        store.addMediaBlocks(["1.jpg", "2.jpg", "3.jpg"], to: folder)
        let row = try XCTUnwrap(store.feedBlocks(in: folder).first)

        store.extractFeedMedia(fileName: "2.jpg", from: row.id, toBlockIndex: 0, in: folder)

        let result = store.feedBlocks(in: folder)
        XCTAssertEqual(result.map(\.fileNames), [["2.jpg"], ["1.jpg", "3.jpg"]])
    }

    func testDeletingSelectedBlocksRemovesTheirFiles() throws {
        let folder = makeFeedFolder()
        let dir = store.folderURL(folder)
        let names = ["a.jpg", "b.jpg"]
        for name in names {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        store.addMediaBlocks(names, to: folder, aspects: ["a.jpg": 1.0, "b.jpg": 1.0])
        store.addTextBlock("Подпись", to: folder)
        let blocks = store.feedBlocks(in: folder)

        store.deleteFeedBlocks(ids: Set(blocks.map(\.id)), in: folder)

        XCTAssertTrue(store.feedBlocks(in: folder).isEmpty)
        XCTAssertTrue(store.feedAspects(in: folder).isEmpty)
        for name in names {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        }
    }

    // Ленты, созданные до появления пропорций, хранились простым массивом блоков
    func testLegacyFeedFileMigratesToDocument() throws {
        let folder = makeFeedFolder()
        let legacy = """
        [
          {
            "id": "0F7A3C3E-4E4E-4C25-9B0D-1F0A22A2B111",
            "kind": "text",
            "text": "Старый блок",
            "fileNames": [],
            "createdAt": 100
          }
        ]
        """
        let url = store.folderURL(folder).appendingPathComponent(".feed.json")
        try Data(legacy.utf8).write(to: url)
        store.reload()

        XCTAssertEqual(store.feedBlocks(in: folder).compactMap(\.text), ["Старый блок"])
        XCTAssertTrue(store.feedAspects(in: folder).isEmpty)

        // Новая запись переводит файл в формат документа, старый блок не теряется
        store.addTextBlock("Новый блок", to: folder)
        store.reload()
        XCTAssertEqual(store.feedBlocks(in: folder).compactMap(\.text), ["Старый блок", "Новый блок"])
    }

    private func makeFeedFolder() -> VaultFolder {
        store.createFolder(name: "Лента", icon: "rectangle.stack", color: "pink", kind: .feed)
        return store.folders[0]
    }
}
