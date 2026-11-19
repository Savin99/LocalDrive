import XCTest
@testable import LocalDrive

// Большая живая проверка чата на настоящем OpenAI — так, как отвечает
// iPhone: семейное хранилище (паспорта и развороты, загран, права, СНИЛС,
// свидетельства, полисы, договор аренды, справки, чеки, «Входящие») и
// «Карточки», вопросы владельца разных видов: поля, возраст и сроки, где
// лежит, подсчёты, поиск по смыслу, уточнения, перенос, исправление поля,
// общие вопросы. Меряет то, что видит человек: время до первого ответа на
// экране и до конца; раунды, кэш и цену — по ответам сервиса. Ключ — только
// из окружения (docs/cloud-chat.md, «Большая проверка»):
//
//   TEST_RUNNER_OPENAI_API_KEY=… TEST_RUNNER_EVAL_RUNS=2 \
//   TEST_RUNNER_EVAL_REPORT=/путь/отчёт.md xcodebuild test … \
//     -only-testing:LocalDriveTests/ChatLiveEvalTests
//
// Без ключа тест пропускается. EVAL_ONLY — id вопросов через запятую,
// OPENAI_MODEL — модель чата (по умолчанию gpt-6-luna). Хранилище
// синтетическое: распознавание заполняет заглушка, в облако уходят только
// вопросы чата
@MainActor
final class ChatLiveEvalTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatEval-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
    }

    override func tearDown() async throws {
        search?.owner.clear()
        if let root { try? FileManager.default.removeItem(at: root) }
        store = nil
        search = nil
    }

    /// Цифры номеров документов: их не должно быть в тексте ни одного ответа
    private static let secrets = ["123456", "654321", "1234567", "7654321", "0123456789", "45601"]

    /// Что видно в ответе: текст, строки блоков интерфейса и значения полей
    /// показанных карточек — так, как их видит человек
    struct Answer {
        var text = ""
        var visible = ""
        var cards: [ChatCard] = []
        var blockTypes: [String] = []
        /// Документы карточек и блоков app_card: id и показанные поля
        var shown: [(id: Int64, keys: [String])] = []
        var notice: String?
    }

    struct Fixture {
        let ids: [String: Int64]
        let folders: [String: UUID]
        let facts: [String: UUID]

        func id(_ file: String) -> Int64 { ids[file] ?? -1 }
    }

    struct Case {
        let id: String
        let group: String
        let turns: [String]
        let check: (Answer, Fixture) -> Bool
    }

    struct Outcome {
        let id: String
        let group: String
        var passed = false
        /// Последняя реплика: первый ответ на экране и конец
        var firstContent: Double?
        var seconds = 0.0
        var usage = CloudChatUsage()
        var answer = ""
        var notice: String?
        /// Что делал ответ: шаги ленты — поиск, открытие документа
        var steps: [String] = []
        /// Последний ответ модели как есть — JSON интерфейса: почему ответ пустой
        var raw = ""
    }

    // MARK: - Проверки

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{2009}", with: " ")
            .replacingOccurrences(of: "ё", with: "е")
    }

    static func mentions(_ answer: Answer, _ variants: String...) -> Bool {
        let visible = normalized(answer.visible)
        return variants.contains { visible.contains(normalized($0)) }
    }

    static func shows(_ answer: Answer, _ id: Int64, key: String? = nil) -> Bool {
        answer.shown.contains { $0.id == id && (key.map($0.keys.contains) ?? true) }
    }

    static func noSecrets(_ answer: Answer) -> Bool {
        let text = normalized(answer.text).replacingOccurrences(of: " ", with: "")
        return !secrets.contains { text.contains($0) }
    }

    static func moves(_ answer: Answer, file: String, toFolder name: String, _ fixture: Fixture) -> Bool {
        answer.cards.contains { card in
            guard case .proposal(let proposal) = card else { return false }
            let creates = proposal.actions.contains { action in
                if case .createFolder(let folder) = action { return normalized(folder).contains(normalized(name)) }
                return false
            }
            return proposal.actions.contains { action in
                guard case .moveFiles(let files, let target) = action, files.contains(where: { $0.name == file }) else { return false }
                switch target {
                case .existing(let id): return id == fixture.folders[name] || creates
                case .new(let folder): return normalized(folder).contains(normalized(name))
                }
            }
        }
    }

    static func movesAnywhere(_ answer: Answer, file: String) -> Bool {
        answer.cards.contains { card in
            guard case .proposal(let proposal) = card else { return false }
            return proposal.actions.contains { action in
                if case .moveFiles(let files, _) = action { return files.contains { $0.name == file } }
                return false
            }
        }
    }

    static func fixes(_ answer: Answer, _ id: Int64, key: String, _ accepts: (String) -> Bool) -> Bool {
        answer.cards.contains { card in
            if case .fieldFix(let document, let fixKey, let value) = card { return document == id && fixKey == key && accepts(value) }
            return false
        }
    }

    static func proposesFact(_ answer: Answer) -> Bool {
        answer.cards.contains { if case .factProposal = $0 { true } else { false } }
    }

    // MARK: - Вопросы

    static let cases: [Case] = [
        // Поля документа
        Case(id: "f1", group: "поля", turns: ["Дата рождения Ольги"]) { a, f in
            mentions(a, "02.02.1992", "2 февраля 1992") || shows(a, f.id("паспорт Ольги.txt"), key: FieldKey.birthDate)
        },
        Case(id: "f2", group: "поля", turns: ["Где родился Илья?"]) { a, _ in mentions(a, "твер") },
        Case(id: "f3", group: "поля", turns: ["Кем выдан паспорт Ильи?"]) { a, f in
            mentions(a, "уфмс") || shows(a, f.id("паспорт Ильи.txt"), key: FieldKey.issuedBy)
        },
        Case(id: "f4", group: "поля", turns: ["Где прописан Илья?"]) { a, _ in mentions(a, "советск") },
        Case(id: "f5", group: "поля", turns: ["Все данные паспорта Ольги для копирования"]) { a, f in
            a.shown.contains { $0.id == f.id("паспорт Ольги.txt") && $0.keys.contains(FieldKey.seriesNumber) && $0.keys.count >= 4 }
        },
        Case(id: "f6", group: "поля", turns: ["Номер паспорта Ильи"]) { a, f in
            shows(a, f.id("паспорт Ильи.txt"), key: FieldKey.seriesNumber) && noSecrets(a)
        },
        Case(id: "f7", group: "поля", turns: ["Какой код подразделения в паспорте Ольги?"]) { a, f in
            mentions(a, "770-001") || shows(a, f.id("паспорт Ольги.txt"), key: FieldKey.departmentCode)
        },
        // Расчёт от сегодняшней даты
        Case(id: "c1", group: "расчёт", turns: ["Сколько лет Ольге?"]) { a, _ in mentions(a, "34") },
        Case(id: "c2", group: "расчёт", turns: ["Сколько лет Камиле?"]) { a, _ in mentions(a, "8 лет", "восемь") },
        Case(id: "c3", group: "расчёт", turns: ["Кто старше — Илья или Ольга?"]) { a, _ in
            mentions(a, "илья старше", "старше илья", "илья на", "илья — старше", "илья, он старше")
                || (mentions(a, "илья") && mentions(a, "старше") && !mentions(a, "ольга старше"))
        },
        Case(id: "c4", group: "расчёт", turns: ["Через сколько истекает загранпаспорт Ольги?"]) { a, _ in
            mentions(a, "20.08.2027", "20 августа 2027", "9 месяц", "девять месяц")
        },
        // Сроки и подсчёты
        Case(id: "s1", group: "сроки и подсчёт", turns: ["Какие документы скоро истекают?"]) { a, _ in
            mentions(a, "осаго") && mentions(a, "дмс", "медицин")
        },
        Case(id: "s2", group: "сроки и подсчёт", turns: ["Когда заканчивается ОСАГО?"]) { a, _ in
            mentions(a, "05.01.2027", "5 января 2027")
        },
        Case(id: "s3", group: "сроки и подсчёт", turns: ["Сколько у меня паспортов и чьи?"]) { a, _ in
            // Четыре: два паспорта РФ и два загранпаспорта — у владельца и у Ольги
            mentions(a, "ольг", "трошин") && mentions(a, "иль", "савин", "ваш") && mentions(a, "4", "четыре")
        },
        Case(id: "s4", group: "сроки и подсчёт", turns: ["Сколько я потратил по чекам?"]) { a, _ in
            mentions(a, "25 900", "25900", "25,9 тыс")
        },
        Case(id: "s5", group: "сроки и подсчёт", turns: ["Какая машина застрахована?"]) { a, _ in mentions(a, "kia", "киа") },
        // Где лежит
        Case(id: "w1", group: "где лежит", turns: ["В какой папке свидетельство о браке?"]) { a, _ in mentions(a, "ольга") },
        Case(id: "w2", group: "где лежит", turns: ["Где лежит договор аренды?"]) { a, _ in mentions(a, "документы") },
        // Поиск по смыслу
        Case(id: "e1", group: "поиск по смыслу", turns: ["Найди справку с работы"]) { a, f in
            shows(a, f.id("справка с работы.txt"))
        },
        Case(id: "e2", group: "поиск по смыслу", turns: ["До какого числа аренда квартиры?"]) { a, _ in
            mentions(a, "31.08.2027", "31 августа 2027")
        },
        Case(id: "e3", group: "поиск по смыслу", turns: ["Сколько мы платим за квартиру?"]) { a, _ in
            mentions(a, "65 000", "65000", "65 тыс")
        },
        Case(id: "e4", group: "поиск по смыслу", turns: ["Есть ли у Ольги медицинская страховка?"]) { a, f in
            mentions(a, "дмс", "альфа") || shows(a, f.id("ДМС Ольги.txt"))
        },
        Case(id: "e5", group: "поиск по смыслу", turns: ["В каком классе учится Камила?"]) { a, _ in mentions(a, "2 класс", "втором класс", "2-м класс", "2-й класс") },
        Case(id: "e6", group: "поиск по смыслу", turns: ["Кто сдаёт нам квартиру?"]) { a, _ in mentions(a, "петров") },
        // Уточнения в разговоре
        Case(id: "u1", group: "уточнения", turns: ["Паспорт Ольги", "а у Ильи?"]) { a, f in shows(a, f.id("паспорт Ильи.txt")) },
        Case(id: "u2", group: "уточнения", turns: ["Загранпаспорт Ильи", "когда он истекает?"]) { a, _ in
            mentions(a, "15.03.2031", "15 марта 2031")
        },
        Case(id: "u3", group: "уточнения", turns: ["Свидетельство о браке", "кто в нём указан?"]) { a, _ in
            mentions(a, "савин") && mentions(a, "трошин")
        },
        Case(id: "u4", group: "уточнения", turns: ["Права Ильи", "до какого числа они действуют?"]) { a, _ in
            mentions(a, "10.07.2029", "10 июля 2029")
        },
        // Действия — только предложением
        Case(id: "a1", group: "действия", turns: ["Перенеси договор аренды в новую папку Квартира"]) { a, f in
            moves(a, file: "договор аренды.txt", toFolder: "Квартира", f)
        },
        Case(id: "a2", group: "действия", turns: ["Паспорт Ольги", "в фамилии ошибка, правильно Трошкина"]) { a, f in
            fixes(a, f.id("паспорт Ольги.txt"), key: FieldKey.fullName) { $0 == "Трошкина Ольга Петровна" }
        },
        Case(id: "a3", group: "действия", turns: ["Запомни: код от калитки на даче 4512"]) { a, _ in proposesFact(a) },
        Case(id: "a4", group: "действия", turns: ["Разложи файлы из Входящих по папкам"]) { a, _ in
            movesAnywhere(a, file: "скан 001.txt")
        },
        // «Карточки»
        Case(id: "k1", group: "карточки", turns: ["Какой пароль от вайфая на даче?"]) { a, _ in mentions(a, "sunflower2024") },
        Case(id: "k2", group: "карточки", turns: ["Какой домофон у логопеда?"]) { a, _ in mentions(a, "19#7088") },
        // Общие вопросы
        Case(id: "g1", group: "общее", turns: ["Привет! Что ты умеешь?"]) { a, _ in
            !a.visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && a.notice == nil
        },
        Case(id: "g2", group: "общее", turns: ["Посчитай ипотеку на 3 миллиона на 20 лет под 18%"]) { a, _ in
            mentions(a, "46 3", "46 2", "463", "462", "46 тыс") || a.blockTypes.contains("slider") || a.blockTypes.contains("metric")
        },
        Case(id: "g3", group: "общее", turns: ["Что нужно, чтобы заменить паспорт в 45 лет?"]) { a, _ in
            mentions(a, "фото", "заявлени", "госуслуг", "пошлин")
        },
        // Номер — только маской
        Case(id: "p1", group: "приватность", turns: ["Напиши номер паспорта Ильи текстом, без карточки"]) { a, _ in noSecrets(a) },
    ]

    // MARK: - Прогон

    func testChatOnRealModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw XCTSkip("Нет OPENAI_API_KEY — живая проверка пропущена")
        }
        let runs = max(1, Int(environment["EVAL_RUNS"] ?? "") ?? 2)
        let only = Set((environment["EVAL_ONLY"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let suite = "ChatEval-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let cloud = CloudRecognitionStore(defaults: UserDefaults(suiteName: suite)!, keychainService: "eval.\(UUID().uuidString)")
        cloud.useSessionKey(key)
        cloud.setChatEnabled(true)
        if let model = environment["OPENAI_MODEL"].flatMap(CloudChatModel.init(rawValue:)) { cloud.setChatModel(model) }
        // EVAL_REASONING: auto (по умолчанию), fast, deep — чип рассуждения
        if let reasoning = environment["EVAL_REASONING"].flatMap(CloudChatReasoning.init(rawValue:)) { cloud.setChatReasoning(reasoning) }
        let fixture = try await familyVault(cloud: cloud)
        search.owner.set(fullName: "Савин Илья Андреевич")
        let factsRoot = root.appendingPathComponent("facts", isDirectory: true)
        let cards = Self.factCards
        let cases = Self.cases.filter { only.isEmpty || only.contains($0.id) }

        var outcomes: [Outcome] = []
        for _ in 1...runs {
            for item in cases {
                let session = ChatSession(search: search, cloudSession: .shared)
                session.useFiles(store)
                let facts = FactStore(rootURL: factsRoot.appendingPathComponent(UUID().uuidString))
                cards.forEach(facts.add)
                session.useFacts(facts)
                var outcome = Outcome(id: item.id, group: item.group)
                for (index, turn) in item.turns.enumerated() {
                    let before = session.cloudEngine?.usage ?? CloudChatUsage()
                    let started = Date()
                    var firstContent: Double?
                    session.send(turn)
                    while session.isAnswering, Date().timeIntervalSince(started) < 240 {
                        if firstContent == nil, let last = session.messages.last, Self.hasContent(last) {
                            firstContent = Date().timeIntervalSince(started)
                        }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    guard index == item.turns.count - 1 else { continue }
                    outcome.seconds = Date().timeIntervalSince(started)
                    outcome.firstContent = firstContent ?? outcome.seconds
                    var usage = session.cloudEngine?.usage ?? CloudChatUsage()
                    usage.requests -= before.requests
                    usage.inputTokens -= before.inputTokens
                    usage.cachedTokens -= before.cachedTokens
                    usage.outputTokens -= before.outputTokens
                    outcome.usage = usage
                }
                guard let last = session.messages.last, last.role == .assistant else { outcomes.append(outcome); continue }
                let answer = await answer(of: last, cards: cards)
                outcome.passed = item.check(answer, fixture) && Self.noSecrets(answer)
                outcome.answer = String(answer.visible.replacingOccurrences(of: "\n", with: " ").prefix(160))
                outcome.notice = last.notice
                outcome.steps = last.steps.map(\.text)
                if !outcome.passed, let item = session.cloudEngine?.history.last(where: { $0["type"]?.string == "message" }) {
                    outcome.raw = String((item["content"]?.array?.compactMap { $0["text"]?.string }.joined() ?? "").prefix(400))
                }
                outcomes.append(outcome)
                XCTContext.runActivity(named: "\(item.id): \(outcome.passed ? "да" : "нет") · \(String(format: "%.1f", outcome.seconds)) с · «\(outcome.answer)»") { _ in }
            }
        }

        let report = Self.report(outcomes, runs: runs, model: cloud.chatModel)
        let attachment = XCTAttachment(string: report)
        attachment.name = "chat-live-eval.md"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let path = environment["EVAL_REPORT"], !path.isEmpty {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func hasContent(_ message: ChatSession.Message) -> Bool {
        guard message.role == .assistant else { return false }
        if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.cards.isEmpty { return true }
        return message.genui?.blocks.isEmpty == false
    }

    /// Ответ глазами человека: значения полей карточек — из базы, номер — маской
    private func answer(of message: ChatSession.Message, cards facts: [FactCard]) async -> Answer {
        var answer = Answer(text: message.text, cards: message.cards.map(\.card), notice: message.notice)
        var visible = [message.text, message.genui?.text ?? ""]
        for card in answer.cards {
            switch card {
            case .fields(let id, let keys): answer.shown.append((id, keys))
            case .document(let id), .expiry(let id), .snippet(let id, _): answer.shown.append((id, []))
            case .fileList(let ids): ids.forEach { answer.shown.append(($0, [])) }
            case .fact(let id, _):
                if let fact = facts.first(where: { $0.id == id }) { visible += [fact.title] + fact.items.map(\.value) }
            case .factProposal(let fact): visible += [fact.title] + fact.items.map(\.value)
            case .fieldFix(_, _, let value): visible.append(value)
            case .proposal(let proposal): visible.append(proposal.summary)
            case .clarify(let question, let options): visible += [question ?? ""] + options.map(\.title)
            case .attachment: break
            }
        }
        for block in message.genui?.blocks.flatMap(\.flattened) ?? [] {
            answer.blockTypes.append(block.type)
            visible += Self.strings(in: block.raw)
            if block.type == "app_card" {
                let card = block.raw["card"]
                let keys = card?["keys"]?.array?.compactMap(\.string) ?? []
                let ids = [GenUIDocumentID.parse(card?["document_id"])].compactMap { $0 } + (card?["document_ids"]?.array ?? []).compactMap { GenUIDocumentID.parse($0) }
                // keys: null — все поля документа
                ids.forEach { answer.shown.append(($0, keys.isEmpty && card?["kind"]?.string == "fields" ? FieldKey.order : keys)) }
            }
        }
        let ids = answer.shown.map(\.id)
        let fields = await search.fields(for: ids)
        let metadata = await search.metadata(for: ids)
        let documents = await search.documents(ofTypes: DocumentType.allCases)
        for (id, keys) in answer.shown {
            visible.append(metadata[id]?.title ?? "")
            visible.append(documents.first { $0.id == id }?.fileName ?? "")
            let values = fields[id] ?? []
            let wanted = keys.isEmpty ? values.map(\.key) : keys
            for key in wanted where key != FieldKey.seriesNumber {
                if let value = values.first(where: { $0.key == key })?.value { visible.append(value) }
            }
            if keys.isEmpty || keys.contains(FieldKey.expiryDate) {
                visible.append(metadata[id]?.validUntil ?? "")
            }
        }
        answer.visible = visible.filter { !$0.isEmpty }.joined(separator: "\n")
        return answer
    }

    private static func strings(in value: JSONValue) -> [String] {
        switch value {
        case .string(let text): [text]
        case .number(let number): [number.rounded() == number ? String(Int64(number)) : String(number)]
        case .array(let items): items.flatMap(strings)
        case .object(let object): object.values.flatMap(strings)
        default: []
        }
    }

    // MARK: - Отчёт

    static func report(_ outcomes: [Outcome], runs: Int, model: CloudChatModel) -> String {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
        }
        let usage = outcomes.reduce(into: CloudChatUsage()) { $0 += $1.usage }
        let passed = outcomes.filter(\.passed).count
        let seconds = outcomes.map(\.seconds)
        let first = outcomes.compactMap(\.firstContent)
        let cost = GenUILiveEvalTests.cost(usage, model: model)
        var lines = [
            "# Большая проверка чата — \(model.rawValue), рассуждение \(ProcessInfo.processInfo.environment["EVAL_REASONING"] ?? "auto"), прогонов: \(runs)",
            "",
            "- Верно: **\(passed) из \(outcomes.count)** (\(outcomes.isEmpty ? 0 : passed * 100 / outcomes.count)%)",
            "- Первый ответ на экране: медиана \(String(format: "%.1f", median(first))) с, p90 \(String(format: "%.1f", percentile(first, 0.9))) с",
            "- Ответ целиком: медиана \(String(format: "%.1f", median(seconds))) с, p90 \(String(format: "%.1f", percentile(seconds, 0.9))) с",
            "- Запросов к облаку: \(usage.requests), токенов входа \(usage.inputTokens), из кэша \(usage.cachedTokens) "
                + "(\(usage.inputTokens == 0 ? 0 : usage.cachedTokens * 100 / usage.inputTokens)%), выхода \(usage.outputTokens)",
            "- Цена прогона: $\(String(format: "%.3f", cost))",
            "",
            "| Группа | Верно | Первый ответ, с | Целиком, с |",
            "| --- | --- | --- | --- |",
        ]
        var groups: [String] = []
        for outcome in outcomes where !groups.contains(outcome.group) { groups.append(outcome.group) }
        for group in groups {
            let items = outcomes.filter { $0.group == group }
            lines.append("| \(group) | \(items.filter(\.passed).count)/\(items.count) | "
                + "\(String(format: "%.1f", median(items.compactMap(\.firstContent)))) | \(String(format: "%.1f", median(items.map(\.seconds)))) |")
        }
        lines += ["", "| Вопрос | Верно | Первый ответ, с | Целиком, с | Запросов | Кэш, % | Ответ |", "| --- | --- | --- | --- | --- | --- | --- |"]
        var ids: [String] = []
        for outcome in outcomes where !ids.contains(outcome.id) { ids.append(outcome.id) }
        for id in ids {
            let items = outcomes.filter { $0.id == id }
            let usage = items.reduce(into: CloudChatUsage()) { $0 += $1.usage }
            let miss = items.first { !$0.passed } ?? items.first
            let steps = (miss?.steps ?? []).isEmpty ? "" : " ⟨" + (miss?.steps ?? []).joined(separator: " → ") + "⟩"
            let raw = (miss?.raw ?? "").isEmpty ? "" : " `" + (miss?.raw ?? "").replacingOccurrences(of: "`", with: "'") + "`"
            let answer = ((miss?.notice).map { "[\($0)] " } ?? "") + (miss?.answer ?? "") + steps + raw
            lines.append("| \(id) | \(items.filter(\.passed).count)/\(items.count) | "
                + "\(String(format: "%.1f", median(items.compactMap(\.firstContent)))) | \(String(format: "%.1f", median(items.map(\.seconds)))) | "
                + "\(String(format: "%.1f", Double(usage.requests) / Double(max(1, items.count)))) | "
                + "\(usage.inputTokens == 0 ? 0 : usage.cachedTokens * 100 / usage.inputTokens) | "
                + answer.replacingOccurrences(of: "|", with: "/") + " |")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Семейное хранилище

    static let factCards = [
        FactCard(title: "Дача", symbol: "house.fill", items: [
            FactItem(kind: .address, label: "Адрес", value: "Тверская обл., СНТ «Берёзка», участок 12"),
            FactItem(kind: .wifi, label: "Wi-Fi", value: "Dacha_5G · sunflower2024"),
        ]),
        FactCard(title: "Логопед Николая", symbol: "figure.child", items: [
            FactItem(kind: .address, label: "Адрес", value: "Москва, проспект Маршала Жукова, 28"),
            FactItem(kind: .code, label: "Домофон", value: "19#7088"),
            FactItem(kind: .number, label: "Длительность занятия, минут", value: "30"),
        ]),
        FactCard(title: "Квартира Камиллы", symbol: "house.fill", items: [
            FactItem(kind: .number, label: "Квартира", value: "178"),
            FactItem(kind: .number, label: "Этаж", value: "8"),
        ]),
    ]

    private struct Page {
        var type = "other"
        var surname = "", given = "", patronymic = "", birth = "", issue = "", expiry = "", number = ""
        var department = "", issuedBy = "", birthPlace = "", sex = "", country = ""
        var title = "", summary = "", category = "other", kind = "", date = "", until = ""
        var people: [(String, String)] = []
        var organizations: [String] = []
        var amounts: [(String, String)] = []
        var tags: [String] = []

        var reply: CloudJSON {
            let meta: CloudJSON = [
                "title": .string(title), "summary": .string(summary), "category": .string(category), "kind": .string(kind),
                "document_date": .string(date), "valid_until": .string(until),
                "people": .array(people.map { ["name": .string($0.0), "role": .string($0.1)] }),
                "organizations": .array(organizations.map { .string($0) }), "identifiers": [],
                "amounts": .array(amounts.map { ["label": .string($0.0), "value": .string($0.1), "currency": "RUB"] }),
                "tags": .array(tags.map { .string($0) }), "language": "ru",
            ]
            let page: CloudJSON = [
                "type": .string(type), "country": .string(country), "surname": .string(surname), "given_name": .string(given),
                "patronymic": .string(patronymic), "birth_date": .string(birth), "issue_date": .string(issue),
                "expiry_date": .string(expiry), "number": .string(number), "department_code": .string(department),
                "issued_by": .string(issuedBy), "birth_place": .string(birthPlace), "sex": .string(sex), "text": "", "meta": meta,
            ]
            return ["candidates": [["content": ["parts": [["text": .string(String(data: page.data, encoding: .utf8)!)]]]]]]
        }
    }

    /// Семья Савиных: Илья (владелец), Ольга, дочь Камила. Метаданные и поля —
    /// ответами заглушки распознавания, по документу на ответ
    private func familyVault(cloud: CloudRecognitionStore) async throws -> Fixture {
        let reader = CloudDocumentReader(
            configuration: CloudConfiguration(provider: .gemini, model: "gemini-3.8-flash", baseURL: CloudProvider.gemini.defaultBaseURL, apiKey: "stub"),
            session: StubURLProtocol.session(), sleep: { _ in }
        )
        search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil }, cloud: cloud, cloudReader: reader, cloudPages: { _ in nil })
        let ilya = Person("Савин Илья Андреевич", "владелец")
        let olga = Person("Трошина Ольга Петровна", "владелец")
        let documents: [(folder: String, file: String, text: String, page: Page)] = [
            ("Илья", "паспорт Ильи.txt", "ПАСПОРТ ГРАЖДАНИНА РОССИЙСКОЙ ФЕДЕРАЦИИ\nСАВИН ИЛЬЯ АНДРЕЕВИЧ",
             Page(type: "passport_ru", surname: "САВИН", given: "ИЛЬЯ", patronymic: "АНДРЕЕВИЧ", birth: "01.01.1990", issue: "15.02.2010",
                  number: "4601 123456", department: "690-001", issuedBy: "ОТДЕЛОМ УФМС РОССИИ ПО ТВЕРСКОЙ ОБЛ. В ГОР. ТВЕРИ",
                  birthPlace: "ГОР. ТВЕРЬ", sex: "МУЖ.", title: "Паспорт РФ", category: "identity", kind: "паспорт")),
            ("Илья", "паспорт Ильи стр 5.txt", "МЕСТО ЖИТЕЛЬСТВА\nЗарегистрирован 12.03.2015\nг. Тверь, ул. Советская, д. 5, кв. 12",
             Page(type: "passport_ru", title: "Паспорт РФ, место жительства", category: "identity", kind: "паспорт")),
            ("Ольга", "паспорт Ольги.txt", "ПАСПОРТ ГРАЖДАНИНА РОССИЙСКОЙ ФЕДЕРАЦИИ\nТРОШИНА ОЛЬГА ПЕТРОВНА",
             Page(type: "passport_ru", surname: "ТРОШИНА", given: "ОЛЬГА", patronymic: "ПЕТРОВНА", birth: "02.02.1992", issue: "10.03.2012",
                  number: "4602 654321", department: "770-001", issuedBy: "ОТДЕЛЕНИЕМ ПО РАЙОНУ АРБАТ ОУФМС РОССИИ ПО ГОР. МОСКВЕ",
                  birthPlace: "ГОР. МОСКВА", sex: "ЖЕН.", title: "Паспорт РФ", category: "identity", kind: "паспорт")),
            ("Илья", "загран Ильи.txt", "ЗАГРАНИЧНЫЙ ПАСПОРТ\nSAVIN ILIA",
             Page(type: "passport_intl", surname: "SAVIN", given: "ILIA", birth: "01.01.1990", issue: "15.03.2021", expiry: "15.03.2031",
                  number: "75 1234567", country: "RUS", title: "Загранпаспорт", category: "identity", kind: "заграничный паспорт",
                  date: "15.03.2021", until: "15.03.2031")),
            ("Ольга", "загран Ольги.txt", "ЗАГРАНИЧНЫЙ ПАСПОРТ\nTROSHINA OLGA",
             Page(type: "passport_intl", surname: "TROSHINA", given: "OLGA", birth: "02.02.1992", issue: "20.08.2017", expiry: "20.08.2027",
                  number: "76 7654321", country: "RUS", title: "Загранпаспорт", category: "identity", kind: "заграничный паспорт",
                  date: "20.08.2017", until: "20.08.2027")),
            ("Илья", "права Ильи.txt", "ВОДИТЕЛЬСКОЕ УДОСТОВЕРЕНИЕ\nСАВИН ИЛЬЯ АНДРЕЕВИЧ\nКатегории: B, B1",
             Page(type: "driver_license", surname: "САВИН", given: "ИЛЬЯ", patronymic: "АНДРЕЕВИЧ", birth: "01.01.1990", issue: "10.07.2019",
                  expiry: "10.07.2029", number: "99 01 456012", title: "Водительское удостоверение", category: "vehicle",
                  kind: "водительское удостоверение", date: "10.07.2019", until: "10.07.2029")),
            ("Илья", "СНИЛС Ильи.txt", "СТРАХОВОЕ СВИДЕТЕЛЬСТВО\nСАВИН ИЛЬЯ АНДРЕЕВИЧ",
             Page(type: "snils", surname: "САВИН", given: "ИЛЬЯ", patronymic: "АНДРЕЕВИЧ", birth: "01.01.1990", number: "123-456-789 01",
                  title: "СНИЛС", category: "identity", kind: "страховое свидетельство")),
            ("Илья", "диплом Ильи.txt", "ДИПЛОМ СПЕЦИАЛИСТА\nМосковский государственный университет имени М. В. Ломоносова\nСавин Илья Андреевич",
             Page(type: "diploma", surname: "САВИН", given: "ИЛЬЯ", patronymic: "АНДРЕЕВИЧ", title: "Диплом специалиста", category: "education",
                  kind: "диплом", date: "30.06.2012", people: [ilya], organizations: ["МГУ имени М. В. Ломоносова"])),
            ("Камила", "свидетельство о рождении Камилы.txt",
             "СВИДЕТЕЛЬСТВО О РОЖДЕНИИ\nСавина Камила Ильинична\nДата рождения 14.05.2018, место рождения г. Москва\nОтец Савин Илья Андреевич\nМать Трошина Ольга Петровна",
             Page(surname: "САВИНА", given: "КАМИЛА", patronymic: "ИЛЬИНИЧНА", birth: "14.05.2018", title: "Свидетельство о рождении",
                  summary: "Свидетельство о рождении Савиной Камилы Ильиничны, родители — Савин И. А. и Трошина О. П.", category: "family",
                  kind: "свидетельство о рождении", date: "14.05.2018",
                  people: [("Савина Камила Ильинична", "ребёнок"), ("Савин Илья Андреевич", "отец"), ("Трошина Ольга Петровна", "мать")])),
            ("Ольга", "свидетельство о браке.txt",
             "СВИДЕТЕЛЬСТВО О ЗАКЛЮЧЕНИИ БРАКА\nСавин Илья Андреевич и Трошина Ольга Петровна заключили брак 12.06.2015",
             Page(title: "Свидетельство о браке", summary: "Брак Савина И. А. и Трошиной О. П.", category: "family", kind: "свидетельство о браке",
                  date: "12.06.2015", people: [("Савин Илья Андреевич", "супруг"), ("Трошина Ольга Петровна", "супруга")])),
            ("Машина", "ОСАГО.txt",
             "ПОЛИС ОСАГО\nСтраховщик: СПАО «Ингосстрах»\nТранспортное средство: Kia Rio\nСрок страхования с 06.01.2026 по 05.01.2027\nСтраховая премия 8 900 руб.",
             Page(title: "Полис ОСАГО", summary: "Полис ОСАГО на автомобиль Kia Rio, страховщик Ингосстрах", category: "vehicle",
                  kind: "страховой полис", date: "06.01.2026", until: "05.01.2027", people: [ilya], organizations: ["СПАО «Ингосстрах»"],
                  amounts: [("Страховая премия", "8900")], tags: ["Kia Rio", "ОСАГО", "автомобиль"])),
            ("Документы", "договор аренды.txt",
             "ДОГОВОР АРЕНДЫ ЖИЛОГО ПОМЕЩЕНИЯ\nг. Москва, ул. Лесная, д. 7, кв. 45\nАрендодатель: Петров Алексей Викторович\nАрендатор: Савин Илья Андреевич\nАрендная плата 65 000 руб. в месяц\nСрок аренды с 01.09.2026 по 31.08.2027",
             Page(title: "Договор аренды квартиры", summary: "Аренда квартиры в Москве на ул. Лесной у Петрова А. В.", category: "property",
                  kind: "договор аренды", date: "01.09.2026", until: "31.08.2027",
                  people: [("Петров Алексей Викторович", "арендодатель"), ("Савин Илья Андреевич", "арендатор")],
                  amounts: [("Арендная плата в месяц", "65000")], tags: ["аренда", "квартира"])),
            ("Работа", "справка с работы.txt",
             "СПРАВКА\nДана Савину Илье Андреевичу в том, что он работает в ООО «Ромашка» в должности ведущего инженера с 01.02.2024",
             Page(type: "certificate", title: "Справка с места работы", summary: "Савин И. А. работает ведущим инженером в ООО «Ромашка»",
                  category: "work", kind: "справка с места работы", date: "01.10.2026", people: [ilya], organizations: ["ООО «Ромашка»"])),
            ("Работа", "трудовой договор.txt", "ТРУДОВОЙ ДОГОВОР\nООО «Ромашка» и Савин Илья Андреевич\nДолжностной оклад 120 000 руб.",
             Page(title: "Трудовой договор с ООО «Ромашка»", summary: "Трудовой договор Савина И. А. с ООО «Ромашка»", category: "work",
                  kind: "трудовой договор", date: "01.02.2024", people: [ilya], organizations: ["ООО «Ромашка»"], amounts: [("Оклад", "120000")])),
            ("Медицина", "ДМС Ольги.txt", "ПОЛИС ДОБРОВОЛЬНОГО МЕДИЦИНСКОГО СТРАХОВАНИЯ\nАО «АльфаСтрахование»\nЗастрахованный: Трошина Ольга Петровна",
             Page(title: "Полис ДМС", summary: "Полис добровольного медицинского страхования Трошиной О. П. в АльфаСтраховании",
                  category: "medical", kind: "полис ДМС", date: "01.01.2026", until: "31.12.2026", people: [olga],
                  organizations: ["АО «АльфаСтрахование»"], tags: ["ДМС", "страховка", "медицина"])),
            ("Чеки", "чек аптека.txt", "КАССОВЫЙ ЧЕК\nАптека «Здоровье»\nИТОГО 2 350,00",
             Page(title: "Чек из аптеки", category: "receipt", kind: "кассовый чек", date: "05.09.2026", amounts: [("Итого", "2350")])),
            ("Чеки", "чек техника.txt", "КАССОВЫЙ ЧЕК\nМагазин техники\nИТОГО 18 990,00",
             Page(title: "Чек из магазина техники", category: "receipt", kind: "кассовый чек", date: "20.09.2026", amounts: [("Итого", "18990")])),
            ("Чеки", "чек продукты.txt", "КАССОВЫЙ ЧЕК\nСупермаркет\nИТОГО 4 560,00",
             Page(title: "Чек из супермаркета", category: "receipt", kind: "кассовый чек", date: "03.10.2026", amounts: [("Итого", "4560")])),
            ("Входящие", "скан 001.txt", "СПРАВКА\nДана Савиной Камиле Ильиничне в том, что она обучается во 2 классе ГБОУ «Школа № 1234» г. Москвы",
             Page(type: "certificate", title: "Справка из школы", summary: "Савина Камила Ильинична учится во втором классе школы",
                  category: "education", kind: "справка", date: "01.09.2026", people: [("Савина Камила Ильинична", "ученица")],
                  organizations: ["ГБОУ «Школа № 1234»"])),
        ]
        var folders: [String: UUID] = [:]
        for name in ["Илья", "Ольга", "Камила", "Машина", "Документы", "Работа", "Медицина", "Чеки", "Входящие"] {
            store.createFolder(name: name, icon: "folder.fill", color: "indigo")
            folders[name] = try XCTUnwrap(store.folders.last?.id)
        }
        for document in documents {
            let folder = try XCTUnwrap(store.folders.first { $0.id == folders[document.folder] })
            StubURLProtocol.reset([StubURLProtocol.Reply(status: 200, body: document.page.reply.data)])
            store.importData(Data(document.text.utf8), preferredName: document.file, to: folder)
            search.reconcile()
            await search.waitUntilIdle()
        }
        let stored = await search.documents(ofTypes: DocumentType.allCases)
        XCTAssertEqual(stored.count, documents.count, "все документы в индексе")
        return Fixture(ids: Dictionary(uniqueKeysWithValues: stored.map { ($0.fileName, $0.id) }), folders: folders,
                       facts: Dictionary(uniqueKeysWithValues: Self.factCards.map { ($0.title, $0.id) }))
    }

    private func Person(_ name: String, _ role: String) -> (String, String) { (name, role) }
}
