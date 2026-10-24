import Foundation

/// День без времени. Даты в интерфейсе модели — строкой «ГГГГ-ММ-ДД»: так их
/// понимает и модель, и JSON Schema (`format: date`). Арифметика — в
/// григорианском календаре по UTC, чтобы переход на летнее время не сдвигал день
struct GenUIDay: Hashable, Sendable, Comparable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        // 31.02 не бывает: календарь перенёс бы его на март
        guard let date = Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              Self.calendar.component(.day, from: date) == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// «2026-10-12»
    init?(iso text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count == 10, parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// День по часам iPhone — в его часовом поясе
    init(date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = components.year ?? 1970
        self.month = components.month ?? 1
        self.day = components.day ?? 1
    }

    /// Полдень по UTC: от него считаются дни и месяцы
    var date: Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date(timeIntervalSince1970: 0)
    }

    /// Тот же день в часовом поясе iPhone — для системного выбора даты
    func localDate(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? date
    }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// «12.10.2026»
    var russian: String { String(format: "%02d.%02d.%04d", day, month, year) }

    var description: String { iso }

    func adding(_ component: Calendar.Component, _ value: Int) -> GenUIDay? {
        guard let moved = Self.calendar.date(byAdding: component, value: value, to: date) else { return nil }
        return GenUIDay(date: moved, calendar: Self.calendar)
    }

    static func < (lhs: GenUIDay, rhs: GenUIDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// Тип переменной состояния
enum GenUIValueKind: String, Hashable, Sendable {
    case number
    case string
    case bool
    case date
}

/// Значение в интерфейсе: литерал из JSON, переменная состояния, результат выражения
enum GenUIScalar: Hashable, Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case date(GenUIDay)

    /// Литерал JSON. Строка «ГГГГ-ММ-ДД» — дата: так модель пишет даты
    init?(json: JSONValue) {
        switch json {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .number(let value):
            guard value.isFinite else { return nil }
            self = .number(value)
        case .string(let value):
            if let day = GenUIDay(iso: value) {
                self = .date(day)
            } else {
                self = .string(value)
            }
        case .array, .object: return nil
        }
    }

    var kind: GenUIValueKind? {
        switch self {
        case .null: nil
        case .bool: .bool
        case .number: .number
        case .string: .string
        case .date: .date
        }
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Дата — и строкой «ГГГГ-ММ-ДД», если пришла строкой
    var day: GenUIDay? {
        switch self {
        case .date(let day): day
        case .string(let text): GenUIDay(iso: text)
        default: nil
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Истинность для `visible_if` и логики: пустое и ноль — ложь
    var truthy: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): !value.isEmpty
        case .date: true
        }
    }

    var json: JSONValue {
        switch self {
        case .null: .null
        case .bool(let value): .bool(value)
        case .number(let value): .number(value)
        case .string(let value): .string(value)
        case .date(let day): .string(day.iso)
        }
    }

    /// Значение того же типа по умолчанию — для переменной без начального значения
    static func defaultValue(for kind: GenUIValueKind) -> GenUIScalar {
        switch kind {
        case .number: .number(0)
        case .string: .string("")
        case .bool: .bool(false)
        case .date: .date(GenUIDay(date: Date()))
        }
    }

    /// Привести к типу, если это возможно без потери смысла: «5» → 5
    func coerced(to kind: GenUIValueKind) -> GenUIScalar? {
        if self.kind == kind { return self }
        switch (self, kind) {
        case (.string(let text), .number):
            return Double(text.replacingOccurrences(of: ",", with: ".")).map(GenUIScalar.number)
        case (.number(let value), .string):
            return .string(GenUIFormat.number(value))
        case (.string(let text), .date):
            return GenUIDay(iso: text).map(GenUIScalar.date)
        case (.date(let day), .string):
            return .string(day.iso)
        case (.number(let value), .bool):
            return .bool(value != 0)
        default:
            return nil
        }
    }

    var description: String { GenUIFormat.display(self) }
}
