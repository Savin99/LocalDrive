import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { "SQLite \(code): \(message)" }
}

/// Значение, которое можно подставить в запрос вместо `?`
protocol SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32
}

// SQLite копирует строку и данные сам: буфер Swift живёт только во время вызова
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension String: SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_text(statement, index, self, -1, transient)
    }
}

extension Int: SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_int64(statement, index, Int64(self))
    }
}

extension Int64: SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_int64(statement, index, self)
    }
}

extension Double: SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_double(statement, index, self)
    }
}

extension Bool: SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        sqlite3_bind_int64(statement, index, self ? 1 : 0)
    }
}

extension Data: SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transient)
        }
    }
}

extension Optional: SQLiteBindable where Wrapped: SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        switch self {
        case .some(let value): value.bind(to: statement, at: index)
        case .none: sqlite3_bind_null(statement, index)
        }
    }
}

/// Строка результата: значения читаются по номеру колонки, начиная с нуля
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func bool(_ column: Int32) -> Bool {
        sqlite3_column_int64(statement, column) != 0
    }

    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    func data(_ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

/// Одно соединение с базой. Не потокобезопасно: владелец — актор индекса,
/// он и обращается к соединению строго по очереди
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    /// Подготовленные запросы переиспользуются: индексация вставляет
    /// тысячи строк одними и теми же командами
    private var statements: [String: OpaquePointer] = [:]

    /// `url == nil` — база в памяти. Файл открывается с классом защиты
    /// `.complete`: пока iPhone заблокирован, база зашифрована вместе с файлами
    init(url: URL?) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
            | SQLITE_OPEN_FILEPROTECTION_COMPLETE
        var db: OpaquePointer?
        let code = sqlite3_open_v2(url?.path ?? ":memory:", &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "база не открылась"
            sqlite3_close(db)
            throw SQLiteError(code: code, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit {
        close()
    }

    func close() {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
        statements.removeAll()
        if let handle {
            sqlite3_close(handle)
        }
        handle = nil
    }

    var lastInsertRowID: Int64 {
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Скрипт из нескольких команд без параметров — схема и PRAGMA
    func execute(_ sql: String) throws {
        let handle = try openHandle()
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &error)
        guard code == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(error)
            throw SQLiteError(code: code, message: message)
        }
    }

    func run(_ sql: String, _ values: [any SQLiteBindable] = []) throws {
        let statement = try prepared(sql, values)
        defer { sqlite3_reset(statement) }
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw lastError(code) }
    }

    func query<T>(
        _ sql: String,
        _ values: [any SQLiteBindable] = [],
        map: (SQLiteRow) throws -> T
    ) throws -> [T] {
        let statement = try prepared(sql, values)
        defer { sqlite3_reset(statement) }
        var rows: [T] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            rows.append(try map(SQLiteRow(statement: statement)))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw lastError(code) }
        return rows
    }

    func scalar(_ sql: String, _ values: [any SQLiteBindable] = []) throws -> Int {
        try query(sql, values) { $0.int(0) }.first ?? 0
    }

    /// Всё или ничего: документ не должен остаться в индексе наполовину
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Внутреннее

    private func openHandle() throws -> OpaquePointer {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "база закрыта") }
        return handle
    }

    private func prepared(_ sql: String, _ values: [any SQLiteBindable]) throws -> OpaquePointer {
        let handle = try openHandle()
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        } else {
            var created: OpaquePointer?
            let code = sqlite3_prepare_v2(handle, sql, -1, &created, nil)
            guard code == SQLITE_OK, let created else { throw lastError(code) }
            statements[sql] = created
            statement = created
        }
        for (offset, value) in values.enumerated() {
            let code = value.bind(to: statement, at: Int32(offset + 1))
            guard code == SQLITE_OK else { throw lastError(code) }
        }
        return statement
    }

    private func lastError(_ code: Int32) -> SQLiteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "база закрыта"
        return SQLiteError(code: code, message: message)
    }
}
