import UIKit
import XCTest
@testable import LocalDrive

// Приёмка этапа 1 из спецификации: «справка антиплагиат» находит нужный PDF,
// а файлы суперскрытой папки не находятся никаким запросом
@MainActor
final class SearchServiceTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDriveSearchTests-\(UUID().uuidString)", isDirectory: true)
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
    private func makeFolder(_ name: String, hidden: Bool = false, kind: VaultFolderKind = .files) throws -> VaultFolder {
        store.createFolder(name: name, icon: "folder.fill", color: "indigo", kind: kind, isSuperHidden: hidden)
        return try XCTUnwrap(store.folders.last)
    }

    private func refreshed(_ folder: VaultFolder) throws -> VaultFolder {
        try XCTUnwrap(store.folder(by: folder.id))
    }

    /// PDF с настоящим текстовым слоем, как из Word или от вуза
    private func pdf(_ lines: [String]) -> Data {
        pdf(pages: [lines])
    }

    private func pdf(pages: [[String]]) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        return renderer.pdfData { context in
            for lines in pages {
                context.beginPage()
                for (index, line) in lines.enumerated() {
                    (line as NSString).draw(
                        at: CGPoint(x: 50, y: 60 + CGFloat(index) * 24),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 14)]
                    )
                }
            }
        }
    }

    /// Картинка с текстом — как фото или скан без текстового слоя
    private func scan(_ lines: [String]) -> Data {
        let size = CGSize(width: 1400, height: 120 + CGFloat(lines.count) * 70)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(
                    at: CGPoint(x: 60, y: 60 + CGFloat(index) * 70),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 44), .foregroundColor: UIColor.black]
                )
            }
        }
        return image.pngData()!
    }

    private func indexAll() async {
        search.reconcile()
        await search.waitUntilIdle()
    }

    private func names(_ query: String) async -> [String] {
        await search.search(query).map(\.file.name)
    }

    // MARK: - Критерий 1: поиск по тексту

    func testPlagiarismCertificateIsFoundInsidePDF() async throws {
        let folder = try makeFolder("Бакалавриат RUDN")
        store.importData(pdf(pages: [
            ["Выпускная квалификационная работа", "Титульный лист"],
            [
                "Федеральное государственное автономное образовательное учреждение",
                "СПРАВКА",
                "о результатах проверки выпускной квалификационной работы",
                "в системе «Антиплагиат.ВУЗ»: оригинальность 87,3 %",
            ],
        ]), preferredName: "Документ 17.pdf", to: folder)
        store.importData(pdf(["Договор аренды квартиры", "Арендодатель передаёт квартиру"]), preferredName: "Договор.pdf", to: folder)

        await indexAll()

        let results = await search.search("справка антиплагиат")
        XCTAssertEqual(results.first?.file.name, "Документ 17.pdf")
        XCTAssertEqual(results.first?.page, 2, "справка на второй странице — открывать надо её")
        let snippet = try XCTUnwrap(results.first?.snippet)
        XCTAssertTrue(String(snippet.characters).contains("Антиплагиат"))
        XCTAssertFalse(results.map(\.file.name).contains("Договор.pdf"))
    }

    func testScannedImageIsRecognized() async throws {
        let folder = try makeFolder("Наука")
        store.importData(scan([
            "СПРАВКА",
            "Редакция журнала подтверждает принятие",
            "статьи к публикации в номере 4 за 2025 год",
        ]), preferredName: "IMG_2041.png", to: folder)

        await indexAll()

        let results = await search.search("справка о принятии статьи")
        XCTAssertEqual(results.map(\.file.name), ["IMG_2041.png"], "текст скана должен распознаться Vision")
        XCTAssertNotNil(results.first?.snippet)
        XCTAssertNil(results.first?.page, "у одностраничного файла номер страницы не показывается")
    }

    func testFolderNameFindsItsFiles() async throws {
        let folder = try makeFolder("Бакалавриат RUDN")
        store.importData(Data("без текста".utf8), preferredName: "заметка.txt", to: folder)
        await indexAll()
        let found = await names("бакалавриат")
        XCTAssertEqual(found, ["заметка.txt"])
    }

    func testFeedAttachmentsAreSearchable() async throws {
        let folder = try makeFolder("Лента", kind: .feed)
        let name = try XCTUnwrap(store.importData(Data("Справка с места работы".utf8), preferredName: "работа.txt", to: folder))
        store.addFileBlocks([name], to: folder)
        await indexAll()
        let found = await names("справку")
        XCTAssertEqual(found, ["работа.txt"])
    }

    // MARK: - Критерий 2: суперскрытые папки

    func testSuperHiddenFolderIsNeverIndexed() async throws {
        let hidden = try makeFolder("Тайник", hidden: true)
        store.importData(Data("Паспорт гражданина Российской Федерации".utf8), preferredName: "паспорт секрет.txt", to: hidden)
        try makeFolder("Обычная")

        await indexAll()

        let indexed = await search.indexedFiles()
        XCTAssertFalse(indexed.contains { $0.folderID == hidden.id }, "в индексе не должно быть ни строки из суперскрытой папки")
        for query in ["паспорт", "секрет", "тайник", "гражданина", "Российской Федерации"] {
            let found = await names(query)
            XCTAssertEqual(found, [], "запрос «\(query)» нашёл файл суперскрытой папки")
        }
    }

    func testHidingFolderErasesItsIndexImmediately() async throws {
        let folder = try makeFolder("Документы")
        store.importData(Data("Справка о доходах".utf8), preferredName: "доходы.txt", to: folder)
        await indexAll()
        let before = await names("справка")
        XCTAssertEqual(before, ["доходы.txt"])

        store.setSuperHidden(true, for: folder.id)
        // Ещё до того, как индекс отработал удаление, выдача пуста
        let immediately = await names("справка")
        XCTAssertEqual(immediately, [])

        await search.waitUntilIdle()
        let counts = await search.rowCounts()
        XCTAssertEqual(counts, SearchIndexStore.RowCounts(documents: 0, chunks: 0, ftsRows: 0, fields: 0))
    }

    func testHiddenFolderCanBeSearchedAgainAfterUnhiding() async throws {
        let folder = try makeFolder("Документы")
        store.importData(Data("Справка о доходах".utf8), preferredName: "доходы.txt", to: folder)
        store.setSuperHidden(true, for: folder.id)
        await indexAll()
        let hidden = await names("справка")
        XCTAssertEqual(hidden, [])

        store.setSuperHidden(false, for: folder.id)
        XCTAssertTrue(try refreshed(folder).isIndexable)
        await indexAll()
        let unhidden = await names("справка")
        XCTAssertEqual(unhidden, ["доходы.txt"])
    }

    func testSearchOffErasesFolderAndSurvivesRelaunch() async throws {
        let folder = try makeFolder("Документы")
        store.importData(Data("Справка о доходах".utf8), preferredName: "доходы.txt", to: folder)
        await indexAll()

        store.setSearchable(false, for: folder.id)
        await search.waitUntilIdle()
        let indexed = await search.indexedFiles()
        XCTAssertEqual(indexed, [])

        let reopened = VaultStore(rootURL: root)
        XCTAssertEqual(reopened.folder(by: folder.id)?.searchable, false, "выбор сохраняется в vault.json")
    }

    func testSuperHiddenFolderCannotBeIndexableEvenIfSearchable() throws {
        let folder = try makeFolder("Тайник", hidden: true)
        store.setSearchable(true, for: folder.id)
        XCTAssertFalse(try refreshed(folder).isIndexable)
    }

    // MARK: - Удаление и переименование

    func testDeletedFileLeavesNothingBehind() async throws {
        let folder = try makeFolder("Документы")
        store.importData(Data("Справка о доходах".utf8), preferredName: "доходы.txt", to: folder)
        await indexAll()
        let file = try XCTUnwrap(store.files(in: folder).first)

        store.deleteFile(file)
        let found = await names("справка")
        XCTAssertEqual(found, [])
        await search.waitUntilIdle()
        let counts = await search.rowCounts()
        XCTAssertEqual(counts?.documents, 0)
        XCTAssertEqual(counts?.ftsRows, 0)
    }

    func testRenamedFileIsFoundByNewNameWithoutReindexing() async throws {
        let folder = try makeFolder("Документы")
        store.importData(Data("Справка о доходах".utf8), preferredName: "IMG_0001.txt", to: folder)
        await indexAll()
        let file = try XCTUnwrap(store.files(in: folder).first)

        store.renameFile(file, to: "Доходы за год")
        await search.waitUntilIdle()
        let byName = await names("доходы за год")
        XCTAssertEqual(byName, ["Доходы за год.txt"])
        let byText = await names("справка")
        XCTAssertEqual(byText, ["Доходы за год.txt"])
        let oldName = await names("img")
        XCTAssertEqual(oldName, [])
    }

    func testDeletedFolderLeavesNothingBehind() async throws {
        let folder = try makeFolder("Документы")
        store.importData(Data("Справка".utf8), preferredName: "a.txt", to: folder)
        await indexAll()
        store.deleteFolder(try refreshed(folder))
        await search.waitUntilIdle()
        let counts = await search.rowCounts()
        XCTAssertEqual(counts?.documents, 0)
    }

    func testChangedFileIsReindexed() async throws {
        let folder = try makeFolder("Документы")
        let name = try XCTUnwrap(store.importData(Data("Справка о доходах".utf8), preferredName: "a.txt", to: folder))
        await indexAll()

        let url = store.folderURL(folder).appendingPathComponent(name)
        try Data("Договор аренды".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        await indexAll()

        let old = await names("справка")
        XCTAssertEqual(old, [])
        let new = await names("договор")
        XCTAssertEqual(new, ["a.txt"])
    }

    func testOldFolderMetadataIsSearchable() throws {
        let json = """
        {"id": "62D95803-F7B9-40B9-A948-60786D3F80CE", "name": "Документы",
         "icon": "folder.fill", "color": "indigo", "createdAt": 100}
        """
        let folder = try JSONDecoder().decode(VaultFolder.self, from: Data(json.utf8))
        XCTAssertTrue(folder.searchable)
        XCTAssertTrue(folder.isIndexable)
    }
}

// Копирование из «Файлов» под координатором — без него недокачанный из
// iCloud документ не копировался, а ошибка молча пропускалась
final class CoordinatedImportTests: XCTestCase {
    func testCopiesAndPicksUniqueName() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LocalDriveImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("Справка.pdf")
        try Data("pdf".utf8).write(to: file)

        let first = try VaultStore.coordinatedCopy(from: file, into: target)
        let second = try VaultStore.coordinatedCopy(from: file, into: target)
        XCTAssertEqual(first.lastPathComponent, "Справка.pdf")
        XCTAssertEqual(second.lastPathComponent, "Справка (1).pdf")
        XCTAssertEqual(try Data(contentsOf: second), Data("pdf".utf8))
    }

    func testMissingSourceIsReportedNotSkipped() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("нет-\(UUID().uuidString).pdf")
        XCTAssertThrowsError(try VaultStore.coordinatedCopy(from: missing, into: FileManager.default.temporaryDirectory))
    }

    @MainActor
    func testImportFilesReportsFailures() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LocalDriveImportStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let store = VaultStore(rootURL: root.appendingPathComponent("Vault"))
        store.createFolder(name: "Документы", icon: "folder.fill", color: "indigo")
        let folder = try XCTUnwrap(store.folders.first)
        let good = root.appendingPathComponent("ok.txt")
        try Data("ok".utf8).write(to: good)
        let missing = root.appendingPathComponent("missing.txt")

        let result = await store.importFiles([good, missing], to: folder)
        XCTAssertEqual(result.imported, ["ok.txt"])
        XCTAssertEqual(result.failed, ["missing.txt"])
        XCTAssertEqual(store.files(in: folder).map(\.name), ["ok.txt"])
    }
}
