import Foundation

/// Откуда блок берёт настоящие данные приложения — как это прислала модель.
/// Параметры могут быть выражениями над состоянием: срок «в ближайшие N дней»
/// следует за ползунком
struct GenUIDataSourceSpec: Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case documents
        case documentStats = "document_stats"
        case expiring
        case amounts
        case fields
    }

    /// Колонки, которые `documents` вправе вернуть. Номеров среди них нет
    static let documentColumns = ["id", "title", "kind", "type", "category", "folder", "owner", "document_date", "valid_until", "pages"]
    static let groupings = ["category", "type", "kind", "folder", "owner", "month", "year"]
    static let metrics = ["count", "amount_sum"]

    let kind: Kind
    var types: [String]?
    var categories: [String]?
    var folderID: UUID?
    var owner: String?
    var query: String?
    var columns: [String]?
    var groupBy: String?
    var metric: String?
    var currency: String?
    var withinDays: GenUIValue?
    var from: GenUIValue?
    var to: GenUIValue?
    var documentID: Int64?
    var keys: [String]?

    init(kind: Kind) {
        self.kind = kind
    }

    /// Запрос с вычисленными параметрами — его выполняет приложение
    @MainActor
    func resolved(with state: GenUIState) -> GenUIDataSource {
        var source = GenUIDataSource(kind: kind)
        source.types = types
        source.categories = categories
        source.folderID = folderID
        source.owner = owner
        source.query = query
        source.columns = columns
        source.groupBy = groupBy
        source.metric = metric
        source.currency = currency
        source.withinDays = withinDays.flatMap { state.evaluate($0)?.number }.map { Int($0.rounded()) }
        source.from = from.flatMap { state.evaluate($0)?.day }
        source.to = to.flatMap { state.evaluate($0)?.day }
        source.documentID = documentID
        source.keys = keys
        return source
    }
}

/// Запрос к данным приложения с готовыми параметрами
struct GenUIDataSource: Hashable, Sendable {
    let kind: GenUIDataSourceSpec.Kind
    var types: [String]?
    var categories: [String]?
    var folderID: UUID?
    var owner: String?
    var query: String?
    var columns: [String]?
    var groupBy: String?
    var metric: String?
    var currency: String?
    var withinDays: Int?
    var from: GenUIDay?
    var to: GenUIDay?
    var documentID: Int64?
    var keys: [String]?

    init(kind: GenUIDataSourceSpec.Kind) {
        self.kind = kind
    }
}

/// Строки, которые вернуло приложение: таблица значений по колонкам
struct GenUIRows: Hashable, Sendable {
    var columns: [String]
    var rows: [[String: GenUIScalar]]

    static let empty = GenUIRows(columns: [], rows: [])

    init(columns: [String], rows: [[String: GenUIScalar]]) {
        self.columns = columns
        self.rows = rows
    }

    /// Строки-массивы в порядке колонок — как их присылает модель
    init(columns: [String], values: [[GenUIScalar]]) {
        self.columns = columns
        rows = values.map { cells in
            var row: [String: GenUIScalar] = [:]
            for (index, key) in columns.enumerated() where index < cells.count {
                row[key] = cells[index]
            }
            return row
        }
    }
}

/// Ряд, вычисляемый на iPhone: график платежей, таблица по годам
struct GenUIGenerate: Hashable, Sendable {
    struct Column: Hashable, Sendable {
        let key: String
        let expression: GenUIExpression
    }

    let variable: String
    let from: GenUIValue
    let to: GenUIValue
    let step: GenUIValue?
    let columns: [Column]

    /// Строки ряда при текущем состоянии. Больше лимита точек — ничего:
    /// интерфейс покажет «—», а не повиснет
    @MainActor
    func rows(with state: GenUIState) -> GenUIRows? {
        guard let start = state.evaluate(from)?.number,
              let end = state.evaluate(to)?.number else { return nil }
        let stride = step.flatMap { state.evaluate($0)?.number } ?? 1
        guard stride > 0, end >= start else { return GenUIRows(columns: [variable] + columns.map(\.key), rows: []) }
        let count = Int(((end - start) / stride).rounded(.down)) + 1
        guard count <= GenUILimits.maxChartPoints else { return nil }

        var rows: [[String: GenUIScalar]] = []
        rows.reserveCapacity(count)
        var previous: [String: GenUIScalar] = [:]
        for index in 0..<count {
            let value = start + Double(index) * stride
            var row: [String: GenUIScalar] = [variable: .number(value)]
            for column in columns {
                // На первой строке prev.<колонка> = 0: так считаются накопления
                var extra: [String: GenUIScalar] = [variable: .number(value)]
                for (key, scalar) in row { extra[key] = scalar }
                for column in columns { extra["prev.\(column.key)"] = previous[column.key] ?? .number(0) }
                row[column.key] = state.evaluate(.expression(column.expression), extra: extra) ?? .null
            }
            rows.append(row)
            previous = row
        }
        return GenUIRows(columns: [variable] + columns.map(\.key), rows: rows)
    }
}
