import XCTest
@testable import LocalDrive

// Чат с локальной моделью: план от модели исполняется тем же кодом, что и
// правила; ошибка, задержка или странный план модели — ответ правилами.
// Сама модель в симуляторе не работает, поэтому здесь — подделка планировщика.
// Векторы MRZ — те же, что в ChatRouterTests, посчитаны независимо от приложения
@MainActor
final class ChatModelTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDriveModelTests-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
        search = SearchService(store: store, databaseURL: nil)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        search = nil
        store = nil
        root = nil
    }

    // MARK: - Данные

    private static let savinRussian = """
    ПАСПОРТ
    Паспорт выдан ГУ МВД РОССИИ ПО Г. МОСКВЕ
    Дата выдачи 20.06.2010 Код подразделения 770-120
    PNRUSSAVIN<<IL98<ANDREEVI3<<<<<<<<<<<<<<<<<<
    4601234561RUS9001011M<<<<<<<1100620770120<34
    """

    private static let savinTravel = """
    ЗАГРАНИЧНЫЙ ПАСПОРТ
    P<RUSSAVIN<<ILIA<<<<<<<<<<<<<<<<<<<<<<<<<<<<
    7212345673RUS9001011M3103153<<<<<<<<<<<<<<02
    """

    private func indexPassports() async throws {
        store.createFolder(name: "Паспорта", icon: "folder.fill", color: "indigo")
        let folder = try XCTUnwrap(store.folders.last)
        store.importData(Data(Self.savinRussian.utf8), preferredName: "паспорт.txt", to: folder)
        store.importData(Data(Self.savinTravel.utf8), preferredName: "загран.txt", to: folder)
        search.reconcile()
        await search.waitUntilIdle()
    }

    private func document(_ type: DocumentType) async throws -> StoredDocument {
        let documents = await search.documents(ofTypes: [type])
        return try XCTUnwrap(documents.first, "в индексе нет документа типа \(type)")
    }

    /// Дожидается ответа на последний вопрос
    private func reply(of session: ChatSession, timeout: TimeInterval = 10) async throws -> ChatSession.Message {
        let deadline = Date().addingTimeInterval(timeout)
        while session.isAnswering, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(session.messages.last)
    }

    // MARK: - План модели

    func testModelPlanAnswersFollowUp() async throws {
        try await indexPassports()
        let travel = try await document(.passportIntl)
        let planner = FakePlanner(plan: ChatPlan(action: .document, types: [.passportIntl], fields: [FieldKey.seriesNumber]))
        let session = ChatSession(search: search, planner: { planner })

        session.send("номер паспорта")
        _ = try await reply(of: session)
        session.send("а загран?")
        let answer = try await reply(of: session)

        XCTAssertEqual(answer.cards.map(\.card), [.fields(documentID: travel.id, keys: [FieldKey.seriesNumber])])
        let asked = await planner.received
        XCTAssertEqual(asked.last?.question, "а загран?")
        // Прошлый вопрос — в истории вместе с планом, по которому на него ответили
        XCTAssertEqual(asked.last?.history.map(\.question), ["номер паспорта"])
        XCTAssertEqual(asked.last?.history.first?.plan.fields, [FieldKey.seriesNumber])
    }

    func testModelNeverSeesFieldValues() async throws {
        try await indexPassports()
        let planner = FakePlanner(plan: ChatPlan(action: .document, types: [.passportRU]))
        let session = ChatSession(search: search, planner: { planner })

        session.send("мой паспорт")
        let first = try await reply(of: session)
        XCTAssertFalse(first.cards.isEmpty)
        session.send("а код подразделения?")
        _ = try await reply(of: session)

        let asked = await planner.received
        let prompts = asked.map { request in
            ChatModelPrompt.messages(question: request.question, history: request.history, inventory: request.inventory)
                .map(\.content).joined(separator: "\n")
        }.joined(separator: "\n")
        for value in ["4601", "123456", "770-120", "Савин", "ГУ МВД", "20.06.2010", "паспорт.txt"] {
            XCTAssertFalse(prompts.contains(value), "модель увидела значение «\(value)»")
        }
        XCTAssertEqual(asked.last?.inventory.types, [.passportRU, .passportIntl])
    }

    func testRulesAnswerIsRememberedAsPlan() async throws {
        try await indexPassports()
        let planner = FakePlanner(plan: ChatPlan(action: .answer, text: "Не знаю"))
        let session = ChatSession(search: search, planner: { planner })

        // Правила узнали паспорт и ответили сами — план в истории их
        session.send("мой паспорт")
        _ = try await reply(of: session)
        session.send("спасибо")
        _ = try await reply(of: session)

        let asked = await planner.received
        let remembered = try XCTUnwrap(asked.last?.history.first?.plan)
        XCTAssertEqual(remembered.action, .document)
        XCTAssertEqual(remembered.types, [.passportRU])
    }

    func testPlannerErrorFallsBackToRules() async throws {
        try await indexPassports()
        let russian = try await document(.passportRU)
        let session = ChatSession(search: search, planner: { FailingPlanner() })

        session.send("мой паспорт")
        let answer = try await reply(of: session)
        guard case .fields(let id, _) = answer.cards.first?.card else {
            return XCTFail("правила должны были ответить данными паспорта: \(answer.cards.map(\.card))")
        }
        XCTAssertEqual(id, russian.id)
    }

    func testSlowModelGivesWayToRules() async throws {
        try await indexPassports()
        let session = ChatSession(search: search, planner: { SlowPlanner() }, plannerTimeout: .milliseconds(200))

        let started = Date()
        session.send("мой паспорт")
        let answer = try await reply(of: session)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "медленная модель не должна задерживать ответ")
        XCTAssertFalse(answer.cards.isEmpty)
    }

    func testRulesWinWhenModelMissesPersonalDocument() async throws {
        try await indexPassports()
        let russian = try await document(.passportRU)
        let planner = FakePlanner(plan: ChatPlan(action: .answer, text: "Не знаю"))
        let session = ChatSession(search: search, planner: { planner })

        session.send("мой паспорт")
        let answer = try await reply(of: session)
        guard case .fields(let id, _) = answer.cards.first?.card else {
            return XCTFail("правила узнали паспорт — их ответ важнее: \(answer.cards.map(\.card))")
        }
        XCTAssertEqual(id, russian.id)
    }

    func testModelAnswerHasNoDigits() async throws {
        try await indexPassports()
        let planner = FakePlanner(plan: ChatPlan(action: .answer, text: "Паспорт меняют в 45 лет, серия 4601"))
        let session = ChatSession(search: search, planner: { planner })

        session.send("что нужно для замены паспорта")
        let answer = try await reply(of: session)
        XCTAssertFalse(answer.text.contains(where: \.isNumber), "в ответе модели не может быть цифр: «\(answer.text)»")
    }

    func testChipChoiceSkipsModel() async throws {
        try await indexPassports()
        let travel = try await document(.passportIntl)
        let planner = FakePlanner(plan: ChatPlan(action: .answer, text: "привет"))
        let session = ChatSession(search: search, planner: { planner })

        session.send("загранпаспорт", documentID: travel.id)
        let answer = try await reply(of: session)
        let asked = await planner.received
        XCTAssertTrue(asked.isEmpty, "чип уже выбрал документ — модель не нужна")
        XCTAssertTrue(answer.cards.contains { $0.card.documentIDs.contains(travel.id) })
    }

    // MARK: - Грамматика и разбор

    func testGrammarListsCatalogEnums() {
        let grammar = ChatModelPrompt.grammar
        for type in DocumentType.allCases {
            XCTAssertTrue(grammar.contains("\\\"\(type.rawValue)\\\""), type.rawValue)
        }
        for key in FieldKey.order {
            XCTAssertTrue(grammar.contains("\\\"\(key)\\\""), key)
        }
        for action in ChatPlan.Action.allCases {
            XCTAssertTrue(grammar.contains("\\\"\(action.rawValue)\\\""), action.rawValue)
        }
        // В ответе модели нет цифр: правило word не допускает 0–9
        let word = grammar.split(separator: "\n").first { $0.hasPrefix("word ::=") }
        XCTAssertNotNil(word)
        XCTAssertFalse(word?.contains("0-9") ?? true)
    }

    /// Примеры из промпта — в точности формат грамматики: разбор и обратная
    /// запись совпадают символ в символ
    func testPromptExamplesRoundTrip() throws {
        let examples = ChatModelPrompt.system.split(separator: "\n").filter { $0.contains(" → {") }
        XCTAssertGreaterThanOrEqual(examples.count, 8)
        for line in examples {
            let json = String(line[line.range(of: "{")!.lowerBound...])
            let plan = try ChatModelPrompt.plan(fromJSON: json)
            XCTAssertEqual(ChatModelPrompt.json(for: plan), json, String(line))
        }
    }

    func testParsingDropsUnknownFieldsAndDigits() throws {
        let json = #"{"action": "document", "types": ["passport_ru"], "fields": ["series_number", "pin_code"], "expiry": false, "owner": ["Савина"], "query": "", "reply": "номер 4601"}"#
        let plan = try ChatModelPrompt.plan(fromJSON: json)
        XCTAssertEqual(plan.types, [.passportRU])
        XCTAssertEqual(plan.fields, [FieldKey.seriesNumber])
        XCTAssertEqual(plan.owner, ["савина"])
        XCTAssertNil(plan.query, "пустая строка значит «нет»")
        XCTAssertEqual(plan.text, "номер")
    }

    func testLongAnswerIsTrimmed() throws {
        let long = String(repeating: "а", count: 1_000)
        let json = #"{"action": "answer", "types": [], "fields": [], "expiry": false, "owner": [], "query": "", "reply": "\#(long)"}"#
        let plan = try ChatModelPrompt.plan(fromJSON: json)
        XCTAssertEqual(plan.text?.count, ChatModelPrompt.maxAnswerLength)
    }

    func testBrokenOutputThrows() {
        XCTAssertThrowsError(try ChatModelPrompt.plan(fromJSON: #"{"action": "docu"#))
    }

    // MARK: - Промпт

    func testPromptCarriesInventoryAndHistory() throws {
        let inventory = ChatInventory(types: [.passportRU, .diploma])
        let history = [ChatTurn(question: "номер паспорта", plan: ChatPlan(action: .document, types: [.passportRU], fields: [FieldKey.seriesNumber]))]
        let messages = ChatModelPrompt.messages(question: "а загран?", history: history, inventory: inventory)

        XCTAssertEqual(messages.map(\.role), [.system, .user, .assistant, .user])
        XCTAssertTrue(messages[0].content.hasSuffix("\n\nДокументы пользователя: паспорт РФ, диплом."))
        XCTAssertTrue(messages[0].content.hasPrefix(ChatModelPrompt.system))
        XCTAssertEqual(messages[1].content, "номер паспорта")
        XCTAssertEqual(
            messages[2].content,
            #"{"action": "document", "types": ["passport_ru"], "fields": ["series_number"], "expiry": false, "owner": [], "query": "", "reply": ""}"#
        )
        XCTAssertEqual(messages[3].content, "а загран?")
    }

    func testHistoryIsLimited() {
        let turns = (0..<10).map { ChatTurn(question: "вопрос \($0)", plan: ChatPlan(action: .search, query: "вопрос")) }
        let messages = ChatModelPrompt.messages(question: "ещё", history: turns, inventory: ChatInventory())
        XCTAssertEqual(messages.count, 1 + ChatModelPrompt.maxTurns * 2 + 1)
    }

    func testInventoryListsTypesWithoutValues() {
        let folder = UUID()
        let documents = [
            StoredDocument(id: 1, folderID: folder, fileName: "a.jpg", type: .passportRU, pageCount: 1),
            StoredDocument(id: 2, folderID: folder, fileName: "b.jpg", type: .passportRU, pageCount: 1),
            StoredDocument(id: 3, folderID: folder, fileName: "c.pdf", type: .other, pageCount: 3),
        ]
        let inventory = ChatInventory(documents: documents)
        XCTAssertEqual(inventory.line, "Документы пользователя: паспорт РФ, другие файлы.")
        XCTAssertFalse(inventory.line.contains(".jpg"), "имена файлов в опись не идут")
        XCTAssertEqual(ChatInventory().line, "Документы пользователя: пока нет.")
    }

    func testRulesPlanForHistory() {
        XCTAssertEqual(ChatPlan(rulesFor: "мой паспорт"), ChatPlan(action: .document, types: [.passportRU]))
        XCTAssertEqual(ChatPlan(rulesFor: "когда истекает загран"), ChatPlan(action: .document, types: [.passportIntl], expiry: true))
        XCTAssertEqual(ChatPlan(rulesFor: "дипломные документы"), ChatPlan(action: .list, types: [.diploma]))
        XCTAssertEqual(ChatPlan(rulesFor: "справка о принятии статьи"), ChatPlan(action: .search, query: "справка о принятии статьи"))
    }

    func testRulesGuard() {
        XCTAssertFalse(ChatSession.accepts(ChatPlan(action: .search, query: "паспорт"), rules: ChatIntent("мой паспорт")))
        XCTAssertTrue(ChatSession.accepts(ChatPlan(action: .document, types: [.passportIntl]), rules: ChatIntent("мой паспорт")))
        XCTAssertTrue(ChatSession.accepts(ChatPlan(action: .answer, text: "Здравствуйте"), rules: ChatIntent("привет")))
    }

    func testModelIsPinned() {
        XCTAssertEqual(ChatModelChoice.allCases, [.standard], "лёгкая модель снята по итогам стенда")
        let model = ChatModelChoice.standard
        XCTAssertEqual(model.revision.count, 40, "ревизия — полный хэш коммита, иначе без сети модель не загрузится")
        XCTAssertTrue(model.revision.allSatisfy(\.isHexDigit))
        XCTAssertTrue(ChatModelChoice.filePatterns.contains("*.txt"), "без merges.txt токенизатор не соберётся")
    }
}

// MARK: - Подделки планировщика

private actor FakePlanner: ChatPlanning {
    struct Request {
        let question: String
        let history: [ChatTurn]
        let inventory: ChatInventory
    }

    private let answer: ChatPlan
    private(set) var received: [Request] = []

    init(plan: ChatPlan) {
        answer = plan
    }

    func plan(question: String, history: [ChatTurn], inventory: ChatInventory) async throws -> ChatPlan {
        received.append(Request(question: question, history: history, inventory: inventory))
        return answer
    }
}

private struct FailingPlanner: ChatPlanning {
    func plan(question: String, history: [ChatTurn], inventory: ChatInventory) async throws -> ChatPlan {
        throw ChatPlannerError.emptyOutput
    }
}

private struct SlowPlanner: ChatPlanning {
    func plan(question: String, history: [ChatTurn], inventory: ChatInventory) async throws -> ChatPlan {
        try await Task.sleep(for: .seconds(10))
        return ChatPlan(action: .answer, text: "поздно")
    }
}
