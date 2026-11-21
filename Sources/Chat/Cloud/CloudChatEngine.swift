import CryptoKit
import Foundation
import OSLog

// Облачный чат (решения владельца от 12.10.2026, docs/cloud-chat.md): OpenAI
// по умолчанию, Google Gemini — на выбор. Модель ведёт разговор и сама зовёт
// инструменты на iPhone: ищет документы, смотрит папки, показывает карточки,
// предлагает действия с файлами. Значения в карточках по-прежнему подставляет
// база; серию и номер модель не видит. История — только в памяти: на диск не
// пишется ничего, у OpenAI ответы не хранятся (store=false)

/// Какая модель отвечает в чате — выбор на поле ввода
enum CloudChatModel: String, CaseIterable, Sendable {
    case luna = "gpt-6-luna"
    case sol = "gpt-6.1-sol"
    case astra = "gpt-6-astra"
    case flash = "gemini-3.8-flash"
    case flashLite = "gemini-3.5-flash-lite"
    /// Без облака: правила и модель на iPhone
    case local

    var provider: CloudProvider? {
        switch self {
        case .luna, .sol, .astra: .openAI
        case .flash, .flashLite: .gemini
        case .local: nil
        }
    }

    var title: String {
        switch self {
        case .luna: "GPT-6 Luna — быстрая"
        case .sol: "GPT-6.1 Sol — умнее"
        case .astra: "GPT-6 Astra — самая умная, дорогая"
        case .flash: "Gemini 3.8 Flash"
        case .flashLite: "Gemini 3.5 Flash-Lite"
        case .local: "На iPhone"
        }
    }

    /// Подпись на чипе — коротко, чтобы поле ввода осталось в одну строку
    var chip: String {
        switch self {
        case .luna: "Luna"
        case .sol: "Sol"
        case .astra: "Astra"
        case .flash: "Flash"
        case .flashLite: "Lite"
        case .local: "iPhone"
        }
    }

    /// Что предложить на поле ввода: модели выбранного сервиса. «iPhone» не
    /// выбирают — чат только облачный (владелец 19.11.2026); без ключа и
    /// связи отвечают правила на iPhone сами
    static func choices(for provider: CloudProvider) -> [CloudChatModel] {
        allCases.filter { $0.provider == provider }
    }

    /// Luna — самая быстрая и дешёвая из GPT-6 ($0.1/$0.5 за миллион токенов)
    static func defaultModel(for provider: CloudProvider) -> CloudChatModel {
        switch provider {
        case .openAI: .luna
        case .gemini: .flash
        }
    }
}

/// Сколько модели думать — выбор на поле ввода
enum CloudChatReasoning: String, CaseIterable, Sendable {
    case auto
    case fast
    case deep

    var title: String {
        switch self {
        case .auto: "Авто"
        case .fast: "Быстро"
        case .deep: "Подумать"
        }
    }

    var chip: String {
        switch self {
        case .auto: "Авто"
        case .fast: "Быстро"
        case .deep: "Думать"
        }
    }

    /// Уровень рассуждения по документации на 12.10.2026. OpenAI
    /// (reasoning.effort): у GPT-6 Luna — none … max, у GPT-6.1 Sol и GPT-6
    /// Astra none нет — low … max. Gemini (thinkingLevel): у 3.8 Flash — low,
    /// medium, high, minimal там ошибка; у 3.5 Flash-Lite — minimal … high.
    /// «Авто» решает сам: самый быстрый уровень для простого вопроса, на ступень
    /// выше — когда просят сравнить, посчитать, разобрать или прислали файлы.
    /// Средний уровень Gemini по умолчанию думал над «паспорт ильи» минуту
    func level(for model: CloudChatModel, message: String = "", hasAttachments: Bool = false, interface: Bool = false) -> String {
        let complex = Self.isComplex(message) || hasAttachments || (interface && Self.wantsInterface(message))
        switch (self, model) {
        case (.deep, _): return "high"
        // Простой вопрос — none, сложный и интерфейс — low. Большая проверка
        // 19.11.2026 (опись в инструкции, 38 вопросов × 2): none — 74/76 и p90
        // первого ответа 3,2 с, low — 72/76 и 4,0 с. Прежде любой вопрос о
        // документах шёл на low: с none Luna угадывала, чей «мой паспорт»
        // (13.10.2026) — теперь владельца знает инструкция, а без него правила
        // спрашивают «Чей?» до облака
        case (.auto, .luna): return complex ? "low" : "none"
        case (.fast, .luna): return "none"
        case (.fast, .flashLite): return "minimal"
        case (.fast, _): return "low"
        case (.auto, _): return complex ? "medium" : "low"
        }
    }

    /// Вопрос, на который лучше ответить интерфейсом: сводка, график, подбор,
    /// расчёт. Для ответа интерфейсом Luna тогда думает на уровне low — без
    /// рассуждения она чаще отвечает одним списком (живая проверка 13.10.2026)
    static func wantsInterface(_ message: String) -> Bool {
        let lower = message.lowercased()
        let stems = ["сколько", "категор", "график", "диаграм", "таблиц", "сводк", "обзор", "что с мо", "подбер", "подобр",
                     "какие документы", "калькул", "ипотек", "кредит", "вклад", "платёж", "платеж", "бюджет", "поездк"]
        return stems.contains { lower.contains($0) }
    }

    /// Сложный вопрос: длинный или просит сравнить, посчитать, проанализировать,
    /// рассортировать, спланировать
    static func isComplex(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.count > 160 { return true }
        let stems = ["сравн", "посчита", "подсчит", "вычисл", "сумм", "анализ", "проанализ", "сортир", "рассортир",
                     "разбер", "разлож", "распредел", "спланир", "план", "объясн", "почему", "итог"]
        return stems.contains { lower.contains($0) }
    }
}

/// Вложение, которое человек кинул в чат: id «a1», имя и кадр JPEG ≤ 2048 px.
/// Список вложений — у агента B (ChatAttachmentInbox)
struct CloudChatAttachment: Sendable, Equatable {
    let id: String
    let name: String
    let jpeg: Data
}

/// Что видно, пока модель отвечает
enum CloudChatEvent: Sendable, Equatable {
    /// Итог рассуждения целиком, уже с маской номеров
    case thoughts(String)
    /// Текст ответа целиком, уже с маской номеров
    case text(String)
    /// Модель зовёт инструмент — новый раунд ответа
    case tool(String)
    /// Что инструмент делает — шаг для экрана: «Ищу в документах: прописка»
    case step(ChatStep.Kind, String)
    /// Карточки show_cards — показать сразу, до текста
    case cards([ChatCard])
    /// Ответ интерфейсом: очередной кусок JSON как есть, без маски — маска
    /// ложится на разобранные значения (`GenUIStreamFeed`)
    case answerDelta(String)
    /// Повторный раунд после пустого ответа или исчерпания шагов: поток
    /// интерфейса и накопленный текст прошлого раунда сбрасываются
    case resetAnswer
}

struct CloudChatReply: Sendable, Equatable {
    var text: String
    var cards: [ChatCard]
    var thoughts: String
    var thinkingSeconds: Double?
}

/// Действия с файлами: модель предлагает, человек подтверждает на карточке.
/// Получает аргументы propose_file_actions в JSON и возвращает карточку.
/// Реализует агент B (FileProposalBuilder в Sources/Chat/Files/FileProposal.swift)
typealias FileProposalMaker = @MainActor (Data) throws -> ChatCard

@MainActor
final class CloudChatEngine {
    struct Configuration: Equatable, Sendable {
        var provider: CloudProvider
        var baseURL: String
        var apiKey: String
        var model: CloudChatModel
        var reasoning: CloudChatReasoning
    }

    static let maxRounds = 6
    /// Инструменты, после которых ответ готов: карточки и предложение показаны,
    /// лишний раунд за финальным текстом не нужен
    static let terminalTools: Set<String> = ["show_cards", "propose_file_actions", "show_fact_card", "propose_fact_card", "propose_field_fix"]

    /// Этап дольше этого — строкой в ленте шагов: где ушло время
    static let slowStage: TimeInterval = 3

    static let emptyAnswerNudge = "Ответ получился пустым. Сделай то, о чём я просил: вызови нужный инструмент или ответь текстом."

    static func isCyrillic(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    /// Пустой ответ. Текстом — ни одной буквы кириллицы. Интерфейсом — ни
    /// текста, ни блоков: карточка app_card без подписи — уже ответ, хоть в её
    /// JSON и нет кириллицы (живая проверка 19.11.2026: такой ответ считался
    /// пустым, повторная просьба затирала карточку — «Не нашёл, что ответить»)
    static func isEmptyAnswer(_ answer: String, genUI: Bool) -> Bool {
        if genUI, let json = try? JSONValue(parsing: answer), json["version"] != nil || json["blocks"] != nil {
            let text = json["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty && (json["blocks"]?.array ?? []).isEmpty
        }
        return !answer.contains(where: isCyrillic)
    }

    /// Опись документов для системной инструкции: id, вид, название, владелец,
    /// папка — без номеров. Стабильный префикс запроса: на нём работает кэш
    var documentIndex = ""
    /// Папки для облака: id · путь · файлов (SearchService.chatFolderIndex)
    var folderIndex = ""
    /// Финальный ответ — интерфейсом: JSON по схеме Generative UI
    /// (docs/genui.md). Текст ответа тогда приходит событиями answerDelta
    var genUI = false
    /// Владелец хранилища — «Савин И. А.»: строкой в инструкции. nil — неизвестен
    var ownerName: String?
    /// Уровень рассуждения вместо выбранного чипом — для живой проверки
    var reasoningOverride: String?
    /// Быстрый режим Luna (service_tier fast). Живая проверка сравнивает с обычным
    var fastTier = true
    /// Сколько токенов ушло за сессию — по usage ответов
    private(set) var usage = CloudChatUsage()
    private let log = Logger(subsystem: "com.ilyaqa.LocalDrive", category: "cloud-chat")

    var configuration: Configuration
    private let session: URLSession
    private let tools: CloudChatTools
    /// Для шагов на экране: название документа по id из аргументов
    private let search: SearchService
    /// «Карточки»: их опись — в инструкции, работа с ними — инструментами
    var facts: FactStore? {
        get { tools.facts }
        set { tools.facts = newValue }
    }
    /// Прошлые ходы разговора в формате сервиса — только в памяти
    private(set) var history: [CloudJSON] = []
    /// Чьей модели история: у другого сервиса другой формат, у другой модели
    /// OpenAI — свой набор уровней рассуждения
    private var historyModel: CloudChatModel?
    private var dialectState = CloudChatDialectState()
    /// Отказы сервера от необязательных полей: дальше в этой сессии без них
    private var options = CloudChatOptions()

    init(configuration: Configuration, search: SearchService, proposals: FileProposalMaker? = nil, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        self.search = search
        tools = CloudChatTools(search: search, proposals: proposals)
    }

    /// Инструкция этого разговора частями — та же, что уйдёт с вопросом
    private func systemParts(genUI: Bool) -> CloudChatSystem {
        Self.parts(documentIndex, genUI: genUI, owner: ownerName, facts: CloudChatFactTools.index(facts, details: true), folders: folderIndex)
    }

    /// Переносит отказы сервера от необязательных полей в настройки сессии,
    /// не трогая флаги, которые были выключены снаружи (например, fastTier)
    private func apply(_ relaxed: CloudChatOptions, from current: CloudChatOptions) {
        if current.summaries, !relaxed.summaries { options.summaries = false }
        if current.fastTier, !relaxed.fastTier { options.fastTier = false }
        if current.configurationUpdates, !relaxed.configurationUpdates { options.configurationUpdates = false }
        if current.cacheBreakpoint, !relaxed.cacheBreakpoint { options.cacheBreakpoint = false }
        if current.genUI, !relaxed.genUI { options.genUI = false }
    }

    /// Прогреть кэш префикса: правила, опись, инструменты и схема ответа
    /// уходят заранее, без вопроса, и первый вопрос не ждёт их разбора.
    /// Запись живёт 12 часов: прогрев повторяется, только когда префикс
    /// изменился (документы, владелец, модель) или срок подходит к концу.
    /// Если сервер отклонил необязательное поле (итоги рассуждения, fast),
    /// прогрев повторяется без него и запоминает отказ на сессию — первый
    /// вопрос не платит лишним кругом 400
    func prewarm(now: Date = Date()) async {
        prepareHistory()
        var state = dialectState
        if state.baseLevel == nil, configuration.provider == .openAI { state.baseLevel = OpenAIChatDialect.baseLevel }
        while true {
            var current = options
            current.fastTier = current.fastTier && fastTier
            let usesGenUI = genUI && current.genUI
            let system = systemParts(genUI: usesGenUI)
            // Отметка — по всему, что входит в кэшируемый префикс, кроме даты: она
            // идёт после отметок кэша, и её смена прогрева не требует
            var undated = system
            undated.today = ""
            guard let request = dialect.prewarmRequest(system: system, configuration: configuration, state: state, options: current, genUI: usesGenUI),
                  let body = dialect.prewarmRequest(system: undated, configuration: configuration, state: state, options: current, genUI: usesGenUI)?.httpBody
            else { return }
            let key = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            if let warm = Self.warmPrefix, warm.key == key, warm.until > now { return }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    if let usage = CloudJSON.parse(data)?["usage"] { self.usage += CloudChatUsage(usage: usage) }
                    Self.warmPrefix = (key, now.addingTimeInterval(Self.warmLifetime))
                    return
                }
                if let relaxed = dialect.relaxing(current, status: status, body: data) {
                    apply(relaxed, from: current)
                    continue
                }
                return
            } catch {
                return
            }
        }
    }

    /// Отметка «префикс прогрет»: хеш тела прогрева и до каких пор. Запись в
    /// кэш живёт не меньше 12 часов — повтор чуть раньше, с запасом
    static let warmLifetime: TimeInterval = 11 * 3600
    private static var warmPrefix: (key: String, until: Date)? {
        get {
            guard let key = UserDefaults.standard.string(forKey: "chat.warmPrefix.key"),
                  let until = UserDefaults.standard.object(forKey: "chat.warmPrefix.until") as? Date else { return nil }
            return (key, until)
        }
        set {
            UserDefaults.standard.set(newValue?.key, forKey: "chat.warmPrefix.key")
            UserDefaults.standard.set(newValue?.until, forKey: "chat.warmPrefix.until")
        }
    }

    func reset() {
        history = []
        historyModel = nil
        dialectState = CloudChatDialectState()
        tools.forgetSensitive()
    }

    private var dialect: any CloudChatDialect {
        switch configuration.provider {
        case .openAI: OpenAIChatDialect()
        case .gemini: GeminiChatDialect()
        }
    }

    /// Модель или сервис сменились: история другого сервиса не подходит, а у
    /// OpenAI сбрасываются уровни рассуждения — у Sol и Astra нет «none»
    private func prepareHistory() {
        guard historyModel != configuration.model else { return }
        if historyModel?.provider != configuration.model.provider {
            history = []
        } else {
            history = history.filter { $0["type"]?.string != "configuration_update" }
        }
        dialectState = CloudChatDialectState()
        historyModel = configuration.model
    }

    /// Ход, на который ответило не облако: быстрый ответ правил или
    /// остановленный ответ. Модель должна знать, что человек уже видел, —
    /// иначе «а адрес?» после него ей не к чему отнести
    func record(question: String, answer: String) {
        prepareHistory()
        history = dialect.appending(note: question, answer: answer, to: history)
    }

    /// Маска номеров документов, прошедших через инструменты
    func mask(_ text: String) -> String {
        tools.mask(text)
    }

    /// Перестроить блок интерфейса: модель видит переписку, блок и значения
    /// состояния, но этот ход в историю не попадает. Возвращает JSON блока
    func regenerate(block: JSONValue, instruction: String?, state: GenUIStateSnapshot) async throws -> JSONValue? {
        let request = CloudChatGenUI.regenerateRequest(block: block, instruction: instruction, state: state)
        let reply = try await respond(to: request, commit: false)
        guard let json = try? JSONValue(Data(reply.text.utf8)) else { return nil }
        return json["blocks"]?[0]
    }

    /// Ответ на сообщение: раунды «модель → инструменты → модель», пока модель
    /// не ответит текстом или карточками, но не больше шести
    /// `commit: false` — ход не остаётся в истории (перестройка блока)
    func respond(
        to text: String,
        attachments: [CloudChatAttachment] = [],
        commit: Bool = true,
        onEvent: @escaping @MainActor (CloudChatEvent) -> Void = { _ in }
    ) async throws -> CloudChatReply {
        prepareHistory()
        let dialect = dialect
        let level = reasoningOverride
            ?? configuration.reasoning.level(for: configuration.model, message: text, hasAttachments: !attachments.isEmpty, interface: genUI)
        let listing = attachments.isEmpty ? "" : "\n\nВложения: " + attachments.map { "\($0.id) — «\($0.name)»" }.joined(separator: ", ")
        var state = dialectState
        var items = dialect.appending(user: text + listing, attachments: attachments, level: level,
                                      to: dialect.withoutOldImages(history), state: &state)

        let round = RoundState()
        let started = Date()
        var thinkingSeconds: Double?
        var firstToken: Double?
        var firstCard: Double?
        var rounds = 0
        defer {
            #if DEBUG
            // Только время — ни вопроса, ни ответа в журнале нет
            let total = Date().timeIntervalSince(started)
            log.debug("облачный чат: первый токен \(firstToken ?? -1, format: .fixed(precision: 2)) с, первая карточка \(firstCard ?? -1, format: .fixed(precision: 2)) с, всего \(total, format: .fixed(precision: 2)) с, раундов \(rounds), рассуждение \(level, privacy: .public), \(self.configuration.model.rawValue, privacy: .public)")
            #endif
        }
        func visible() {
            if thinkingSeconds == nil, !round.thoughts.isEmpty { thinkingSeconds = Date().timeIntervalSince(started) }
        }
        let genUI = genUI
        func finish(_ text: String) -> CloudChatReply {
            if commit {
                history = items
                dialectState = state
            }
            if thinkingSeconds == nil, !round.thoughts.isEmpty { thinkingSeconds = Date().timeIntervalSince(started) }
            // JSON интерфейса — как есть: маска на сыром JSON сломала бы числа.
            // Сервер мог отказаться от схемы — тогда это обычный текст
            let usesGenUI = genUI && self.options.genUI
            return CloudChatReply(text: usesGenUI ? text : tools.mask(text), cards: round.cards, thoughts: tools.mask(round.thoughts), thinkingSeconds: thinkingSeconds)
        }

        var nudged = false
        for _ in 0..<Self.maxRounds {
            rounds += 1
            round.answer = ""
            round.early = [:]
            var seen = 0
            // Настройки запроса читаются при каждой попытке: после отказа от
            // необязательного поля повтор идёт уже без него
            let request = {
                var options = self.options
                options.fastTier = options.fastTier && self.fastTier
                return dialect.request(history: items, system: self.systemParts(genUI: genUI && self.options.genUI),
                                       configuration: self.configuration, level: level, state: state, options: options,
                                       genUI: genUI && self.options.genUI)
            }
            let turn = try await stream(request, dialect: dialect, onStage: { onEvent(.step(.think, $0)) }) { delta in
                if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                if delta.thought {
                    round.thoughts += delta.text
                    onEvent(.thoughts(self.tools.mask(round.thoughts)))
                } else {
                    visible()
                    round.answer += delta.text
                    onEvent((genUI && self.options.genUI) ? .answerDelta(delta.text) : .text(self.tools.mask(round.answer)))
                }
            } onCall: { call in
                // Карточки — как только вызов пришёл целиком, до текста ответа
                let index = seen
                seen += 1
                guard call.name == "show_cards" else { return }
                await self.announce(call, onEvent: onEvent)
                await self.run(call, index: index, round: round, onEvent: onEvent)
                if !round.cards.isEmpty {
                    visible()
                    if firstCard == nil { firstCard = Date().timeIntervalSince(started) }
                }
            }
            items = dialect.appending(turn: turn, to: items)
            // Пустой ответ без карточек — модель потеряла нить: ещё один раунд
            // с подсказкой. Живая проверка 25.10.2026: «запомни: …» — пустой
            // ответ в 1 из 5. Ответ по-русски без единой буквы кириллицы — пустой
            if turn.calls.isEmpty, !nudged, round.cards.isEmpty, Self.isEmptyAnswer(round.answer, genUI: genUI && self.options.genUI) {
                nudged = true
                // Прежний пустой JSON уже закрыл парсер интерфейса (.done):
                // сбрасываем его, иначе повторный ответ будет молча отброшен
                onEvent(.resetAnswer)
                items = dialect.appending(user: Self.emptyAnswerNudge, attachments: [], level: level, to: items, state: &state)
                continue
            }
            guard !turn.calls.isEmpty else { return finish(round.answer) }

            var results: [(call: CloudChatCall, result: CloudJSON)] = []
            var endsTurn = true
            for (index, call) in turn.calls.enumerated() {
                onEvent(.tool(call.name))
                if round.early[index] == nil {
                    await announce(call, onEvent: onEvent)
                    await run(call, index: index, round: round, onEvent: onEvent)
                    if !round.cards.isEmpty {
                        visible()
                        if firstCard == nil { firstCard = Date().timeIntervalSince(started) }
                    }
                }
                let outcome = round.early[index] ?? (result: [:], shown: false)
                results.append((call, outcome.result))
                // Карточка не показалась — модели нужен ещё раунд, чтобы это объяснить
                if !Self.terminalTools.contains(call.name) || !outcome.shown { endsTurn = false }
            }
            items = dialect.appending(results: results, to: items)
            // Только карточки и предложения — ответ готов. Результаты остаются
            // в истории, следующий вопрос продолжит этот ход
            if endsTurn { return finish(round.answer) }
        }
        if round.answer.isEmpty {
            onEvent(.resetAnswer)
            return finish("Не успел собрать ответ — уточните вопрос.")
        }
        return finish(round.answer)
    }

    /// Шаг на экране — до того, как инструмент начнёт работу
    private func announce(_ call: CloudChatCall, onEvent: @MainActor (CloudChatEvent) -> Void) async {
        guard let (kind, text) = await CloudChatSteps.step(for: call.name, arguments: call.arguments, search: search, facts: facts) else { return }
        onEvent(.step(kind, text))
    }

    /// Инструмент и его карточки. Результат запоминается по номеру вызова в
    /// ходе: show_cards, выполненный прямо из потока, второй раз не зовётся
    private func run(_ call: CloudChatCall, index: Int, round: RoundState, onEvent: @MainActor (CloudChatEvent) -> Void) async {
        var cards = round.cards
        let before = cards.count
        let result = await tools.run(call.name, arguments: call.arguments, cards: &cards)
        round.cards = cards
        let shown = cards.count > before
        round.early[index] = (result, shown)
        if shown { onEvent(.cards(Array(cards[before...]))) }
    }

    /// `facts` — опись «Карточек» (CloudChatFactTools.index)
    static func system(_ index: String, genUI: Bool = false, owner: String? = nil, facts: String = "", today: Date = Date()) -> String {
        parts(index, genUI: genUI, owner: owner, facts: facts, today: today).text
    }

    /// Инструкция частями: правила, хранилище, дата — от редко меняющегося к
    /// ежедневному (CloudChatSystem)
    static func parts(_ index: String, genUI: Bool = false, owner: String? = nil, facts: String = "", folders: String = "",
                      today: Date = Date()) -> CloudChatSystem {
        // Чей «мой паспорт»: модель не угадывает владельца по документам
        let ownerLine = owner.map { "Владелец хранилища: \($0). «Мой паспорт», «мои права», «мне» — о его документах; «сколько у меня … и чьи», «что у меня есть» — обо всём хранилище." }
            ?? "Владелец хранилища неизвестен. На «мой паспорт», «мои документы» при документах нескольких людей не угадывай — спроси, чей, вариантами с именами."
        // Без даты модель считала возраст от своего года: «Ольге 33 года (по
        // состоянию на 2025 год)» 26.10.2026 (живая проверка C2)
        let day = Calendar(identifier: .gregorian).dateComponents([.day, .month, .year], from: today)
        let dateLine = String(format: "Сегодня %02d.%02d.%04d — возраст и сроки считай от этой даты.", day.day ?? 1, day.month ?? 1, day.year ?? 2026)
        let rules = (genUI ? CloudChatGenUI.system : CloudChatPrompt.system) + "\n" + CloudChatFactTools.instruction
        let lines = index.split(separator: "\n").map { LocalAgentPrompt.labeled(String($0), withType: true) }
        var vault = ownerLine
        if !lines.isEmpty { vault += "\n\nДокументы хранилища:\n" + lines.joined(separator: "\n") }
        if !folders.isEmpty { vault += "\n\nПапки (id · путь · файлов) — для переноса берите id отсюда, без list_folders:\n" + folders }
        if !facts.isEmpty { vault += "\n\nКарточки (id · название · поля):\n" + facts }
        return CloudChatSystem(rules: rules, vault: vault, today: dateLine)
    }

    // MARK: - Поток

    /// Запрос и поток ответа. Если сервер отказался от необязательного поля
    /// (итоги рассуждения без верификации организации, быстрый режим, смена
    /// уровня посреди разговора), тот же раунд повторяется без него
    private func stream(
        _ request: () -> URLRequest,
        dialect: any CloudChatDialect,
        onStage: (String) -> Void = { _ in },
        onDelta: (CloudChatDelta) -> Void,
        onCall: (CloudChatCall) async -> Void
    ) async throws -> CloudChatTurn {
        while true {
            let (bytes, response): (URLSession.AsyncBytes, URLResponse)
            let sent = Date()
            do {
                (bytes, response) = try await session.bytes(for: request())
                // Долго до ответа сервера — это сеть или VPN, а не модель: видно
                // в ленте шагов (сборка 22 на iPhone владельца молчала 20 с)
                let waited = Date().timeIntervalSince(sent)
                if waited >= Self.slowStage { onStage("Соединение с облаком · \(Int(waited.rounded())) с") }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError where error.code == .timedOut {
                throw CloudChatTimeout(seconds: Int(streamRequestTimeout))
            } catch {
                throw CloudFailure.network
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                var body = Data()
                for try await byte in bytes { body.append(byte) }
                var current = options
                current.fastTier = current.fastTier && fastTier
                if let relaxed = dialect.relaxing(current, status: status, body: body) {
                    apply(relaxed, from: current)
                    continue
                }
                throw CloudResponseParser.failure(status: status, data: body) ?? CloudFailure.badResponse
            }
            do {
                // Сервер ответил, а модель долго не начинает — это уже облако
                let answered = Date()
                var started = false
                let turn = try await dialect.read(bytes.lines, onDelta: { delta in
                    if !started {
                        started = true
                        let waited = Date().timeIntervalSince(answered)
                        if waited >= Self.slowStage { onStage("Облако начало отвечать через \(Int(waited.rounded())) с") }
                    }
                    onDelta(delta)
                }, onCall: onCall)
                usage += turn.usage
                guard !turn.items.isEmpty else { throw CloudFailure.badResponse }
                return turn
            } catch let failure as CloudFailure {
                throw failure
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError where error.code == .timedOut {
                throw CloudChatTimeout(seconds: Int(streamRequestTimeout))
            } catch {
                throw CloudFailure.network
            }
        }
    }
}

/// Что копится за раунд: карточки, текст и рассуждение, результаты
/// инструментов, выполненных прямо из потока
@MainActor
private final class RoundState {
    var cards: [ChatCard] = []
    var thoughts = ""
    var answer = ""
    var early: [Int: (result: CloudJSON, shown: Bool)] = [:]
}

// MARK: - Сервисы

/// Кусок потока: текст ответа или итог рассуждения
struct CloudChatDelta {
    let text: String
    let thought: Bool
}

/// Вызов инструмента: аргументы уже без null — строгая схема OpenAI шлёт null
/// вместо пропущенного поля
struct CloudChatCall {
    let id: String?
    let name: String
    let arguments: CloudJSON
}

/// Ход модели: элементы ответа дословно, как их вернуть в историю, и вызовы
struct CloudChatTurn {
    var items: [CloudJSON] = []
    var calls: [CloudChatCall] = []
    var usage = CloudChatUsage()
}

/// Расход токенов по ответам сервиса — для оценки цены
struct CloudChatUsage: Equatable, Sendable {
    var requests = 0
    var inputTokens = 0
    /// Из них прочитано из кэша
    var cachedTokens = 0
    /// Из них записано в кэш: на 30 минут — 1,25× цены входа, на 12 часов — 2,5×
    var cacheWriteTokens = 0
    var longCacheWriteTokens = 0
    var outputTokens = 0

    /// usage ответа OpenAI: input_tokens_details.cached_tokens — прочитанное,
    /// cache_write_tokens — записанное, по срокам в cache_write_tokens_details
    init(usage: CloudJSON) {
        requests = 1
        inputTokens = usage["input_tokens"]?.int ?? 0
        cachedTokens = usage["input_tokens_details"]?["cached_tokens"]?.int ?? 0
        cacheWriteTokens = usage["input_tokens_details"]?["cache_write_tokens"]?.int ?? 0
        longCacheWriteTokens = usage["input_tokens_details"]?["cache_write_tokens_details"]?["ttl_12h_tokens"]?.int ?? 0
        outputTokens = usage["output_tokens"]?.int ?? 0
    }

    init(requests: Int = 0, inputTokens: Int = 0, cachedTokens: Int = 0, outputTokens: Int = 0) {
        self.requests = requests
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
    }

    static func += (lhs: inout CloudChatUsage, rhs: CloudChatUsage) {
        lhs.requests += rhs.requests
        lhs.inputTokens += rhs.inputTokens
        lhs.cachedTokens += rhs.cachedTokens
        lhs.cacheWriteTokens += rhs.cacheWriteTokens
        lhs.longCacheWriteTokens += rhs.longCacheWriteTokens
        lhs.outputTokens += rhs.outputTokens
    }
}

/// Системная инструкция частями. У OpenAI это три блока сообщения developer:
/// правила неизменны, опись хранилища меняется вместе с документами, дата —
/// раз в сутки. Правила и опись — каждый со своей отметкой кэша на 12 часов,
/// дата — после них: её смена кэш не сбивает (docs/cloud-chat.md, «Кэш»)
struct CloudChatSystem: Equatable, Sendable {
    var rules: String
    var vault: String
    var today: String

    /// Одной строкой — для Gemini и для «instructions», если отметки кэша не приняты
    var text: String { [rules, vault, today].filter { !$0.isEmpty }.joined(separator: "\n\n") }
}

/// Уровень рассуждения OpenAI: на уровне запроса — постоянный для модели
/// (CloudChatModel.baseLevel), а уровень вопроса — элементом
/// configuration_update перед ним. Поле запроса входит в кэшируемый префикс:
/// его смена от разговора к разговору сбрасывала бы кэш
/// (developers.openai.com: reasoning, «Change reasoning mid-conversation»)
struct CloudChatDialectState: Equatable {
    var baseLevel: String?
    var currentLevel: String?
}

/// Чего сервер не принял — и без чего дальше обходимся
struct CloudChatOptions: Equatable {
    /// reasoning.summary: «может потребоваться верификация организации»
    var summaries = true
    /// service_tier «fast»: проект может его не разрешать (400 Invalid service_tier)
    var fastTier = true
    /// configuration_update: уровень тогда меняется полем запроса
    var configurationUpdates = true
    /// Инструкция — сообщением developer с явной отметкой кэша
    /// (prompt_cache_breakpoint): верхнеуровневые instructions отметку не
    /// принимают, и общий префикс не кэшировался между разговорами
    var cacheBreakpoint = true
    /// Ответ по схеме Generative UI. Если сервер отклонит схему (400
    /// invalid_json_schema), ответ придёт текстом и карточками, а не ошибкой
    var genUI = true
}

/// Как говорить с конкретным облаком: запрос, поток ответа, история
@MainActor
protocol CloudChatDialect {
    func appending(user text: String, attachments: [CloudChatAttachment], level: String, to history: [CloudJSON],
                   state: inout CloudChatDialectState) -> [CloudJSON]
    /// Вопрос и ответ, данный без облака
    func appending(note question: String, answer: String, to history: [CloudJSON]) -> [CloudJSON]
    func request(history: [CloudJSON], system: CloudChatSystem, configuration: CloudChatEngine.Configuration, level: String,
                 state: CloudChatDialectState, options: CloudChatOptions, genUI: Bool) -> URLRequest
    /// Прогрев кэша префикса без ответа модели. nil — сервис так не умеет
    func prewarmRequest(system: CloudChatSystem, configuration: CloudChatEngine.Configuration, state: CloudChatDialectState,
                        options: CloudChatOptions, genUI: Bool) -> URLRequest?
    func read<Lines: AsyncSequence>(_ lines: Lines, onDelta: (CloudChatDelta) -> Void,
                                    onCall: (CloudChatCall) async -> Void) async throws -> CloudChatTurn where Lines.Element == String
    func appending(turn: CloudChatTurn, to history: [CloudJSON]) -> [CloudJSON]
    func appending(results: [(call: CloudChatCall, result: CloudJSON)], to history: [CloudJSON]) -> [CloudJSON]
    /// Картинки прошлых сообщений модель уже видела: в истории — подпись
    func withoutOldImages(_ history: [CloudJSON]) -> [CloudJSON]
    /// Отказ от необязательного поля: с чем повторить. nil — повторять нечего
    func relaxing(_ options: CloudChatOptions, status: Int, body: Data) -> CloudChatOptions?
}

/// Таймаут HTTP-запроса больше сроков чата (90 с / 180 с для «Подумать»),
/// чтобы обрыв по сроку контролировал сторож `ChatSession`, а не URLSession
private let streamRequestTimeout: TimeInterval = 180

private func streamRequest(_ url: String, apiKey: (field: String, value: String), body: Data) -> URLRequest {
    var request = URLRequest(url: URL(string: url) ?? URL(string: "https://invalid.invalid")!)
    request.httpMethod = "POST"
    request.timeoutInterval = streamRequestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey.value, forHTTPHeaderField: apiKey.field)
    request.httpBody = body
    return request
}

private func baseURL(_ configuration: CloudChatEngine.Configuration) -> String {
    configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
}

/// Картинки из результата инструмента (view_document кладёт их в «_images»):
/// результат без них и сами кадры base64
func toolImages(_ result: CloudJSON) -> (CloudJSON, [String]) {
    guard case .object(var object) = result, let images = object["_images"]?.array else { return (result, []) }
    object["_images"] = nil
    return (.object(object), images.compactMap(\.string))
}

/// Строка SSE «data: …» — объект JSON. Строки «event: …» и пустые пропускаются
private func event(_ line: String) -> CloudJSON? {
    guard line.hasPrefix("data:") else { return CloudJSON.parse(Data(line.utf8)) }
    return CloudJSON.parse(Data(line.dropFirst(5).utf8))
}

// MARK: Gemini

/// Gemini API, streamGenerateContent (ai.google.dev, 12.10.2026). Части
/// ответа возвращаются в историю дословно — с thoughtSignature, иначе Gemini 3
/// отвечает 400. Роли user и model должны чередоваться
struct GeminiChatDialect: CloudChatDialect {
    func appending(user text: String, attachments: [CloudChatAttachment], level: String, to history: [CloudJSON],
                   state: inout CloudChatDialectState) -> [CloudJSON] {
        var parts: [CloudJSON] = attachments.map { attachment in
            ["inline_data": ["mime_type": "image/jpeg", "data": .string(attachment.jpeg.base64EncodedString())]]
        }
        parts.append(["text": .string(text)])
        return appendingUser(parts, to: history)
    }

    func appending(note question: String, answer: String, to history: [CloudJSON]) -> [CloudJSON] {
        appendingUser([["text": .string(question)]], to: history) + [["role": "model", "parts": [["text": .string(answer)]]]]
    }

    /// Прошлый ответ кончился карточками без текстового раунда: ход человека
    /// с результатами инструментов продолжается этим сообщением
    private func appendingUser(_ parts: [CloudJSON], to history: [CloudJSON]) -> [CloudJSON] {
        var contents = history
        if let last = contents.last, last["role"]?.string == "user", let previous = last["parts"]?.array {
            contents[contents.count - 1] = ["role": "user", "parts": .array(previous + parts)]
        } else {
            contents.append(["role": "user", "parts": .array(parts)])
        }
        return contents
    }

    func request(history: [CloudJSON], system: CloudChatSystem, configuration: CloudChatEngine.Configuration, level: String,
                 state: CloudChatDialectState, options: CloudChatOptions, genUI: Bool) -> URLRequest {
        let model = configuration.model.provider == .gemini ? configuration.model.rawValue : CloudChatModel.flash.rawValue
        let body: CloudJSON = [
            "system_instruction": ["parts": [["text": .string(system.text)]]],
            "contents": .array(history),
            "tools": [["functionDeclarations": CloudChatPrompt.tools]],
            "generationConfig": ["thinkingConfig": ["includeThoughts": true, "thinkingLevel": .string(level)]],
        ]
        return streamRequest("\(baseURL(configuration))/models/\(model):streamGenerateContent?alt=sse",
                             apiKey: ("x-goog-api-key", configuration.apiKey), body: body.data)
    }

    /// У Gemini прогрева префикса нет
    func prewarmRequest(system: CloudChatSystem, configuration: CloudChatEngine.Configuration, state: CloudChatDialectState,
                        options: CloudChatOptions, genUI: Bool) -> URLRequest? {
        nil
    }

    /// Каждая строка «data: …» — GenerateContentResponse. Части копятся
    /// дословно — их вернём в историю как есть
    func read<Lines: AsyncSequence>(_ lines: Lines, onDelta: (CloudChatDelta) -> Void,
                                    onCall: (CloudChatCall) async -> Void) async throws -> CloudChatTurn where Lines.Element == String {
        var turn = CloudChatTurn()
        for try await line in lines {
            guard let json = event(line) else { continue }
            if let error = json["error"] {
                throw CloudResponseParser.failure(status: 400, data: (["error": error] as CloudJSON).data) ?? CloudFailure.badResponse
            }
            for part in json["candidates"]?.array?.first?["content"]?["parts"]?.array ?? [] {
                turn.items.append(part)
                if let text = part["text"]?.string, !text.isEmpty {
                    onDelta(CloudChatDelta(text: text, thought: part["thought"]?.bool == true))
                }
                if let call = part["functionCall"], let name = call["name"]?.string {
                    let parsed = CloudChatCall(id: call["id"]?.string, name: name, arguments: (call["args"] ?? [:]).withoutNulls)
                    turn.calls.append(parsed)
                    await onCall(parsed)
                }
            }
        }
        return turn
    }

    func appending(turn: CloudChatTurn, to history: [CloudJSON]) -> [CloudJSON] {
        history + [["role": "model", "parts": .array(turn.items)]]
    }

    func appending(results: [(call: CloudChatCall, result: CloudJSON)], to history: [CloudJSON]) -> [CloudJSON] {
        var images: [String] = []
        var parts: [CloudJSON] = results.map { call, result in
            let (json, pictures) = toolImages(result)
            images += pictures
            var response: [String: CloudJSON] = ["name": .string(call.name), "response": json]
            if let id = call.id { response["id"] = .string(id) }
            return ["functionResponse": .object(response)]
        }
        // Страницы view_document — картинками в том же ходе
        parts += images.map { ["inline_data": ["mime_type": "image/jpeg", "data": .string($0)]] }
        return history + [["role": "user", "parts": .array(parts)]]
    }

    func withoutOldImages(_ history: [CloudJSON]) -> [CloudJSON] {
        history.map { content in
            guard content["role"]?.string == "user", let parts = content["parts"]?.array,
                  parts.contains(where: { $0["inline_data"] != nil }) else { return content }
            let replaced: [CloudJSON] = parts.map { part in
                part["inline_data"] == nil ? part : ["text": "[изображение вложения — уже показано выше]"]
            }
            return ["role": "user", "parts": .array(replaced)]
        }
    }

    func relaxing(_ options: CloudChatOptions, status: Int, body: Data) -> CloudChatOptions? {
        nil
    }
}

// MARK: OpenAI

/// OpenAI Responses API (developers.openai.com, 12.10.2026). store=false:
/// ответы у OpenAI не хранятся, поэтому история отправляется целиком —
/// элементы ответа дословно, вместе с зашифрованным рассуждением
/// (encrypted_content), иначе модель теряет ход мысли между вызовами
/// инструментов. Инструменты — строгие (strict), как советует документация
struct OpenAIChatDialect: CloudChatDialect {
    /// Уровень рассуждения на уровне запроса — один для всех разговоров: так
    /// префикс кэша общий. «low» — самый частый уровень вопроса у «Авто», и у
    /// Sol и Astra нет «none». Другой уровень вопроса — configuration_update
    /// перед ним, даже у первого вопроса (проверено на API 19.11.2026)
    static let baseLevel = "low"

    func appending(user text: String, attachments: [CloudChatAttachment], level: String, to history: [CloudJSON],
                   state: inout CloudChatDialectState) -> [CloudJSON] {
        var items = history
        if state.baseLevel == nil { state.baseLevel = Self.baseLevel }
        if (state.currentLevel ?? state.baseLevel) != level {
            items.append(["type": "configuration_update", "reasoning": ["effort": .string(level)]])
        }
        state.currentLevel = level
        var content: [CloudJSON] = [["type": "input_text", "text": .string(text)]]
        content += attachments.map { attachment in
            ["type": "input_image", "image_url": .string("data:image/jpeg;base64,\(attachment.jpeg.base64EncodedString())"), "detail": "high"]
        }
        items.append(["role": "user", "content": .array(content)])
        return items
    }

    func appending(note question: String, answer: String, to history: [CloudJSON]) -> [CloudJSON] {
        history + [
            ["role": "user", "content": .string(question)],
            ["role": "assistant", "content": .string(answer)],
        ]
    }

    func request(history: [CloudJSON], system: CloudChatSystem, configuration: CloudChatEngine.Configuration, level: String,
                 state: CloudChatDialectState, options: CloudChatOptions, genUI: Bool) -> URLRequest {
        var input = history
        var effort = state.baseLevel ?? Self.baseLevel
        if !options.configurationUpdates {
            // Без configuration_update уровень меняется полем запроса
            input = input.filter { $0["type"]?.string != "configuration_update" }
            effort = state.currentLevel ?? level
        }
        var body = Self.body(system: system, configuration: configuration, effort: effort, options: options, genUI: genUI)
        if options.cacheBreakpoint {
            body["input"] = .array([Self.developer(system)] + input)
        } else {
            body["input"] = .array(input)
            body["instructions"] = .string(system.text)
        }
        body["stream"] = true
        // Без случайной «обфускации» в каждом событии потока — меньше байт
        // через VPN (справочник POST /responses, stream_options)
        body["stream_options"] = ["include_obfuscation": false]
        return streamRequest("\(baseURL(configuration))/responses", apiKey: ("Authorization", "Bearer \(configuration.apiKey)"),
                             body: genUI ? CloudChatGenUI.body(.object(body)) : CloudJSON.object(body).data)
    }

    /// Прогрев кэша: тот же префикс — инструменты, схема ответа, инструкция и
    /// опись — без вопроса и без ответа модели (prompt_cache_options.prewarm).
    /// Первый вопрос после него не ждёт, пока сервер прочтёт ~20 тыс. токенов
    func prewarmRequest(system: CloudChatSystem, configuration: CloudChatEngine.Configuration, state: CloudChatDialectState,
                        options: CloudChatOptions, genUI: Bool) -> URLRequest? {
        guard options.cacheBreakpoint, options.configurationUpdates else { return nil }
        var body = Self.body(system: system, configuration: configuration, effort: state.baseLevel ?? Self.baseLevel, options: options, genUI: genUI)
        body["input"] = [Self.developer(system)]
        body["prompt_cache_options"] = ["mode": "implicit", "prewarm": true]
        return streamRequest("\(baseURL(configuration))/responses", apiKey: ("Authorization", "Bearer \(configuration.apiKey)"),
                             body: genUI ? CloudChatGenUI.body(.object(body)) : CloudJSON.object(body).data)
    }

    /// Всё, что входит в кэшируемый префикс, кроме сообщений: у вопроса и у
    /// прогрева одно и то же — иначе прогрев не пригодится
    private static func body(system: CloudChatSystem, configuration: CloudChatEngine.Configuration, effort: String,
                             options: CloudChatOptions, genUI: Bool) -> [String: CloudJSON] {
        var reasoning: [String: CloudJSON] = ["effort": .string(effort)]
        if options.summaries { reasoning["summary"] = "auto" }
        var body: [String: CloudJSON] = [
            "model": .string(configuration.model.provider == .openAI ? configuration.model.rawValue : CloudChatModel.luna.rawValue),
            "tools": genUI ? genUITools : tools,
            "reasoning": .object(reasoning),
            // Коротко — меньше токенов, быстрее ответ (API deployment checklist).
            // Интерфейсом — строгий JSON по схеме Generative UI
            "text": genUI ? ["verbosity": "low", "format": CloudChatGenUI.textFormat] : ["verbosity": "low"],
            "store": false,
            "max_output_tokens": 16_000,
        ]
        // Правила и опись — отметками кэша на 12 часов (developer), разговор —
        // неявной отметкой в конце последнего сообщения на 30 минут
        if options.cacheBreakpoint { body["prompt_cache_options"] = ["mode": "implicit"] }
        // Быстрый режим: до 2,5× быстрее за двойную цену. У Luna это $0.2 за
        // миллион токенов входа — копейки за ответ без ожидания
        if configuration.model == .luna, options.fastTier { body["service_tier"] = "fast" }
        return body
    }

    /// Инструменты в формате Responses API: строгие схемы — все поля
    /// обязательны, необязательные принимают null, лишних полей нет
    static let tools: CloudJSON = .array((CloudChatPrompt.tools.array ?? []).map { declaration in
        [
            "type": "function",
            "name": declaration["name"] ?? "",
            "description": declaration["description"] ?? "",
            "parameters": CloudSchema.strict(declaration["parameters"] ?? ["type": "object", "properties": [:]]),
            "strict": true,
        ]
    })

    /// Системная инструкция сообщением developer: правила и опись — блоками с
    /// явной отметкой кэша на 12 часов, дата — после них. Без отдельной отметки
    /// после неизменного начала кэш срабатывал только на запросе целиком
    /// (prompt caching, «A shared prefix is not always a cached prefix»)
    static func developer(_ system: CloudChatSystem) -> CloudJSON {
        let breakpoint: CloudJSON = ["mode": "explicit", "ttl": "12h"]
        var content: [CloudJSON] = [["type": "input_text", "text": .string(system.rules), "prompt_cache_breakpoint": breakpoint]]
        if !system.vault.isEmpty {
            content.append(["type": "input_text", "text": .string("\n\n" + system.vault), "prompt_cache_breakpoint": breakpoint])
        }
        content.append(["type": "input_text", "text": .string("\n\n" + system.today)])
        return ["role": "developer", "content": .array(content)]
    }

    /// Для ответа интерфейсом — без show_cards: карточки документов — блоки app_card
    static let genUITools: CloudJSON = .array((tools.array ?? []).filter { $0["name"]?.string != "show_cards" })

    /// События SSE Responses API: итоги рассуждения и текст — дельтами,
    /// готовые элементы — в response.output_item.done (у рассуждения там полный
    /// encrypted_content), весь ответ — в response.completed
    func read<Lines: AsyncSequence>(_ lines: Lines, onDelta: (CloudChatDelta) -> Void,
                                    onCall: (CloudChatCall) async -> Void) async throws -> CloudChatTurn where Lines.Element == String {
        var done: [Int: CloudJSON] = [:]
        var completed: [CloudJSON]?
        var tokens = CloudChatUsage(requests: 1)
        var calls: [CloudChatCall] = []
        var summaryPart: String?
        for try await line in lines {
            guard let json = event(line), let type = json["type"]?.string else { continue }
            switch type {
            case "response.reasoning_summary_text.delta":
                // Части итога рассуждения — абзацами
                let part = "\(json["item_id"]?.string ?? "")#\(json["summary_index"]?.int ?? 0)"
                let separator = summaryPart.map { $0 == part ? "" : "\n\n" } ?? ""
                summaryPart = part
                if let delta = json["delta"]?.string { onDelta(CloudChatDelta(text: separator + delta, thought: true)) }
            case "response.output_text.delta", "response.refusal.delta":
                if let delta = json["delta"]?.string { onDelta(CloudChatDelta(text: delta, thought: false)) }
            case "response.output_item.done":
                guard let item = json["item"], let index = json["output_index"]?.int else { continue }
                done[index] = item
                if let call = Self.call(item) {
                    calls.append(call)
                    await onCall(call)
                }
            case "response.completed", "response.incomplete":
                if let output = json["response"]?["output"]?.array, !output.isEmpty { completed = output }
                if let usage = json["response"]?["usage"] {
                    tokens = CloudChatUsage(usage: usage)
                }
            case "response.failed":
                throw Self.failure(json["response"]?["error"])
            case "error":
                throw Self.failure(json)
            default:
                continue
            }
        }
        let items = completed ?? done.keys.sorted().compactMap { done[$0] }
        if calls.isEmpty { calls = items.compactMap(Self.call) }
        return CloudChatTurn(items: items, calls: calls, usage: tokens)
    }

    private static func call(_ item: CloudJSON) -> CloudChatCall? {
        guard item["type"]?.string == "function_call", let name = item["name"]?.string else { return nil }
        let arguments = item["arguments"]?.string.flatMap { CloudJSON.parse(Data($0.utf8)) } ?? [:]
        return CloudChatCall(id: item["call_id"]?.string, name: name, arguments: arguments.withoutNulls)
    }

    /// Ошибка внутри потока: событие error или response.failed
    static func failure(_ error: CloudJSON?) -> CloudFailure {
        let code = error?["code"]?.string ?? ""
        let transient = ["server_error", "rate_limit_exceeded", "server_is_overloaded", "slow_down"].contains(code)
        return CloudResponseParser.failure(status: transient ? 503 : 400, data: (["error": error ?? [:]] as CloudJSON).data) ?? .badResponse
    }

    func appending(turn: CloudChatTurn, to history: [CloudJSON]) -> [CloudJSON] {
        history + turn.items
    }

    func appending(results: [(call: CloudChatCall, result: CloudJSON)], to history: [CloudJSON]) -> [CloudJSON] {
        history + results.map { call, result in
            let (json, images) = toolImages(result)
            let text = String(data: json.data, encoding: .utf8) ?? "{}"
            // Страницы view_document — картинками прямо в ответе инструмента:
            // output принимает input_text и input_image (справочник Responses API)
            let output: CloudJSON = images.isEmpty ? .string(text) : .array(
                [["type": "input_text", "text": .string(text)]]
                    + images.map { ["type": "input_image", "image_url": .string("data:image/jpeg;base64,\($0)"), "detail": "high"] }
            )
            return ["type": "function_call_output", "call_id": .string(call.id ?? ""), "output": output]
        }
    }

    func withoutOldImages(_ history: [CloudJSON]) -> [CloudJSON] {
        history.map { item in
            // Страницы, которые модель уже посмотрела, второй раз не уходят
            if item["type"]?.string == "function_call_output", let output = item["output"]?.array,
               output.contains(where: { $0["type"]?.string == "input_image" }), case .object(var object) = item {
                object["output"] = .array(output.filter { $0["type"]?.string != "input_image" }
                    + [["type": "input_text", "text": "[страницы документа — уже показаны выше]"]])
                return .object(object)
            }
            guard item["role"]?.string == "user", let content = item["content"]?.array,
                  content.contains(where: { $0["type"]?.string == "input_image" }) else { return item }
            let replaced: [CloudJSON] = content.map { part in
                part["type"]?.string == "input_image" ? ["type": "input_text", "text": "[изображение вложения — уже показано выше]"] : part
            }
            return ["role": "user", "content": .array(replaced)]
        }
    }

    func relaxing(_ options: CloudChatOptions, status: Int, body: Data) -> CloudChatOptions? {
        guard status == 400 else { return nil }
        let message = CloudResponseParser.errorMessage(body).lowercased()
        var relaxed = options
        if options.summaries, message.contains("summary") {
            relaxed.summaries = false
        } else if options.fastTier, message.contains("service_tier") {
            relaxed.fastTier = false
        } else if options.configurationUpdates, message.contains("configuration_update") {
            relaxed.configurationUpdates = false
        } else if options.cacheBreakpoint, message.contains("prompt_cache") || message.contains("breakpoint") || message.contains("prewarm") {
            relaxed.cacheBreakpoint = false
        } else if options.genUI, message.contains("response_format") || message.contains("json_schema") {
            relaxed.genUI = false
        } else {
            return nil
        }
        return relaxed
    }
}

// MARK: - Настройки по модели

extension CloudChatEngine.Configuration {
    /// Сервис — по модели: у каждой облачной модели он один
    init(baseURL: String, apiKey: String, model: CloudChatModel, reasoning: CloudChatReasoning) {
        self.init(provider: model.provider ?? .gemini, baseURL: baseURL, apiKey: apiKey, model: model, reasoning: reasoning)
    }
}
