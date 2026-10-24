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
            let found = query.isEmpty ? Array(facts.cards.prefix(20)) : facts.search(query)
            return ["cards": .array(found.prefix(10).map(describe))]
        case "show_fact_card":
            guard let raw = arguments["id"]?.string, let card = facts.card(id: decodeID(raw) ?? UUID()) else {
                return ["error": "Нет такой карточки"]
            }
            let labels = Set((arguments["labels"]?.array ?? []).compactMap(\.string).map { $0.lowercased() })
            let items = card.items.filter { labels.contains($0.label.lowercased()) }.map(\.id)
            cards.append(.fact(id: card.id, items: items))
            return ["shown": .string(encodeID(card.id))]
        case "propose_fact_card":
            guard let draft = draft(from: arguments, facts: facts) else {
                return ["error": "Нужны название и хотя бы одно поле со значением"]
            }
            cards.append(.factProposal(draft))
            return ["proposed": .string(encodeID(draft.id)), "note": "Карточка показана. Сохранит её человек кнопкой."]
        default:
            return ["error": .string("Нет такого инструмента: \(name)")]
        }
    }

    /// Опись карточек для инструкции: «f… · Дом Камилы · адрес, домофон, этаж» —
    /// без значений: их модель берёт инструментом, когда спросят
    static func index(_ facts: FactStore?) -> String {
        guard let facts, !facts.cards.isEmpty else { return "" }
        return facts.cards.prefix(100).map { card in
            "\(encodeID(card.id)) · \(card.title) · " + card.items.map(\.label).joined(separator: ", ")
        }.joined(separator: "\n")
    }

    static func encodeID(_ id: UUID) -> String { "f\(id.uuidString)" }

    static func decodeID(_ raw: String) -> UUID? {
        UUID(uuidString: raw.hasPrefix("f") ? String(raw.dropFirst()) : raw)
    }

    private static func describe(_ card: FactCard) -> CloudJSON {
        [
            "id": .string(encodeID(card.id)),
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
        if let raw = arguments["id"]?.string, let id = decodeID(raw), var existing = facts.card(id: id) {
            existing.title = title
            existing.symbol = symbol
            existing.items = items
            return existing
        }
        return FactCard(title: title, symbol: symbol, items: items)
    }

    static let instruction = """
    «Карточки» — то, что человек просил запомнить и чего нет в документах: дом друга (адрес, домофон, этаж), Wi-Fi, дача, коды. Их опись — ниже, после документов.
    Вопрос о таком («дом Камилы», «код калитки на даче») — show_fact_card, в labels — поля, о которых спросили. Значения в тексте не повторяй.
    «Запомни …», скриншот или фото с такими данными — разложи по полям и вызови propose_fact_card: короткое название («Дом Камилы»), значок SF Symbol (house.fill, car.fill, wifi, key.fill, building.2.fill, briefcase.fill, cross.case.fill…), поля с видом: address, link, phone, email, code, text, date, number, wifi, note и своим значком. Дополнить существующую — тот же id и все поля целиком. Человек сохранит кнопкой.
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
                    "id": ["type": "string", "description": "id карточки, f…"],
                    "labels": ["type": "array", "items": ["type": "string"]],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "propose_fact_card",
            "description": "Предложить новую карточку или правку существующей. Ничего не сохраняется, пока человек не нажмёт «Сохранить».",
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
