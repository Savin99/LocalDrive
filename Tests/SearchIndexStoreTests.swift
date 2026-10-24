import SQLite3
import XCTest
@testable import LocalDrive

final class SearchIndexStoreTests: XCTestCase {
    private var index: SearchIndexStore!
    private let folder = UUID()
    private let otherFolder = UUID()

    override func setUpWithError() throws {
        index = try SearchIndexStore(url: nil)
    }

    override func tearDown() {
        index.close()
        index = nil
    }

    private func record(
        _ name: String,
        in folder: UUID,
        text: String,
        fields: [DocumentField] = []
    ) -> DocumentRecord {
        let title = SearchText.title(fromFileName: name)
        return DocumentRecord(
            folderID: folder,
            fileName: name,
            type: .other,
            title: title,
            pageCount: 1,
            fileSize: Int64(text.utf8.count),
            fileModified: 1_000,
            failed: false,
            chunks: [SearchIndexer.chunk(page: 0, text: title), SearchIndexer.chunk(page: 1, text: text)],
            fields: fields
        )
    }

    private func found(_ text: String, in folders: Set<UUID>? = nil) throws -> [String] {
        let query = SearchQuery(text)
        let scope = folders ?? [folder, otherFolder]
        for matchAll in [true, false] {
            guard let expression = query.ftsExpression(matchAll: matchAll) else { return [] }
            let matches = try index.search(expression, folders: scope, limit: 20)
            if !matches.isEmpty {
                let documents = try index.documents(ids: matches.map(\.documentID))
                var names: [String] = []
                for match in matches {
                    if let name = documents[match.documentID]?.fileName, !names.contains(name) { names.append(name) }
                }
                return names
            }
        }
        return []
    }

    /// FTS5 есть в системной SQLite. Версия попадает в лог теста — она нужна
    /// для docs/search.md, а на iPhone может быть старше, чем в SDK
    func testSystemSQLiteHasFTS5() {
        XCTAssertEqual(sqlite3_compileoption_used("ENABLE_FTS5"), 1)
        print("SQLite runtime:", String(cString: sqlite3_libversion()))
    }

    func testFindsInflectedWords() throws {
        try index.save(record("скан.pdf", in: folder, text: "Справка о проверке выпускной работы на антиплагиат"), indexVersion: 1)
        XCTAssertEqual(try found("справку антиплагиат"), ["скан.pdf"])
        XCTAssertEqual(try found("проверка"), ["скан.pdf"])
        XCTAssertEqual(try found("антиплаг"), ["скан.pdf"], "начало слова тоже находит")
    }

    func testFindsByFileName() throws {
        try index.save(record("Диплом_бакалавра.pdf", in: folder, text: "без текста"), indexVersion: 1)
        XCTAssertEqual(try found("диплом"), ["Диплом_бакалавра.pdf"])
    }

    func testYoAndYeAreTheSame() throws {
        try index.save(record("a.txt", in: folder, text: "Пётр Алексеевич"), indexVersion: 1)
        XCTAssertEqual(try found("петр"), ["a.txt"])
    }

    func testAllWordsFirstThenAnyWord() throws {
        try index.save(record("both.txt", in: folder, text: "справка антиплагиат"), indexVersion: 1)
        try index.save(record("one.txt", in: folder, text: "справка о доходах"), indexVersion: 1)
        XCTAssertEqual(try found("справка антиплагиат"), ["both.txt"], "документ со всеми словами вытесняет частичные")
        // Всех слов нет ни в одном документе — тогда подходит любое
        XCTAssertEqual(Set(try found("справка диссертация")), ["both.txt", "one.txt"])
    }

    func testSearchIsLimitedToAllowedFolders() throws {
        try index.save(record("public.txt", in: folder, text: "паспорт"), indexVersion: 1)
        try index.save(record("secret.txt", in: otherFolder, text: "паспорт"), indexVersion: 1)
        XCTAssertEqual(try found("паспорт", in: [folder]), ["public.txt"])
    }

    func testDeletingDocumentRemovesAllExtractedData() throws {
        try index.save(
            record("p.jpg", in: folder, text: "паспорт 4601 123456", fields: [
                DocumentField(key: "series_number", value: "4601 123456", confidence: 0.99, source: .mrz, verified: false),
            ]),
            indexVersion: 1
        )
        XCTAssertTrue(try index.deleteDocument(folderID: folder, fileName: "p.jpg"))
        let counts = try index.rowCounts()
        XCTAssertEqual(counts, SearchIndexStore.RowCounts(documents: 0, chunks: 0, ftsRows: 0, fields: 0))
        XCTAssertEqual(try found("паспорт"), [])
    }

    func testDeletingFolderKeepsOtherFolders() throws {
        try index.save(record("a.txt", in: folder, text: "справка"), indexVersion: 1)
        try index.save(record("b.txt", in: otherFolder, text: "справка"), indexVersion: 1)
        XCTAssertEqual(try index.deleteFolder(folder), 1)
        XCTAssertEqual(try found("справка"), ["b.txt"])
        XCTAssertEqual(try index.deleteFolders(except: []), 1)
        XCTAssertEqual(try index.rowCounts().ftsRows, 0)
    }

    func testManualFieldSurvivesReindexing() throws {
        let recognized = DocumentField(key: "series_number", value: "4601 123458", confidence: 0.4, source: .mrz, verified: false)
        let id = try index.save(record("p.jpg", in: folder, text: "паспорт", fields: [recognized]), indexVersion: 1)
        try index.setManualField(documentID: id, key: "series_number", value: "4601 123456")

        let again = try index.save(record("p.jpg", in: folder, text: "паспорт", fields: [recognized]), indexVersion: 2)
        XCTAssertEqual(again, id, "перечитанный документ сохраняет id")
        let field = try XCTUnwrap(index.fields(documentID: id).first)
        XCTAssertEqual(field.value, "4601 123456")
        XCTAssertEqual(field.source, .manual)
        XCTAssertTrue(field.verified)
    }

    func testRenameKeepsTextAndChangesTitle() throws {
        try index.save(record("IMG_0001.jpg", in: folder, text: "справка антиплагиат"), indexVersion: 1)
        let title = SearchIndexer.chunk(page: 0, text: SearchText.title(fromFileName: "Справка РУДН.jpg"))
        try index.renameDocument(folderID: folder, from: "IMG_0001.jpg", to: "Справка РУДН.jpg", title: title)
        XCTAssertEqual(try found("рудн"), ["Справка РУДН.jpg"])
        XCTAssertEqual(try found("img"), [])
        XCTAssertEqual(try found("антиплагиат"), ["Справка РУДН.jpg"])
    }

    // MARK: - Смена модели (24.10.2026)

    /// Владелец сменил модель распознавания — и приложение перечитало всё. Теперь
    /// прочитанное любой моделью той же версии схемы заново не отправляется;
    /// новая модель берёт новое и то, что прежней не далось; «Перечитать» — всё
    func testCloudModelChangeDoesNotRereadReadDocuments() throws {
        let read = try index.save(record("паспорт.jpg", in: folder, text: "паспорт"), indexVersion: 3)
        let failed = try index.save(record("скан.jpg", in: folder, text: "скан"), indexVersion: 3)
        let skipped = try index.save(record("договор.pdf", in: folder, text: "договор"), indexVersion: 3)
        let fresh = try index.save(record("новый.jpg", in: folder, text: "новый"), indexVersion: 3)
        let old = try index.save(record("старый.jpg", in: folder, text: "старый"), indexVersion: 3)
        let sol = "cloud3:openai:gpt-6.1-sol"
        let luna = "cloud3:openai:gpt-6-luna"
        try index.markCloud(documentID: read, mark: sol)
        try index.markCloud(documentID: failed, mark: SearchIndexStore.CloudMark.failed(sol))
        try index.markCloud(documentID: skipped, mark: SearchIndexStore.CloudMark.skipped(sol))
        try index.markCloud(documentID: old, mark: "cloud2:openai:gpt-6.1-sol")

        let candidates = try index.cloudCandidates(mark: luna, folders: [folder]).map(\.documentID)
        XCTAssertEqual(Set(candidates), [failed, fresh, old], "прочитанное другой моделью отправилось бы заново")
        XCTAssertEqual(try index.cloudCounts(mark: luna, folders: [folder]).read, 1)

        // Не далось и этой — больше не пробует
        try index.markCloud(documentID: failed, mark: SearchIndexStore.CloudMark.failed(luna))
        XCTAssertFalse(try index.cloudCandidates(mark: luna, folders: [folder]).map(\.documentID).contains(failed))

        try index.resetCloudMarks(folders: [folder])
        XCTAssertEqual(try index.cloudCandidates(mark: luna, folders: [folder]).count, 5)
    }

    func testLocalModelChangeDoesNotRereadReadDocuments() throws {
        let passport = DocumentRecord(
            folderID: folder, fileName: "паспорт.jpg", type: .passportRU, title: "паспорт", pageCount: 1,
            fileSize: 10, fileModified: 1_000, failed: false, chunks: [SearchIndexer.chunk(page: 1, text: "паспорт")], fields: []
        )
        let read = try index.save(passport, indexVersion: 3)
        let failedRecord = DocumentRecord(
            folderID: folder, fileName: "скан.jpg", type: .passportRU, title: "скан", pageCount: 1,
            fileSize: 10, fileModified: 1_000, failed: false, chunks: [SearchIndexer.chunk(page: 1, text: "скан")], fields: []
        )
        let failed = try index.save(failedRecord, indexVersion: 3)
        try index.markModelRead(documentID: read, revision: "model-4b")
        try index.markModelRead(documentID: failed, revision: SearchIndexStore.ModelMark.failed("model-4b"))

        let candidates = try index.modelCandidates(types: [.passportRU], revision: "model-2b", folders: [folder])
        XCTAssertEqual(candidates.map(\.documentID), [failed])
        XCTAssertEqual(try index.modelCounts(types: [.passportRU], revision: "model-2b", folders: [folder]).read, 1)
        XCTAssertEqual(try index.modelState(folderID: folder, fileName: "паспорт.jpg", types: [.passportRU], revision: "model-2b"), .read)

        try index.resetModelMarks(folders: [folder])
        XCTAssertEqual(try index.modelCandidates(types: [.passportRU], revision: "model-2b", folders: [folder]).count, 2)
    }
}
