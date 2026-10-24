import Foundation
import SwiftUI

/// Документ карточки: живой файл, папка и поля из базы
struct ChatDocument: Identifiable, Hashable {
    let id: Int64
    let file: VaultFile
    let folder: VaultFolder
    let type: DocumentType
    let pageCount: Int
    var fields: [DocumentField]

    func field(_ key: String) -> DocumentField? {
        fields.first { $0.key == key }
    }

    /// «Паспорт РФ», «Загранпаспорт», «Паспорт Таджикистана»
    var title: String {
        type.title(country: field(FieldKey.country)?.value)
    }

    var spokenTitle: String {
        type.spokenTitle(country: field(FieldKey.country)?.value)
    }
}

/// Карточка с подставленными из базы данными — то, что рисует экран
struct ResolvedCard: Identifiable {
    enum Content {
        case fields(ChatDocument, keys: [String])
        case document(ChatDocument)
        case fileList([ChatDocument])
        case snippet(ChatDocument, page: Int?, snippet: AttributedString?)
        case clarify(question: String?, options: [ClarifyOption])
        case expiry(ChatDocument, DocumentValidity)
        /// Предложение разложить файлы — из базы ему брать нечего
        case proposal(FileProposal)
        /// Вложение чата: файл ищет карточка во вложениях
        case attachment(id: String)
        /// Карточка из «Карточек» и поля, о которых спросили
        case fact(FactCard, highlighted: Set<UUID>)
        /// Черновик карточки — «Сохранить» кладёт его в «Карточки»
        case factProposal(FactCard)
        /// Исправление поля: документ, поле и новое значение
        case fieldFix(ChatDocument, key: String, value: String)
    }

    let id = UUID()
    let card: ChatCard
    var content: Content
}

// Подстановка значений: карточка знает только id документа и ключи полей,
// всё остальное — из индекса и хранилища. Документ, которого уже нет или
// который стал недоступен для поиска, из ответа просто выпадает
@MainActor
struct ChatCardResolver {
    let search: SearchService
    /// «Карточки»: без них карточка-факт из ответа выпадает
    var facts: FactStore?

    func resolve(_ cards: [ChatCard], hits: [Int64: SearchResult] = [:]) async -> [ResolvedCard] {
        let ids = Array(Set(cards.flatMap(\.documentIDs)))
        let stored = await search.documents(ids: ids)
        let fields = await search.fields(for: ids)
        let metadata = await search.metadata(for: ids)
        var documents: [Int64: ChatDocument] = [:]
        for document in stored {
            guard let live = search.file(for: document) else { continue }
            documents[document.id] = ChatDocument(
                id: document.id,
                file: live.file,
                folder: live.folder,
                type: document.type,
                pageCount: document.pageCount,
                fields: fields[document.id] ?? []
            )
        }

        return cards.compactMap { card -> ResolvedCard? in
            switch card {
            case .fields(let id, let keys):
                guard let document = documents[id] else { return nil }
                let known = keys.filter { document.field($0) != nil }
                guard !known.isEmpty else { return nil }
                return ResolvedCard(card: card, content: .fields(document, keys: known))
            case .document(let id):
                return documents[id].map { ResolvedCard(card: card, content: .document($0)) }
            case .fileList(let ids):
                let list = ids.compactMap { documents[$0] }
                guard !list.isEmpty else { return nil }
                return ResolvedCard(card: card, content: .fileList(list))
            case .snippet(let id, let page):
                guard let document = documents[id] else { return nil }
                let shownPage = document.pageCount > 1 ? (page ?? hits[id]?.page) : nil
                return ResolvedCard(card: card, content: .snippet(document, page: shownPage, snippet: hits[id]?.snippet))
            case .clarify(let question, let options):
                guard !options.isEmpty else { return nil }
                return ResolvedCard(card: card, content: .clarify(question: question, options: Array(options.prefix(4))))
            case .expiry(let id):
                guard let document = documents[id] else { return nil }
                let values = Dictionary(document.fields.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
                // Срок полиса или договора — из метаданных облака
                let until = metadata[id]?.validUntil.nilIfEmpty
                return ResolvedCard(card: card, content: .expiry(document, DocumentValidity.of(type: document.type, fields: values, validUntil: until)))
            case .proposal(let proposal):
                guard !proposal.actions.isEmpty else { return nil }
                return ResolvedCard(card: card, content: .proposal(proposal))
            case .attachment(let id):
                return ResolvedCard(card: card, content: .attachment(id: id))
            case .fact(let id, let items):
                // Карточку удалили — из ответа она выпадает, как документ
                guard let fact = facts?.card(id: id) else { return nil }
                return ResolvedCard(card: card, content: .fact(fact, highlighted: Set(items)))
            case .factProposal(let draft):
                guard !draft.items.isEmpty else { return nil }
                return ResolvedCard(card: card, content: .factProposal(draft))
            case .fieldFix(let id, let key, let value):
                guard let document = documents[id], FieldKey.order.contains(key), !value.isEmpty else { return nil }
                return ResolvedCard(card: card, content: .fieldFix(document, key: key, value: value))
            }
        }
    }
}

/// Переписка, пока работает приложение. На диск не пишется: в ответах номера
/// документов (спецификация). Блокировка её не стирает — только снова
/// закрывает номера маской; начать заново — кнопка «Новый чат»
@MainActor
@Observable
final class ChatSession {
    struct Message: Identifiable {
        enum Role {
            case user
            case assistant
        }

        let id = UUID()
        let role: Role
        var text: String
        var cards: [ResolvedCard] = []
        var isPending = false
        /// Итог рассуждения облачной модели — уже с маской номеров
        var thoughts = ""
        /// Сколько модель думала до первого слова ответа
        var thinkingSeconds: Double?
        /// Одна строка над ответом: «Облако недоступно — отвечаю без него»
        var notice: String?
        /// Вложения вопроса — «a1», «a2» из ящика вложений
        var attachments: [String] = []
        /// Когда облако начало отвечать — для строки «Думает · N с»
        var startedAt: Date?
        /// Ответ интерфейсом (docs/genui.md): текст, состояние и блоки
        var genui: GenUIMessageModel?
        /// Действия его кнопок и форм
        var genuiPerformer: GenUIChatPerformer?
        /// Чип «Запомнить: это я — Савин И. А.»
        var ownerSuggestion: OwnerSuggestion?
        /// Что чат делал, пока отвечал: понял, перебрал людей, открыл
        /// документ. Пока ответ идёт — живая лента, потом — одна строка
        var steps: [ChatStep] = []
        /// Когда ответ готов — для «нашёл за 0,1 с»
        var finishedAt: Date?
        /// Когда пришёл вопрос
        let askedAt = Date()
    }

    private(set) var messages: [Message] = []
    /// Номера документов открыты касанием «глаза» — до ухода приложения в фон
    var revealsSensitive = false
    /// Отвечает облако: вместо «Отправить» — «Стоп»
    private(set) var answeringInCloud = false

    @ObservationIgnored private let search: SearchService
    /// Модель на iPhone для агента. Спрашивается при каждом вопросе: модель
    /// могли скачать или удалить, пока экран открыт
    @ObservationIgnored private var agentModel: @MainActor () -> (any LocalAgentModel)?
    /// Сколько ждать агента на iPhone целиком, со всеми шагами, прежде чем
    /// ответить правилами
    @ObservationIgnored private let agentTimeout: Duration
    /// Облачный чат: одна переписка на сессию, только в памяти
    @ObservationIgnored private var cloudEngine: CloudChatEngine?
    @ObservationIgnored private let cloudSession: URLSession
    /// Сколько ждать облако целиком, со всеми раундами инструментов
    @ObservationIgnored private let cloudTimeout: Duration
    /// Сколько облако может молчать — ни рассуждения, ни текста. Дольше —
    /// отвечают правила
    @ObservationIgnored private let cloudSilence: Duration
    @ObservationIgnored private var cloudTask: Task<Void, Never>?
    @ObservationIgnored private var stopRequested = false
    /// Предложения действий с файлами: FileProposalBuilder проверяет аргументы
    /// модели по хранилищу. Пока nil, инструмент propose_file_actions отвечает
    /// модели «недоступно»
    @ObservationIgnored var proposals: FileProposalMaker?
    /// Файлы, брошенные в чат: живут, пока их не разложили или не начали
    /// новый чат
    let inbox: ChatAttachmentInbox
    /// Хранилище — для подсказки, куда положить вложение без облака
    @ObservationIgnored private var store: VaultStore?
    /// «Карточки»: факты, которых нет в документах, — «дом Камилы»
    @ObservationIgnored private(set) var facts: FactStore?
    /// Чат спросил «как правильно?»: следующий ответ — новое значение поля
    @ObservationIgnored private var pendingFix: (documentID: Int64, key: String, namePart: ChatFieldFix.NamePart?)?
    /// Что разбор прочитал во вложениях: вид и поля. По ним чат отвечает на
    /// «какой день рождения у этого человека», пока файл не разложен по папкам
    /// и в базе его нет. Только в памяти, как и переписка
    @ObservationIgnored private var attachmentReadings: [String: FilePlacementAdvisor.Reading] = [:]
    /// Что умеет экран для действий интерфейса: открыть файл, скопировать,
    /// напомнить, подтвердить. Даёт ChatView
    @ObservationIgnored private var genuiHooks: GenUIChatHooks?

    init(
        search: SearchService,
        agentModel: @escaping @MainActor () -> (any LocalAgentModel)? = { nil },
        agentTimeout: Duration = .seconds(45),
        cloudSession: URLSession = .shared,
        cloudTimeout: Duration = .seconds(60),
        cloudSilence: Duration = .seconds(20),
        inbox: ChatAttachmentInbox? = nil
    ) {
        self.search = search
        self.agentModel = agentModel
        self.agentTimeout = agentTimeout
        self.cloudSession = cloudSession
        self.cloudTimeout = cloudTimeout
        self.cloudSilence = cloudSilence
        self.inbox = inbox ?? ChatAttachmentInbox()
    }

    /// Хранилище приходит из окружения экрана, как и модель: с ним чат
    /// предлагает, куда положить файлы, и выполняет это по кнопке
    func useFiles(_ store: VaultStore) {
        self.store = store
        let inbox = inbox
        proposals = { data in
            .proposal(try FileProposalBuilder.make(from: JSONValue(data), store: store, inbox: inbox))
        }
    }

    var isAnswering: Bool { messages.last?.isPending == true }

    /// «Карточки» приходят из окружения экрана, как и хранилище
    func useFacts(_ facts: FactStore) {
        self.facts = facts
        cloudEngine?.facts = facts
    }

    /// Замыкания экрана для действий ответа интерфейсом
    func useGenUIHooks(_ hooks: GenUIChatHooks) {
        genuiHooks = hooks
    }

    /// Модель на iPhone приходит из окружения экрана — уже после создания сессии
    func useAgentModel(_ model: @escaping @MainActor () -> (any LocalAgentModel)?) {
        agentModel = model
    }

    /// `documentID` — чип уточнения указал документ, его и показываем.
    /// `attachments` — вложения из «+»: их кадры видит облачная модель
    func send(_ text: String, documentID: Int64? = nil, attachments: [CloudChatAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isAnswering else { return }
        let context = contextDocumentIDs()
        // Прошлый вопрос — для уточнений «а загран?», «а у Ольги?»
        let previous = messages.last { $0.role == .user && !$0.text.isEmpty }?.text
        messages.append(Message(role: .user, text: trimmed))
        let pending = Message(role: .assistant, text: "", isPending: true)
        messages.append(pending)
        // Чип указал документ — отвечают правила: выбор уже сделан
        let model = documentID == nil ? agentModel() : nil
        // Облако — если выбрано на поле ввода, включено и с ключом
        let cloud = search.cloud
        // Выключенный облачный чат — не сбой: чип и так показывает «iPhone»
        let wantsCloud = documentID == nil && cloud.chatAvailable && cloud.chatModel != .local
        let configuration = wantsCloud ? cloud.chatConfiguration : nil

        cloudTask = Task {
            let steps = self.stepSink(for: pending.id)
            defer { self.finishSteps(of: pending.id) }
            // Кто владелец и чей «мой паспорт» — правила, без облака: модель
            // угадывала чужой паспорт (жалоба владельца 13.10.2026)
            if documentID == nil, attachments.isEmpty, let local = await self.ownerAnswer(trimmed, context: context) {
                await self.show(local, pending: pending.id, question: trimmed, configuration: configuration)
                return
            }
            // «Положи его в Семью», «перенеси паспорт Ольги в Документы» —
            // предложение сразу, без облака: куда класть, человек уже сказал
            if documentID == nil, attachments.isEmpty, let command = ChatFileCommand(trimmed),
               let reply = await self.fileCommandReply(command, context: context, steps: steps) {
                await self.show(OwnerAnswer(reply: reply), pending: pending.id, question: trimmed, configuration: configuration)
                return
            }
            // «Запомни: у Камилы домофон 45, этаж 3» — черновик карточки. С
            // облаком разбирает модель: она свободнее раскладывает поля и
            // подбирает значки; без облака — разбор на iPhone
            if documentID == nil, attachments.isEmpty, configuration == nil, facts != nil,
               FactDraftParser.request(in: trimmed) != nil {
                steps(.understand, "Понял: запомнить")
                let reply: ChatReply
                if let draft = FactDraftParser.draft(from: trimmed) {
                    steps(.propose, "Раскладываю по полям: " + draft.items.map(\.label).joined(separator: ", "))
                    reply = ChatReply(text: "Проверьте и сохраните — карточка появится в «Карточках»:",
                                      cards: [.factProposal(draft)], isConfident: true)
                } else {
                    reply = ChatReply(text: "Не понял, что запомнить. Напишите, например: «запомни: дом Камилы — домофон 45, этаж 3, адрес Тверская 5».",
                                      cards: [], isConfident: true)
                }
                await self.show(OwnerAnswer(reply: reply), pending: pending.id, question: trimmed, configuration: configuration)
                return
            }
            // «В фамилии ошибка», «исправь дату рождения на 12.05.1985» —
            // карточка «было → станет» с кнопкой «Исправить»
            if documentID == nil, attachments.isEmpty, let reply = await self.fieldFixReply(trimmed, context: context, steps: steps) {
                await self.show(OwnerAnswer(reply: reply), pending: pending.id, question: trimmed, configuration: configuration)
                return
            }
            // «Какой день рождения у этого человека?» сразу после вложения:
            // файла ещё нет в базе, но его разбор знает поля
            if documentID == nil, attachments.isEmpty, let reply = await self.attachmentAnswer(trimmed, steps: steps) {
                await self.show(OwnerAnswer(reply: reply), pending: pending.id, question: trimmed, configuration: configuration)
                return
            }
            // Правила — первыми, при любом чате: точный ответ из базы
            // («дата рождения Ольги», «паспорт Ильи», «а дата выдачи?»)
            // показывается сразу. Владелец 24.10.2026: такой вопрос думал
            // больше 30 с. «Подумать» и вложения — всегда облако
            var rules: (ChatReply, [Int64: SearchResult])?
            if attachments.isEmpty, configuration?.reasoning != .deep {
                var router = ChatRouter(search: search)
                router.onStep = steps
                router.facts = facts
                let local = await router.reply(to: trimmed, preferring: documentID, context: context, previous: previous)
                rules = local
                if local.0.isConfident || Self.isConfidentLookup(trimmed, reply: local.0) {
                    let cards = await ChatCardResolver(search: search, facts: facts).resolve(local.0.cards, hits: local.1)
                    if !cards.isEmpty, let index = messages.firstIndex(where: { $0.id == pending.id }) {
                        messages[index].text = local.0.text
                        messages[index].cards = cards
                        messages[index].isPending = false
                        // Облако должно знать, что показано: «а адрес?» — о нём
                        if let configuration {
                            engine(for: configuration).record(question: trimmed, answer: Self.summary(of: local.0.cards))
                        }
                        if let documentID, let suggestion = await self.ownerSuggestion(for: documentID),
                           let index = messages.firstIndex(where: { $0.id == pending.id }) {
                            messages[index].ownerSuggestion = suggestion
                        }
                        return
                    }
                }
            }
            var notice: String?
            if let configuration {
                steps(.think, "Спрашиваю облако · \(configuration.model.chip)")
                let result = await answerInCloud(trimmed, attachments: attachments, configuration: configuration, pending: pending.id)
                if result.done { return }
                notice = result.notice
            } else if wantsCloud {
                notice = Self.cloudNotice
            }
            // Облака нет — думает агент на iPhone, если модель скачана
            if configuration == nil, let model, await self.answerWithLocalAgent(trimmed, model: model, pending: pending.id, steps: steps) {
                return
            }
            let (reply, hits) = await answer(trimmed, documentID: documentID, context: context, rules: rules, steps: steps)
            let cards = await ChatCardResolver(search: search, facts: facts).resolve(reply.cards, hits: hits)
            if configuration != nil {
                cloudEngine?.record(question: trimmed, answer: Self.summary(of: reply.cards))
            }
            guard let index = messages.firstIndex(where: { $0.id == pending.id }) else { return }
            // Если все карточки отпали при подстановке, текст «нашёл» обманывал бы
            let text = cards.isEmpty && !reply.cards.isEmpty
                ? "Документ больше недоступен — возможно, его удалили или убрали из поиска."
                : reply.text
            messages[index].text = text
            messages[index].cards = cards
            messages[index].notice = notice
            messages[index].thoughts = ""
            messages[index].isPending = false
            // Выбрали чип после «чей паспорт?» — предложить запомнить владельца
            if let documentID, let suggestion = await self.ownerSuggestion(for: documentID),
               let index = messages.firstIndex(where: { $0.id == pending.id }) {
                messages[index].ownerSuggestion = suggestion
            }
        }
    }

    // MARK: - Шаги

    /// Куда роутер, модель и облако пишут шаги ответа `message`: прошлый шаг
    /// закрывается, новый встаёт в ленту. Одинаковый шаг подряд не дублируется
    private func stepSink(for message: UUID) -> ChatStepSink {
        { [weak self] kind, text in
            guard let self, let index = self.messages.firstIndex(where: { $0.id == message }) else { return }
            let now = Date()
            if let last = self.messages[index].steps.last, last.kind == kind, last.text == text { return }
            if let last = self.messages[index].steps.indices.last, self.messages[index].steps[last].finishedAt == nil {
                self.messages[index].steps[last].finishedAt = now
            }
            self.messages[index].steps.append(ChatStep(kind: kind, text: text, startedAt: now))
        }
    }

    /// Ответ готов: последний шаг закрыт, время ответа записано
    private func finishSteps(of message: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == message }) else { return }
        let now = Date()
        for step in messages[index].steps.indices where messages[index].steps[step].finishedAt == nil {
            messages[index].steps[step].finishedAt = now
        }
        messages[index].finishedAt = now
    }

    // MARK: - Владелец

    private struct OwnerAnswer {
        var reply: ChatReply
        var hits: [Int64: SearchResult] = [:]
        var suggestion: OwnerSuggestion?
    }

    /// «Я Илья»: кто владелец — предложить запомнить. «Мой паспорт», а владелец
    /// неизвестен и людей несколько — спросить, чей, а не угадывать
    private func ownerAnswer(_ text: String, context: [Int64]) async -> OwnerAnswer? {
        if let words = Self.introducedName(text) {
            let people = await search.peopleNames().filter { ChatRouter.nameMatches(words, owner: $0) }
            if people.count == 1, let fullName = people.first {
                let name = ChatRouter.shortName(fullName)
                let known = search.owner.owns(fullName: fullName)
                let (reply, hits) = await documentReply(of: fullName)
                let lead = known ? "Да, вы — \(name)." : "Понял: вы — \(name)."
                return OwnerAnswer(reply: ChatReply(text: lead + (reply.cards.isEmpty ? "" : " Ваш документ:"), cards: reply.cards),
                                   hits: hits, suggestion: known ? nil : OwnerSuggestion(fullName: fullName, name: name))
            }
        }
        guard search.owner.owner == nil else { return nil }
        let intent = ChatIntent(text)
        guard intent.types.contains(where: \.isPersonal), intent.nameWords.isEmpty else { return nil }
        let (reply, hits) = await ChatRouter(search: search).reply(to: text, preferring: nil, context: context)
        let asks = reply.cards.contains { card in
            if case .clarify(let question, let options) = card { question == nil && options.count >= 2 } else { false }
        }
        guard asks, await search.peopleNames().count >= 2 else { return nil }
        return OwnerAnswer(reply: ChatReply(text: "Чей документ? Выберите — и я предложу запомнить, кто вы.", cards: reply.cards), hits: hits)
    }

    /// «Я Илья», «меня зовут Ольга Трошина» — слова имени
    static func introducedName(_ text: String) -> [String]? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for prefix in ["меня зовут ", "это я, ", "это я ", "я — ", "я - ", "я, ", "я "] where lower.hasPrefix(prefix) {
            let words = SearchText.tokens(in: String(lower.dropFirst(prefix.count))).map(\.word)
                .filter { !SearchQuery.stopWords.contains($0) && $0.count > 1 }
            return (1...3).contains(words.count) ? words : nil
        }
        return nil
    }

    /// Главный документ человека — паспорт РФ, если есть, со всеми полями
    private func documentReply(of fullName: String) async -> (ChatReply, [Int64: SearchResult]) {
        let key = ChatRouter.personKey(fullName)
        let documents = await search.documents(ofTypes: DocumentType.allCases.filter(\.isPersonal))
        let fields = await search.fields(for: documents.map(\.id))
        let mine = documents.filter { document in
            ChatRouter.personKey(fields[document.id]?.first { $0.key == FieldKey.fullName }?.value ?? "") == key
        }
        guard let main = mine.first(where: { $0.type == .passportRU }) ?? mine.first else { return (ChatReply(text: "", cards: []), [:]) }
        return await ChatRouter(search: search).reply(to: "паспорт", preferring: main.id, context: [])
    }

    /// Выбранный чипом личный документ при нескольких людях — чей он
    private func ownerSuggestion(for documentID: Int64) async -> OwnerSuggestion? {
        guard search.owner.owner == nil,
              let document = await search.documents(ids: [documentID]).first, document.type.isPersonal,
              let fullName = await search.fields(for: [documentID])[documentID]?.first(where: { $0.key == FieldKey.fullName })?.value,
              await search.peopleNames().count >= 2 else { return nil }
        return OwnerSuggestion(fullName: fullName, name: ChatRouter.shortName(fullName))
    }

    private func show(_ local: OwnerAnswer, pending: UUID, question: String, configuration: CloudChatEngine.Configuration?) async {
        let cards = await ChatCardResolver(search: search, facts: facts).resolve(local.reply.cards, hits: local.hits)
        guard let index = messages.firstIndex(where: { $0.id == pending }) else { return }
        messages[index].text = local.reply.text
        messages[index].cards = cards
        messages[index].ownerSuggestion = local.suggestion
        messages[index].isPending = false
        if let configuration {
            engine(for: configuration).record(question: question, answer: local.reply.text + " " + Self.summary(of: local.reply.cards))
        }
    }

    /// «Запомнить: это я» — владелец хранится на iPhone, чип убирается
    func rememberOwner(_ suggestion: OwnerSuggestion) {
        search.owner.set(fullName: suggestion.fullName)
        for index in messages.indices where messages[index].ownerSuggestion != nil {
            messages[index].ownerSuggestion = nil
        }
        messages.append(Message(role: .assistant, text: "Запомнил: вы — \(suggestion.name). «Мой паспорт» теперь — ваш."))
    }

    static let cloudNotice = "Облако недоступно — отвечаю без него"

    /// Правила уверены: нашли один личный документ и показывают его поля или
    /// сам документ — без вопроса «какой?» и без поиска по тексту. Чип «Ещё
    /// есть:» под ответом не делает ответ неуверенным, развороты паспорта — один
    /// документ: у них одна карточка полей
    static func isConfidentLookup(_ text: String, reply: ChatReply) -> Bool {
        let intent = ChatIntent(text)
        // Уточнение к прошлому ответу: «все данные», «а дата выдачи?»,
        // «регистрацию тоже» — правила знают документ из контекста
        let followUp = intent.types.isEmpty && intent.nameWords.isEmpty
            && (intent.wantsAllFields || !intent.fieldKeys.isEmpty || intent.wantsExpiry || intent.wantsAddress)
        // Прописка: правила нашли одну страницу — по имени из вопроса или из прошлого ответа
        if intent.wantsAddress, reply.cards.count == 1, case .snippet = reply.cards[0] { return true }
        guard intent.types.contains(where: \.isPersonal) || followUp else { return false }
        var primary = Set<Int64>()
        var shown = Set<Int64>()
        var keySets: [Set<String>] = []
        for card in reply.cards {
            switch card {
            case .fields(let id, let keys):
                primary.insert(id)
                keySets.append(Set(keys))
            case .expiry(let id): primary.insert(id)
            case .document(let id): shown.insert(id)
            case .fileList(let ids): shown.formUnion(ids)
            case .clarify(let question, _) where question == "Ещё есть:": continue
            default: return false
            }
        }
        // Развороты одного паспорта — карточки полей без общих полей: на
        // втором развороте только то, чего нет на первом (прописка). У двух
        // людей поля совпадают
        let spreads = keySets.count > 1 && keySets.indices.allSatisfy { first in
            keySets.indices.allSatisfy { second in first == second || keySets[first].isDisjoint(with: keySets[second]) }
        }
        return primary.count == 1 || spreads || (primary.isEmpty && shown.count == 1)
    }

    /// Что показали правила — для истории облака: только id документов,
    /// вид и название модель найдёт в описи
    static func summary(of cards: [ChatCard]) -> String {
        var seen = Set<Int64>()
        let ids = cards.flatMap(\.documentIDs).filter { seen.insert($0).inserted }.map(ChatCard.encodeID)
        return ids.isEmpty ? "Ответил без облака." : "Ответил без облака и показал карточки документов: \(ids.joined(separator: ", "))."
    }

    /// Пометка над ответом правилами — настоящая причина, а не «недоступно»
    static func notice(for error: Error) -> String {
        switch error {
        case let timeout as CloudChatTimeout: "Облако думало дольше \(timeout.seconds) с — ответил сам"
        case CloudFailure.regionUnavailable, CloudFailure.network: "Облако недоступно — проверьте VPN"
        case CloudFailure.keyRejected: "Ключ не подошёл"
        case CloudFailure.quotaExceeded: "На счёте облака кончились деньги — ответил сам"
        case CloudFailure.overloaded: "Облако перегружено — ответил сам"
        case CloudFailure.modelNotFound: "Модель облака не найдена — ответил сам"
        case CloudFailure.rejected(let text): "Облако отклонило запрос: \(text) — ответил сам"
        default: cloudNotice
        }
    }

    /// Ответ, оборванный по сроку: текст уже шёл и остаётся
    static func cutNotice(seconds: Int) -> String {
        "Облако думало дольше \(seconds) с — ответ неполный"
    }

    /// Остановить ответ облака: что пришло, то и остаётся
    func stop() {
        guard answeringInCloud else { return }
        stopRequested = true
        cloudTask?.cancel()
    }

    func reset() {
        // Разговор агента на iPhone тоже с нуля
        if let model = agentModel() { Task { await model.resetAgent() } }
        messages.removeAll()
        attachmentReadings.removeAll()
        revealsSensitive = false
        cloudEngine?.reset()
        // Временные копии вложений стираются вместе с перепиской
        inbox.clear()
    }

    // MARK: - Вложения

    /// Вопрос с файлами из поля ввода. Облако видит кадры вложений, а те, что
    /// кадром не сделать, — по имени. Без облака раскладку предлагает
    /// FilePlacementAdvisor: тот же разбор, что у индекса
    func send(_ text: String, attaching items: [ChatAttachment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !items.isEmpty else { return send(trimmed) }
        guard !isAnswering else { return }
        messages.append(Message(role: .user, text: trimmed, attachments: items.map(\.id)))
        let pending = Message(role: .assistant, text: "", isPending: true)
        messages.append(pending)
        let cloud = search.cloud
        let wantsCloud = cloud.chatAvailable && cloud.chatModel != .local
        let configuration = wantsCloud ? cloud.chatConfiguration : nil

        cloudTask = Task {
            let steps = self.stepSink(for: pending.id)
            defer { self.finishSteps(of: pending.id) }
            steps(.files, "Смотрю " + (items.count == 1 ? "вложение «\(items[0].name)»" : pluralize(items.count, "вложение", "вложения", "вложений")))
            // Вложения читаются сразу и запоминаются: следующий вопрос «а какой
            // у него день рождения?» — по ним. С облаком — параллельно ответу
            let reading = Task { @MainActor in
                for item in items where self.attachmentReadings[item.id] == nil {
                    self.attachmentReadings[item.id] = await FilePlacementAdvisor.read(item)
                }
            }
            // «Положи в Паспорта» вместе с файлом — куда, уже сказано
            if let command = ChatFileCommand(trimmed), let store {
                let target = command.target(in: store)
                steps(.folders, Self.folderStep(command, target: target, store: store))
                let proposal = FileProposal(
                    summary: "В «\(FileProposalBuilder.folderTitle(target, store: store))»",
                    actions: items.map { .saveAttachment(attachmentID: $0.id, folder: target, name: nil) }
                )
                let reply = ChatReply(text: Self.proposalLead, cards: [.proposal(proposal)], isConfident: true)
                await self.show(OwnerAnswer(reply: reply), pending: pending.id, question: trimmed, configuration: configuration)
                return
            }
            var notice: String?
            if let configuration {
                steps(.think, "Показываю облаку · \(configuration.model.chip)")
                var imaged: [CloudChatAttachment] = []
                var named: [ChatAttachment] = []
                for item in items {
                    if let jpeg = await inbox.modelImage(item.id) {
                        imaged.append(CloudChatAttachment(id: item.id, name: item.name, jpeg: jpeg))
                    } else {
                        named.append(item)
                    }
                }
                var prompt = trimmed.isEmpty ? "Куда положить эти файлы?" : trimmed
                if !named.isEmpty {
                    prompt += "\n\nВложения без кадра: " + named.map { "\($0.id) — «\($0.name)»" }.joined(separator: ", ")
                }
                let result = await answerInCloud(prompt, attachments: imaged, configuration: configuration, pending: pending.id)
                if result.done { return }
                notice = result.notice
            } else if wantsCloud {
                notice = Self.cloudNotice
            }

            let reply: ChatReply
            if let store {
                steps(.search, "Распознаю и ищу подходящую папку")
                await reading.value
                var placed = await FilePlacementAdvisor(store: store, search: search).localReply(for: items, readings: attachmentReadings)
                // «Какой у него день рождения?» вместе с файлом — сначала ответ
                if !trimmed.isEmpty, let answer = await attachmentAnswer(trimmed, steps: steps, footer: false) {
                    placed.text = answer.text + "\n\n" + placed.text
                }
                reply = placed
            } else {
                reply = ChatReply(text: "Файлы получил, но разложить их сейчас не могу — откройте чат заново.", cards: [])
            }
            let cards = await ChatCardResolver(search: search, facts: facts).resolve(reply.cards)
            guard let index = messages.firstIndex(where: { $0.id == pending.id }) else { return }
            messages[index].text = reply.text
            messages[index].cards = cards
            messages[index].notice = notice
            messages[index].thoughts = ""
            messages[index].isPending = false
        }
    }

    // MARK: - Исправление поля

    /// Поправка поля, которое распознавание прочитало неверно. nil — это не
    /// поправка: обычный вопрос идёт дальше
    private func fieldFixReply(_ text: String, context: [Int64], steps: @escaping ChatStepSink) async -> ChatReply? {
        var fix: ChatFieldFix
        var documentID: Int64?
        if let pending = pendingFix, ChatFieldFix(text) == nil, ChatIntent(text).types.isEmpty, text.count <= 80 {
            // Ответ на «как правильно?» — само значение
            fix = ChatFieldFix(key: pending.key, namePart: pending.namePart, answer: text)
            documentID = pending.documentID
        } else if let parsed = ChatFieldFix(text) {
            fix = parsed
        } else {
            pendingFix = nil
            return nil
        }
        pendingFix = nil
        if documentID == nil { documentID = await fixTarget(fix, text: text, context: context) }
        guard let documentID, let document = await search.documents(ids: [documentID]).first else {
            // «Не паспорт, а справка» без документа в разговоре — не поправка
            guard fix.key != nil else { return nil }
            return ChatReply(text: "Какой документ поправить? Откройте его в чате — например, «паспорт Ольги», — и скажите, что исправить.",
                             cards: [], isConfident: true)
        }
        let fields = await search.fields(for: [documentID])[documentID] ?? []
        // Поле не названо: «не Трошина, а Трошкина» — то, где есть старое значение
        if fix.key == nil, let replacing = fix.replacing {
            guard let field = fields.first(where: { $0.value.localizedCaseInsensitiveContains(replacing) }) else { return nil }
            fix.key = field.key
        }
        guard let key = fix.key else {
            return ChatReply(text: "Что исправить? Например: «фамилия Трошкина» или «дата рождения 12.05.1985».", cards: [], isConfident: true)
        }
        let current = fields.first { $0.key == key }?.value
        steps(.open, "Открываю: \(document.type.title) — поле «\(FieldKey.title(key))»")
        let shown = current.map { FieldKey.isSensitive(key) ? FieldMask.masked($0) : $0 }
        guard let value = fix.resolvedValue(current: current) else {
            pendingFix = (documentID, key, fix.namePart)
            let part = fix.namePart?.title ?? FieldKey.title(key)
            return ChatReply(text: "Как правильно? Напишите \(part.lowercased()) — покажу, что изменится." + (shown.map { " Сейчас: «\($0)»." } ?? ""),
                             cards: [.document(documentID: documentID)], isConfident: true)
        }
        guard value != current else {
            return ChatReply(text: "Так и записано: «\(shown ?? value)».", cards: [], isConfident: true)
        }
        return ChatReply(text: "Проверьте и нажмите «Исправить». Поле станет ручным — повторное распознавание его не перезапишет:",
                         cards: [.fieldFix(documentID: documentID, key: key, value: value)], isConfident: true)
    }

    /// Чей документ поправить: названный в просьбе («в паспорте Ольги»); из
    /// прошлого ответа — с этим полем; иначе удостоверение, добавленное за
    /// последние полчаса; иначе единственное
    private func fixTarget(_ fix: ChatFieldFix, text: String, context: [Int64]) async -> Int64? {
        // Слова нового значения — не имя: «правильно Трошкина»
        let valueWords = Set(SearchText.tokens(in: (fix.value ?? "") + " " + (fix.replacing ?? "")).map(\.word))
        let words = ChatIntent(text).nameWords.filter { $0.count >= 3 && !valueWords.contains($0) }
        if !words.isEmpty {
            let personal = await search.documents(ofTypes: ChatRouter.personalPriority.filter(\.isPersonal))
            let fields = await search.fields(for: personal.map(\.id))
            let named = personal.filter { document in
                let owner = fields[document.id]?.first { $0.key == FieldKey.fullName }?.value ?? ""
                return words.contains { ChatRouter.nameMatches([$0], owner: owner) }
            }
            let ranked = named.sorted { (ChatRouter.personalPriority.firstIndex(of: $0.type) ?? .max) < (ChatRouter.personalPriority.firstIndex(of: $1.type) ?? .max) }
            if let key = fix.key, let holder = ranked.first(where: { document in fields[document.id]?.contains { $0.key == key } == true }) {
                return holder.id
            }
            if let first = ranked.first { return first.id }
        }
        if !context.isEmpty {
            let fields = await search.fields(for: context)
            if let key = fix.key, let id = context.first(where: { id in fields[id]?.contains { $0.key == key } == true }) { return id }
            if let replacing = fix.replacing,
               let id = context.first(where: { id in fields[id]?.contains { $0.value.localizedCaseInsensitiveContains(replacing) } == true }) {
                return id
            }
            let documents = await search.documents(ids: context)
            if let personal = context.first(where: { id in documents.contains { $0.id == id && $0.type.isPersonal } }) { return personal }
        }
        let personal = await search.documents(ofTypes: DocumentType.allCases.filter(\.isPersonal))
        let dated = personal.compactMap { document in search.file(for: document).map { (document.id, $0.file.addedAt) } }
        if let newest = dated.max(by: { $0.1 < $1.1 }), Date().timeIntervalSince(newest.1) < 30 * 60 { return newest.0 }
        return personal.count == 1 ? personal[0].id : nil
    }

    // MARK: - Вопрос о вложении

    /// Ответ по прочитанному во вложениях последнего сообщения с файлами — если
    /// после него речь не заходила о документах из базы. nil — вопрос не о
    /// полях или вложений с документом нет
    /// `footer` — подсказка «положите в папку»: в ответе вместе с предложением
    /// разложить файл она лишняя
    private func attachmentAnswer(_ text: String, steps: @escaping ChatStepSink, footer: Bool = true) async -> ChatReply? {
        let intent = ChatIntent(text)
        guard intent.nameWords.isEmpty, !intent.fieldKeys.isEmpty || intent.wantsAllFields,
              intent.types.allSatisfy(\.isPersonal),
              let sent = messages.lastIndex(where: { $0.role == .user && !$0.attachments.isEmpty }) else { return nil }
        let laterDocuments = messages[(sent + 1)...].contains { message in
            message.role == .assistant && message.cards.contains { !$0.card.documentIDs.isEmpty }
        }
        guard !laterDocuments else { return nil }
        let ids = messages[sent].attachments
        // С облаком вложения ещё могли не дочитаться
        for id in ids where attachmentReadings[id] == nil {
            guard let item = inbox.item(id) else { continue }
            attachmentReadings[id] = await FilePlacementAdvisor.read(item)
        }
        let keys = intent.fieldKeys.isEmpty ? FieldKey.order : intent.fieldKeys
        let readings = ids.compactMap { id in attachmentReadings[id].map { (id: id, analysis: $0.analysis) } }
        guard let chosen = readings.first(where: { reading in keys.contains { key in reading.analysis.fields.contains { $0.key == key } } })
            ?? readings.first(where: { $0.analysis.type.isPersonal }) else { return nil }
        let name = inbox.names[chosen.id] ?? "вложение"
        steps(.open, "Смотрю вложение «\(name)»")
        let analysis = chosen.analysis
        let owner = analysis.fields.first { $0.key == FieldKey.fullName }?.value ?? ""
        let country = analysis.fields.first { $0.key == FieldKey.country }?.value
        let head = [analysis.type == .other ? "" : analysis.type.title(country: country), owner.isEmpty ? "" : ChatRouter.shortName(owner)]
            .filter { !$0.isEmpty }.joined(separator: " — ")
        let found = keys.compactMap { key in analysis.fields.first { $0.key == key } }
        let source = "«\(name)»" + (head.isEmpty ? "" : " (\(head))")
        guard !found.isEmpty else {
            let asked = keys.map { "«\(FieldKey.title($0))»" }.joined(separator: ", ")
            let deeper = search.cloud.isEnabled && search.cloud.hasKey ? " — там его прочитает облако" : " — там его прочитают внимательнее"
            return ChatReply(text: "На вложении \(source) не разобрал \(asked). Положите файл в папку кнопкой «Выполнить» выше\(deeper).",
                             cards: [], isConfident: true)
        }
        // Номер — маской, как в карточке: значения здесь — текст, а не карточка
        let lines = found.map { field in
            let value = FieldKey.isSensitive(field.key) ? FieldMask.masked(field.value) : field.value
            return "\(FieldKey.title(field.key)): \(value)" + (field.needsReview ? " — сверьте с фото" : "")
        }
        return ChatReply(
            text: "По вложению \(source):\n" + lines.joined(separator: "\n")
                + (footer ? "\n\nЧтобы данные были под рукой всегда, положите файл в папку — «Выполнить» выше." : ""),
            cards: [], isConfident: true
        )
    }

    // MARK: - Просьбы разложить файлы

    static let proposalLead = "Предлагаю так. Ничего не изменится, пока вы не нажмёте «Выполнить»:"

    /// «Ищу папку «Семья»» или «Папки «Семья» нет — создам»
    static func folderStep(_ command: ChatFileCommand, target: FolderTarget, store: VaultStore) -> String {
        switch target {
        case .existing: "Нашёл папку «\(FileProposalBuilder.folderTitle(target, store: store))»"
        case .new(let name): "Папки «\(name)» нет — предложу создать"
        }
    }

    /// «Положи их в Семью» — вложения, которые ещё не разложили, или
    /// документы прошлого ответа. «Перенеси паспорт Ольги в Документы» — что
    /// именно, находят правила. nil — чата файлов нет (тесты без хранилища)
    private func fileCommandReply(_ command: ChatFileCommand, context: [Int64], steps: @escaping ChatStepSink) async -> ChatReply? {
        guard let store else { return nil }
        let target = command.target(in: store)
        var actions: [FileProposal.Action] = []
        var ids: [Int64] = []
        if command.refersToContext {
            let draft = Set(inbox.draft.map(\.id))
            let waiting = inbox.items.filter { !draft.contains($0.id) }
            if !waiting.isEmpty {
                steps(.files, "Беру " + (waiting.count == 1 ? "вложение «\(waiting[0].name)»" : pluralize(waiting.count, "вложение", "вложения", "вложений")))
                actions = waiting.map { .saveAttachment(attachmentID: $0.id, folder: target, name: nil) }
            } else {
                ids = context
            }
        } else {
            var router = ChatRouter(search: search)
            router.onStep = steps
            router.facts = facts
            let (found, _) = await router.reply(to: command.subject, context: context)
            var seen = Set<Int64>()
            ids = found.cards.flatMap(\.documentIDs).filter { seen.insert($0).inserted }
            // Несколько людей или документов — сначала выбрать, какой
            if ids.isEmpty, found.cards.contains(where: { if case .clarify = $0 { true } else { false } }) {
                return ChatReply(text: "Какой именно перенести? Выберите, а потом скажите «перенеси его в \(command.destination)».",
                                 cards: found.cards, isConfident: true)
            }
        }
        if actions.isEmpty, !ids.isEmpty {
            let documents = await search.documents(ids: ids)
            let files = ids.compactMap { id in documents.first { $0.id == id } }
                .map { FileRef(folderID: $0.folderID, name: $0.fileName) }
            let moving = files.filter { file in
                if case .existing(let folderID) = target { file.folderID != folderID } else { true }
            }
            if !moving.isEmpty {
                steps(.files, "Беру " + pluralize(moving.count, "файл", "файла", "файлов"))
                actions = [.moveFiles(files: moving, folder: target)]
            } else if !files.isEmpty {
                return ChatReply(text: "Уже лежит в «\(FileProposalBuilder.folderTitle(target, store: store))».", cards: [], isConfident: true)
            }
        }
        guard !actions.isEmpty else {
            return ChatReply(
                text: "Не понял, что положить в «\(command.destination)». Пришлите файл через «+» или найдите документ — потом скажите «положи его в \(command.destination)».",
                cards: [], isConfident: true
            )
        }
        steps(.folders, Self.folderStep(command, target: target, store: store))
        let proposal = FileProposal(summary: "В «\(FileProposalBuilder.folderTitle(target, store: store))»", actions: actions)
        return ChatReply(text: Self.proposalLead, cards: [.proposal(proposal)], isConfident: true)
    }

    // MARK: - Облако

    /// Ответ облака в пузырь `pending`. done — ответ готов: облаком, остановлен
    /// человеком или оборван по сроку, но что-то уже показано. Иначе отвечают
    /// правила, а notice — настоящая причина
    private func answerInCloud(
        _ text: String,
        attachments: [CloudChatAttachment],
        configuration: CloudChatEngine.Configuration,
        pending: UUID
    ) async -> (done: Bool, notice: String?) {
        answeringInCloud = true
        stopRequested = false
        defer { answeringInCloud = false }
        let started = Date()
        if let index = messages.firstIndex(where: { $0.id == pending }) { messages[index].startedAt = started }
        let shown = ShownCards()
        let interface = InterfaceStream()
        do {
            let reply = try await cloudAnswer(text, attachments: attachments, configuration: configuration, pending: pending,
                                              shown: shown, interface: interface)
            guard let index = messages.firstIndex(where: { $0.id == pending }) else { return (true, nil) }
            // Карточки, показанные из потока, остаются те же — без мигания
            let cards = reply.cards == shown.raw && messages[index].cards.count == reply.cards.count
                ? messages[index].cards
                : await ChatCardResolver(search: search, facts: facts).resolve(reply.cards)
            guard let index = messages.firstIndex(where: { $0.id == pending }) else { return (true, nil) }
            // Ответ интерфейсом: JSON проверяется целиком. Ход, кончившийся
            // одними карточками, интерфейса не показывает
            interface.feed?.finish()
            let model = interface.feed?.hasContent == true ? interface.feed?.model : nil
            messages[index].genui = model
            if model == nil { messages[index].genuiPerformer = nil }
            let answer = model?.text ?? (interface.isGenUI ? "" : reply.text)
            messages[index].text = answer.isEmpty && cards.isEmpty && model == nil ? "Не нашёл, что ответить — уточните вопрос." : answer
            messages[index].cards = cards
            messages[index].thoughts = reply.thoughts
            messages[index].thinkingSeconds = reply.thinkingSeconds
            messages[index].isPending = false
            return (true, nil)
        } catch {
            guard let index = messages.firstIndex(where: { $0.id == pending }) else { return (true, nil) }
            let partial = messages[index].text
            let interfaceShown = interface.feed?.hasContent == true && !(interface.feed?.model.blocks.isEmpty ?? true)
            let somethingShown = !partial.isEmpty || !messages[index].cards.isEmpty || interfaceShown
            // Оборвано: блоки, что успели прийти, остаются
            interface.feed?.stop(stopRequested ? "остановлено" : "оборвано по сроку")
            if stopRequested || (error is CloudChatTimeout && somethingShown) {
                // «Стоп» или срок, а ответ уже шёл: что успело прийти, остаётся
                if let timeout = error as? CloudChatTimeout, !stopRequested {
                    messages[index].notice = Self.cutNotice(seconds: timeout.seconds)
                }
                if !messages[index].thoughts.isEmpty, messages[index].thinkingSeconds == nil {
                    messages[index].thinkingSeconds = Date().timeIntervalSince(started)
                }
                if !somethingShown { messages[index].notice = "Остановлено" }
                messages[index].isPending = false
                stopRequested = false
                if somethingShown {
                    cloudEngine?.record(question: text, answer: partial.isEmpty ? Self.summary(of: shown.raw) : partial)
                }
                return (true, nil)
            }
            // Отвечают правила — интерфейс облака убирается
            messages[index].genui = nil
            messages[index].genuiPerformer = nil
            return (false, Self.notice(for: error))
        }
    }

    /// Ответ интерфейсом по ходу потока: модель, которая сейчас наполняется.
    /// Новый раунд после вызова инструмента — новый ответ
    private func interfaceFeed(_ interface: InterfaceStream, engine: CloudChatEngine, pending: UUID, index: Int) -> GenUIStreamFeed {
        if let feed = interface.feed, !interface.newRound { return feed }
        interface.newRound = false
        let feed = GenUIStreamFeed(mask: { [weak engine] text in engine?.mask(text) ?? text })
        interface.feed = feed
        messages[index].genui = feed.model
        messages[index].genuiPerformer = performer(for: feed.model, message: pending)
        return feed
    }

    /// Действия кнопок ответа интерфейсом: вопросы — в чат, карточки — под
    /// ответ, перестройка блока — моделью, файловые действия — карточкой
    /// предложения Агента B
    private func performer(for model: GenUIMessageModel, message: UUID) -> GenUIChatPerformer {
        GenUIChatPerformer(model: model, search: search, hooks: { [weak self] in self?.genuiHooks }, target: .init(
            addCard: { [weak self] card in await self?.append(card, to: message) },
            regenerate: { [weak self] block, instruction, state in
                await self?.regenerate(block, instruction: instruction, state: state)
            },
            proposal: { [weak self] arguments in
                guard let proposals = self?.proposals else { throw FileProposalError.malformed }
                // Строгая схема шлёт null вместо пропуска — FileProposalBuilder ждёт пропуск
                let data = (try? JSONEncoder().encode(arguments)) ?? Data()
                return try proposals(CloudJSON.parse(data)?.withoutNulls.data ?? data)
            }
        ))
    }

    private func append(_ card: ChatCard, to message: UUID) async {
        let resolved = await ChatCardResolver(search: search, facts: facts).resolve([card])
        guard let index = messages.firstIndex(where: { $0.id == message }) else { return }
        messages[index].cards += resolved
    }

    private func regenerate(_ block: JSONValue, instruction: String?, state: GenUIStateSnapshot) async -> JSONValue? {
        guard let engine = cloudEngine,
              let rebuilt = try? await engine.regenerate(block: block, instruction: instruction, state: state) else { return nil }
        return GenUIStreamFeed.masked(rebuilt, with: { engine.mask($0) })
    }

    /// Движок облака: один на сессию, с её перепиской
    private func engine(for configuration: CloudChatEngine.Configuration) -> CloudChatEngine {
        if let cloudEngine {
            cloudEngine.configuration = configuration
            return cloudEngine
        }
        let engine = CloudChatEngine(configuration: configuration, search: search, proposals: proposals, session: cloudSession)
        engine.facts = facts
        cloudEngine = engine
        return engine
    }

    /// Ответ облачной модели с потоком текста и рассуждения в пузырь ответа.
    /// Сроки — молчание дольше `cloudSilence` или ответ дольше `cloudTimeout`;
    /// «Подумать» думает дольше — сроки вдвое больше
    private func cloudAnswer(
        _ text: String,
        attachments: [CloudChatAttachment],
        configuration: CloudChatEngine.Configuration,
        pending: UUID,
        shown: ShownCards,
        interface: InterfaceStream
    ) async throws -> CloudChatReply {
        let engine = engine(for: configuration)
        engine.documentIndex = await search.chatDocumentIndex()
        engine.genUI = CloudChatGenUI.isEnabled(for: configuration.provider)
        engine.ownerName = search.owner.owner?.name
        interface.isGenUI = engine.genUI
        let activity = CloudActivity()
        let scale = configuration.reasoning == .deep ? 2.0 : 1.0
        let silence = cloudSilence.seconds * scale
        let overall = cloudTimeout.seconds * scale
        return try await withThrowingTaskGroup(of: CloudChatReply.self) { group in
            group.addTask { @MainActor in
                try await engine.respond(to: text, attachments: attachments) { [weak self] event in
                    activity.last = Date()
                    guard let self, let index = self.messages.firstIndex(where: { $0.id == pending }) else { return }
                    switch event {
                    case .thoughts(let thoughts): self.messages[index].thoughts = thoughts
                    case .text(let answer): self.messages[index].text = answer
                    case .answerDelta(let delta):
                        let feed = self.interfaceFeed(interface, engine: engine, pending: pending, index: index)
                        feed.feed(delta)
                        self.messages[index].text = feed.model.text
                    case .tool: interface.newRound = true
                    case .step(let kind, let text): self.stepSink(for: pending)(kind, text)
                    case .cards(let cards):
                        // Карточки — сразу, до текста ответа. Подставляется весь
                        // список: два вызова show_cards не перепутают порядок
                        shown.raw += cards
                        let snapshot = shown.raw
                        Task { @MainActor in
                            let resolved = await ChatCardResolver(search: self.search, facts: self.facts).resolve(snapshot)
                            guard shown.raw == snapshot, let index = self.messages.firstIndex(where: { $0.id == pending }),
                                  self.messages[index].isPending else { return }
                            self.messages[index].cards = resolved
                        }
                    }
                }
            }
            group.addTask { @MainActor in
                let started = Date()
                while true {
                    try await Task.sleep(for: .milliseconds(100))
                    let now = Date()
                    if now.timeIntervalSince(activity.last) > silence { throw CloudChatTimeout(seconds: Int(silence.rounded(.up))) }
                    if now.timeIntervalSince(started) > overall { throw CloudChatTimeout(seconds: Int(overall.rounded(.up))) }
                }
            }
            defer { group.cancelAll() }
            guard let reply = try await group.next() else { throw CloudFailure.network }
            return reply
        }
    }

    // MARK: - Агент на iPhone или правила

    /// Ответ правил: точный сюда не доходит — его показали раньше. `rules` —
    /// ответ правил, если его уже получили
    private func answer(
        _ text: String,
        documentID: Int64?,
        context: [Int64],
        rules: (ChatReply, [Int64: SearchResult])? = nil,
        steps: ChatStepSink? = nil
    ) async -> (ChatReply, [Int64: SearchResult]) {
        var router = ChatRouter(search: search)
        router.onStep = steps
        router.facts = facts
        if let rules { return rules }
        return await router.reply(to: text, preferring: documentID, context: context)
    }

    /// Агент на iPhone — когда облака нет, а модель скачана: сам ищет,
    /// открывает документы, предлагает перенос и карточки — теми же
    /// инструментами, что облако. true — ответ готов; false — не успел или
    /// сбился, и отвечают правила
    private func answerWithLocalAgent(_ text: String, model: any LocalAgentModel, pending: UUID, steps: @escaping ChatStepSink) async -> Bool {
        // Пока человек спрашивает, фоновое чтение документов не вытесняет
        // модель чата из памяти
        await ModelResidency.shared.noteChatActivity()
        steps(.think, "Модель на iPhone думает")
        let engine = LocalAgentEngine(model: model, search: search, proposals: proposals, facts: facts)
        let history = agentHistory()
        let owner = search.owner.owner?.name
        let shown = ShownCards()
        do {
            let reply = try await withThrowingTaskGroup(of: CloudChatReply.self) { group in
                group.addTask { @MainActor in
                    try await engine.respond(to: text, history: history, owner: owner) { [weak self] event in
                        guard let self else { return }
                        switch event {
                        case .step(let kind, let label): steps(kind, label)
                        case .cards(let cards):
                            shown.raw += cards
                            let snapshot = shown.raw
                            Task { @MainActor in
                                let resolved = await ChatCardResolver(search: self.search, facts: self.facts).resolve(snapshot)
                                guard shown.raw == snapshot, let index = self.messages.firstIndex(where: { $0.id == pending }),
                                      self.messages[index].isPending else { return }
                                self.messages[index].cards = resolved
                            }
                        default: break
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: self.agentTimeout)
                    throw CloudChatTimeout(seconds: Int(self.agentTimeout.components.seconds))
                }
                defer { group.cancelAll() }
                guard let reply = try await group.next() else { throw CancellationError() }
                return reply
            }
            let cards = await ChatCardResolver(search: search, facts: facts).resolve(reply.cards)
            guard let index = messages.firstIndex(where: { $0.id == pending }) else { return true }
            messages[index].text = reply.text
            messages[index].cards = cards
            messages[index].isPending = false
            return true
        } catch {
            steps(.think, error is CloudChatTimeout ? "Модель не успела — отвечаю по базе" : "Модель сбилась — отвечаю по базе")
            if let index = messages.firstIndex(where: { $0.id == pending }) { messages[index].cards = [] }
            return false
        }
    }

    /// Прошлые реплики для агента: вопрос и что показал ответ. Значений полей
    /// здесь нет — только id документов, их модель откроет сама
    private func agentHistory() -> [AgentMessage] {
        var history: [AgentMessage] = []
        for (question, answer) in zip(messages, messages.dropFirst())
        where question.role == .user && answer.role == .assistant && !answer.isPending && !question.text.isEmpty {
            history.append(AgentMessage(role: .user, content: question.text))
            let shown = Self.summary(of: answer.cards.map(\.card))
            history.append(AgentMessage(role: .assistant, content: [answer.text, shown].filter { !$0.isEmpty }.joined(separator: " ")))
        }
        return Array(history.suffix(6))
    }

    /// Документы прошлого ответа: к ним относятся уточнения «а адрес?»,
    /// «а дата выдачи?»
    private func contextDocumentIDs() -> [Int64] {
        guard let last = messages.last(where: { $0.role == .assistant && !$0.isPending }) else { return [] }
        var seen = Set<Int64>()
        return last.cards.flatMap(\.card.documentIDs).filter { seen.insert($0).inserted }
    }

    /// Поле исправили или подтвердили — карточки с этим документом перечитываются
    func refresh(documentID: Int64) async {
        let resolver = ChatCardResolver(search: search, facts: facts)
        for messageIndex in messages.indices {
            for cardIndex in messages[messageIndex].cards.indices {
                let card = messages[messageIndex].cards[cardIndex].card
                guard card.documentIDs.contains(documentID),
                      let fresh = await resolver.resolve([card]).first else { continue }
                messages[messageIndex].cards[cardIndex].content = fresh.content
            }
        }
    }
}

/// Облако думало дольше срока — отвечают правила
struct CloudChatTimeout: Error, Equatable {
    let seconds: Int
}

/// Когда облако последний раз что-то прислало: рассуждение, текст, вызов
@MainActor
private final class CloudActivity {
    var last = Date()
}

/// Карточки, показанные из потока, — в том виде, как их прислала модель
@MainActor
private final class ShownCards {
    var raw: [ChatCard] = []
}

/// Ответ интерфейсом по ходу потока: текущий разбор и начался ли новый раунд
@MainActor
private final class InterfaceStream {
    var feed: GenUIStreamFeed?
    var newRound = false
    var isGenUI = false
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
