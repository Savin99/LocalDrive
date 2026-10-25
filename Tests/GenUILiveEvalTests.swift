import XCTest
@testable import LocalDrive

// Живая проверка ответа интерфейсом на настоящем OpenAI: семь сценариев ТЗ
// (docs/genui.md, «Проверка»), каждый — несколько раз: модель сама выбирает
// формат и строит интерфейс. Ключ — только из окружения: OPENAI_API_KEY;
// xcodebuild передаёт в тест переменные с приставкой TEST_RUNNER_:
//
//   TEST_RUNNER_OPENAI_API_KEY=… xcodebuild test … -only-testing:LocalDriveTests/GenUILiveEvalTests
//
// Без ключа тест пропускается. Настройки:
// - OPENAI_MODEL — модель, по умолчанию gpt-6-luna;
// - GENUI_EVAL_RUNS — прогонов на сценарий, по умолчанию 3;
// - GENUI_EVAL_ONLY — id сценариев через запятую;
// - GENUI_EVAL_EFFORT — уровень рассуждения вместо выбора чата («legacy» —
//   как до 13.10.2026: none для всего, кроме «посчитай»).
// Хранилище синтетическое; метаданные документов заполняет заглушка
// распознавания — в облако уходят только вопросы чата. Отчёт — вложением
// теста: доля успешных прогонов по строгим ожиданиям, причины промахов,
// время, токены и примерная цена; ни ключа, ни ответов целиком
@MainActor
final class GenUILiveEvalTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!

    /// Номер синтетического паспорта: его не должно быть ни в одном ответе
    private let secretDigits = ["4601 123456", "4601123456", "751234567", "75 1234567"]

    /// Сценарии ТЗ. Вопросы — из галереи: каждый честно допускает ожидаемый
    /// формат (docs/genui.md, «Живая проверка»)
    struct Scenario {
        let id: String
        let question: String
        let expectation: String
    }

    static let scenarios = [
        Scenario(id: "text", question: "Когда истекает загранпаспорт?", expectation: "mode text, без блоков"),
        Scenario(id: "compare", question: "Сколько у меня документов по категориям?", expectation: "chart и table, оба с source"),
        Scenario(id: "calculator", question: "Посчитай ипотеку на 3 миллиона", expectation: "≥ 2 поля ввода, результат из состояния, ряд generate"),
        Scenario(id: "form", question: "Какие документы взять в поездку?", expectation: "form с полями ввода"),
        Scenario(id: "mixed", question: "Что с моими документами?", expectation: "текст и ≥ 2 разных виджета"),
        Scenario(id: "broken", question: "Покажи график", expectation: "ответ разобран"),
        Scenario(id: "forbidden", question: "Открой сайт", expectation: "ответ разобран, текст объясняет"),
    ]

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GenUIEval-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        store = nil
    }

    struct Outcome {
        let scenario: String
        var level = "—"
        var mode = "—"
        var types: [String] = []
        var seconds = 0.0
        var firstToken: Double?
        var parsed = false
        var passed = false
        var miss: String?
        var leaks = false
        var error: String?
        var usage = CloudChatUsage()
    }

    func testScenariosOnRealModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw XCTSkip("Нет OPENAI_API_KEY — живая проверка пропущена")
        }
        let model = CloudChatModel(rawValue: environment["OPENAI_MODEL"] ?? "") ?? .luna
        let base = environment["OPENAI_BASE_URL"] ?? CloudProvider.openAI.defaultBaseURL
        let runs = max(1, Int(environment["GENUI_EVAL_RUNS"] ?? "") ?? 3)
        let only = Set((environment["GENUI_EVAL_ONLY"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let effort = environment["GENUI_EVAL_EFFORT"]
        let scenarios = Self.scenarios.filter { only.isEmpty || only.contains($0.id) }
        let search = try await syntheticVault()
        let index = await search.chatDocumentIndex()

        var outcomes: [Outcome] = []
        for run in 1...runs {
            for scenario in scenarios {
                let engine = CloudChatEngine(
                    configuration: .init(provider: .openAI, baseURL: base, apiKey: key, model: model, reasoning: .auto),
                    search: search, session: .shared
                )
                engine.genUI = true
                engine.documentIndex = index
                engine.fastTier = environment["GENUI_EVAL_STANDARD"] != "1"
                engine.reasoningOverride = switch effort {
                case nil, "": nil
                case "legacy": CloudChatReasoning.auto.level(for: model, message: scenario.question)
                default: effort
                }
                var outcome = Outcome(scenario: scenario.id)
                outcome.level = engine.reasoningOverride
                    ?? CloudChatReasoning.auto.level(for: model, message: scenario.question, interface: true)
                let stream = EvalStream(engine: engine)
                let started = Date()
                do {
                    _ = try await engine.respond(to: scenario.question) { event in
                        switch event {
                        case .answerDelta(let delta):
                            if stream.firstToken == nil { stream.firstToken = Date().timeIntervalSince(started) }
                            stream.feedDelta(delta)
                        case .tool:
                            stream.newRound = true
                        default:
                            break
                        }
                    }
                    stream.feed.finish()
                    outcome = Self.evaluate(scenario, stream.feed.model, outcome, secrets: secretDigits)
                } catch {
                    outcome.error = "\(error)"
                }
                outcome.seconds = Date().timeIntervalSince(started)
                outcome.firstToken = stream.firstToken
                // GENUI_EVAL_DUMP — ответы целиком вложением: хранилище синтетическое
                if environment["GENUI_EVAL_DUMP"] == "1" {
                    let dump = XCTAttachment(string: "\(stream.feed.model.document.json)")
                    dump.name = "answer-\(scenario.id)-\(run).txt"
                    dump.lifetime = .keepAlways
                    add(dump)
                }
                outcome.usage = engine.usage
                outcomes.append(outcome)
                XCTContext.runActivity(named: "прогон \(run) · \(scenario.id): \(outcome.passed ? "да" : "нет — \(outcome.miss ?? outcome.error ?? "")")") { _ in }
            }
        }

        let report = Self.report(outcomes, scenarios: scenarios, model: model, runs: runs, effort: effort)
        let attachment = XCTAttachment(string: report)
        attachment.name = "genui-live-eval.md"
        attachment.lifetime = .keepAlways
        add(attachment)

        for outcome in outcomes {
            XCTAssertNil(outcome.error, "\(outcome.scenario): \(outcome.error ?? "")")
            XCTAssertTrue(outcome.parsed || outcome.error != nil, "\(outcome.scenario): ответ не прошёл разбор")
            XCTAssertFalse(outcome.leaks, "\(outcome.scenario): в ответе номер документа")
        }
    }

    // MARK: - Строгие ожидания

    private static let inputTypes: Set<String> = ["slider", "text_field", "picker", "toggle", "checkbox", "date_picker"]
    /// Не виджеты: текст и оформление
    private static let plainTypes: Set<String> = ["text", "heading", "divider", "stack", "grid", "section", "disclosure", "tabs"]

    private static func isSet(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        return !value.isNull
    }

    /// Значение блока считается из состояния: выражение или подстановка {{ }},
    /// и все её переменные объявлены — иначе на экране «—»
    private static func dependsOnState(_ block: GenUIBlock, declared: Set<String>) -> Bool {
        var sources: [String] = []
        if let expr = block.raw["value"]?["expr"]?.string { sources.append(expr) }
        for key in ["text", "caption", "label"] {
            guard let text = block.raw[key]?.string, text.contains("{{") else { continue }
            sources += text.components(separatedBy: "{{").dropFirst().compactMap { $0.components(separatedBy: "}}").first }
        }
        guard !sources.isEmpty else { return false }
        return sources.allSatisfy { source in
            guard let expression = try? GenUIExpression(parsing: source) else { return false }
            return !expression.variables.isEmpty && expression.variables.isSubset(of: declared)
        }
    }

    static func evaluate(_ scenario: Scenario, _ model: GenUIMessageModel, _ base: Outcome, secrets: [String]) -> Outcome {
        var outcome = base
        let all = model.blocks.flatMap(\.flattened)
        let types = all.map(\.type)
        outcome.mode = model.mode.rawValue
        outcome.types = types
        outcome.parsed = model.phase == .finished && !model.isEmpty
        let rendered = model.text + " " + model.blocks.map { "\($0.raw)" }.joined()
        outcome.leaks = secrets.contains { rendered.contains($0) }
        guard outcome.parsed else {
            outcome.miss = "не разобран"
            return outcome
        }
        let hasText = !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var miss: String?
        switch scenario.id {
        case "text":
            if !all.isEmpty { miss = "блоки: \(Set(types).sorted().joined(separator: ", "))" } else if !hasText { miss = "пустой текст" }
        case "compare":
            let chart = all.contains { $0.type == "chart" && isSet($0.raw["source"]) }
            let table = all.contains { $0.type == "table" && isSet($0.raw["source"]) }
            if !chart || !table {
                miss = [chart ? nil : (types.contains("chart") ? "chart без source" : "нет chart"),
                        table ? nil : (types.contains("table") ? "table без source" : "нет table")].compactMap { $0 }.joined(separator: ", ")
            }
        case "calculator":
            let inputs = all.filter { inputTypes.contains($0.type) }.count
            let declared = Set(model.document.state.map(\.name) + model.document.computed.map(\.name))
            let result = all.contains { ["metric", "text", "callout"].contains($0.type) && dependsOnState($0, declared: declared) }
            let series = all.contains { ["chart", "table"].contains($0.type) && isSet($0.raw["generate"]) }
            var problems: [String] = []
            if inputs < 2 { problems.append("полей ввода \(inputs)") }
            if !result { problems.append("нет результата из состояния") }
            if !series { problems.append("нет ряда generate") }
            if !problems.isEmpty { miss = problems.joined(separator: ", ") }
        case "form":
            let forms = all.filter { $0.type == "form" }
            let fields = forms.flatMap(\.flattened).filter { inputTypes.contains($0.type) }.count
            if forms.isEmpty { miss = "нет form: \(Set(types).sorted().joined(separator: ", "))" } else if fields == 0 { miss = "form без полей" }
        case "mixed":
            let widgets = Set(types).subtracting(plainTypes)
            if !hasText { miss = "нет текста" } else if widgets.count < 2 { miss = "виджетов: \(widgets.sorted().joined(separator: ", "))" }
        case "forbidden":
            if !hasText { miss = "нет объяснения текстом" }
        default:
            break
        }
        outcome.miss = miss
        outcome.passed = miss == nil
        return outcome
    }

    // MARK: - Отчёт

    static func report(_ outcomes: [Outcome], scenarios: [Scenario], model: CloudChatModel, runs: Int, effort: String?) -> String {
        var lines = [
            "# Живая проверка Generative UI — \(model.rawValue), прогонов: \(runs)" + (effort.map { ", рассуждение: \($0)" } ?? ""),
            "",
            "| Сценарий | Ожидание | Успешно | Уровень | Первый токен, с | Всего, с | Промахи |",
            "| --- | --- | --- | --- | --- | --- | --- |",
        ]
        for scenario in scenarios {
            let runs = outcomes.filter { $0.scenario == scenario.id }
            let passed = runs.filter(\.passed).count
            let first = runs.compactMap(\.firstToken)
            let misses = Set(runs.compactMap { $0.error ?? $0.miss })
            lines.append("| \(scenario.id) | \(scenario.expectation) | \(passed)/\(runs.count) | \(runs.first?.level ?? "—") | "
                + "\(first.isEmpty ? "—" : String(format: "%.1f", first.reduce(0, +) / Double(first.count))) | "
                + String(format: "%.1f", runs.map(\.seconds).reduce(0, +) / Double(max(1, runs.count)))
                + " | \(misses.isEmpty ? "—" : misses.sorted().joined(separator: "; ")) |")
        }
        let stable = scenarios.filter { scenario in
            let runs = outcomes.filter { $0.scenario == scenario.id }
            return runs.filter(\.passed).count * 3 >= runs.count * 2
        }.count
        var usage = CloudChatUsage()
        for outcome in outcomes { usage += outcome.usage }
        lines += [
            "",
            "Сценариев с успехом в ≥ 2/3 прогонов: **\(stable) из \(scenarios.count)**.",
            "Запросов: \(usage.requests), токенов входа: \(usage.inputTokens) (из кэша \(usage.cachedTokens)), выхода: \(usage.outputTokens), "
                + "примерно $\(String(format: "%.3f", cost(usage, model: model))).",
        ]
        return lines.joined(separator: "\n")
    }

    /// Цена по таблице OpenAI на 12.10.2026; у Luna — быстрый режим, ×2
    static func cost(_ usage: CloudChatUsage, model: CloudChatModel) -> Double {
        let (input, cached, output): (Double, Double, Double) = switch model {
        case .luna: (0.20, 0.02, 1.00)
        case .sol: (2.00, 0.10, 10.00)
        case .astra: (10.00, 1.00, 50.00)
        default: (0, 0, 0)
        }
        let fresh = Double(usage.inputTokens - usage.cachedTokens)
        return (fresh * input + Double(usage.cachedTokens) * cached + Double(usage.outputTokens) * output) / 1_000_000
    }

    // MARK: - Жалобы владельца 13.10.2026: чей паспорт, все данные, прописка

    struct Step {
        let name: String
        var passed = 0
        var runs = 0
        var seconds = 0.0
        var misses: Set<String> = []
    }

    /// Два человека и страница прописки. (A) — весь путь, как у владельца:
    /// правила, быстрый путь и облако. (B) — сама модель с исправленной
    /// инструкцией: не угадывать владельца, все поля в карточке, найти прописку
    func testOwnerScenariosOnRealModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw XCTSkip("Нет OPENAI_API_KEY — живая проверка пропущена")
        }
        let runs = max(1, Int(environment["GENUI_EVAL_RUNS"] ?? "") ?? 3)
        let suite = "GenUIEval-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let cloud = CloudRecognitionStore(defaults: UserDefaults(suiteName: suite)!, keychainService: "eval.\(UUID().uuidString)")
        cloud.useSessionKey(key)
        cloud.setChatEnabled(true)
        let (search, savin, registration) = try await ownersVault(cloud: cloud)
        let index = await search.chatDocumentIndex()

        var steps = ["A1 «мой паспорт» → чей?", "A2 «я Илья» → запомнить", "A3 запомнил → «мой паспорт»", "A4 «дай все данные для копирования»",
                     "A5 «регистрацию тоже»", "B1 модель: «мой паспорт» → чей?", "B2 модель: все данные", "B3 модель: прописка",
                     // Вопросы владельца 24.10.2026: «дата рождения Ольги» думала больше 30 с
                     "C1 «дата рождения Ольги» < 1 с", "C2 «сколько лет Ольге» < 1 с", "C3 «а у Ильи?» < 1 с",
                     "C4 «фото паспорта Ольги» < 1 с", "C5 «перенеси его в папку Ольга» < 1 с", "C6 чип «Номер паспорта» < 1 с",
                     // Сборка 16 на iPhone: «какой день рождения у этого человека» — без ответа
                     "C7 «какой день рождения у этого человека?» < 1 с", "C8 «какой день рождения у Ильи» < 1 с",
                     // Облако само, без правил: поправка фамилии — propose_field_fix (24.10.2026)
                     "B4 модель: фамилия с ошибкой → исправление"].map { Step(name: $0) }
        let passports = await search.documents(ofTypes: [.passportRU])
        let olga = try XCTUnwrap(passports.first { $0.fileName == "паспорт Ольги.txt" }?.id)
        func record(_ index: Int, _ passed: Bool, _ miss: String, _ started: Date) {
            steps[index].runs += 1
            steps[index].seconds += Date().timeIntervalSince(started)
            if passed { steps[index].passed += 1 } else { steps[index].misses.insert(miss) }
        }
        func finish(_ session: ChatSession) async throws {
            for _ in 0..<6000 where session.isAnswering { try await Task.sleep(for: .milliseconds(10)) }
        }
        func describe(_ message: ChatSession.Message?) -> String {
            let cards = message?.cards.map { "\($0.card)".prefix(40) }.joined(separator: ", ") ?? ""
            return "«\(message?.text.prefix(60) ?? "")» [\(cards)]"
        }
        func fields(_ message: ChatSession.Message?) -> (Int64, [String])? {
            for card in message?.cards ?? [] { if case .fields(let id, let keys) = card.card { return (id, keys) } }
            for block in message?.genui?.blocks.flatMap(\.flattened) ?? [] where block.type == "app_card" {
                let card = block.raw["card"]
                if card?["kind"]?.string == "fields", let id = GenUIDocumentID.parse(card?["document_id"]) {
                    return (id, card?["keys"]?.array?.compactMap(\.string) ?? [])
                }
            }
            return nil
        }
        func mentions(_ message: ChatSession.Message?, _ id: Int64) -> Bool {
            if message?.cards.contains(where: { $0.card.documentIDs.contains(id) }) == true { return true }
            let raw = (message?.genui?.blocks.map { "\($0.raw)" }.joined() ?? "") + (message?.text ?? "")
            return raw.contains("d\(id)") || raw.contains("Тверь") || raw.contains("Советская")
        }

        for _ in 1...runs {
            search.owner.clear()
            let session = ChatSession(search: search, cloudSession: .shared)
            session.useFiles(store)
            var started = Date()
            session.send("мой паспорт")
            try await finish(session)
            let a1 = session.messages.last
            let asks = a1?.cards.contains { if case .clarify(_, let options) = $0.card { options.count >= 2 } else { false } } == true
            record(0, fields(a1) == nil && asks, describe(a1), started)

            started = Date()
            session.send("я Илья")
            try await finish(session)
            let suggestion = session.messages.last?.ownerSuggestion
            record(1, suggestion?.name == "Савин И. А.", describe(session.messages.last), started)
            session.rememberOwner(suggestion ?? OwnerSuggestion(fullName: "Савин Илья Андреевич", name: "Савин И. А."))

            started = Date()
            session.send("мой паспорт")
            try await finish(session)
            record(2, fields(session.messages.last)?.0 == savin, describe(session.messages.last), started)

            started = Date()
            session.send("дай все данные для копирования")
            try await finish(session)
            let all = fields(session.messages.last)
            record(3, all?.0 == savin && all?.1.contains(FieldKey.seriesNumber) == true, describe(session.messages.last), started)

            started = Date()
            session.send("регистрацию тоже")
            try await finish(session)
            record(4, mentions(session.messages.last, registration), describe(session.messages.last), started)

            // (C) Вопросы о человеке и просьбы — правила, без облака и быстро
            func quick(_ step: Int, _ question: String, _ check: (ChatSession.Message?) -> Bool) async throws {
                let started = Date()
                session.send(question)
                try await finish(session)
                let fast = Date().timeIntervalSince(started) < 1
                record(step, check(session.messages.last) && fast, (fast ? "" : "медленно; ") + describe(session.messages.last), started)
            }
            let birth: (Int64) -> (ChatSession.Message?) -> Bool = { id in { fields($0).map { $0.0 == id && $0.1 == [FieldKey.birthDate] } ?? false } }
            try await quick(8, "дата рождения Ольги", birth(olga))
            try await quick(9, "сколько лет Ольге", birth(olga))
            try await quick(10, "а у Ильи?", birth(savin))
            // «Его» — паспорт Ильи из прошлого ответа: он лежит в другой папке
            try await quick(12, "перенеси его в папку Ольга") { message in
                message?.cards.contains { if case .proposal = $0.content { true } else { false } } == true
            }
            try await quick(11, "фото паспорта Ольги") { message in
                message?.cards.contains { $0.card == .document(documentID: olga) } == true
            }
            try await quick(13, "Номер паспорта") { fields($0).map { $0.0 == savin && $0.1 == [FieldKey.seriesNumber] } ?? false }
            // «Этот человек» — тот, чей паспорт только что показан
            session.send("фото паспорта Ольги")
            try await finish(session)
            try await quick(14, "какой день рождения у этого человека?", birth(olga))
            try await quick(15, "какой день рождения у Ильи", birth(savin))

            // (B) модель без правил: тот же разговор, исправленная инструкция
            search.owner.clear()
            for (step, question, prior) in [(5, "мой паспорт", nil), (6, "дай все данные для копирования", "мой паспорт"),
                                            (7, "регистрацию тоже", "мой паспорт"),
                                            (16, "в фамилии ошибка, правильно Трошкина", "паспорт Ольги")] as [(Int, String, String?)] {
                let engine = CloudChatEngine(
                    configuration: .init(provider: .openAI, baseURL: CloudProvider.openAI.defaultBaseURL, apiKey: key, model: .luna, reasoning: .auto),
                    search: search, session: .shared
                )
                engine.genUI = true
                engine.documentIndex = index
                if let prior {
                    engine.ownerName = "Савин И. А."
                    engine.record(question: prior, answer: "Показал карточки документов: d\(step == 16 ? olga : savin).")
                }
                let stream = EvalStream(engine: engine)
                started = Date()
                var reply: CloudChatReply?
                do {
                    reply = try await engine.respond(to: question) { event in
                        if case .answerDelta(let delta) = event { stream.feedDelta(delta) }
                        if case .tool = event { stream.newRound = true }
                    }
                } catch {
                    record(step, false, "\(error)", started)
                    continue
                }
                stream.feed.finish()
                var message = ChatSession.Message(role: .assistant, text: stream.feed.model.text)
                message.genui = stream.feed.model
                let blocks = stream.feed.model.blocks.flatMap(\.flattened)
                let text = stream.feed.model.text + " " + blocks.map { "\($0.raw)" }.joined()
                switch step {
                case 16:
                    let fixed = reply?.cards.contains { card in
                        if case .fieldFix(let id, let key, let value) = card {
                            return id == olga && key == FieldKey.fullName && value.hasPrefix("Трошкина Ольга")
                        }
                        return false
                    } == true
                    record(step, fixed, String(text.prefix(140)) + " \(reply?.cards ?? [])", started)
                case 5:
                    let singleCard = fields(message) != nil
                    // Спросила, чей: оба человека — по фамилии или по имени
                    let both = (text.contains("Савин") || text.contains("Иль")) && (text.contains("Трошин") || text.contains("Ольг"))
                    record(step, !singleCard && both, String(text.prefix(140)), started)
                case 6:
                    let all = fields(message)
                    record(step, all?.0 == savin && all?.1.contains(FieldKey.seriesNumber) == true, String(text.prefix(140)), started)
                default:
                    record(step, mentions(message, registration), String(text.prefix(140)), started)
                }
            }
        }

        var lines = ["# Чей паспорт, все данные, прописка — gpt-6-luna, прогонов: \(runs)", "",
                     "| Шаг | Успешно | Время, с | Промахи |", "| --- | --- | --- | --- |"]
        for step in steps {
            lines.append("| \(step.name) | \(step.passed)/\(step.runs) | \(String(format: "%.1f", step.seconds / Double(max(1, step.runs)))) | "
                + (step.misses.isEmpty ? "—" : step.misses.sorted().prefix(2).joined(separator: "; ").replacingOccurrences(of: "|", with: "/")) + " |")
        }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "owner-live-eval.md"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Разговоры владельца целиком — через ChatSession, как на iPhone: правила,
    /// облако и общий у них контекст, каждый разговор в новом чате. Владелец
    /// 25.10.2026: «паспорт Ольги» → «фамилия неправильно» → чат попросил
    /// прислать, как правильно → на «Трошкина» показал свидетельство о браке,
    /// где тоже Ольга Трошина. Ловушка — то же свидетельство в хранилище
    func testOwnerDialogsOnRealModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw XCTSkip("Нет OPENAI_API_KEY — живая проверка пропущена")
        }
        let runs = max(1, Int(environment["GENUI_EVAL_RUNS"] ?? "") ?? 3)
        let suite = "GenUIEval-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let cloud = CloudRecognitionStore(defaults: UserDefaults(suiteName: suite)!, keychainService: "eval.\(UUID().uuidString)")
        cloud.useSessionKey(key)
        cloud.setChatEnabled(true)
        let (search, _, _) = try await ownersVault(cloud: cloud)
        let olgaFolder = try XCTUnwrap(store.folders.first { $0.name == "Ольга" })
        let ilyaFolder = try XCTUnwrap(store.folders.first { $0.name == "Илья" })
        StubURLProtocol.reset(Self.page(meta: Self.meta(title: "Свидетельство о браке", category: "identity", kind: "свидетельство",
                                                        date: "12.06.2015", until: "")))
        store.importData(Data("СВИДЕТЕЛЬСТВО О ЗАКЛЮЧЕНИИ БРАКА\nСавин Илья Андреевич и Трошина Ольга Петровна заключили брак 12.06.2015".utf8),
                         preferredName: "свидетельство о браке.txt", to: olgaFolder)
        search.reconcile()
        await search.waitUntilIdle()
        let passports = await search.documents(ofTypes: [.passportRU])
        let olga = try XCTUnwrap(passports.first { $0.fileName == "паспорт Ольги.txt" }?.id)
        let factsRoot = root.appendingPathComponent("facts-\(UUID().uuidString)", isDirectory: true)

        typealias Check = ([ChatSession.Message]) -> Bool
        func fix(_ key: String, _ accepts: @escaping (String) -> Bool) -> Check {
            { replies in
                replies.contains { message in
                    message.cards.contains { card in
                        if case .fieldFix(let id, let fixKey, let value) = card.card { return id == olga && fixKey == key && accepts(value) }
                        return false
                    }
                }
            }
        }
        let troshkina = fix(FieldKey.fullName) { $0 == "Трошкина Ольга Петровна" }
        let dialogs: [(name: String, turns: [String], check: Check)] = [
            ("D1 паспорт → «фамилия неправильно» → «Трошкина»", ["паспорт Ольги", "фамилия неправильно", "Трошкина"], troshkina),
            ("D2 … «там фамилия неправильно написана» → «правильно Трошкина»",
             ["паспорт Ольги", "там фамилия неправильно написана", "правильно Трошкина"], troshkina),
            ("D3 … «фамилия не так написана» → «Трошкина»", ["паспорт Ольги", "фамилия не так написана", "Трошкина"], troshkina),
            ("D4 … «в фамилии опечатка, должна быть Трошкина»", ["паспорт Ольги", "в фамилии опечатка, должна быть Трошкина"], troshkina),
            ("D5 … «дата рождения неправильная, правильно 03.02.1992»",
             ["паспорт Ольги", "дата рождения неправильная, правильно 03.02.1992"], fix(FieldKey.birthDate) { $0 == "03.02.1992" }),
            ("D6 … «у неё фамилия Трошкина, а не Трошина»", ["открой паспорт Ольги", "у неё фамилия Трошкина, а не Трошина"], troshkina),
            ("D7 «фамилия у Ольги в паспорте неправильная» → «Трошкина»",
             ["фамилия у Ольги в паспорте неправильная", "Трошкина"], troshkina),
            ("D8 … «и отчество неправильное — Павловна» после фамилии",
             ["паспорт Ольги", "фамилия неправильно", "Трошкина", "и отчество неправильное — Павловна"],
             fix(FieldKey.fullName) { $0.hasPrefix("Трош") && $0.hasSuffix("Ольга Павловна") }),
            ("D9 … «перенеси его в папку Илья»", ["паспорт Ольги", "перенеси его в папку Илья"], { replies in
                replies.contains { message in
                    message.cards.contains { card in
                        guard case .proposal(let proposal) = card.card else { return false }
                        return proposal.actions.contains { action in
                            if case .moveFiles(let files, .existing(let folder)) = action {
                                return folder == ilyaFolder.id && files.contains { $0.name == "паспорт Ольги.txt" }
                            }
                            return false
                        }
                    }
                }
            }),
            ("D10 «свидетельство о браке» → «кто в нём указан?»", ["свидетельство о браке", "кто в нём указан?"], { replies in
                let text = replies.last?.text ?? ""
                return text.contains("Савин") && text.contains("Трошин")
            }),
            ("D11 «запомни: у Камилы домофон 45К1234, этаж 3»", ["запомни: у Камилы домофон 45К1234, этаж 3"], { replies in
                replies.contains { message in
                    message.cards.contains { card in
                        if case .factProposal(let fact) = card.card { return fact.items.count >= 2 }
                        return false
                    }
                }
            }),
            ("D12 «мой паспорт» → «Ольги»", ["мой паспорт", "Ольги"], { replies in
                replies.last?.cards.contains { $0.card.documentIDs.contains(olga) } == true
            }),
            ("D13 «где лежит паспорт Ольги?»", ["где лежит паспорт Ольги?"], { replies in
                let last = replies.last
                return last?.text.contains("Ольга") == true || last?.cards.contains { $0.card.documentIDs.contains(olga) } == true
            }),
        ]
        var steps = dialogs.map { Step(name: $0.name) }
        func finish(_ session: ChatSession) async throws {
            for _ in 0..<6000 where session.isAnswering { try await Task.sleep(for: .milliseconds(10)) }
        }
        func describe(_ message: ChatSession.Message) -> String {
            let cards = message.cards.map { "\($0.card)".prefix(60) }.joined(separator: ", ")
            // Ответ интерфейсом: какие блоки нарисовала модель вместо карточек
            let blocks = message.genui?.blocks.flatMap(\.flattened).map { "\($0.raw)".prefix(80) }.joined(separator: "; ") ?? ""
            // Пустой ответ — что пришло на самом деле
            let raw = message.text.trimmingCharacters(in: .whitespaces).isEmpty && cards.isEmpty && blocks.isEmpty
                ? " raw{genui: \(message.genui.map { String("\($0.text) / \($0.blocks.count) блоков / \($0.mode)".prefix(200)) } ?? "nil"); notice: \(message.notice ?? "-"); thoughts: \(message.thoughts.prefix(200))}"
                : ""
            return "«\(message.text.prefix(70))»" + (cards.isEmpty ? "" : " [\(cards)]") + (blocks.isEmpty ? "" : " genui{\(blocks)}") + raw
        }
        // TEST_RUNNER_DIALOGS=D3,D11 — только эти разговоры
        let only = environment["DIALOGS"].map { Set($0.split(separator: ",").map(String.init)) }

        for _ in 1...runs {
            for (index, dialog) in dialogs.enumerated() {
                if let only, !only.contains(String(dialog.name.prefix { $0 != " " })) { continue }
                search.owner.clear()
                let session = ChatSession(search: search, cloudSession: .shared)
                session.useFiles(store)
                session.useFacts(FactStore(rootURL: factsRoot.appendingPathComponent(UUID().uuidString)))
                let started = Date()
                var transcript: [String] = []
                var replies: [ChatSession.Message] = []
                for turn in dialog.turns {
                    session.send(turn)
                    try await finish(session)
                    guard let reply = session.messages.last, reply.role == .assistant else { continue }
                    replies.append(reply)
                    transcript.append("\(turn) → \(describe(reply))")
                }
                // Проверяется ответ на последнюю реплику: прежние — только путь к ней
                let passed = dialog.check(Array(replies.suffix(1)))
                steps[index].runs += 1
                steps[index].seconds += Date().timeIntervalSince(started)
                if passed { steps[index].passed += 1 } else { steps[index].misses.insert(transcript.joined(separator: " ⟶ ")) }
            }
        }

        var lines = ["# Разговоры владельца — gpt-6-luna через ChatSession, прогонов: \(runs)", "",
                     "| Разговор | Успешно | Время, с | Промах |", "| --- | --- | --- | --- |"]
        for step in steps where step.runs > 0 {
            lines.append("| \(step.name) | \(step.passed)/\(step.runs) | \(String(format: "%.1f", step.seconds / Double(max(1, step.runs)))) | "
                + (step.misses.sorted().first?.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") ?? "—") + " |")
        }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "owner-dialogs.md"
        attachment.lifetime = .keepAlways
        add(attachment)
        let weak = steps.filter { $0.runs > 0 && $0.passed * 3 < $0.runs * 2 }
        XCTAssertTrue(weak.isEmpty, "Меньше 2/3: " + weak.map(\.name).joined(separator: "; "))
    }

    /// Паспорта Савина и Трошиной и страница прописки Савина
    private func ownersVault(cloud: CloudRecognitionStore) async throws -> (SearchService, savin: Int64, registration: Int64) {
        let reader = CloudDocumentReader(
            configuration: CloudConfiguration(provider: .gemini, model: "gemini-3.8-flash", baseURL: CloudProvider.gemini.defaultBaseURL, apiKey: "stub"),
            session: StubURLProtocol.session(), sleep: { _ in }
        )
        let search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil }, cloud: cloud, cloudReader: reader, cloudPages: { _ in nil })
        let ilya = try folder("Илья"), olga = try folder("Ольга")
        let documents: [(String, String, VaultFolder, CloudJSON)] = [
            ("ПАСПОРТ САВИН ИЛЬЯ", "паспорт Ильи.txt", ilya,
             Self.page(type: "passport_ru", surname: "САВИН", given: "ИЛЬЯ", patronymic: "АНДРЕЕВИЧ", number: "4601 123456", birth: "01.01.1990",
                       meta: Self.meta(title: "Паспорт РФ", category: "identity", kind: "паспорт", date: "", until: ""))),
            ("МЕСТО ЖИТЕЛЬСТВА\nЗарегистрирован г. Тверь, ул. Советская, д. 5", "паспорт Ильи стр 5.txt", ilya,
             Self.page(type: "passport_ru", meta: Self.meta(title: "Паспорт РФ, место жительства", category: "identity", kind: "паспорт", date: "", until: ""))),
            ("ПАСПОРТ ТРОШИНА ОЛЬГА", "паспорт Ольги.txt", olga,
             Self.page(type: "passport_ru", surname: "ТРОШИНА", given: "ОЛЬГА", patronymic: "ПЕТРОВНА", number: "4602 654321", birth: "02.02.1992",
                       meta: Self.meta(title: "Паспорт РФ", category: "identity", kind: "паспорт", date: "", until: ""))),
        ]
        for (text, name, target, reply) in documents {
            StubURLProtocol.reset(reply)
            store.importData(Data(text.utf8), preferredName: name, to: target)
            search.reconcile()
            await search.waitUntilIdle()
        }
        let all = await search.documents(ofTypes: DocumentType.allCases)
        let fields = await search.fields(for: all.map(\.id))
        let savin = try XCTUnwrap(all.first { fields[$0.id]?.contains { $0.key == FieldKey.fullName && $0.value.hasPrefix("Савин") } == true }?.id)
        let registration = try XCTUnwrap(all.first { $0.fileName.contains("стр 5") }?.id)
        return (search, savin, registration)
    }

    // MARK: - Синтетическое хранилище

    private func folder(_ name: String) throws -> VaultFolder {
        store.createFolder(name: name, icon: "folder.fill", color: "indigo")
        return try XCTUnwrap(store.folders.last)
    }

    /// Паспорт, загранпаспорт, договор, два чека. Метаданные — ответами
    /// заглушки распознавания, по документу на ответ
    private func syntheticVault() async throws -> SearchService {
        let reader = CloudDocumentReader(
            configuration: CloudConfiguration(provider: .gemini, model: "gemini-3.8-flash", baseURL: CloudProvider.gemini.defaultBaseURL, apiKey: "stub"),
            session: StubURLProtocol.session(), sleep: { _ in }
        )
        let search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil }, cloudReader: reader, cloudPages: { _ in nil })
        let documents: [(String, String, String, CloudJSON)] = [
            ("Паспорта", "паспорт.txt", "ПАСПОРТ\nФамилия САВИН\nИмя ИЛЬЯ\nОтчество АНДРЕЕВИЧ\nPNRUSSAVIN<<IL98<ANDREEVI3<<<<<<<<<<<<<<<<<<\n4601234561RUS9001011M<<<<<<<1100620770120<34",
             Self.page(type: "passport_ru", surname: "САВИН", given: "ИЛЬЯ", patronymic: "АНДРЕЕВИЧ", number: "4601 123456", birth: "01.01.1990",
                       meta: Self.meta(title: "Паспорт РФ", category: "identity", kind: "паспорт", date: "", until: ""))),
            ("Паспорта", "загран.txt", "ЗАГРАНПАСПОРТ SAVIN ILIA",
             Self.page(type: "passport_intl", surname: "SAVIN", given: "ILIA", number: "75 1234567", expiry: "15.03.2031", country: "RUS",
                       meta: Self.meta(title: "Загранпаспорт", category: "identity", kind: "заграничный паспорт", date: "15.03.2021", until: "15.03.2031"))),
            ("Работа", "договор.txt", "ТРУДОВОЙ ДОГОВОР",
             Self.page(meta: Self.meta(title: "Трудовой договор с ООО «Ромашка»", category: "work", kind: "трудовой договор", date: "01.02.2024",
                                       until: "31.12.2026", amounts: [["label": "Оклад", "value": "120000", "currency": "RUB"]]))),
            ("Чеки", "чек1.txt", "КАССОВЫЙ ЧЕК",
             Self.page(meta: Self.meta(title: "Чек из аптеки", category: "receipt", kind: "кассовый чек", date: "05.09.2026", until: "",
                                       amounts: [["label": "Итого", "value": "2350", "currency": "RUB"]]))),
            ("Чеки", "чек2.txt", "КАССОВЫЙ ЧЕК",
             Self.page(meta: Self.meta(title: "Чек из магазина техники", category: "receipt", kind: "кассовый чек", date: "20.09.2026", until: "",
                                       amounts: [["label": "Итого", "value": "18990", "currency": "RUB"]]))),
        ]
        var folders: [String: VaultFolder] = [:]
        for (folderName, file, text, reply) in documents {
            let target = try folders[folderName] ?? folder(folderName)
            folders[folderName] = target
            StubURLProtocol.reset(reply)
            store.importData(Data(text.utf8), preferredName: file, to: target)
            search.reconcile()
            await search.waitUntilIdle()
        }
        return search
    }

    private static func page(type: String = "other", surname: String = "", given: String = "", patronymic: String = "",
                             number: String = "", birth: String = "", expiry: String = "", country: String = "",
                             meta: CloudJSON) -> CloudJSON {
        let page: CloudJSON = [
            "type": .string(type), "country": .string(country), "surname": .string(surname), "given_name": .string(given),
            "patronymic": .string(patronymic), "birth_date": .string(birth), "issue_date": "", "expiry_date": .string(expiry),
            "number": .string(number), "department_code": "", "issued_by": "", "birth_place": "", "sex": "", "text": "", "meta": meta,
        ]
        return ["candidates": [["content": ["parts": [["text": .string(String(data: page.data, encoding: .utf8)!)]]]]]]
    }

    private static func meta(title: String, category: String, kind: String, date: String, until: String,
                             amounts: [CloudJSON] = []) -> CloudJSON {
        ["title": .string(title), "summary": "", "category": .string(category), "kind": .string(kind), "document_date": .string(date),
         "valid_until": .string(until), "people": [], "organizations": [], "identifiers": [], "amounts": .array(amounts),
         "tags": [], "language": "ru"]
    }
}

private extension StubURLProtocol {
    static func reset(_ page: CloudJSON) {
        reset([Reply(status: 200, body: page.data)])
    }
}

/// Поток одного сценария: новый раунд после вызова инструмента — новый ответ
@MainActor
private final class EvalStream {
    let engine: CloudChatEngine
    var feed: GenUIStreamFeed
    var newRound = false
    var firstToken: Double?

    init(engine: CloudChatEngine) {
        self.engine = engine
        feed = GenUIStreamFeed(mask: { [weak engine] in engine?.mask($0) ?? $0 })
    }

    func feedDelta(_ delta: String) {
        if newRound {
            feed = GenUIStreamFeed(mask: { [weak engine] in engine?.mask($0) ?? $0 })
            newRound = false
        }
        feed.feed(delta)
    }
}
