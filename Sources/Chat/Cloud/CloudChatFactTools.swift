import Foundation
import UIKit

// Инструменты облачного чата для «Карточек»: найти карточку, показать её и
// предложить новую или правку. Как и с файлами, модель только предлагает —
// в «Карточки» черновик попадает по «Сохранить». Значения карточек модель
// видит: их человек сам записал для чата, а облачный чат он включил сам
@MainActor
enum CloudChatFactTools {
    static let names: Set<String> = ["find_fact_cards", "show_fact_card", "propose_fact_card"]

    static func run(_ name: String, arguments: CloudJSON, facts: FactStore?, cards: inout [ChatCard]) -> CloudJSON {
        guard let facts else { return ["error": "«Карточки» недоступны"] }
        switch name {
        case "find_fact_cards":
            let query = arguments["query"]?.string ?? ""
            let found = query.isEmpty ? Array(ordered(facts).prefix(20)) : facts.search(query)
            return ["cards": .array(found.prefix(10).map { describe($0, in: facts) })]
        case "show_fact_card":
            guard let raw = arguments["id"]?.string, let id = decodeID(raw, in: facts), let card = facts.card(id: id) else {
                return ["error": "Нет такой карточки"]
            }
            let labels = Set((arguments["labels"]?.array ?? []).compactMap(\.string).map { $0.lowercased() })
            let items = card.items.filter { labels.contains($0.label.lowercased()) }.map(\.id)
            cards.append(.fact(id: card.id, items: items))
            return ["shown": .string(encodeID(card.id, in: facts))]
        case "propose_fact_card":
            guard let draft = draft(from: arguments, facts: facts) else {
                return ["error": "Нужны название и хотя бы одно поле со значением"]
            }
            cards.append(.factProposal(draft))
            return ["proposed": .string(encodeID(draft.id, in: facts)), "note": "Карточка показана. Сохранит её человек кнопкой."]
        default:
            return ["error": .string("Нет такого инструмента: \(name)")]
        }
    }

    /// Стабильный порядок карточек для коротких id (f1, f2…): по дате создания,
    /// при равенстве — по UUID. Правка карточки не меняет её номер и не сбивает кэш
    private static func ordered(_ facts: FactStore) -> [FactCard] {
        facts.cards.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Опись карточек для инструкции: «f1 · Дом Камилы · Адрес, Домофон, Этаж».
    /// Короткие номера вместо 37-значных UUID снижают ошибки модели и стабильны
    /// для кэша. При `details: true` (для облака) у описательных полей
    /// (адрес, текст, заметка) добавляется короткое значение без длинных цифр;
    /// коды и пароли Wi-Fi в опись не попадают никогда
    static func index(_ facts: FactStore?, details: Bool = false) -> String {
        guard let facts, !facts.cards.isEmpty else { return "" }
        return ordered(facts).prefix(100).enumerated().map { offset, card in
            let id = "f\(offset + 1)"
            let summary = details
                ? card.items.prefix(8).map(indexItem).joined(separator: "; ")
                : card.items.map(\.label).joined(separator: ", ")
            return "\(id) · \(clean(card.title)) · \(summary)"
        }.joined(separator: "\n")
    }

    private static func indexItem(_ item: FactItem) -> String {
        let label = clean(item.displayLabel)
        guard [.address, .text, .note].contains(item.kind) else { return label }
        let value = clean(String(item.value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)))
        guard !value.isEmpty else { return label }
        return "\(label): \(value)"
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\d{4,}"#, with: "…", options: .regularExpression)
    }

    static func encodeID(_ id: UUID) -> String { "f\(id.uuidString)" }

    /// Короткий id «f1», «f2»… для существующей карточки; для черновика — с UUID
    static func encodeID(_ id: UUID, in facts: FactStore?) -> String {
        if let facts, let index = ordered(facts).firstIndex(where: { $0.id == id }) {
            return "f\(index + 1)"
        }
        return encodeID(id)
    }

    /// Принимает и короткий id («f1», «1»), и прежний формат с UUID («f…»)
    static func decodeID(_ raw: String, in facts: FactStore? = nil) -> UUID? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = (trimmed.hasPrefix("f") || trimmed.hasPrefix("F")) ? String(trimmed.dropFirst()) : trimmed
        if let number = Int(stripped), number >= 1, let facts {
            let cards = ordered(facts)
            if number <= cards.count { return cards[number - 1].id }
        }
        return UUID(uuidString: stripped)
    }

    private static func describe(_ card: FactCard, in facts: FactStore) -> CloudJSON {
        [
            "id": .string(encodeID(card.id, in: facts)),
            "title": .string(card.title),
            "items": .array(card.items.map { ["kind": .string($0.kind.rawValue), "label": .string($0.label), "value": .string($0.value)] }),
        ]
    }

    /// Черновик из аргументов. Значок, которого нет в SF Symbols, заменяется
    /// значком по виду поля; вид поля не из списка — текст
    static func draft(from arguments: CloudJSON, facts: FactStore) -> FactCard? {
        let title = arguments["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let items: [FactItem] = (arguments["items"]?.array ?? []).compactMap { raw in
            let value = raw["value"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let label = raw["label"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty, !label.isEmpty else { return nil }
            let kind = raw["kind"]?.string.flatMap(FactItem.Kind.init(rawValue:)) ?? .text
            let symbol = raw["symbol"]?.string.flatMap { UIImage(systemName: $0) == nil ? nil : $0 }
            return FactItem(kind: kind, label: label, value: value, symbol: symbol)
        }
        guard !title.isEmpty, !items.isEmpty else { return nil }
        let symbol = arguments["symbol"]?.string.flatMap { UIImage(systemName: $0) == nil ? nil : $0 } ?? FactDraftParser.symbol(for: items)
        // Правка существующей карточки — тот же id, «Сохранить» её обновит
        if let raw = arguments["id"]?.string, let id = decodeID(raw, in: facts), var existing = facts.card(id: id) {
            existing.title = title
            existing.symbol = symbol
            existing.items = items
            return existing
        }
        return FactCard(title: title, symbol: symbol, items: items)
    }

    static let instruction = """
    «Карточки» — то, что человек просил запомнить и чего нет в документах: дом друга (адрес, домофон, этаж), Wi-Fi, дача, коды. Их опись — ниже, после документов.
    Вопрос о таком («дом Камилы», «код калитки на даче») — сразу вызови show_fact_card с id из списка карточек ниже (без find_fact_cards, если карточка уже видна в списке), в labels — поля, о которых спросили. Значения в тексте не повторяй.
    «Запомни …», скриншот или фото с такими данными — разложи по полям и вызови propose_fact_card: короткое название («Дом Камилы»), значок SF Symbol (house.fill, car.fill, wifi, key.fill, building.2.fill, briefcase.fill, cross.case.fill…), поля с видом: address, link, phone, email, code, text, date, number, wifi, note и своим значком. Дополнить существующую — тот же id и все поля целиком. Сразу, с тем, что сказано: недостающее (адрес, этаж) не спрашивай — человек допишет потом. Человек сохранит кнопкой.
    """

    static let tools: [CloudJSON] = [
        [
            "name": "find_fact_cards",
            "description": "Найти карточки «Карточек» по словам: название, подписи и значения полей. Пустой запрос — все.",
            "parameters": [
                "type": "object",
                "properties": ["query": ["type": "string"]],
                "required": ["query"],
            ],
        ],
        [
            "name": "show_fact_card",
            "description": "Показать карточку человеку. labels — подписи полей, о которых спросили: они будут подсвечены.",
            "parameters": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "id карточки из описи, например f1"],
                    "labels": ["type": "array", "items": ["type": "string"]],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "propose_fact_card",
            "description": "Предложить новую карточку или правку существующей — сразу, с полями из сказанного; недостающих (адреса, этажа) не требуй. Ничего не сохраняется, пока человек не нажмёт «Сохранить».",
            "parameters": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "id существующей карточки, если это правка"],
                    "title": ["type": "string"],
                    "symbol": ["type": "string", "description": "SF Symbol карточки"],
                    "items": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "kind": ["type": "string", "enum": ["address", "link", "phone", "email", "code", "text", "date", "number", "wifi", "note"]],
                                "label": ["type": "string"],
                                "value": ["type": "string"],
                                "symbol": ["type": "string", "description": "SF Symbol поля"],
                            ],
                            "required": ["kind", "label", "value"],
                        ],
                    ],
                ],
                "required": ["title", "items"],
            ],
        ],
    ]
}
