import Foundation

// Карточки фактов — то, что владелец просил запомнить, но чего нет ни в одном
// документе: домофон у Камилы, этаж, пароль от Wi-Fi на даче. Поля создаёт
// агент чата или сам владелец в редакторе, см. docs/facts.md

/// Одно поле карточки: «Домофон — 45К1234»
struct FactItem: Identifiable, Codable, Hashable, Sendable {
    /// Вид значения решает, что делает касание: адрес открывает Карты,
    /// ссылка — браузер, телефон — звонок, остальное копируется
    enum Kind: String, Codable, CaseIterable, Sendable {
        case address, link, phone, email, code, text, date, number, wifi, note

        /// Незнакомый вид — от агента или из будущей версии — читается как
        /// текст: иначе одна строка испортила бы чтение всего файла
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .text
        }

        var title: String {
            switch self {
            case .address: "Адрес"
            case .link: "Ссылка"
            case .phone: "Телефон"
            case .email: "E-mail"
            case .code: "Код"
            case .text: "Текст"
            case .date: "Дата"
            case .number: "Число"
            case .wifi: "Wi-Fi"
            case .note: "Заметка"
            }
        }
    }

    var id: UUID
    var kind: Kind
    /// «Домофон», «Адрес», «Этаж»
    var label: String
    /// «45К1234», «Москва, Тверская 5», «https://…»
    var value: String
    /// Значок, выбранный агентом или владельцем; nil — по виду и подписи
    var symbol: String?

    init(id: UUID = UUID(), kind: Kind, label: String, value: String, symbol: String? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.value = value
        self.symbol = symbol
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, label, value, symbol
    }

    // Поля, которых нет, не роняют чтение: карточки могут прийти от агента
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
    }

    /// Подпись для экрана: пустая заменяется названием вида
    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.title : trimmed
    }
}

/// Карточка: «Дом Камилы» и её поля
struct FactCard: Identifiable, Codable, Hashable, Sendable {
    static let defaultSymbol = "square.text.square.fill"
    /// Как у новой папки: первый цвет палитры
    static let defaultColor = "indigo"

    var id: UUID
    /// «Дом Камилы»
    var title: String
    /// Значок SF Symbols, например "house.fill"
    var symbol: String
    /// Имя цвета из палитры папок `Theme.palette`
    var color: String
    var items: [FactItem]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        symbol: String = FactCard.defaultSymbol,
        color: String = FactCard.defaultColor,
        items: [FactItem],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.color = color
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, symbol, color, items, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? Self.defaultSymbol
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? Self.defaultColor
        items = try container.decodeIfPresent([FactItem].self, forKey: .items) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// «Дом Камилы» и поля строками «Домофон: 45К1234» — для «Скопировать всё»
    /// и «Поделиться»
    var plainText: String {
        let lines = items
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.displayLabel): \($0.value)" }
        return ([title] + lines).joined(separator: "\n")
    }
}
