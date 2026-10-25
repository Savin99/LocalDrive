import Foundation

/// Что умеет экран чата для действий интерфейса. Замыкания даёт ChatView:
/// открыть файл, скопировать поле, напоминание, подтверждение
struct GenUIChatHooks {
    /// Сообщение в чат от имени человека — как чип
    var send: @MainActor (String) -> Void
    var open: @MainActor (ChatDocument) -> Void
    /// Скопировать поле. false — скопировать не вышло
    var copy: @MainActor (ChatDocument, DocumentField) async -> Bool
    var remind: @MainActor (ChatDocument, DocumentValidity) async -> String
    /// Подтверждение действия, меняющего данные: напоминание
    var confirm: @MainActor (String) async -> Bool
}

/// Действия интерфейса одного сообщения чата (docs/genui.md, «Действия»).
/// Локальные `set` и `reset` выполняет движок, остальное — здесь. Меняющее
/// данные — с подтверждением: напоминание — вопросом, файловые действия —
/// карточкой предложения, которую выполняет только «Принять»
@MainActor
final class GenUIChatPerformer: GenUIActionPerformer {
    /// Куда идут вопросы к модели и карточки: сессия чата
    struct Target {
        /// Показать карточку из каталога под ответом
        var addCard: @MainActor (ChatCard) async -> Void
        /// Перестроить блок моделью: вернуть JSON блока или nil
        var regenerate: @MainActor (_ block: JSONValue, _ instruction: String?, _ state: GenUIStateSnapshot) async -> JSONValue?
        /// Предложение файловых действий: карточка из FileProposalBuilder
        var proposal: @MainActor (JSONValue) throws -> ChatCard
    }

    private let search: SearchService
    /// Замыкания экрана чата: экран даёт их при появлении, сообщение может
    /// прийти раньше
    private let hooks: @MainActor () -> GenUIChatHooks?
    private let target: Target
    private weak var model: GenUIMessageModel?

    init(model: GenUIMessageModel, search: SearchService, hooks: @escaping @MainActor () -> GenUIChatHooks?, target: Target) {
        self.model = model
        self.search = search
        self.hooks = hooks
        self.target = target
    }

    func perform(_ action: GenUIAction, block: String, state: GenUIStateSnapshot) async -> GenUIActionOutcome {
        guard let hooks = hooks() else { return .failed("Действие недоступно") }
        switch action {
        case .set, .reset:
            return .done(nil)
        case .submit(_, let message):
            // Значения формы — следующим сообщением: модель видит их как ответ человека
            let lead = message.map { model?.state.text($0) ?? $0.description } ?? "Значения формы"
            hooks.send(state.values.isEmpty ? lead : "\(lead)\n\(state.summary)")
            return .done(nil)
        case .ask(let text):
            hooks.send(model?.state.text(text) ?? text.description)
            return .done(nil)
        case .regenerate(let blockID, let instruction):
            guard let model, let raw = Self.find(blockID, in: model.document.json) else { return .failed("Блок не найден") }
            guard let rebuilt = await target.regenerate(raw, instruction, state) else { return .failed("Не получилось перестроить") }
            return model.replace(blockID: blockID, with: rebuilt) ? .done(nil) : .failed("Не получилось перестроить")
        case .openDocument(let id):
            guard let document = await document(id) else { return .failed("Документ недоступен") }
            hooks.open(document)
            return .done(nil)
        case .showFields(let id, let keys):
            guard await document(id) != nil else { return .failed("Документ недоступен") }
            await target.addCard(.fields(documentID: id, keys: keys.isEmpty ? FieldKey.order : keys))
            return .done(nil)
        case .copyField(let id, let key):
            guard let document = await document(id), let field = document.field(key) else { return .failed("Поля нет") }
            return await hooks.copy(document, field) ? .done("Скопировано") : .failed("Не подтверждено")
        case .openFolder(let id):
            // Переход в папку из чата экран пока не умеет — её документы
            // показываются карточкой под ответом
            guard search.searchableFolders.contains(where: { $0.id == id }) else { return .failed("Папка недоступна") }
            let documents = await search.documents(ofTypes: DocumentType.allCases).filter { $0.folderID == id }.map(\.id)
            guard !documents.isEmpty else { return .done("В папке нет распознанных документов") }
            await target.addCard(.fileList(documentIDs: Array(documents.prefix(12))))
            return .done(nil)
        case .remind(let id):
            guard let document = await document(id) else { return .failed("Документ недоступен") }
            let values = Dictionary(document.fields.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            let until = await search.metadata(for: [id])[id]?.validUntil.nilIfEmpty
            let validity = DocumentValidity.of(type: document.type, fields: values, validUntil: until)
            guard validity.date != nil else { return .failed("У документа нет срока") }
            guard await hooks.confirm("Напомнить о сроке «\(document.title)»?") else { return .done(nil) }
            return .done(await hooks.remind(document, validity))
        case .proposeFileActions(let arguments):
            do {
                await target.addCard(try target.proposal(arguments))
                return .done("Предложение — ниже: ничего не изменится без «Принять»")
            } catch {
                return .failed("Предложение не собралось")
            }
        }
    }

    /// Документ — только из папок, доступных для поиска
    private func document(_ id: Int64) async -> ChatDocument? {
        let card = await ChatCardResolver(search: search).resolve([.document(documentID: id)]).first
        if case .document(let document)? = card?.content { return document }
        return nil
    }

    /// Блок по id на любой глубине — его JSON уходит модели при перестройке
    static func find(_ id: String, in json: JSONValue) -> JSONValue? {
        switch json {
        case .object(let object):
            if object["id"]?.string == id, object["type"] != nil { return json }
            for value in object.values {
                if let found = find(id, in: value) { return found }
            }
            return nil
        case .array(let items):
            for item in items {
                if let found = find(id, in: item) { return found }
            }
            return nil
        default:
            return nil
        }
    }
}
