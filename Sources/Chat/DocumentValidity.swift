import Foundation

/// Срок действия документа для карточки `expiry`
struct DocumentValidity: Equatable {
    enum Status: Equatable {
        /// Действует до даты — загранпаспорт
        case until(Date)
        /// Паспорт РФ меняют по достижении 20 и 45 лет
        case replaceAtAge(Int, Date)
        /// Паспорт РФ, выданный после 45 лет, бессрочный
        case indefinite
        case unknown
    }

    let status: Status

    var date: Date? {
        switch status {
        case .until(let date), .replaceAtAge(_, let date): date
        case .indefinite, .unknown: nil
        }
    }

    /// `validUntil` — срок из метаданных облачного распознавания: у полиса,
    /// договора, справки. Поле «Действует до» у них не распознаётся
    static func of(type: DocumentType, fields: [String: String], validUntil: String? = nil, today: Date = Date()) -> DocumentValidity {
        switch type {
        case .passportIntl, .driverLicense:
            guard let expiry = (fields[FieldKey.expiryDate] ?? validUntil).flatMap(parse) else { return .init(status: .unknown) }
            return .init(status: .until(expiry))
        case .passportRU:
            // Срок действия в MRZ не пишется: он следует из возраста.
            // Паспорт, полученный до 20 лет, меняют в 20; до 45 — в 45
            guard let birth = fields[FieldKey.birthDate].flatMap(parse) else { return .init(status: .unknown) }
            let calendar = Calendar(identifier: .gregorian)
            guard let at20 = calendar.date(byAdding: .year, value: 20, to: birth),
                  let at45 = calendar.date(byAdding: .year, value: 45, to: birth) else { return .init(status: .unknown) }
            let reference = fields[FieldKey.issueDate].flatMap(parse) ?? today
            if reference < at20 { return .init(status: .replaceAtAge(20, at20)) }
            if reference < at45 { return .init(status: .replaceAtAge(45, at45)) }
            return .init(status: .indefinite)
        default:
            // Полис, договор, справка — срок только из метаданных облака
            guard let expiry = validUntil.flatMap(parse) else { return .init(status: .unknown) }
            return .init(status: .until(expiry))
        }
    }

    /// «осталось 4 года 5 месяцев», «истёк 2 месяца назад»
    func remainingText(today: Date = Date()) -> String? {
        guard let date else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: today)
        let end = calendar.startOfDay(for: date)
        if start == end { return "истекает сегодня" }
        let expired = end < start
        let parts = calendar.dateComponents([.year, .month, .day], from: min(start, end), to: max(start, end))
        var pieces: [String] = []
        if let years = parts.year, years > 0 { pieces.append(pluralize(years, "год", "года", "лет")) }
        if let months = parts.month, months > 0 { pieces.append(pluralize(months, "месяц", "месяца", "месяцев")) }
        if pieces.isEmpty, let days = parts.day { pieces.append(pluralize(days, "день", "дня", "дней")) }
        let span = pieces.prefix(2).joined(separator: " ")
        return expired ? "истёк \(span) назад" : "осталось \(span)"
    }

    func isExpired(today: Date = Date()) -> Bool {
        guard let date else { return false }
        return date < Calendar(identifier: .gregorian).startOfDay(for: today)
    }

    static func parse(_ text: String) -> Date? {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return DateComponents(calendar: Calendar(identifier: .gregorian), year: parts[2], month: parts[1], day: parts[0]).date
    }

    static func format(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.day, .month, .year], from: date)
        return DocumentAnalyzer.format(parts)
    }
}
