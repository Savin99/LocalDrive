import Foundation

// Каталог карточек ответа. Идея — из протокола A2UI: ответ описывает интерфейс
// декларативно и может использовать только заранее одобренные компоненты.
// Рендерер свой, нативный SwiftUI.
//
// Жёсткое правило спецификации: в карточке только `documentId` и ключи полей.
// Значения — серию, номер, даты — рендерер берёт из базы. Ни роутер, ни модель
// не печатают номер паспорта сами, поэтому и придумать его не могут.
//
// Формат JSON:
//   {"cards": [
//     {"type": "fields", "documentId": "d42", "keys": ["series_number", "issue_date"]},
//     {"type": "document", "documentId": "d42"}
//   ]}
enum ChatCard: Hashable, Sendable {
    /// Поля документа с маской и отметкой уверенности
    case fields(documentID: Int64, keys: [String])
    /// Один документ: превью, название, папка, ключевые поля
    case document(documentID: Int64)
    /// Несколько файлов сеткой превью
    case fileList(documentIDs: [Int64])
    /// Файл и фрагмент текста с подсветкой
    case snippet(documentID: Int64, page: Int?)
    /// Запрос неоднозначный: 2–4 варианта уточнения
    case clarify(question: String?, options: [ClarifyOption])
    /// Срок действия и сколько осталось
    case expiry(documentID: Int64)
    /// Предложение разложить файлы: выполняется только кнопкой
    case proposal(FileProposal)
    /// Вложение чата — файл, брошенный в переписку
    case attachment(id: String)
    /// Карточка из «Карточек»; `items` — поля, о которых спросили
    case fact(id: UUID, items: [UUID])
    /// Черновик карточки: в «Карточки» попадает по «Сохранить»
    case factProposal(FactCard)
    /// Исправление поля, которое распознавание прочитало неверно: меняется
    /// только по кнопке «Исправить»
    case fieldFix(documentID: Int64, key: String, value: String)

    var documentIDs: [Int64] {
        switch self {
        case .fields(let id, _), .document(let id), .snippet(let id, _), .expiry(let id), .fieldFix(let id, _, _): [id]
        case .fileList(let ids): ids
        case .clarify, .proposal, .attachment, .fact, .factProposal: []
        }
    }
}

/// Вариант уточнения: подпись на чипе и запрос, который уйдёт по тапу.
/// `documentID` выбирает документ напрямую: два одинаковых паспорта одного
/// человека из разных папок повторным текстом не различить
struct ClarifyOption: Hashable, Codable, Sendable {
    let title: String
    let query: String
    var documentID: Int64? = nil

    private enum CodingKeys: String, CodingKey {
        case title, query, documentId
    }

    init(title: String, query: String, documentID: Int64? = nil) {
        self.title = title
        self.query = query
        self.documentID = documentID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        query = try container.decode(String.self, forKey: .query)
        documentID = try container.decodeIfPresent(String.self, forKey: .documentId).flatMap(ChatCard.decodeID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(query, forKey: .query)
        try container.encodeIfPresent(documentID.map(ChatCard.encodeID), forKey: .documentId)
    }
}

/// Ответ целиком: короткий текст без значений полей и карточки
struct ChatReply: Hashable, Sendable {
    var text: String
    var cards: [ChatCard]
    /// Правила точно знают ответ: человек и поле, вид документа, уточнение к
    /// прошлому ответу. Такой ответ показывается сразу — ни модель, ни облако
    /// не спрашиваются
    var isConfident = false
}

// MARK: - JSON

extension ChatCard: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, documentId, documentIds, keys, page, question, options, proposal, attachmentId, factId, itemIds, fact, key, value
    }

    private enum Kind: String, Codable {
        case fields, document, fileList, snippet, clarify, expiry, proposal, attachment, fact, factProposal, fieldFix
    }

    /// Идентификатор в JSON — «d42», как в спецификации
    static func encodeID(_ id: Int64) -> String { "d\(id)" }

    static func decodeID(_ text: String) -> Int64? {
        Int64(text.hasPrefix("d") ? String(text.dropFirst()) : text)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func id() throws -> Int64 {
            let raw = try container.decode(String.self, forKey: .documentId)
            guard let id = Self.decodeID(raw) else {
                throw DecodingError.dataCorruptedError(forKey: .documentId, in: container, debugDescription: "documentId: \(raw)")
            }
            return id
        }
        switch try container.decode(Kind.self, forKey: .type) {
        case .fields:
            self = .fields(documentID: try id(), keys: try container.decode([String].self, forKey: .keys))
        case .document:
            self = .document(documentID: try id())
        case .fileList:
            let raw = try container.decode([String].self, forKey: .documentIds)
            self = .fileList(documentIDs: raw.compactMap(Self.decodeID))
        case .snippet:
            self = .snippet(documentID: try id(), page: try container.decodeIfPresent(Int.self, forKey: .page))
        case .clarify:
            self = .clarify(
                question: try container.decodeIfPresent(String.self, forKey: .question),
                options: try container.decode([ClarifyOption].self, forKey: .options)
            )
        case .expiry:
            self = .expiry(documentID: try id())
        case .proposal:
            self = .proposal(try container.decode(FileProposal.self, forKey: .proposal))
        case .attachment:
            self = .attachment(id: try container.decode(String.self, forKey: .attachmentId))
        case .fact:
            self = .fact(id: try container.decode(UUID.self, forKey: .factId),
                         items: try container.decodeIfPresent([UUID].self, forKey: .itemIds) ?? [])
        case .factProposal:
            self = .factProposal(try container.decode(FactCard.self, forKey: .fact))
        case .fieldFix:
            self = .fieldFix(documentID: try id(), key: try container.decode(String.self, forKey: .key),
                             value: try container.decode(String.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fields(let id, let keys):
            try container.encode(Kind.fields, forKey: .type)
            try container.encode(Self.encodeID(id), forKey: .documentId)
            try container.encode(keys, forKey: .keys)
        case .document(let id):
            try container.encode(Kind.document, forKey: .type)
            try container.encode(Self.encodeID(id), forKey: .documentId)
        case .fileList(let ids):
            try container.encode(Kind.fileList, forKey: .type)
            try container.encode(ids.map(Self.encodeID), forKey: .documentIds)
        case .snippet(let id, let page):
            try container.encode(Kind.snippet, forKey: .type)
            try container.encode(Self.encodeID(id), forKey: .documentId)
            try container.encodeIfPresent(page, forKey: .page)
        case .clarify(let question, let options):
            try container.encode(Kind.clarify, forKey: .type)
            try container.encodeIfPresent(question, forKey: .question)
            try container.encode(options, forKey: .options)
        case .expiry(let id):
            try container.encode(Kind.expiry, forKey: .type)
            try container.encode(Self.encodeID(id), forKey: .documentId)
        case .proposal(let proposal):
            try container.encode(Kind.proposal, forKey: .type)
            try container.encode(proposal, forKey: .proposal)
        case .attachment(let id):
            try container.encode(Kind.attachment, forKey: .type)
            try container.encode(id, forKey: .attachmentId)
        case .fact(let id, let items):
            try container.encode(Kind.fact, forKey: .type)
            try container.encode(id, forKey: .factId)
            try container.encode(items, forKey: .itemIds)
        case .factProposal(let card):
            try container.encode(Kind.factProposal, forKey: .type)
            try container.encode(card, forKey: .fact)
        case .fieldFix(let id, let key, let value):
            try container.encode(Kind.fieldFix, forKey: .type)
            try container.encode(Self.encodeID(id), forKey: .documentId)
            try container.encode(key, forKey: .key)
            try container.encode(value, forKey: .value)
        }
    }
}

/// Обёртка `{"cards": [...]}` — так ответ приходит от модели
struct ChatCardsPayload: Codable {
    var text: String?
    var cards: [ChatCard]
}
