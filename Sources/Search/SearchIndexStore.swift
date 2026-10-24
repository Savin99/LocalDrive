import Foundation

/// Что индекс помнит о файле, чтобы заметить изменения на диске
struct IndexedFileState: Hashable, Sendable {
    let documentID: Int64
    let folderID: UUID
    let fileName: String
    let fileSize: Int64
    let fileModified: Double
    let indexVersion: Int
    let failed: Bool
}

/// Фрагмент текста, готовый к записи: исходник для подсветки и две колонки FTS
struct ChunkRecord: Sendable {
    let page: Int
    let text: String
    let words: String
    let stems: String
}

/// Документ, готовый к записи в индекс
struct DocumentRecord: Sendable {
    let folderID: UUID
    let fileName: String
    let type: DocumentType
    let title: String
    let pageCount: Int
    let fileSize: Int64
    let fileModified: Double
    /// Текст достать не удалось — документ ищется только по имени
    let failed: Bool
    let chunks: [ChunkRecord]
    let fields: [DocumentField]
}

/// Совпадение во фрагменте
struct ChunkMatch: Sendable {
    let chunkID: Int64
    let documentID: Int64
    let page: Int
    /// bm25: чем меньше, тем лучше
    let score: Double
}

/// Удостоверение, которое ждёт второго чтения моделью. Размер и дата файла —
/// с момента распознавания: если файл с тех пор заменили, чтение выбрасывается
struct ModelReadCandidate: Sendable, Equatable {
    let documentID: Int64
    let folderID: UUID
    let fileName: String
    let type: DocumentType
    let fileSize: Int64
    let fileModified: Double
}

/// Строка документа для выдачи
struct StoredDocument: Sendable {
    let id: Int64
    let folderID: UUID
    let fileName: String
    let type: DocumentType
    let pageCount: Int
}

// Схема и запросы индекса. Синхронный класс: владеет им актор SearchIndexer,
// он же гарантирует, что обращения идут по одному
final class SearchIndexStore {
    /// Номер схемы базы. Рост номера без миграции означает пересоздание:
    /// индекс производный и восстанавливается из файлов.
    /// 2 — `model_revision`: какая модель уже прочитала документ;
    /// 3 — `cloud_revision`: отдельно, чтобы облако и локальная модель не
    /// затирали отметки друг друга;
    /// 4 — `document_meta`: метаданные документа от облачного распознавания
    static let schemaVersion = 4

    /// Страница фрагмента с метаданными: по ним документ ищется, но выдержкой
    /// поиска фрагмент не становится (выдержки берутся со страниц от 1)
    static let metadataPage = -1

    private let db: SQLiteDatabase

    init(url: URL?) throws {
        db = try SQLiteDatabase(url: url)
        // secure_delete затирает освобождённые страницы нулями: удалённый
        // текст паспорта не должен оставаться в файле базы. Журнал отката, а
        // не WAL: после коммита он удаляется вместе со своим ключом шифрования
        try db.execute("""
            PRAGMA foreign_keys = ON;
            PRAGMA secure_delete = ON;
            PRAGMA journal_mode = DELETE;
            """)
        try migrate()
    }

    func close() {
        db.close()
    }

    private func migrate() throws {
        let version = try db.scalar("PRAGMA user_version")
        guard version != Self.schemaVersion else { return }
        if (1...3).contains(version) {
            // Только новое: распознанное раньше не пропадает
            if version == 1 { try db.execute("ALTER TABLE document ADD COLUMN model_revision TEXT;") }
            if version <= 2 { try db.execute("ALTER TABLE document ADD COLUMN cloud_revision TEXT;") }
            try db.execute("""
                \(Self.metadataTable)
                PRAGMA user_version = \(Self.schemaVersion);
                """)
            return
        }
        if version != 0 {
            try db.execute("""
                DROP TABLE IF EXISTS document_meta;
                DROP TABLE IF EXISTS field;
                DROP TABLE IF EXISTS chunk_fts;
                DROP TABLE IF EXISTS chunk;
                DROP TABLE IF EXISTS document;
                """)
        }
        try db.execute("""
            CREATE TABLE document (
                id INTEGER PRIMARY KEY,
                folder_id TEXT NOT NULL,
                file_name TEXT NOT NULL,
                type TEXT NOT NULL DEFAULT 'other',
                title TEXT NOT NULL,
                page_count INTEGER NOT NULL DEFAULT 0,
                file_size INTEGER NOT NULL,
                file_modified REAL NOT NULL,
                indexed_at REAL NOT NULL,
                index_version INTEGER NOT NULL,
                failed INTEGER NOT NULL DEFAULT 0,
                model_revision TEXT,
                cloud_revision TEXT,
                UNIQUE (folder_id, file_name)
            );
            CREATE TABLE chunk (
                id INTEGER PRIMARY KEY,
                document_id INTEGER NOT NULL REFERENCES document(id) ON DELETE CASCADE,
                page INTEGER NOT NULL,
                text TEXT NOT NULL,
                embedding BLOB
            );
            CREATE INDEX chunk_by_document ON chunk(document_id);
            CREATE VIRTUAL TABLE chunk_fts USING fts5(
                words, stems, tokenize = 'unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER chunk_fts_cleanup AFTER DELETE ON chunk BEGIN
                DELETE FROM chunk_fts WHERE rowid = old.id;
            END;
            \(Self.metadataTable)
            CREATE TABLE field (
                document_id INTEGER NOT NULL REFERENCES document(id) ON DELETE CASCADE,
                key TEXT NOT NULL,
                value TEXT NOT NULL,
                confidence REAL NOT NULL,
                source TEXT NOT NULL,
                verified INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (document_id, key)
            );
            PRAGMA user_version = \(Self.schemaVersion);
            """)
    }

    /// Метаданные стираются вместе с документом — и при скрытии папки тоже
    private static let metadataTable = """
        CREATE TABLE IF NOT EXISTS document_meta (
            document_id INTEGER PRIMARY KEY REFERENCES document(id) ON DELETE CASCADE,
            json TEXT NOT NULL,
            revision TEXT NOT NULL
        );
        """

    // MARK: - Сверка с диском

    func fileStates() throws -> [IndexedFileState] {
        try db.query("""
            SELECT id, folder_id, file_name, file_size, file_modified, index_version, failed
            FROM document
            """) { row in
            IndexedFileState(
                documentID: row.int64(0),
                folderID: UUID(uuidString: row.text(1)) ?? UUID(),
                fileName: row.text(2),
                fileSize: row.int64(3),
                fileModified: row.double(4),
                indexVersion: row.int(5),
                failed: row.bool(6)
            )
        }
    }

    // MARK: - Запись

    /// Новый документ или перечитанный старый. Ручные правки полей переживают
    /// переиндексацию: распознавание их не перезаписывает
    @discardableResult
    func save(_ record: DocumentRecord, indexVersion: Int, indexedAt: Date = Date()) throws -> Int64 {
        try db.transaction {
            let folder = record.folderID.uuidString
            let existing = try db.query(
                "SELECT id FROM document WHERE folder_id = ? AND file_name = ?",
                [folder, record.fileName]
            ) { $0.int64(0) }.first

            let documentID: Int64
            if let existing {
                try db.run("DELETE FROM chunk WHERE document_id = ?", [existing])
                // Файл перечитан — прежние метаданные к нему могут не подходить
                try db.run("DELETE FROM document_meta WHERE document_id = ?", [existing])
                try db.run("DELETE FROM field WHERE document_id = ? AND source != ?", [existing, FieldSource.manual.rawValue])
                try db.run("""
                    UPDATE document SET type = ?, title = ?, page_count = ?, file_size = ?,
                        file_modified = ?, indexed_at = ?, index_version = ?, failed = ?,
                        model_revision = NULL, cloud_revision = NULL
                    WHERE id = ?
                    """, [
                        record.type.rawValue, record.title, record.pageCount, record.fileSize,
                        record.fileModified, indexedAt.timeIntervalSince1970, indexVersion, record.failed,
                        existing,
                    ])
                documentID = existing
            } else {
                try db.run("""
                    INSERT INTO document (folder_id, file_name, type, title, page_count, file_size,
                        file_modified, indexed_at, index_version, failed)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [
                        folder, record.fileName, record.type.rawValue, record.title, record.pageCount,
                        record.fileSize, record.fileModified, indexedAt.timeIntervalSince1970, indexVersion,
                        record.failed,
                    ])
                documentID = db.lastInsertRowID
            }

            for chunk in record.chunks {
                try db.run(
                    "INSERT INTO chunk (document_id, page, text) VALUES (?, ?, ?)",
                    [documentID, chunk.page, chunk.text]
                )
                try db.run(
                    "INSERT INTO chunk_fts (rowid, words, stems) VALUES (?, ?, ?)",
                    [db.lastInsertRowID, chunk.words, chunk.stems]
                )
            }
            for field in record.fields {
                // OR IGNORE: если ключ уже исправлен руками, распознанное значение не нужно
                try db.run("""
                    INSERT OR IGNORE INTO field (document_id, key, value, confidence, source, verified)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, [documentID, field.key, field.value, field.confidence, field.source.rawValue, field.verified])
            }
            return documentID
        }
    }

    /// Файл переименовали: текст тот же, меняются имя и фрагмент-заголовок
    func renameDocument(folderID: UUID, from oldName: String, to newName: String, title: ChunkRecord) throws {
        try db.transaction {
            let folder = folderID.uuidString
            let ids = try db.query(
                "SELECT id FROM document WHERE folder_id = ? AND file_name = ?",
                [folder, oldName]
            ) { $0.int64(0) }
            guard let id = ids.first else { return }

            // Устаревшая запись под новым именем мешала бы ограничению UNIQUE
            try db.run("DELETE FROM document WHERE folder_id = ? AND file_name = ?", [folder, newName])
            try db.run(
                "UPDATE document SET file_name = ?, title = ? WHERE id = ?",
                [newName, title.text, id]
            )
            try retitle(documentID: id, with: title)
        }
    }

    /// Файл перенесли в другую папку: строка документа переезжает целиком —
    /// с фрагментами, полями и ручными правками. Меняются папка, имя и заголовок
    func moveDocument(
        folderID: UUID,
        fileName: String,
        toFolder destination: UUID,
        newName: String,
        title: ChunkRecord
    ) throws {
        try db.transaction {
            let ids = try db.query(
                "SELECT id FROM document WHERE folder_id = ? AND file_name = ?",
                [folderID.uuidString, fileName]
            ) { $0.int64(0) }
            guard let id = ids.first else { return }

            // Устаревшая запись под тем же именем в папке назначения мешала бы
            // ограничению UNIQUE: файла с таким именем там уже нет
            try db.run(
                "DELETE FROM document WHERE folder_id = ? AND file_name = ? AND id != ?",
                [destination.uuidString, newName, id]
            )
            try db.run(
                "UPDATE document SET folder_id = ?, file_name = ?, title = ? WHERE id = ?",
                [destination.uuidString, newName, title.text, id]
            )
            try retitle(documentID: id, with: title)
        }
    }

    /// Фрагмент-заголовок (страница 0) ищется по имени файла — после смены
    /// имени он переписывается вместе со строкой FTS
    private func retitle(documentID id: Int64, with title: ChunkRecord) throws {
        let titleChunks = try db.query(
            "SELECT id FROM chunk WHERE document_id = ? AND page = 0",
            [id]
        ) { $0.int64(0) }
        for chunkID in titleChunks {
            try db.run("UPDATE chunk SET text = ? WHERE id = ?", [title.text, chunkID])
            try db.run(
                "UPDATE chunk_fts SET words = ?, stems = ? WHERE rowid = ?",
                [title.words, title.stems, chunkID]
            )
        }
    }

    @discardableResult
    func deleteDocument(folderID: UUID, fileName: String) throws -> Bool {
        try db.run(
            "DELETE FROM document WHERE folder_id = ? AND file_name = ?",
            [folderID.uuidString, fileName]
        )
        return try db.scalar("SELECT changes()") > 0
    }

    /// Всё, что извлечено из папки: документы, фрагменты, поля и векторы
    @discardableResult
    func deleteFolder(_ folderID: UUID) throws -> Int {
        try db.run("DELETE FROM document WHERE folder_id = ?", [folderID.uuidString])
        let removed = try db.scalar("SELECT changes()")
        if removed > 0 { try compact() }
        return removed
    }

    /// Папки, которых больше нет или которые убрали из поиска
    @discardableResult
    func deleteFolders(except keep: Set<UUID>) throws -> Int {
        let stale = try db.query("SELECT DISTINCT folder_id FROM document") { $0.text(0) }
            .filter { UUID(uuidString: $0).map { !keep.contains($0) } ?? true }
        guard !stale.isEmpty else { return 0 }
        var removed = 0
        try db.transaction {
            for folder in stale {
                try db.run("DELETE FROM document WHERE folder_id = ?", [folder])
                removed += try db.scalar("SELECT changes()")
            }
        }
        try compact()
        return removed
    }

    /// Удаление строки в FTS5 оставляет в старых сегментах индекса её слова
    /// до слияния. optimize сливает сегменты, а secure_delete затирает
    /// освободившиеся страницы — после этого текст не восстановить из файла
    func compact() throws {
        try db.run("INSERT INTO chunk_fts (chunk_fts) VALUES ('optimize')")
    }

    // MARK: - Поиск

    func search(_ expression: String, folders: Set<UUID>, limit: Int) throws -> [ChunkMatch] {
        guard !folders.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: folders.count).joined(separator: ", ")
        var values: [any SQLiteBindable] = [expression]
        values.append(contentsOf: folders.map(\.uuidString))
        values.append(limit)
        return try db.query("""
            SELECT chunk.id, chunk.document_id, chunk.page, bm25(chunk_fts) AS score
            FROM chunk_fts
            JOIN chunk ON chunk.id = chunk_fts.rowid
            JOIN document ON document.id = chunk.document_id
            WHERE chunk_fts MATCH ? AND document.folder_id IN (\(placeholders))
            ORDER BY score
            LIMIT ?
            """, values) { row in
            ChunkMatch(chunkID: row.int64(0), documentID: row.int64(1), page: row.int(2), score: row.double(3))
        }
    }

    func documents(ids: [Int64]) throws -> [Int64: StoredDocument] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let rows = try db.query(
            "SELECT id, folder_id, file_name, type, page_count FROM document WHERE id IN (\(placeholders))",
            ids
        ) { row in
            StoredDocument(
                id: row.int64(0),
                folderID: UUID(uuidString: row.text(1)) ?? UUID(),
                fileName: row.text(2),
                type: DocumentType(rawValue: row.text(3)) ?? .other,
                pageCount: row.int(4)
            )
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    func chunkTexts(ids: [Int64]) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let rows = try db.query(
            "SELECT id, text FROM chunk WHERE id IN (\(placeholders))",
            ids
        ) { ($0.int64(0), $0.text(1)) }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    struct RowCounts: Equatable {
        let documents: Int
        let chunks: Int
        let ftsRows: Int
        let fields: Int
    }

    /// Строки во всех таблицах: удаление не должно оставлять сирот в FTS
    func rowCounts() throws -> RowCounts {
        RowCounts(
            documents: try db.scalar("SELECT count(*) FROM document"),
            chunks: try db.scalar("SELECT count(*) FROM chunk"),
            ftsRows: try db.scalar("SELECT count(*) FROM chunk_fts"),
            fields: try db.scalar("SELECT count(*) FROM field")
        )
    }

    /// Какие файлы есть в индексе. Для проверок: суперскрытой папки здесь быть не должно
    func indexedFiles() throws -> [FileKey] {
        try db.query("SELECT folder_id, file_name FROM document ORDER BY id") { row in
            FileKey(folderID: UUID(uuidString: row.text(0)) ?? UUID(), name: row.text(1))
        }
    }

    func documentCount(folders: Set<UUID>) throws -> Int {
        guard !folders.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: folders.count).joined(separator: ", ")
        return try db.scalar(
            "SELECT count(*) FROM document WHERE folder_id IN (\(placeholders))",
            folders.map(\.uuidString)
        )
    }

    /// Документы нужных типов из разрешённых папок — для ответов чата
    func documents(types: [DocumentType], folders: Set<UUID>) throws -> [StoredDocument] {
        guard !types.isEmpty, !folders.isEmpty else { return [] }
        let typeMarks = Array(repeating: "?", count: types.count).joined(separator: ", ")
        let folderMarks = Array(repeating: "?", count: folders.count).joined(separator: ", ")
        var values: [any SQLiteBindable] = types.map(\.rawValue)
        values.append(contentsOf: folders.map(\.uuidString))
        return try db.query("""
            SELECT id, folder_id, file_name, type, page_count FROM document
            WHERE type IN (\(typeMarks)) AND folder_id IN (\(folderMarks))
            ORDER BY indexed_at DESC
            """, values) { row in
            StoredDocument(
                id: row.int64(0),
                folderID: UUID(uuidString: row.text(1)) ?? UUID(),
                fileName: row.text(2),
                type: DocumentType(rawValue: row.text(3)) ?? .other,
                pageCount: row.int(4)
            )
        }
    }

    // MARK: - Поля

    func fields(documentIDs ids: [Int64]) throws -> [Int64: [DocumentField]] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let rows = try db.query(
            "SELECT document_id, key, value, confidence, source, verified FROM field WHERE document_id IN (\(placeholders)) ORDER BY rowid",
            ids
        ) { row in
            (row.int64(0), DocumentField(
                key: row.text(1),
                value: row.text(2),
                confidence: row.double(3),
                source: FieldSource(rawValue: row.text(4)) ?? .regex,
                verified: row.bool(5)
            ))
        }
        return Dictionary(grouping: rows, by: \.0).mapValues { $0.map(\.1) }
    }

    /// Человек сверил поле с фото и подтвердил: значение остаётся прежним
    func verifyField(documentID: Int64, key: String) throws {
        try db.run(
            "UPDATE field SET verified = 1 WHERE document_id = ? AND key = ?",
            [documentID, key]
        )
    }

    func fields(documentID: Int64) throws -> [DocumentField] {
        try db.query(
            "SELECT key, value, confidence, source, verified FROM field WHERE document_id = ? ORDER BY rowid",
            [documentID]
        ) { row in
            DocumentField(
                key: row.text(0),
                value: row.text(1),
                confidence: row.double(2),
                source: FieldSource(rawValue: row.text(3)) ?? .regex,
                verified: row.bool(4)
            )
        }
    }

    // MARK: - Второе чтение моделью

    /// Отметки второго чтения: ревизия — модель прочитала документ; «rules:» —
    /// правила подтвердили всё, модель не понадобилась; «none:» — модель
    /// пробовала, но значений не дала
    enum ModelMark {
        static func read(_ revision: String) -> String { revision }
        static func notNeeded(_ revision: String) -> String { "rules:\(revision)" }
        static func failed(_ revision: String) -> String { "none:\(revision)" }
    }

    /// Удостоверения из разрешённых папок, которые ещё не читала ни одна модель.
    /// Прочитанное другой моделью заново не читается: владелец 24.10.2026 сменил
    /// модель — и приложение принялось перечитывать всё. Новая модель читает
    /// новые файлы и те, что прежней не дались («none:»); перечитать всё —
    /// отдельной кнопкой (`resetModelMarks`)
    func modelCandidates(types: [DocumentType], revision: String, folders: Set<UUID>) throws -> [ModelReadCandidate] {
        guard !types.isEmpty, !folders.isEmpty else { return [] }
        let typeMarks = Array(repeating: "?", count: types.count).joined(separator: ", ")
        let folderMarks = Array(repeating: "?", count: folders.count).joined(separator: ", ")
        var values: [any SQLiteBindable] = types.map(\.rawValue)
        values.append(contentsOf: folders.map(\.uuidString))
        values.append(ModelMark.failed(revision))
        return try db.query("""
            SELECT id, folder_id, file_name, type, file_size, file_modified FROM document
            WHERE type IN (\(typeMarks)) AND folder_id IN (\(folderMarks)) AND failed = 0
                AND (model_revision IS NULL
                     OR (substr(model_revision, 1, 5) = 'none:' AND model_revision != ?))
            ORDER BY indexed_at DESC
            """, values) { row in
            ModelReadCandidate(
                documentID: row.int64(0),
                folderID: UUID(uuidString: row.text(1)) ?? UUID(),
                fileName: row.text(2),
                type: DocumentType(rawValue: row.text(3)) ?? .other,
                fileSize: row.int64(4),
                fileModified: row.double(5)
            )
        }
    }

    /// Модель документ прочитала или читать там нечего: второй раз не нужно
    func markModelRead(documentID: Int64, revision: String) throws {
        try db.run("UPDATE document SET model_revision = ? WHERE id = ?", [revision, documentID])
    }

    /// Поля после второго чтения. Исправленное и подтверждённое человеком
    /// не перезаписывается, даже если слияние почему-то вернуло другое.
    /// `type` — модель узнала документ, которого правила не узнали
    func applyModelFields(documentID: Int64, fields: [DocumentField], revision: String, type: DocumentType? = nil) throws {
        try db.transaction {
            if let type {
                try db.run("UPDATE document SET type = ? WHERE id = ?", [type.rawValue, documentID])
            }
            for field in fields {
                try db.run("""
                    INSERT INTO field (document_id, key, value, confidence, source, verified)
                    VALUES (?, ?, ?, ?, ?, 0)
                    ON CONFLICT (document_id, key) DO UPDATE SET
                        value = excluded.value, confidence = excluded.confidence, source = excluded.source
                    WHERE field.source != ? AND field.verified = 0
                    """, [documentID, field.key, field.value, field.confidence, field.source.rawValue, FieldSource.manual.rawValue])
            }
            try db.run("UPDATE document SET model_revision = ? WHERE id = ?", [revision, documentID])
        }
    }

    func documentID(folderID: UUID, fileName: String) throws -> Int64? {
        try db.query(
            "SELECT id FROM document WHERE folder_id = ? AND file_name = ?",
            [folderID.uuidString, fileName]
        ) { $0.int64(0) }.first
    }

    /// Метаданные документов: JSON по id
    func metadata(documentIDs ids: [Int64]) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let rows = try db.query(
            "SELECT document_id, json FROM document_meta WHERE document_id IN (\(placeholders))",
            ids
        ) { ($0.int64(0), $0.text(1)) }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    /// Весь текст документа со страниц от 1 — для облака, когда отправлять
    /// картинку незачем
    func documentText(documentID: Int64) throws -> String {
        try db.query(
            "SELECT text FROM chunk WHERE document_id = ? AND page > 0 ORDER BY page, id",
            [documentID]
        ) { $0.text(0) }.joined(separator: "\n")
    }

    /// Текст страницы от Vision — им подтверждаются значения модели
    func pageText(documentID: Int64, page: Int = 1) throws -> String {
        try db.query(
            "SELECT text FROM chunk WHERE document_id = ? AND page = ? ORDER BY id",
            [documentID, page]
        ) { $0.text(0) }.joined(separator: "\n")
    }

    struct ModelCounts: Equatable {
        var identity = 0
        var read = 0
    }

    /// Удостоверения разрешённых папок и сколько из них прочитала эта модель
    func modelCounts(types: [DocumentType], revision: String, folders: Set<UUID>) throws -> ModelCounts {
        guard !types.isEmpty, !folders.isEmpty else { return ModelCounts() }
        let typeMarks = Array(repeating: "?", count: types.count).joined(separator: ", ")
        let folderMarks = Array(repeating: "?", count: folders.count).joined(separator: ", ")
        var values: [any SQLiteBindable] = types.map(\.rawValue)
        values.append(contentsOf: folders.map(\.uuidString))
        // Прочитанным считается прочитанное любой моделью: отметки «rules:» и
        // «none:» — не чтение
        return try db.query("""
            SELECT count(*), coalesce(sum(model_revision IS NOT NULL
                AND substr(model_revision, 1, 6) != 'rules:' AND substr(model_revision, 1, 5) != 'none:'), 0)
            FROM document
            WHERE type IN (\(typeMarks)) AND folder_id IN (\(folderMarks))
            """, values) { row in ModelCounts(identity: row.int(0), read: row.int(1)) }.first ?? ModelCounts()
    }

    /// Второе чтение одного файла: nil — файл не удостоверение или не в индексе
    func modelState(folderID: UUID, fileName: String, types: [DocumentType], revision: String) throws -> ModelReadState? {
        let rows = try db.query(
            "SELECT type, model_revision FROM document WHERE folder_id = ? AND file_name = ?",
            [folderID.uuidString, fileName]
        ) { row in (DocumentType(rawValue: row.text(0)) ?? .other, row.isNull(1) ? nil : row.text(1)) }
        guard let (type, mark) = rows.first, types.contains(type) else { return nil }
        guard let mark else { return .waiting }
        if mark.hasPrefix("rules:") { return .notNeeded }
        // Не далось другой модели — эта ещё попробует
        if mark.hasPrefix("none:") { return mark == ModelMark.failed(revision) ? .failed : .waiting }
        return .read
    }

    // MARK: - Облако

    /// Отметки облака: «cloud:…» — прочитан; «cloud-skip:…» — отправлять
    /// нечего (текстовый PDF, не фото); «cloud-fail:…» — ответ не разобрался
    enum CloudMark {
        static func skipped(_ mark: String) -> String { "\(mark)#skip" }
        static func failed(_ mark: String) -> String { "\(mark)#fail" }
        /// Версия схемы ответа: «cloud3:» из «cloud3:openai:gpt-6.1-sol». Её
        /// повышают, когда облако должно вернуть новое (метаданные, прописку)
        static func generation(_ mark: String) -> String {
            String(mark.prefix { $0 != ":" }) + ":"
        }
    }

    /// Документы разрешённых папок, которые облако этой версии схемы ещё не
    /// читало. Другая модель или сервис прочитанное заново не отправляют —
    /// это страницы и деньги (владелец 24.10.2026: «поменял модель — зачем
    /// всё заново распознала»). Не далось прежней модели — эта попробует;
    /// перечитать всё — отдельной кнопкой (`resetCloudMarks`)
    func cloudCandidates(mark: String, folders: Set<UUID>) throws -> [ModelReadCandidate] {
        guard !folders.isEmpty else { return [] }
        let folderMarks = Array(repeating: "?", count: folders.count).joined(separator: ", ")
        let generation = CloudMark.generation(mark)
        var values: [any SQLiteBindable] = folders.map(\.uuidString)
        values.append(contentsOf: [generation.count, generation, CloudMark.failed(mark)] as [any SQLiteBindable])
        return try db.query("""
            SELECT id, folder_id, file_name, type, file_size, file_modified FROM document
            WHERE folder_id IN (\(folderMarks))
                AND (cloud_revision IS NULL
                     OR substr(cloud_revision, 1, ?) != ?
                     OR (substr(cloud_revision, -5) = '#fail' AND cloud_revision != ?))
            ORDER BY indexed_at DESC
            """, values) { row in
            ModelReadCandidate(
                documentID: row.int64(0),
                folderID: UUID(uuidString: row.text(1)) ?? UUID(),
                fileName: row.text(2),
                type: DocumentType(rawValue: row.text(3)) ?? .other,
                fileSize: row.int64(4),
                fileModified: row.double(5)
            )
        }
    }

    /// «Перечитать всё»: отметки облака в разрешённых папках стираются, и
    /// очередь отправит документы заново — уже выбранной моделью
    func resetCloudMarks(folders: Set<UUID>) throws {
        guard !folders.isEmpty else { return }
        let folderMarks = Array(repeating: "?", count: folders.count).joined(separator: ", ")
        try db.run("UPDATE document SET cloud_revision = NULL WHERE folder_id IN (\(folderMarks))", folders.map(\.uuidString))
    }

    /// «Перечитать всё» для модели на iPhone: так же, только отметки модели
    func resetModelMarks(folders: Set<UUID>) throws {
        guard !folders.isEmpty else { return }
        let folderMarks = Array(repeating: "?", count: folders.count).joined(separator: ", ")
        try db.run("UPDATE document SET model_revision = NULL WHERE folder_id IN (\(folderMarks))", folders.map(\.uuidString))
    }

    func markCloud(documentID: Int64, mark: String) throws {
        try db.run("UPDATE document SET cloud_revision = ? WHERE id = ?", [mark, documentID])
    }

    /// Прочитанное облаком: его текст заменяет фрагменты этих страниц, поля
    /// сливаются (ручное и подтверждённое человеком не меняется), вид документа —
    /// если облако узнало его, а правила нет
    func applyCloud(
        documentID: Int64,
        fields: [DocumentField],
        pages: [Int],
        chunks: [ChunkRecord],
        type: DocumentType?,
        mark: String,
        metadata: (json: String, chunk: ChunkRecord)? = nil
    ) throws {
        try db.transaction {
            if let type {
                try db.run("UPDATE document SET type = ? WHERE id = ?", [type.rawValue, documentID])
            }
            if let metadata {
                try db.run("""
                    INSERT INTO document_meta (document_id, json, revision) VALUES (?, ?, ?)
                    ON CONFLICT (document_id) DO UPDATE SET json = excluded.json, revision = excluded.revision
                    """, [documentID, metadata.json, mark])
                try db.run("DELETE FROM chunk WHERE document_id = ? AND page = ?", [documentID, Self.metadataPage])
                try db.run("INSERT INTO chunk (document_id, page, text) VALUES (?, ?, ?)", [documentID, Self.metadataPage, metadata.chunk.text])
                try db.run(
                    "INSERT INTO chunk_fts (rowid, words, stems) VALUES (?, ?, ?)",
                    [db.lastInsertRowID, metadata.chunk.words, metadata.chunk.stems]
                )
            }
            for field in fields {
                try db.run("""
                    INSERT INTO field (document_id, key, value, confidence, source, verified)
                    VALUES (?, ?, ?, ?, ?, 0)
                    ON CONFLICT (document_id, key) DO UPDATE SET
                        value = excluded.value, confidence = excluded.confidence, source = excluded.source
                    WHERE field.source != ? AND field.verified = 0
                    """, [documentID, field.key, field.value, field.confidence, field.source.rawValue, FieldSource.manual.rawValue])
            }
            for page in pages {
                try db.run("DELETE FROM chunk WHERE document_id = ? AND page = ?", [documentID, page])
            }
            for chunk in chunks {
                try db.run("INSERT INTO chunk (document_id, page, text) VALUES (?, ?, ?)", [documentID, chunk.page, chunk.text])
                try db.run(
                    "INSERT INTO chunk_fts (rowid, words, stems) VALUES (?, ?, ?)",
                    [db.lastInsertRowID, chunk.words, chunk.stems]
                )
            }
            try db.run("UPDATE document SET cloud_revision = ? WHERE id = ?", [mark, documentID])
        }
    }

    /// Документы разрешённых папок и сколько из них прочитано облаком
    func cloudCounts(mark: String, folders: Set<UUID>) throws -> ModelCounts {
        guard !folders.isEmpty else { return ModelCounts() }
        let folderMarks = Array(repeating: "?", count: folders.count).joined(separator: ", ")
        let generation = CloudMark.generation(mark)
        var values: [any SQLiteBindable] = [generation.count, generation]
        values.append(contentsOf: folders.map(\.uuidString))
        // Прочитанное любой моделью этой версии схемы; «#skip» и «#fail» — не чтение
        return try db.query("""
            SELECT count(*), coalesce(sum(cloud_revision IS NOT NULL AND substr(cloud_revision, 1, ?) = ?
                AND substr(cloud_revision, -5) NOT IN ('#skip', '#fail')), 0)
            FROM document
            WHERE folder_id IN (\(folderMarks))
            """, values) { row in ModelCounts(identity: row.int(0), read: row.int(1)) }.first ?? ModelCounts()
    }

    func cloudState(folderID: UUID, fileName: String, mark: String) throws -> CloudReadState? {
        let rows = try db.query(
            "SELECT cloud_revision FROM document WHERE folder_id = ? AND file_name = ?",
            [folderID.uuidString, fileName]
        ) { row in row.isNull(0) ? nil : row.text(0) }
        guard let first = rows.first else { return nil }
        guard let stored = first, stored.hasPrefix(CloudMark.generation(mark)) else { return .waiting }
        if stored.hasSuffix("#skip") { return .notNeeded }
        // Не далось другой модели — эта ещё попробует
        if stored.hasSuffix("#fail") { return stored == CloudMark.failed(mark) ? .failed : .waiting }
        return .read
    }

    /// Какая модель прочитала документ. Для проверок
    func modelRevision(documentID: Int64) throws -> String? {
        try db.query("SELECT model_revision FROM document WHERE id = ?", [documentID]) { row in
            row.isNull(0) ? nil : row.text(0)
        }.first ?? nil
    }

    /// Правка человеком: значение проверено и больше не перезаписывается
    func setManualField(documentID: Int64, key: String, value: String) throws {
        try db.run("""
            INSERT INTO field (document_id, key, value, confidence, source, verified)
            VALUES (?, ?, ?, 1.0, ?, 1)
            ON CONFLICT (document_id, key) DO UPDATE SET
                value = excluded.value, confidence = 1.0, source = excluded.source, verified = 1
            """, [documentID, key, value, FieldSource.manual.rawValue])
    }
}
