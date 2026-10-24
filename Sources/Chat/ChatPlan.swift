import Foundation

/// План ответа: что показать. Его составляет роутер на правилах или локальная
/// модель — исполняет всегда один и тот же код, а карточки заполняются из
/// базы. Модель не видит ни текста документов, ни значений полей: в плане
/// только тип документа, ключи полей и слова имени владельца
struct ChatPlan: Codable, Equatable, Sendable {
    enum Action: String, Codable, CaseIterable, Sendable {
        /// Личный документ: тип, нужные поля, срок, владелец
        case document
        /// Документы одного типа списком: «дипломные документы»
        case list
        /// Поиск по тексту документов
        case search
        /// Ответ своими словами, без данных документов: «что взять на замену паспорта»
        case answer
    }

    var action: Action
    var types: [DocumentType] = []
    var fields: [String] = []
    var expiry = false
    /// Слова имени владельца, как их написал человек: «савина», «илья»
    var owner: [String] = []
    /// Что искать в тексте документов, если `action == .search`
    var query: String?
    /// Ответ модели, если `action == .answer`. Цифр в нём быть не может —
    /// это гарантирует грамматика генерации, а `sanitized` проверяет ещё раз
    var text: String?

    // В JSON ответ называется «reply»: с ключом «text» модель на стенде
    // подставляла само слово «text» в соседнее поле query
    private enum CodingKeys: String, CodingKey {
        case action, types, fields, expiry, owner, query
        case text = "reply"
    }

    init(
        action: Action,
        types: [DocumentType] = [],
        fields: [String] = [],
        expiry: Bool = false,
        owner: [String] = [],
        query: String? = nil,
        text: String? = nil
    ) {
        self.action = action
        self.types = types
        self.fields = fields
        self.expiry = expiry
        self.owner = owner
        self.query = query
        self.text = text
    }

    /// Пропущенный ключ — не ошибка: план из модели лучше принять частично,
    /// чем выбросить и отвечать правилами
    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(Action.self, forKey: .action)
        types = try container.decodeIfPresent([DocumentType].self, forKey: .types) ?? []
        fields = try container.decodeIfPresent([String].self, forKey: .fields) ?? []
        expiry = try container.decodeIfPresent(Bool.self, forKey: .expiry) ?? false
        owner = try container.decodeIfPresent([String].self, forKey: .owner) ?? []
        query = try container.decodeIfPresent(String.self, forKey: .query)
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }

    /// Модель могла ошибиться: оставляем только то, что есть в каталоге
    func sanitized() -> ChatPlan {
        var plan = self
        plan.fields = fields.filter(FieldKey.order.contains)
        plan.owner = Array(owner.map { SearchText.normalize($0) }.filter { !$0.isEmpty }.prefix(3))
        plan.query = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.text = text.map(Self.withoutDigits)
        return plan
    }

    /// Последняя линия обороны правила «модель не печатает номера»
    static func withoutDigits(_ text: String) -> String {
        String(text.filter { !$0.isNumber })
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ChatIntent {
    /// План модели в тех же понятиях, что и разбор на правилах
    init(plan: ChatPlan) {
        self.init("")
        types = plan.types
        fieldKeys = plan.fields
        wantsExpiry = plan.expiry
        wantsList = plan.action == .list
        nameWords = plan.owner
    }
}
