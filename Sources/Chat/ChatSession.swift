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
        /// План, по которому собран ответ: модели или правил. Его видит
        /// модель в истории, когда человек уточняет вопрос
        var plan: ChatPlan?
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
    }

    private(set) var messages: [Message] = []
    /// Номера документов открыты после Face ID — до блокировки приложения
    var revealsSensitive = false
    /// Отвечает облако: вместо «Отправить» — «Стоп»
    private(set) var answeringInCloud = false

    @ObservationIgnored private let search: SearchService
    /// Планировщик скачанной модели. Спрашивается при каждом вопросе: модель
    /// могли скачать или удалить, пока экран открыт
    @ObservationIgnored private var planner: @MainActor () -> (any ChatPlanning)?
    /// Сколько ждать модель, прежде чем ответить правилами
    @ObservationIgnored private let plannerTimeout: Duration
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
    /// Что умеет экран для действий интерфейса: открыть файл, скопировать,
    /// напомнить, подтвердить. Даёт ChatView
    @ObservationIgnored private var genuiHooks: GenUIChatHooks?

    init(
        search: SearchService,
        planner: @escaping @MainActor () -> (any ChatPlanning)? = { nil },
        plannerTimeout: Duration = .seconds(20),
        cloudSession: URLSession = .shared,
        cloudTimeout: Duration = .seconds(60),
        cloudSilence: Duration = .seconds(20),
        inbox: ChatAttachmentInbox? = nil
    ) {
        self.search = search
        self.planner = planner
        self.plannerTimeout = plannerTimeout
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

    /// Замыкания экрана для действий ответа интерфейсом
    func useGenUIHooks(_ hooks: GenUIChatHooks) {
        genuiHooks = hooks
    }

    /// Хранилище модели приходит из окружения экрана — уже после создания сессии
    func usePlanner(_ planner: @escaping @MainActor () -> (any ChatPlanning)?) {
        self.planner = planner
    }

    /// `documentID` — чип уточнения указал документ, его и показываем.
    /// `attachments` — вложения из «+»: их кадры видит облачная модель
    func send(_ text: String, documentID: Int64? = nil, attachments: [CloudChatAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isAnswering else { return }
        let history = turns()
        let context = contextDocumentIDs()
        messages.append(Message(role: .user, text: trimmed))
        let pending = Message(role: .assistant, text: "", isPending: true)
        messages.append(pending)
        // Чип указал документ — отвечают правила: выбор уже сделан
        let model = documentID == nil ? planner() : nil
        // Облако — если выбрано на поле ввода, включено и с ключом
        let cloud = search.cloud
        // Выключенный облачный чат — не сбой: чип и так показывает «iPhone»
        let wantsCloud = documentID == nil && cloud.chatAvailable && cloud.chatModel != .local
        let configuration = wantsCloud ? cloud.chatConfiguration : nil

        cloudTask = Task {
            // Кто владелец и чей «мой паспорт» — правила, без облака: модель
            // угадывала чужой паспорт (жалоба владельца 13.10.2026)
            if documentID == nil, attachments.isEmpty, let local = await self.ownerAnswer(trimmed, context: context) {
                await self.show(local, pending: pending.id, question: trimmed, configuration: configuration)
                return
            }
            var notice: String?
            if let configuration {
                // Быстрый путь: однозначный поиск своего документа правила
                // отвечают сразу — облако думало над «паспорт ильи» минуту.
                // «Подумать» и вложения — всегда облако
                if configuration.reasoning != .deep, attachments.isEmpty {
                    let (local, hits) = await ChatRouter(search: search).reply(to: trimmed, preferring: nil, context: context)
                    if Self.isConfidentLookup(trimmed, reply: local) {
                        let cards = await ChatCardResolver(search: search).resolve(local.cards, hits: hits)
                        if !cards.isEmpty, let index = messages.firstIndex(where: { $0.id == pending.id }) {
                            messages[index].text = local.text
                            messages[index].cards = cards
                            messages[index].plan = ChatPlan(rulesFor: trimmed)
                            messages[index].isPending = false
                            // Облако должно знать, что показано: «а адрес?» — о нём
                            engine(for: configuration).record(question: trimmed, answer: Self.summary(of: local.cards))
                            return
                        }
                    }
                }
                let result = await answerInCloud(trimmed, attachments: attachments, configuration: configuration, pending: pending.id)
                if result.done { return }
                notice = result.notice
            } else if wantsCloud {
                notice = Self.cloudNotice
            }
            let (reply, hits, plan) = await answer(trimmed, documentID: documentID, context: context, history: history, model: model)
            let cards = await ChatCardResolver(search: search).resolve(reply.cards, hits: hits)
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
            messages[index].plan = plan
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
        let cards = await ChatCardResolver(search: search).resolve(local.reply.cards, hits: local.hits)
        guard let index = messages.firstIndex(where: { $0.id == pending }) else { return }
        messages[index].text = local.reply.text
        messages[index].cards = cards
        messages[index].plan = ChatPlan(rulesFor: question)
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
        messages.removeAll()
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
            var notice: String?
            if let configuration {
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
                reply = await FilePlacementAdvisor(store: store, search: search).localReply(for: items)
            } else {
                reply = ChatReply(text: "Файлы получил, но разложить их сейчас не могу — откройте чат заново.", cards: [])
            }
            let cards = await ChatCardResolver(search: search).resolve(reply.cards)
            guard let index = messages.firstIndex(where: { $0.id == pending.id }) else { return }
            messages[index].text = reply.text
            messages[index].cards = cards
            messages[index].notice = notice
            messages[index].thoughts = ""
            messages[index].isPending = false
        }
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
                : await ChatCardResolver(search: search).resolve(reply.cards)
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
        let resolved = await ChatCardResolver(search: search).resolve([card])
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
                    case .cards(let cards):
                        // Карточки — сразу, до текста ответа. Подставляется весь
                        // список: два вызова show_cards не перепутают порядок
                        shown.raw += cards
                        let snapshot = shown.raw
                        Task { @MainActor in
                            let resolved = await ChatCardResolver(search: self.search).resolve(snapshot)
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

    // MARK: - Модель или правила

    /// Ответ модели, если она есть и успела, иначе — правила. Чат с моделью
    /// не должен отвечать хуже, чем без неё: если правила узнали личный
    /// документ, а модель увела в поиск или в разговор, верят правилам
    private func answer(
        _ text: String,
        documentID: Int64?,
        context: [Int64],
        history: [ChatTurn],
        model: (any ChatPlanning)?
    ) async -> (ChatReply, [Int64: SearchResult], ChatPlan) {
        let router = ChatRouter(search: search)
        // Адрес модель не планирует: его страницу ищут правила
        if let model, !ChatIntent(text).wantsAddress {
            let inventory = ChatInventory(documents: await search.documents(ofTypes: DocumentType.allCases))
            if let plan = await Self.plan(with: model, question: text, history: history, inventory: inventory, timeout: plannerTimeout),
               Self.accepts(plan, rules: ChatIntent(text)) {
                let (reply, hits) = await router.reply(plan: plan, text: text)
                return (reply, hits, plan)
            }
        }
        let (reply, hits) = await router.reply(to: text, preferring: documentID, context: context)
        return (reply, hits, ChatPlan(rulesFor: text))
    }

    /// Документы прошлого ответа: к ним относятся уточнения «а адрес?»,
    /// «а дата выдачи?»
    private func contextDocumentIDs() -> [Int64] {
        guard let last = messages.last(where: { $0.role == .assistant && !$0.isPending }) else { return [] }
        var seen = Set<Int64>()
        return last.cards.flatMap(\.card.documentIDs).filter { seen.insert($0).inserted }
    }

    /// Правила узнали личный документ — план модели годится, только если
    /// он тоже о документе
    static func accepts(_ plan: ChatPlan, rules: ChatIntent) -> Bool {
        let rulesFoundDocument = rules.types.contains(where: \.isPersonal)
        guard rulesFoundDocument else { return true }
        return plan.action == .document || plan.action == .list
    }

    /// Гонка модели и таймера. Проигравший не задерживает ответ: долгая первая
    /// загрузка модели доработает в фоне и пригодится к следующему вопросу
    static func plan(
        with model: any ChatPlanning,
        question: String,
        history: [ChatTurn],
        inventory: ChatInventory,
        timeout: Duration
    ) async -> ChatPlan? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let work = Task {
                once.resume(try? await model.plan(question: question, history: history, inventory: inventory))
            }
            Task {
                try? await Task.sleep(for: timeout)
                work.cancel()
                once.resume(nil)
            }
        }
    }

    /// Прошлые вопросы и планы ответов на них — для уточнений вроде «а загран?».
    /// Ни карточек, ни значений полей модель не видит
    private func turns() -> [ChatTurn] {
        var turns: [ChatTurn] = []
        for (question, answer) in zip(messages, messages.dropFirst())
        where question.role == .user && answer.role == .assistant && !answer.isPending {
            guard let plan = answer.plan else { continue }
            turns.append(ChatTurn(question: question.text, plan: plan))
        }
        return Array(turns.suffix(ChatModelPrompt.maxTurns))
    }

    /// Поле исправили или подтвердили — карточки с этим документом перечитываются
    func refresh(documentID: Int64) async {
        let resolver = ChatCardResolver(search: search)
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

/// Продолжение, которое возобновляется ровно один раз — кто первый
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
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
