import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import LocalDrive

// Перенос, копии, дубликаты и вставка: имена не сталкиваются, дата съёмки и
// ручной порядок едут вместе с файлом, а индекс переносит документ целиком —
// или стирает его, если папка назначения вне поиска
@MainActor
final class FileOperationsTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDriveFileOps-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
        search = SearchService(store: store, databaseURL: nil)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        search = nil
        store = nil
        root = nil
    }

    // MARK: - Помощники

    @discardableResult
    private func makeFolder(
        _ name: String,
        kind: VaultFolderKind = .files,
        hidden: Bool = false,
        searchable: Bool = true
    ) throws -> VaultFolder {
        store.createFolder(
            name: name,
            icon: "folder.fill",
            color: "indigo",
            kind: kind,
            isSuperHidden: hidden,
            searchable: searchable
        )
        return try XCTUnwrap(store.folders.last)
    }

    @discardableResult
    private func add(_ data: Data, as name: String, to folder: VaultFolder) throws -> VaultFile {
        let stored = try XCTUnwrap(store.importData(data, preferredName: name, to: folder))
        return try XCTUnwrap(store.file(named: stored, in: folder))
    }

    @discardableResult
    private func add(_ text: String, as name: String, to folder: VaultFolder) throws -> VaultFile {
        try add(Data(text.utf8), as: name, to: folder)
    }

    private func names(in folder: VaultFolder) -> [String] {
        store.files(in: folder).map(\.name).sorted()
    }

    private func indexAll() async {
        search.reconcile()
        await search.waitUntilIdle()
    }

    /// Картинка 30×10: пропорции читаются из заголовка файла
    private func widePNG() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 30, height: 10), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 10))
        }.pngData()!
    }

    /// Картинка, скопированная в «Фото» или браузере: данные без имени
    private func imageProvider(_ data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: .png, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// Векторы MRZ из PassportFieldsTests, посчитаны независимо
    private static let passport = """
    PNRUSSAVIN<<IL98<ANDREEVI3<<<<<<<<<<<<<<<<<<
    4601234561RUS9001011M<<<<<<<1100620770120<34
    """

    private static let shot = Date(timeIntervalSince1970: 1_600_000_000)

    // MARK: - Перенос

    func testMoveKeepsNamesUniqueAndCarriesShotDate() async throws {
        let source = try makeFolder("Входящие")
        let destination = try makeFolder("Архив")
        let file = try add("новый", as: "Отчёт.txt", to: source)
        try add("старый", as: "Отчёт.txt", to: destination)
        store.setContentDates(["Отчёт.txt": Self.shot], in: source)

        let result = await store.moveFiles([file], from: source, to: destination)

        XCTAssertEqual(result.imported, ["Отчёт (1).txt"])
        XCTAssertEqual(result.failed, [])
        XCTAssertEqual(names(in: source), [])
        XCTAssertEqual(names(in: destination), ["Отчёт (1).txt", "Отчёт.txt"])
        let moved = store.folderURL(destination).appendingPathComponent("Отчёт (1).txt")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "новый")
        XCTAssertEqual(store.contentDates(in: destination)["Отчёт (1).txt"], Self.shot)
        XCTAssertNil(store.contentDates(in: source)["Отчёт.txt"], "дата не должна достаться следующему файлу с этим именем")
    }

    func testMoveUpdatesManualOrderOnBothSides() async throws {
        let source = try makeFolder("Входящие")
        let destination = try makeFolder("Архив")
        let x = try add("x", as: "x.txt", to: source)
        try add("y", as: "y.txt", to: source)
        try add("z", as: "z.txt", to: destination)
        store.setFileOrder(["x.txt", "y.txt"], in: source)
        // В порядке назначения осталось имя давно удалённого файла
        store.setFileOrder(["x.txt", "z.txt"], in: destination)

        await store.moveFiles([x], from: source, to: destination)

        XCTAssertEqual(store.fileOrder(in: source), ["y.txt"])
        XCTAssertEqual(store.fileOrder(in: destination), ["z.txt", "x.txt"], "без повтора имени — иначе сортировка упала бы")
        let destinationNow = try XCTUnwrap(store.folder(by: destination.id))
        XCTAssertEqual(store.files(in: destinationNow, sortedBy: .manual).map(\.name), ["z.txt", "x.txt"])
    }

    func testMoveIntoFeedAppendsBlocks() async throws {
        let source = try makeFolder("Входящие")
        let feed = try makeFolder("Поездка", kind: .feed)
        let photo = try add(widePNG(), as: "фото.png", to: source)
        let contract = try add("договор", as: "договор.pdf", to: source)

        let result = await store.moveFiles([photo, contract], from: source, to: feed)

        XCTAssertEqual(result.imported, ["фото.png", "договор.pdf"])
        let blocks = store.feedBlocks(in: feed)
        XCTAssertEqual(blocks.map(\.kind), [.media, .file])
        XCTAssertEqual(blocks.map(\.fileNames), [["фото.png"], ["договор.pdf"]])
        XCTAssertEqual(try XCTUnwrap(store.feedAspects(in: feed)["фото.png"]), 3.0, accuracy: 0.001)
    }

    func testMoveOutOfFeedIsRefused() async throws {
        let feed = try makeFolder("Поездка", kind: .feed)
        let target = try makeFolder("Архив")
        let file = try add("билет", as: "билет.pdf", to: feed)
        store.addFileBlocks([file.name], to: feed)

        let result = await store.moveFiles([file], from: feed, to: target)

        XCTAssertEqual(result.imported, [])
        XCTAssertEqual(result.failed, ["билет.pdf"])
        XCTAssertEqual(names(in: feed), ["билет.pdf"], "файл ленты — часть блока, блок не должен опустеть")
        XCTAssertEqual(names(in: target), [])
    }

    // MARK: - Копии

    func testCopyKeepsOriginalAndCarriesShotDate() async throws {
        let source = try makeFolder("Входящие")
        let destination = try makeFolder("Архив")
        let scan = try add("скан", as: "скан.jpg", to: source)
        try add("b", as: "b.txt", to: destination)
        store.setContentDates(["скан.jpg": Self.shot], in: source)
        store.setFileOrder(["b.txt"], in: destination)
        try FileManager.default.setAttributes([.creationDate: Self.shot], ofItemAtPath: scan.url.path)

        let result = await store.copyFiles([scan], to: destination)

        XCTAssertEqual(result.imported, ["скан.jpg"])
        XCTAssertEqual(names(in: source), ["скан.jpg"])
        XCTAssertEqual(store.contentDates(in: destination)["скан.jpg"], Self.shot)
        XCTAssertEqual(store.fileOrder(in: destination), ["b.txt", "скан.jpg"])
        let copy = try XCTUnwrap(store.file(named: "скан.jpg", in: destination))
        XCTAssertGreaterThan(copy.addedAt, Date().addingTimeInterval(-60), "копия добавлена сейчас, а не в день оригинала")
    }

    func testDuplicateNamesFollowFinder() async throws {
        let folder = try makeFolder("Документы")
        let passport = try add("p", as: "Паспорт.pdf", to: folder)

        let first = await store.duplicate(passport)
        let second = await store.duplicate(passport)
        XCTAssertEqual(first, "Паспорт копия.pdf")
        XCTAssertEqual(second, "Паспорт копия 2.pdf")

        let copy = try XCTUnwrap(store.file(named: "Паспорт копия.pdf", in: folder))
        let third = await store.duplicate(copy)
        XCTAssertEqual(third, "Паспорт копия 3.pdf", "у копии копии растёт номер, а не «копия копия»")

        let readme = try add("r", as: "README", to: folder)
        let plain = await store.duplicate(readme)
        XCTAssertEqual(plain, "README копия")
    }

    func testDuplicateSitsNextToOriginalInManualOrder() async throws {
        let folder = try makeFolder("Документы")
        let a = try add("a", as: "a.txt", to: folder)
        try add("b", as: "b.txt", to: folder)
        store.setFileOrder(["a.txt", "b.txt"], in: folder)
        store.setContentDates(["a.txt": Self.shot], in: folder)

        let copy = await store.duplicate(a)

        XCTAssertEqual(copy, "a копия.txt")
        XCTAssertEqual(store.fileOrder(in: folder), ["a.txt", "a копия.txt", "b.txt"])
        XCTAssertEqual(store.contentDates(in: folder)["a копия.txt"], Self.shot)
    }

    // MARK: - Буфер обмена

    func testPastedNames() {
        let date = Date(timeIntervalSince1970: 1_760_271_802) // 12.10.2026 по UTC — в имени местное время
        let stamp = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            return formatter.string(from: date)
        }()
        XCTAssertEqual(VaultStore.pastedName(suggested: "Отчёт", type: .pdf, date: date), "Отчёт.pdf")
        XCTAssertEqual(VaultStore.pastedName(suggested: "Отчёт v1.2", type: .pdf, date: date), "Отчёт v1.2.pdf")
        XCTAssertEqual(VaultStore.pastedName(suggested: "IMG_0001.HEIC", type: .heic, date: date), "IMG_0001.HEIC")
        XCTAssertEqual(VaultStore.pastedName(suggested: "Скан.heic", type: .jpeg, date: date), "Скан.jpeg")
        XCTAssertEqual(VaultStore.pastedName(suggested: "notes.txt", type: .utf8PlainText, date: date), "notes.txt")
        XCTAssertEqual(VaultStore.pastedName(suggested: nil, type: .png, date: date), "Фото \(stamp).png")
        XCTAssertEqual(VaultStore.pastedName(suggested: nil, type: .quickTimeMovie, date: date), "Видео \(stamp).mov")
        XCTAssertEqual(VaultStore.pastedName(suggested: nil, type: .utf8PlainText, date: date), "Текст \(stamp).txt")
        XCTAssertEqual(VaultStore.pastedName(suggested: nil, type: .pdf, date: date), "Файл \(stamp).pdf")
        XCTAssertEqual(VaultStore.pastedName(suggested: "   ", type: .pdf, date: date), "Файл \(stamp).pdf")
    }

    func testForeignNamesCannotEscapeOrHide() {
        XCTAssertEqual(VaultStore.cleanedName("../секрет/имя:1"), "-секрет-имя-1")
        XCTAssertEqual(VaultStore.cleanedName(".скрытый"), "скрытый")
        XCTAssertNil(VaultStore.cleanedName(" \n"))
        XCTAssertNil(VaultStore.cleanedName(nil))
    }

    func testCopiedFileCarriesItsName() throws {
        let folder = try makeFolder("Документы")
        let file = try add("pdf", as: "Справка.pdf", to: folder)
        let provider = try XCTUnwrap(FileClipboard.provider(for: file))
        XCTAssertEqual(provider.suggestedName, "Справка.pdf", "без имени получатель назвал бы файл «PDF document.pdf»")
        XCTAssertTrue(provider.registeredContentTypes.contains(.pdf))
    }

    func testPastedFileKeepsItsName() async throws {
        let folder = try makeFolder("Документы")
        let outside = root.appendingPathComponent("Снаружи", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = outside.appendingPathComponent("Справка.pdf")
        try Data("%PDF-1.4 справка".utf8).write(to: source)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: source))
        provider.suggestedName = "Справка.pdf"

        let result = await store.importItems([provider], to: folder).value

        XCTAssertEqual(result.imported, ["Справка.pdf"])
        XCTAssertEqual(result.failed, [])
        let pasted = store.folderURL(folder).appendingPathComponent("Справка.pdf")
        XCTAssertEqual(try Data(contentsOf: pasted), Data("%PDF-1.4 справка".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("%PDF-1.4 справка".utf8), "источник не трогаем")
    }

    func testPastedPhotosGetDatedUniqueNames() async throws {
        let folder = try makeFolder("Фото")
        let data = widePNG()

        let result = await store.importItems([imageProvider(data), imageProvider(data)], to: folder).value

        XCTAssertEqual(result.failed, [])
        XCTAssertEqual(result.imported.count, 2)
        XCTAssertEqual(Set(result.imported).count, 2, "два фото за одну секунду — два разных имени")
        for name in result.imported {
            XCTAssertTrue(name.hasPrefix("Фото "), name)
            XCTAssertTrue(name.hasSuffix(".png"), name)
        }
        XCTAssertEqual(store.files(in: folder).count, 2)
    }

    func testLinksAndOwnDragsAreNotPasted() async throws {
        let folder = try makeFolder("Документы")
        let link = NSItemProvider(object: URL(string: "https://example.com/a")! as NSURL)
        let drag = NSItemProvider()
        drag.registerDataRepresentation(for: .localDriveFileName, visibility: .all) { completion in
            completion(Data("{}".utf8), nil)
            return nil
        }

        let result = await store.importItems([link, drag], to: folder).value

        XCTAssertEqual(result.imported, [])
        XCTAssertEqual(result.failed, [])
        XCTAssertEqual(names(in: folder), [])
    }

    // MARK: - Индекс

    func testMovedDocumentKeepsItsFieldsAndManualCorrection() async throws {
        let source = try makeFolder("Входящие")
        let destination = try makeFolder("Паспорта")
        let file = try add(Self.passport, as: "паспорт.txt", to: source)
        await indexAll()
        let before = await search.documents(ofTypes: [.passportRU])
        let id = try XCTUnwrap(before.first?.id)
        await search.setManualField(documentID: id, key: FieldKey.issuedBy, value: "ГУ МВД России по г. Москве")

        let result = await store.moveFiles([file], from: source, to: destination)
        XCTAssertEqual(result.imported, ["паспорт.txt"])
        await search.waitUntilIdle()

        let indexed = await search.indexedFiles()
        XCTAssertEqual(indexed, [FileKey(folderID: destination.id, name: "паспорт.txt")])
        let after = await search.documents(ofTypes: [.passportRU])
        XCTAssertEqual(after.map(\.id), [id], "та же строка документа: заново не распознавали")
        XCTAssertEqual(after.first?.folderID, destination.id)
        let fields = await search.fields(for: [id])[id] ?? []
        XCTAssertEqual(fields.first { $0.key == FieldKey.issuedBy }?.source, .manual, "ручная правка переехала вместе с файлом")
        XCTAssertNotNil(fields.first { $0.key == FieldKey.seriesNumber })

        // Сверка после переноса ничего не перечитывает и не теряет
        await indexAll()
        let swept = await search.documents(ofTypes: [.passportRU])
        XCTAssertEqual(swept.map(\.id), [id])
        let found = await search.search("паспорт")
        XCTAssertEqual(found.map(\.folder.id), [destination.id])
    }

    func testMovingIntoUnsearchableFolderErasesExtractedData() async throws {
        let source = try makeFolder("Входящие")
        let closed = try makeFolder("Личное", searchable: false)
        let file = try add(Self.passport, as: "паспорт.txt", to: source)
        await indexAll()

        await store.moveFiles([file], from: source, to: closed)
        await search.waitUntilIdle()

        let indexed = await search.indexedFiles()
        XCTAssertEqual(indexed, [])
        let counts = await search.rowCounts()
        XCTAssertEqual(counts, SearchIndexStore.RowCounts(documents: 0, chunks: 0, ftsRows: 0, fields: 0))
        await indexAll()
        let swept = await search.indexedFiles()
        XCTAssertEqual(swept, [], "сверка не возвращает файл папки вне поиска")
    }

    func testMovingIntoSuperHiddenFolderErasesExtractedData() async throws {
        let source = try makeFolder("Входящие")
        let vault = try makeFolder("Тайник", hidden: true)
        let file = try add(Self.passport, as: "паспорт.txt", to: source)
        await indexAll()

        await store.moveFiles([file], from: source, to: vault)
        await search.waitUntilIdle()

        let counts = await search.rowCounts()
        XCTAssertEqual(counts, SearchIndexStore.RowCounts(documents: 0, chunks: 0, ftsRows: 0, fields: 0))
        let indexed = await search.indexedFiles()
        XCTAssertEqual(indexed, [], "суперскрытая папка не индексируется никогда")
    }

    func testFolderUnknownToIndexGetsTheFileOnNextSweep() async throws {
        let source = try makeFolder("Входящие")
        let file = try add("Справка о доходах", as: "справка.txt", to: source)
        await indexAll()
        // Папку создали после сверки — индекс о ней ещё не знает
        let fresh = try makeFolder("Новая")

        await store.moveFiles([file], from: source, to: fresh)
        await search.waitUntilIdle()
        await indexAll()

        let indexed = await search.indexedFiles()
        XCTAssertEqual(indexed, [FileKey(folderID: fresh.id, name: "справка.txt")])
    }

    func testMoveReplacesStaleRowWithTheSameName() async throws {
        let source = try makeFolder("Входящие")
        let destination = try makeFolder("Архив")
        let file = try add("Договор аренды", as: "документ.txt", to: source)
        try add("Справка о доходах", as: "документ.txt", to: destination)
        await indexAll()
        // Файл исчез мимо хранилища — строка индекса под его именем осталась
        try FileManager.default.removeItem(at: store.folderURL(destination).appendingPathComponent("документ.txt"))

        let result = await store.moveFiles([file], from: source, to: destination)
        XCTAssertEqual(result.imported, ["документ.txt"])
        await search.waitUntilIdle()

        let indexed = await search.indexedFiles()
        XCTAssertEqual(indexed, [FileKey(folderID: destination.id, name: "документ.txt")])
        let byText = await search.search("договор")
        XCTAssertEqual(byText.map(\.file.name), ["документ.txt"])
        let stale = await search.search("справка")
        XCTAssertTrue(stale.isEmpty, "текст пропавшего файла не должен находиться")
    }

    func testCopyIsIndexedAsItsOwnDocument() async throws {
        let source = try makeFolder("Входящие")
        let destination = try makeFolder("Архив")
        let file = try add("Справка о доходах", as: "справка.txt", to: source)
        await indexAll()

        await store.copyFiles([file], to: destination)
        await indexAll()

        let indexed = Set(await search.indexedFiles())
        XCTAssertEqual(indexed, [
            FileKey(folderID: source.id, name: "справка.txt"),
            FileKey(folderID: destination.id, name: "справка.txt"),
        ])
    }
}
