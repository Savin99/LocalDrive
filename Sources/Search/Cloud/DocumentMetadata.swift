import Foundation

/// О чём документ — заполняет облачное распознавание тем же запросом (решение
/// владельца от 12.10.2026: «чтобы он при обработке заполнял в БД метаданные»).
/// Идентификаторы (номера договоров, полисов, счетов) — такие же секретные,
/// как серия паспорта: в тексте чата они под маской, в «Сведениях» не видны
struct DocumentMetadata: Codable, Equatable, Sendable {
    struct Person: Codable, Equatable, Sendable {
        var name: String
        var role: String
    }

    struct Identifier: Codable, Equatable, Sendable {
        var label: String
        var value: String
    }

    struct Amount: Codable, Equatable, Sendable {
        var label: String
        var value: String
        var currency: String
    }

    var title: String = ""
    var summary: String = ""
    var category: String = DocumentCategory.other.rawValue
    var kind: String = ""
    /// «ДД.ММ.ГГГГ» или пусто
    var documentDate: String = ""
    var validUntil: String = ""
    var people: [Person] = []
    var organizations: [String] = []
    var identifiers: [Identifier] = []
    var amounts: [Amount] = []
    var tags: [String] = []
    var language: String = ""

    private enum CodingKeys: String, CodingKey {
        case title, summary, category, kind, people, organizations, identifiers, amounts, tags, language
        case documentDate = "document_date"
        case validUntil = "valid_until"
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            ((try? container.decodeIfPresent(String.self, forKey: key)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        title = text(.title)
        summary = text(.summary)
        category = text(.category)
        kind = text(.kind)
        documentDate = text(.documentDate)
        validUntil = text(.validUntil)
        people = (try? container.decodeIfPresent([Person].self, forKey: .people)) ?? []
        organizations = (try? container.decodeIfPresent([String].self, forKey: .organizations)) ?? []
        identifiers = (try? container.decodeIfPresent([Identifier].self, forKey: .identifiers)) ?? []
        amounts = (try? container.decodeIfPresent([Amount].self, forKey: .amounts)) ?? []
        tags = (try? container.decodeIfPresent([String].self, forKey: .tags)) ?? []
        language = text(.language)
    }

    /// Проверенное: название ≤ 80 знаков, категория из перечня, даты настоящие,
    /// тегов не больше 8, пустые записи выброшены
    var sanitized: DocumentMetadata {
        var copy = self
        copy.title = String(title.prefix(80))
        copy.summary = String(summary.prefix(400))
        copy.category = DocumentCategory(rawValue: category)?.rawValue ?? DocumentCategory.other.rawValue
        copy.kind = String(kind.prefix(80))
        copy.documentDate = DocumentReadingMerge.date(documentDate) == nil ? "" : documentDate
        copy.validUntil = DocumentReadingMerge.date(validUntil) == nil ? "" : validUntil
        copy.people = people.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(10).map { $0 }
        copy.organizations = organizations.filter { !$0.isEmpty }.prefix(10).map { $0 }
        copy.identifiers = identifiers.filter { !$0.value.isEmpty }.prefix(10).map { $0 }
        copy.amounts = amounts.filter { !$0.value.isEmpty }.prefix(10).map { $0 }
        copy.tags = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(8).map { $0 }
        return copy
    }

    var isEmpty: Bool {
        title.isEmpty && summary.isEmpty && kind.isEmpty
    }

    /// Текст для поиска: по нему чат и поиск находят документ. Без
    /// идентификаторов и сумм — номера в индекс отдельной строкой не кладём
    var searchText: String {
        ([title, summary, kind, DocumentCategory(rawValue: category)?.title ?? ""]
            + people.map(\.name) + organizations + tags)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    var json: String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}"
    }

    static func parse(_ json: String) -> DocumentMetadata? {
        try? JSONDecoder().decode(DocumentMetadata.self, from: Data(json.utf8))
    }
}

/// Категория документа — русские подписи для «Сведений»
enum DocumentCategory: String, CaseIterable, Sendable {
    case identity, education, work, finance, medical, property, vehicle, family, legal, travel, receipt, other

    var title: String {
        switch self {
        case .identity: "Удостоверение личности"
        case .education: "Образование"
        case .work: "Работа"
        case .finance: "Финансы"
        case .medical: "Медицина"
        case .property: "Имущество"
        case .vehicle: "Транспорт"
        case .family: "Семья"
        case .legal: "Юридический"
        case .travel: "Поездки"
        case .receipt: "Чек или квитанция"
        case .other: "Другое"
        }
    }
}

extension String {
    /// Пустая строка — nil: для «название из метаданных или имя файла»
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
