import XCTest
@testable import LocalDrive

// Агент на iPhone (LocalAgentEngine): модель сама зовёт инструменты в
// несколько шагов, исполняет их код облака (CloudChatTools). Сама модель в
// симуляторе не работает — здесь подделка с заготовленными ходами; настоящая
// Qwen3 проверяется стендом на Mac (docs/agent.md). Векторы MRZ — те же, что в
// ChatRouterTests, посчитаны независимо от приложения
@MainActor
final class ChatAgentTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDriveAgentTests-\(UUID().uuidString)", isDirectory: true)
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

    private func reply(of session: ChatSession, timeout: TimeInterval = 10) async throws -> ChatSession.Message {
        let deadline = Date().addingTimeInterval(timeout)
        while session.isAnswering, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(session.messages.last)
    }

    /// Вопрос, на который у правил точного ответа нет — он доходит до агента
    private let freeQuestion = "покажи что-нибудь полезное про поездки"

    // MARK: - Цикл агента

    func testAgentCallsToolsInStepsAndShowsCards() async throws {
        try await indexPassports()
        let travel = try await document(.passportIntl)
        let agent = ScriptedAgent([
            AgentTurn(calls: [.call("search_documents", #"{"query": "заграничный паспорт"}"#)]),
            AgentTurn(text: "Вот загранпаспорт.", calls: [.call("show_cards", #"{"cards": [{"type": "fields", "documentId": "d\#(travel.id)", "keys": ["series_number", "expiry_date"]}]}"#)]),
        ])
        let session = ChatSession(search: search, agentModel: { agent })

        session.send(freeQuestion)
        let answer = try await reply(of: session)

        XCTAssertEqual(answer.cards.map(\.card), [.fields(documentID: travel.id, keys: [FieldKey.seriesNumber, FieldKey.expiryDate])])
        XCTAssertEqual(answer.text, "Вот загранпаспорт.")
        XCTAssertTrue(answer.steps.contains { $0.kind == .search && $0.text.contains("заграничный паспорт") }, "в ленте нет шага поиска: \(answer.steps.map(\.text))")
        // Результат поиска ушёл модели, номер в нём — маской
        let results = await agent.results
        XCTAssertEqual(results.count, 1)
        let seen = results.flatMap { $0 }.map(\.content).joined()
        XCTAssertTrue(seen.contains("d\(travel.id)"))
        XCTAssertFalse(seen.contains("7212345673") || seen.contains("72 1234567"), "модель увидела номер целиком: \(seen)")
    }

    func testAgentSeesInstructionsWithIndexAndHistoryOfRulesAnswers() async throws {
        try await indexPassports()
        let russian = try await document(.passportRU)
        let agent = ScriptedAgent([AgentTurn(text: "Понял.")])
        let session = ChatSession(search: search, agentModel: { agent })

        // Правила ответили сами — модель всё равно видит этот ход в истории
        session.send("мой паспорт")
        _ = try await reply(of: session)
        session.send(freeQuestion)
        _ = try await reply(of: session)

        let begun = await agent.begun
        let call = try XCTUnwrap(begun.last)
        XCTAssertTrue(call.instructions.contains("d\(russian.id) — "), "в инструкции нет описи документов")
        XCTAssertEqual(call.history.first?.content, "мой паспорт")
        XCTAssertTrue(call.history.contains { $0.role == .assistant && $0.content.contains("d\(russian.id)") },
                      "модель не знает, что показали правила: \(call.history)")
        XCTAssertEqual(call.question, freeQuestion)
    }

    func testExactQuestionsNeverReachTheModel() async throws {
        try await indexPassports()
        let agent = ScriptedAgent([AgentTurn(text: "Не знаю")])
        let session = ChatSession(search: search, agentModel: { agent })

        session.send("номер паспорта")
        _ = try await reply(of: session)
        session.send("а загран?")
        _ = try await reply(of: session)
        let travel = try await document(.passportIntl)
        session.send("загранпаспорт", documentID: travel.id)
        _ = try await reply(of: session)

        let begun = await agent.begun
        XCTAssertTrue(begun.isEmpty, "точный вопрос ушёл в модель: \(begun.map(\.question))")
    }

    func testAgentFailureFallsBackToRules() async throws {
        try await indexPassports()
        let session = ChatSession(search: search, agentModel: { FailingAgent() })

        session.send("паспорт выдан где")
        let answer = try await reply(of: session)
        XCTAssertFalse(answer.text.isEmpty)
        XCTAssertTrue(answer.steps.contains { $0.text.contains("отвечаю по базе") }, "\(answer.steps.map(\.text))")
    }

    func testSlowAgentGivesWayToRules() async throws {
        try await indexPassports()
        let session = ChatSession(search: search, agentModel: { SlowAgent() }, agentTimeout: .milliseconds(300))

        let started = Date()
        session.send(freeQuestion)
        let answer = try await reply(of: session)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "медленная модель не должна держать ответ")
        XCTAssertFalse(answer.isPending)
    }

    /// Номер, прошедший через инструменты, в тексте модели закрывается маской
    func testDocumentNumbersInModelTextAreMasked() async throws {
        try await indexPassports()
        let travel = try await document(.passportIntl)
        let agent = ScriptedAgent([
            AgentTurn(calls: [.call("get_document", #"{"id": "d\#(travel.id)"}"#)]),
            AgentTurn(text: "Номер загранпаспорта 721234567, всё в порядке."),
        ])
        let session = ChatSession(search: search, agentModel: { agent })

        session.send(freeQuestion)
        let answer = try await reply(of: session)
        XCTAssertFalse(answer.text.contains("721234567"), answer.text)
    }

    func testCallWrittenAsTextIsRecovered() async throws {
        try await indexPassports()
        let agent = ScriptedAgent([
            AgentTurn(text: #"search_documents(query="загран")"#),
            AgentTurn(text: "Нашёл."),
        ])
        let session = ChatSession(search: search, agentModel: { agent })

        session.send(freeQuestion)
        let answer = try await reply(of: session)
        XCTAssertEqual(answer.text, "Нашёл.")
        let results = await agent.results
        XCTAssertEqual(results.first?.first?.name, "search_documents", "вызов, написанный словами, не исполнился")
        XCTAssertNil(LocalAgentEngine.recoverCall(from: "Я бы вызвал search_documents(query=\"загран\") и посмотрел"), "упоминание — не вызов")
        XCTAssertNil(LocalAgentEngine.recoverCall(from: #"delete_everything(id="d1")"#), "только объявленные инструменты")
    }

    func testBrokenCallIsRetried() async throws {
        try await indexPassports()
        let russian = try await document(.passportRU)
        let agent = ScriptedAgent([
            AgentTurn(rejected: true),
            AgentTurn(calls: [.call("show_cards", #"{"cards": [{"type": "document", "documentId": "d\#(russian.id)"}]}"#)]),
        ])
        let session = ChatSession(search: search, agentModel: { agent })

        session.send(freeQuestion)
        let answer = try await reply(of: session)
        XCTAssertEqual(answer.cards.map(\.card), [.document(documentID: russian.id)])
        let results = await agent.results
        XCTAssertTrue(results.first?.first?.content.contains("не разобрался") == true)
    }

    func testFileProposalFromAgent() async throws {
        try await indexPassports()
        let russian = try await document(.passportRU)
        store.createFolder(name: "Семья", icon: "folder.fill", color: "indigo")
        let family = try XCTUnwrap(store.folders.last)
        let agent = ScriptedAgent([
            AgentTurn(calls: [.call("propose_file_actions", #"{"summary": "Паспорт — в «Семья»", "actions": [{"action": "move_files", "files": [{"folder_id": "\#(russian.folderID.uuidString)", "name": "\#(russian.fileName)"}], "folder_id": "\#(family.id.uuidString)"}]}"#)]),
        ])
        let session = ChatSession(search: search, agentModel: { agent })
        session.useFiles(store)

        session.send("разбери мои папки, пожалуйста")
        let answer = try await reply(of: session)
        guard case .proposal(let proposal) = answer.cards.first?.content else { return XCTFail("нет предложения: \(answer.text)") }
        XCTAssertEqual(proposal.actions, [.moveFiles(files: [FileRef(folderID: russian.folderID, name: russian.fileName)], folder: .existing(family.id))])
        XCTAssertEqual(answer.text, ChatSession.proposalLead, "без своего текста — пояснение к кнопке")
    }

    /// Модель знает документ по описи (d42), а не имя файла — перенос по id
    func testAgentMovesFileByDocumentID() async throws {
        try await indexPassports()
        let russian = try await document(.passportRU)
        store.createFolder(name: "Семья", icon: "folder.fill", color: "indigo")
        let family = try XCTUnwrap(store.folders.last)
        let agent = ScriptedAgent([
            AgentTurn(calls: [.call("propose_file_actions", #"{"summary": "В «Семья»", "actions": [{"action": "move_files", "files": [{"document_id": "d\#(russian.id)"}], "folder_id": "Семья"}]}"#)]),
        ])
        let session = ChatSession(search: search, agentModel: { agent })
        session.useFiles(store)

        session.send("разбери мои папки, пожалуйста")
        let answer = try await reply(of: session)
        guard case .proposal(let proposal) = answer.cards.first?.content else { return XCTFail("нет предложения: \(answer.text)") }
        XCTAssertEqual(proposal.actions, [.moveFiles(files: [FileRef(folderID: russian.folderID, name: russian.fileName)], folder: .existing(family.id))])
    }

    /// «Трошкина» вместо ФИО целиком — меняется только фамилия
    func testAgentFieldFixKeepsGivenNames() async throws {
        try await indexPassports()
        let russian = try await document(.passportRU)
        let agent = ScriptedAgent([
            AgentTurn(calls: [.call("propose_field_fix", #"{"document_id": "d\#(russian.id)", "key": "full_name", "value": "Савельев"}"#)]),
        ])
        let session = ChatSession(search: search, agentModel: { agent })

        session.send("с фамилией какая-то беда, проверь")
        let answer = try await reply(of: session)
        XCTAssertEqual(answer.cards.map(\.card), [.fieldFix(documentID: russian.id, key: FieldKey.fullName, value: "Савельев Илья Андреевич")])
    }

    /// Агент спросил — короткий ответ уходит ему же, а не правилам. Владелец
    /// 25.10.2026: на «Трошкина» после «пришлите, как правильно» правила
    /// показали другой документ, где тоже есть это имя
    func testReplyToAgentQuestionGoesBackToAgent() async throws {
        try await indexPassports()
        let russian = try await document(.passportRU)
        let agent = ScriptedAgent([
            AgentTurn(text: "Пришлите, как правильно пишется фамилия."),
            AgentTurn(calls: [.call("propose_field_fix", #"{"document_id": "d\#(russian.id)", "key": "full_name", "value": "Савельев"}"#)]),
        ])
        let session = ChatSession(search: search, agentModel: { agent })

        session.send("с фамилией какая-то беда")
        _ = try await reply(of: session)
        session.send("Савельев")
        let answer = try await reply(of: session)

        let begun = await agent.begun
        XCTAssertEqual(begun.map(\.question), ["с фамилией какая-то беда", "Савельев"])
        XCTAssertEqual(answer.cards.map(\.card), [.fieldFix(documentID: russian.id, key: FieldKey.fullName, value: "Савельев Илья Андреевич")])
    }

    /// После вопроса агента самостоятельный вопрос — снова правилам, сразу
    func testOwnQuestionAfterAgentQuestionStaysWithRules() async throws {
        try await indexPassports()
        let agent = ScriptedAgent([AgentTurn(text: "Что именно показать?")])
        let session = ChatSession(search: search, agentModel: { agent })

        session.send(freeQuestion)
        _ = try await reply(of: session)
        session.send("дата рождения в загранпаспорте")
        let answer = try await reply(of: session)

        let begun = await agent.begun
        XCTAssertEqual(begun.count, 1, "точный вопрос ушёл модели")
        XCTAssertTrue(answer.cards.contains { if case .fields = $0.card { true } else { false } }, answer.text)
    }

    func testNewChatResetsAgentConversation() async throws {
        let agent = ScriptedAgent([])
        let session = ChatSession(search: search, agentModel: { agent })
        session.reset()
        try await Task.sleep(for: .milliseconds(100))
        let resets = await agent.resets
        XCTAssertEqual(resets, 1)
    }

    func testModelIsPinned() {
        XCTAssertEqual(ChatModelChoice.allCases, [.standard], "лёгкая модель снята по итогам стенда")
        let model = ChatModelChoice.standard
        XCTAssertEqual(model.revision.count, 40, "ревизия — полный хэш коммита, иначе без сети модель не загрузится")
        XCTAssertTrue(model.revision.allSatisfy(\.isHexDigit))
        XCTAssertTrue(ChatModelChoice.filePatterns.contains("*.txt"), "без merges.txt токенизатор не соберётся")
    }
}

// MARK: - Подделки модели

private extension AgentCall {
    static func call(_ name: String, _ json: String) -> AgentCall {
        AgentCall(id: nil, name: name, arguments: Data(json.utf8))
    }
}

/// Ходы модели по списку; кончились — короткий ответ
private actor ScriptedAgent: LocalAgentModel {
    struct Begin {
        let instructions: String
        let history: [AgentMessage]
        let question: String
    }

    private var turns: [AgentTurn]
    private(set) var begun: [Begin] = []
    private(set) var results: [[AgentToolResult]] = []
    private(set) var resets = 0

    init(_ turns: [AgentTurn]) {
        self.turns = turns
    }

    func beginAgent(instructions: String, toolsJSON: String, history: [AgentMessage], question: String) async throws -> AgentTurn {
        begun.append(Begin(instructions: instructions, history: history, question: question))
        return next()
    }

    func continueAgent(results: [AgentToolResult]) async throws -> AgentTurn {
        self.results.append(results)
        return next()
    }

    func resetAgent() async {
        resets += 1
    }

    private func next() -> AgentTurn {
        turns.isEmpty ? AgentTurn(text: "Готово.") : turns.removeFirst()
    }
}

private struct FailingAgent: LocalAgentModel {
    func beginAgent(instructions: String, toolsJSON: String, history: [AgentMessage], question: String) async throws -> AgentTurn {
        throw LocalChatModelError.unavailableOnSimulator
    }

    func continueAgent(results: [AgentToolResult]) async throws -> AgentTurn {
        throw LocalChatModelError.unavailableOnSimulator
    }

    func resetAgent() async {}
}

private struct SlowAgent: LocalAgentModel {
    func beginAgent(instructions: String, toolsJSON: String, history: [AgentMessage], question: String) async throws -> AgentTurn {
        try await Task.sleep(for: .seconds(30))
        return AgentTurn(text: "поздно")
    }

    func continueAgent(results: [AgentToolResult]) async throws -> AgentTurn {
        AgentTurn()
    }

    func resetAgent() async {}
}
