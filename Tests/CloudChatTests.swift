import SQLite3
import XCTest
@testable import LocalDrive

// Облачный чат и метаданные без сети: ответы Gemini — заглушка (SSE), запросы
// проверяются целиком. Данные синтетические: тот же паспорт, что в других тестах
private enum Gemini {
    static func sse(_ chunks: [CloudJSON]) -> StubURLProtocol.Reply {
        let body = chunks.map { "data: " + String(data: $0.data, encoding: .utf8)! + "\r\n\r\n" }.joined()
        return StubURLProtocol.Reply(status: 200, body: Data(body.utf8))
    }

    static func chunk(_ parts: [CloudJSON]) -> CloudJSON {
        ["candidates": [["content": ["role": "model", "parts": .array(parts)]]]]
    }

    static func text(_ text: String) -> StubURLProtocol.Reply {
        sse([chunk([["text": .string(text)]])])
    }

    static func call(_ name: String, _ args: CloudJSON, id: String, signature: String) -> StubURLProtocol.Reply {
        sse([chunk([["functionCall": ["name": .string(name), "args": args, "id": .string(id)], "thoughtSignature": .string(signature)]])])
    }

    static func location() -> StubURLProtocol.Reply {
        let body: CloudJSON = ["error": ["code": 400, "message": "User location is not supported for the API use.", "status": "FAILED_PRECONDITION"]]
        return StubURLProtocol.Reply(status: 400, body: body.data)
    }
}

/// Ответы OpenAI Responses API потоком SSE: «event: тип» и «data: JSON»
private enum OpenAI {
    static func lines(_ events: [CloudJSON]) -> Data {
        Data(events.map { "event: \($0["type"]?.string ?? "")\ndata: " + String(data: $0.data, encoding: .utf8)! + "\n\n" }.joined().utf8)
    }

    /// Тип text/event-stream, как у настоящего потока: без него URLSession
    /// копит первые байты, чтобы угадать тип, и короткий кусок не доходит
    static let stream = ["Content-Type": "text/event-stream"]

    static func sse(_ events: [CloudJSON]) -> StubURLProtocol.Reply {
        StubURLProtocol.Reply(status: 200, body: lines(events), headers: stream)
    }

    /// Поток кусками: первый — сразу, остальные — после паузы
    static func stalling(_ first: [CloudJSON], then rest: [CloudJSON], after delay: TimeInterval) -> StubURLProtocol.Reply {
        StubURLProtocol.Reply(status: 200, body: Data(), headers: stream, parts: [(0, lines(first)), (delay, lines(rest))])
    }

    static func reasoning(_ id: String = "rs_1", encrypted: String = "enc-1") -> CloudJSON {
        ["id": .string(id), "type": "reasoning", "summary": [], "encrypted_content": .string(encrypted)]
    }

    static func message(_ text: String, id: String = "msg_1") -> CloudJSON {
        ["id": .string(id), "type": "message", "role": "assistant", "status": "completed", "phase": "final_answer",
         "content": [["type": "output_text", "text": .string(text), "annotations": []]]]
    }

    static func functionCall(_ name: String, _ args: CloudJSON, callID: String, id: String = "fc_1") -> CloudJSON {
        ["id": .string(id), "type": "function_call", "status": "completed", "call_id": .string(callID), "name": .string(name),
         "arguments": .string(String(data: args.data, encoding: .utf8)!)]
    }

    static func done(_ item: CloudJSON, _ index: Int) -> CloudJSON {
        ["type": "response.output_item.done", "output_index": .number(Double(index)), "item": item]
    }

    static func completed(_ output: [CloudJSON]) -> CloudJSON {
        ["type": "response.completed", "response": ["id": "resp_1", "status": "completed", "output": .array(output)]]
    }

    static func textDelta(_ text: String, item: String = "msg_1") -> CloudJSON {
        ["type": "response.output_text.delta", "item_id": .string(item), "output_index": 0, "content_index": 0, "delta": .string(text)]
    }

    static func summaryDelta(_ text: String, index: Int, item: String = "rs_1") -> CloudJSON {
        ["type": "response.reasoning_summary_text.delta", "item_id": .string(item), "output_index": 0,
         "summary_index": .number(Double(index)), "delta": .string(text)]
    }

    static func text(_ text: String) -> StubURLProtocol.Reply {
        let message = message(text)
        return sse([textDelta(text), done(message, 0), completed([message])])
    }

    static func call(_ name: String, _ args: CloudJSON, callID: String, encrypted: String = "enc-1") -> StubURLProtocol.Reply {
        let reasoning = reasoning(encrypted: encrypted), call = functionCall(name, args, callID: callID)
        return sse([done(reasoning, 0), done(call, 1), completed([reasoning, call])])
    }

    static func error(_ status: Int, _ message: String, code: String, param: String? = nil) -> StubURLProtocol.Reply {
        var error: [String: CloudJSON] = ["message": .string(message), "type": "invalid_request_error", "code": .string(code)]
        if let param { error["param"] = .string(param) }
        return StubURLProtocol.Reply(status: status, body: (["error": .object(error)] as CloudJSON).data)
    }
}

@MainActor
final class CloudChatTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!

    /// Савин Илья Андреевич, 4601 123456, код 770-120 — векторы MRZ из PassportFieldsTests
    private let passport = """
    ПАСПОРТ
    Фамилия САВИН
    Имя ИЛЬЯ
    Отчество АНДРЕЕВИЧ
    PNRUSSAVIN<<IL98<ANDREEVI3<<<<<<<<<<<<<<<<<<
    4601234561RUS9001011M<<<<<<<1100620770120<34
    """

    override func setUp() async throws {
        StubURLProtocol.reset()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudChat-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
        search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil })
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        search = nil
        store = nil
    }

    private func folder(_ name: String, hidden: Bool = false) throws -> VaultFolder {
        store.createFolder(name: name, icon: "folder.fill", color: "indigo", isSuperHidden: hidden)
        return try XCTUnwrap(store.folders.last)
    }

    private func indexPassport(in service: SearchService? = nil) async throws -> Int64 {
        let service = service ?? search!
        store.importData(Data(passport.utf8), preferredName: "паспорт.txt", to: try folder("Паспорта"))
        service.reconcile()
        await service.waitUntilIdle()
        let documents = await service.documents(ofTypes: [.passportRU])
        return try XCTUnwrap(documents.first?.id)
    }

    private func engine(_ model: CloudChatModel = .flash, reasoning: CloudChatReasoning = .auto, proposals: FileProposalMaker? = nil) -> CloudChatEngine {
        let provider = model.provider ?? .gemini
        return CloudChatEngine(
            configuration: .init(provider: provider, baseURL: provider.defaultBaseURL, apiKey: "k", model: model, reasoning: reasoning),
            search: search, proposals: proposals, session: StubURLProtocol.session()
        )
    }

    private func body(_ index: Int) throws -> CloudJSON {
        try XCTUnwrap(CloudJSON.parse(XCTUnwrap(StubURLProtocol.requests[index].httpBody)))
    }

    /// Инструкция OpenAI — первый элемент input, сообщение developer: блоки
    /// правил, описи и даты подряд
    private func instructions(_ json: CloudJSON) -> String? {
        json["input"]?.array?.first { $0["role"]?.string == "developer" }?["content"]?.array?.compactMap { $0["text"]?.string }.joined()
    }

    /// Уровень рассуждения последнего вопроса: последний configuration_update,
    /// а без него — поле запроса
    private func effort(_ json: CloudJSON) -> String? {
        conversation(json).last { $0["type"]?.string == "configuration_update" }?["reasoning"]?["effort"]?.string
            ?? json["reasoning"]?["effort"]?.string
    }

    /// Ход разговора без инструкции
    private func conversation(_ json: CloudJSON) -> [CloudJSON] {
        (json["input"]?.array ?? []).filter { $0["role"]?.string != "developer" }
    }

    func testRequestDeclaresToolsSystemPromptAndThinking() async throws {
        StubURLProtocol.reset([Gemini.text("Здравствуйте!")])
        let reply = try await engine().respond(to: "привет")
        XCTAssertEqual(reply.text, "Здравствуйте!")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "k")
        let json = try body(0)
        XCTAssertTrue(json["system_instruction"]?["parts"]?.array?.first?["text"]?.string?.hasPrefix(CloudChatPrompt.system) == true)
        let names = Set(json["tools"]?.array?.first?["functionDeclarations"]?.array?.compactMap { $0["name"]?.string } ?? [])
        // С 24.10.2026 — и инструменты «Карточек»
        XCTAssertEqual(names, ["search_documents", "list_documents", "list_folders", "list_files", "get_document",
                               "view_document", "list_expiring", "show_cards", "propose_field_fix", "propose_file_actions",
                               "find_fact_cards", "show_fact_card", "propose_fact_card"])
        let thinking = json["generationConfig"]?["thinkingConfig"]
        XCTAssertEqual(thinking?["includeThoughts"]?.bool, true)
        XCTAssertEqual(thinking?["thinkingLevel"]?.string, "low", "«Авто» для простого вопроса — low, а не medium по умолчанию")
        XCTAssertEqual(json["contents"]?.array?.count, 1)
    }

    func testToolLoopShowsCardsAndKeepsThoughtSignatures() async throws {
        let id = try await indexPassport()
        // Текст и show_cards — в одном ходе, как просит инструкция: после
        // карточек третий запрос за текстом не нужен
        let cards: CloudJSON = ["cards": [["type": "fields", "documentId": .string("d\(id)"), "keys": ["full_name"]]]]
        StubURLProtocol.reset([
            Gemini.call("list_documents", ["type": "passport_ru"], id: "c1", signature: "sig-1"),
            Gemini.sse([Gemini.chunk([
                ["text": "Вот ваш паспорт."],
                ["functionCall": ["name": "show_cards", "args": cards, "id": "c2"], "thoughtSignature": "sig-2"],
            ])]),
        ])
        let reply = try await engine().respond(to: "мой паспорт")
        XCTAssertEqual(reply.text, "Вот ваш паспорт.")
        XCTAssertEqual(reply.cards, [.fields(documentID: id, keys: ["full_name"])])
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "show_cards завершает ответ")

        let second = try XCTUnwrap(body(1)["contents"]?.array)
        XCTAssertEqual(second.map { $0["role"]?.string }, ["user", "model", "user"])
        let modelPart = try XCTUnwrap(second[1]["parts"]?.array?.first)
        XCTAssertEqual(modelPart["thoughtSignature"]?.string, "sig-1", "часть с вызовом вернулась дословно")
        let response = try XCTUnwrap(second[2]["parts"]?.array?.first?["functionResponse"])
        XCTAssertEqual(response["id"]?.string, "c1")
        XCTAssertEqual(response["name"]?.string, "list_documents")
        XCTAssertEqual(response["response"]?["documents"]?.array?.first?["id"]?.string, "d\(id)")
    }

    func testNextQuestionContinuesTurnThatEndedWithCards() async throws {
        let id = try await indexPassport()
        let cards: CloudJSON = ["cards": [["type": "document", "documentId": .string("d\(id)")]]]
        StubURLProtocol.reset([Gemini.call("show_cards", cards, id: "c1", signature: "s"), Gemini.text("Это он.")])
        let chat = engine()
        _ = try await chat.respond(to: "мой паспорт")
        _ = try await chat.respond(to: "спасибо")
        let contents = try XCTUnwrap(body(1)["contents"]?.array)
        XCTAssertEqual(contents.map { $0["role"]?.string }, ["user", "model", "user"], "роли чередуются: ответ инструмента и вопрос — один ход")
        let last = try XCTUnwrap(contents.last?["parts"]?.array)
        XCTAssertNotNil(last.first?["functionResponse"])
        XCTAssertEqual(last.last?["text"]?.string, "спасибо")
    }

    func testDocumentNumbersNeverReachModelOrText() async throws {
        let id = try await indexPassport()
        StubURLProtocol.reset([
            Gemini.call("get_document", ["id": .string("d\(id)")], id: "c1", signature: "s"),
            Gemini.text("Серия и номер 4601 123456, код 770-120."),
        ])
        let reply = try await engine().respond(to: "какой номер паспорта")
        XCTAssertFalse(reply.text.contains("123456"), reply.text)
        XCTAssertFalse(reply.text.contains("770-120"), reply.text)
        let sent = String(data: try XCTUnwrap(StubURLProtocol.requests[1].httpBody), encoding: .utf8) ?? ""
        XCTAssertFalse(sent.contains("4601 123456"), "модель видит номер только маской")
        XCTAssertFalse(sent.contains("PNRUS"), "строки MRZ из выдержки вырезаны")
    }

    func testHiddenFolderDoesNotExistForModel() async throws {
        _ = try await indexPassport()
        store.importData(Data(passport.utf8), preferredName: "тайный паспорт.txt", to: try folder("Тайное", hidden: true))
        search.reconcile()
        await search.waitUntilIdle()
        StubURLProtocol.reset([
            Gemini.sse([Gemini.chunk([
                ["functionCall": ["name": "list_folders", "args": [:], "id": "c1"], "thoughtSignature": "s"],
                ["functionCall": ["name": "list_documents", "args": [:], "id": "c2"]],
            ])]),
            Gemini.text("Готово."),
        ])
        _ = try await engine().respond(to: "какие у меня папки")
        let sent = String(data: try XCTUnwrap(StubURLProtocol.requests[1].httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(sent.contains("Паспорта"))
        XCTAssertFalse(sent.contains("Тайное"))
        XCTAssertFalse(sent.contains("тайный паспорт"))
    }

    func testAttachmentImagesOnlyInTheirOwnTurn() async throws {
        StubURLProtocol.reset([Gemini.text("Положу в «Паспорта»."), Gemini.text("Хорошо.")])
        let chat = engine()
        _ = try await chat.respond(to: "куда положить?", attachments: [CloudChatAttachment(id: "a1", name: "скан.jpg", jpeg: Data([0xFF, 0xD8]))])
        let firstParts = try XCTUnwrap(body(0)["contents"]?.array?.first?["parts"]?.array)
        XCTAssertEqual(firstParts.filter { $0["inline_data"] != nil }.count, 1)
        XCTAssertTrue(firstParts.last?["text"]?.string?.contains("a1 — «скан.jpg»") == true)

        _ = try await chat.respond(to: "спасибо")
        let history = try XCTUnwrap(body(1)["contents"]?.array)
        XCTAssertFalse(history.contains { $0["parts"]?.array?.contains { $0["inline_data"] != nil } == true },
                       "картинка прошлого сообщения второй раз не уходит")
    }

    func testThoughtsStreamBeforeAnswer() async throws {
        StubURLProtocol.reset([Gemini.sse([
            Gemini.chunk([["text": "Ищу паспорт…", "thought": true]]),
            Gemini.chunk([["text": "Нашёл."]]),
        ])])
        var events: [CloudChatEvent] = []
        let reply = try await engine().respond(to: "мой паспорт") { events.append($0) }
        XCTAssertEqual(events, [.thoughts("Ищу паспорт…"), .text("Нашёл.")])
        XCTAssertEqual(reply.thoughts, "Ищу паспорт…")
        XCTAssertNotNil(reply.thinkingSeconds)
    }

    func testSelectorsMapToModelAndThinkingLevel() async throws {
        // Gemini: у 3.8 Flash minimal — ошибка, у Flash-Lite — самый быстрый
        XCTAssertEqual(CloudChatReasoning.auto.level(for: .flash, message: "паспорт ильи"), "low")
        XCTAssertEqual(CloudChatReasoning.auto.level(for: .flash, message: "сравни сроки моих паспортов"), "medium")
        XCTAssertEqual(CloudChatReasoning.fast.level(for: .flash), "low")
        XCTAssertEqual(CloudChatReasoning.fast.level(for: .flashLite), "minimal")
        XCTAssertEqual(CloudChatReasoning.deep.level(for: .flash), "high")
        // OpenAI: none есть только у Luna
        XCTAssertEqual(CloudChatReasoning.auto.level(for: .luna, message: "паспорт ильи"), "none",
                       "простой вопрос о документе — none: большая проверка 19.11.2026, 74/76 против 72/76 у low")
        XCTAssertEqual(CloudChatReasoning.auto.level(for: .luna, message: "Привет!"), "none", "болтовня — none")
        XCTAssertEqual(CloudChatReasoning.auto.level(for: .luna, message: "спасибо"), "none")
        XCTAssertEqual(CloudChatReasoning.auto.level(for: .luna, message: "посчитай, сколько у меня полисов"), "low")
        XCTAssertEqual(CloudChatReasoning.auto.level(for: .luna, message: "куда положить", hasAttachments: true), "low")
        XCTAssertEqual(CloudChatReasoning.fast.level(for: .luna), "none")
        XCTAssertEqual(CloudChatReasoning.fast.level(for: .sol), "low", "у Sol нет none")
        XCTAssertEqual(CloudChatReasoning.auto.level(for: .astra, message: "привет"), "low")
        XCTAssertEqual(CloudChatReasoning.deep.level(for: .luna), "high")
        // Чат только облачный (19.11.2026): «iPhone» на поле ввода не выбирают
        XCTAssertEqual(CloudChatModel.choices(for: .openAI), [.luna, .sol, .astra])
        XCTAssertEqual(CloudChatModel.choices(for: .gemini), [.flash, .flashLite])

        StubURLProtocol.reset([Gemini.text("ок")])
        _ = try await engine(.flashLite, reasoning: .fast).respond(to: "привет")
        XCTAssertTrue(StubURLProtocol.requests[0].url?.absoluteString.contains("gemini-3.5-flash-lite:streamGenerateContent") == true)
        XCTAssertEqual(try body(0)["generationConfig"]?["thinkingConfig"]?["thinkingLevel"]?.string, "minimal")
    }

    func testFileProposalIsStubUntilAgentB() async throws {
        let args: CloudJSON = ["actions": [["action": "create_folder", "new_folder_name": "Чеки"]], "summary": "Создам папку «Чеки»"]
        StubURLProtocol.reset([Gemini.call("propose_file_actions", args, id: "c1", signature: "s"), Gemini.text("Не могу пока.")])
        _ = try await engine().respond(to: "создай папку чеки")
        let sent = String(data: try XCTUnwrap(StubURLProtocol.requests[1].httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(sent.contains("пока недоступны"))

        let id = try await indexPassport()
        StubURLProtocol.reset([Gemini.call("propose_file_actions", args, id: "c1", signature: "s"), Gemini.text("Предлагаю.")])
        var received: Data?
        let reply = try await engine(proposals: { data in
            received = data
            return .document(documentID: id)
        }).respond(to: "создай папку чеки")
        XCTAssertEqual(reply.cards, [.document(documentID: id)], "карточка предложения — от FileProposalBuilder агента B")
        XCTAssertEqual(CloudJSON.parse(try XCTUnwrap(received))?["summary"]?.string, "Создам папку «Чеки»")
    }

    /// Чат только облачный (владелец 19.11.2026: «почему ответил сам, если всё
    /// только облако»): правила ответ облака не подменяют — причина, «Повторить»
    /// и явная кнопка «Найти на iPhone», если VPN пропал в дороге
    func testCloudFailureShowsCauseAndRetry() async throws {
        let (session, local) = cloudSession()
        let id = try await indexPassport(in: local)
        StubURLProtocol.reset([OpenAI.error(403, "Country, region, or territory not supported", code: "unsupported_country_region_territory")])
        session.send("мой паспорт")
        try await finish(session)
        let answer = try XCTUnwrap(session.messages.last)
        XCTAssertEqual(answer.notice, "Облако недоступно — проверьте VPN", "причина, а не общее «недоступно»")
        XCTAssertTrue(answer.text.isEmpty, "правила не отвечают вместо облака")
        guard case .clarify(_, let options)? = answer.cards.first?.card else { return XCTFail("нет «Повторить»: \(answer.cards)") }
        XCTAssertEqual(options.map(\.title), ["Повторить", "Найти на iPhone"])
        XCTAssertEqual(options[0].query, "мой паспорт", "повтор — тот же вопрос")
        XCTAssertFalse(options[0].localOnly)
        XCTAssertEqual(options[1].query, "мой паспорт")
        XCTAssertTrue(options[1].localOnly)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)

        // Явное нажатие «Найти на iPhone» отдаёт паспорт из базы без сети
        session.send(options[1].query, localOnly: options[1].localOnly)
        try await finish(session)
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "локальный поиск не ходит в облако")
        let offline = try XCTUnwrap(session.messages.last)
        XCTAssertTrue(offline.cards.contains { card in
            if case .fields(let document, _) = card.card { document == id } else { false }
        }, "нашёл паспорт локально: \(offline.cards)")
    }

    // MARK: - OpenAI

    func testOpenAIRequestShapeAndStrictTools() async throws {
        StubURLProtocol.reset([OpenAI.text("Здравствуйте!")])
        let chat = engine(.luna)
        chat.documentIndex = "d1 · passport_ru · Паспорт · Савин И. А. · Паспорта"
        let reply = try await chat.respond(to: "привет")
        XCTAssertEqual(reply.text, "Здравствуйте!")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let json = try body(0)
        XCTAssertEqual(json["model"]?.string, "gpt-6-luna")
        XCTAssertEqual(json["store"]?.bool, false, "переписка у OpenAI не хранится")
        XCTAssertEqual(json["stream"]?.bool, true)
        XCTAssertEqual(json["reasoning"]?["effort"]?.string, "low", "уровень запроса постоянный — префикс кэша общий у всех разговоров")
        XCTAssertEqual(json["reasoning"]?["summary"]?.string, "auto")
        XCTAssertEqual(json["text"]?["verbosity"]?.string, "low")
        XCTAssertEqual(json["service_tier"]?.string, "fast")
        XCTAssertNil(json["instructions"], "инструкция — сообщением developer: там её можно отметить для кэша")
        let instructions = try XCTUnwrap(self.instructions(json))
        XCTAssertTrue(instructions.hasPrefix(CloudChatPrompt.system))
        XCTAssertTrue(instructions.contains("d1 — Паспорт (passport_ru); владелец: Савин И. А.; папка: Паспорта"), "опись с подписями — в инструкции")
        let developer = try XCTUnwrap(json["input"]?.array?.first)
        let blocks = try XCTUnwrap(developer["content"]?.array)
        XCTAssertEqual(blocks.count, 3, "правила, опись, дата")
        for block in blocks.prefix(2) {
            XCTAssertEqual(block["prompt_cache_breakpoint"], ["mode": "explicit", "ttl": "12h"], "правила и опись — кэш на 12 часов")
        }
        XCTAssertNil(blocks[2]["prompt_cache_breakpoint"], "дата — после отметок: её смена кэш не сбивает")
        XCTAssertTrue(blocks[2]["text"]?.string?.contains("Сегодня") == true)
        XCTAssertEqual(json["stream_options"]?["include_obfuscation"]?.bool, false)
        let input = conversation(json)
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[0], ["type": "configuration_update", "reasoning": ["effort": "none"]], "«Авто» для простого вопроса у Luna — none")
        XCTAssertEqual(input[1]["role"]?.string, "user")
        XCTAssertEqual(input[1]["content"]?.array?.first?["text"]?.string, "привет")

        let tools = try XCTUnwrap(json["tools"]?.array)
        XCTAssertEqual(Set(tools.compactMap { $0["name"]?.string }), ["search_documents", "list_documents", "list_folders", "list_files",
                                                                     "get_document", "view_document", "list_expiring", "show_cards", "propose_field_fix", "propose_file_actions",
                                                                     "find_fact_cards", "show_fact_card", "propose_fact_card"])
        for tool in tools {
            XCTAssertEqual(tool["type"]?.string, "function")
            XCTAssertEqual(tool["strict"]?.bool, true)
            try assertStrict(XCTUnwrap(tool["parameters"]), path: tool["name"]?.string ?? "")
        }
        let search = try XCTUnwrap(tools.first { $0["name"]?.string == "search_documents" }?["parameters"])
        XCTAssertEqual(search["properties"]?["query"]?["type"]?.string, "string", "обязательное поле — без null")
        XCTAssertEqual(search["properties"]?["owner"]?["type"], ["string", "null"], "необязательное — с null")
    }

    /// Строгая схема OpenAI: у каждого объекта все поля обязательны, лишних нет
    private func assertStrict(_ schema: CloudJSON, path: String) throws {
        if let properties = schema["properties"]?.object {
            XCTAssertEqual(schema["additionalProperties"]?.bool, false, path)
            XCTAssertEqual(Set(schema["required"]?.array?.compactMap(\.string) ?? []), Set(properties.keys), path)
            for (key, value) in properties { try assertStrict(value, path: "\(path).\(key)") }
        }
        if let items = schema["items"] { try assertStrict(items, path: path + "[]") }
    }

    func testOpenAIStreamsSummariesAndCardsBeforeText() async throws {
        let id = try await indexPassport()
        let show = OpenAI.functionCall("show_cards", ["cards": [[
            "type": "fields", "documentId": .string("d\(id)"), "keys": ["full_name"],
            "documentIds": .null, "page": .null, "question": .null, "options": .null,
        ]]], callID: "call_1")
        let message = OpenAI.message("Вот ваш паспорт.", id: "msg_2")
        let reasoning = OpenAI.reasoning()
        StubURLProtocol.reset([OpenAI.sse([
            ["type": "response.created", "response": ["id": "resp_1", "status": "in_progress", "output": []]],
            OpenAI.summaryDelta("Ищу паспорт", index: 0),
            OpenAI.summaryDelta("Нашёл", index: 1),
            OpenAI.done(reasoning, 0),
            OpenAI.done(show, 1),
            OpenAI.textDelta("Вот ваш ", item: "msg_2"),
            OpenAI.textDelta("паспорт.", item: "msg_2"),
            OpenAI.done(message, 2),
            OpenAI.completed([reasoning, show, message]),
        ])])
        var log: [CloudChatEvent] = []
        let reply = try await engine(.luna).respond(to: "паспорт ильи") { log.append($0) }
        let card = ChatCard.fields(documentID: id, keys: ["full_name"])
        // Шаг «Готовлю карточки» — для ленты шагов в чате, сразу перед ними
        XCTAssertEqual(log, [
            .thoughts("Ищу паспорт"), .thoughts("Ищу паспорт\n\nНашёл"),
            .step(.open, "Готовлю карточки"),
            .cards([card]),
            .text("Вот ваш "), .text("Вот ваш паспорт."),
            .tool("show_cards"),
        ], "карточки — как только пришёл вызов, до текста ответа")
        XCTAssertEqual(reply.text, "Вот ваш паспорт.")
        XCTAssertEqual(reply.cards, [card], "show_cards из потока второй раз не выполняется")
        XCTAssertEqual(reply.thoughts, "Ищу паспорт\n\nНашёл")
        XCTAssertNotNil(reply.thinkingSeconds)
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "поиск своего документа — один раунд")
    }

    func testOpenAIToolLoopReplaysReasoningAndOutputs() async throws {
        let id = try await indexPassport()
        StubURLProtocol.reset([
            OpenAI.call("list_documents", ["type": "passport_ru", "folder_id": .null], callID: "call_1", encrypted: "secret-reasoning"),
            OpenAI.text("Нашёл паспорт."),
        ])
        let reply = try await engine(.luna).respond(to: "какие у меня паспорта")
        XCTAssertEqual(reply.text, "Нашёл паспорт.")

        // Уровень вопроса (configuration_update) проверяют свои тесты — здесь ход разговора
        let input = conversation(try body(1)).filter { $0["type"]?.string != "configuration_update" }
        XCTAssertEqual(input.map { $0["type"]?.string ?? $0["role"]?.string }, ["user", "reasoning", "function_call", "function_call_output"])
        XCTAssertEqual(input[1]["encrypted_content"]?.string, "secret-reasoning", "рассуждение вернулось дословно")
        XCTAssertEqual(input[3]["call_id"]?.string, "call_1")
        let output = try XCTUnwrap(input[3]["output"]?.string.flatMap { CloudJSON.parse(Data($0.utf8)) })
        XCTAssertEqual(output["documents"]?.array?.first?["id"]?.string, "d\(id)", "null в аргументах — как пропуск")
    }

    func testOpenAIReasoningChangeKeepsRequestPrefix() async throws {
        StubURLProtocol.reset([OpenAI.text("Привет!"), OpenAI.text("Сравнил.")])
        let chat = engine(.luna)
        _ = try await chat.respond(to: "привет")
        _ = try await chat.respond(to: "сравни сроки паспортов")
        XCTAssertEqual(try body(0)["reasoning"]?["effort"]?.string, "low")
        XCTAssertEqual(try body(1)["reasoning"]?["effort"]?.string, "low", "поле запроса прежнее — префикс и кэш не меняются")
        XCTAssertEqual(conversation(try body(0)).first, ["type": "configuration_update", "reasoning": ["effort": "none"]],
                       "уровень первого вопроса — тоже элементом")
        let input = conversation(try body(1))
        let update = try XCTUnwrap(input.lastIndex { $0["type"]?.string == "configuration_update" })
        XCTAssertEqual(input[update]["reasoning"]?["effort"]?.string, "low")
        XCTAssertEqual(input[update + 1]["role"]?.string, "user")
        XCTAssertEqual(input[update + 1]["content"]?.array?.first?["text"]?.string, "сравни сроки паспортов")
        XCTAssertEqual(Array(input[..<update]), conversation(try body(0)) + [OpenAI.message("Привет!")],
                       "прежняя история — дословно")
    }

    /// Тот же вопрос в новом чате — те же байты. Словарь Swift перебирается в
    /// случайном порядке, и без сортировки ключей схемы инструментов уходили
    /// каждый раз по-новому: кэш OpenAI не срабатывал ни разу (19.11.2026)
    func testOpenAIRequestBytesAreStableForCache() async throws {
        StubURLProtocol.reset([OpenAI.text("Привет!"), OpenAI.text("Привет!"), OpenAI.text("Сравнил.")])
        for question in ["привет", "привет", "сравни сроки паспортов"] {
            let chat = engine(.luna)
            chat.genUI = true
            chat.documentIndex = "d1 · passport_ru · Паспорт · Савин И. А. · Паспорта"
            _ = try await chat.respond(to: question)
        }
        let bodies = try StubURLProtocol.requests.map { try XCTUnwrap($0.httpBody) }
        XCTAssertEqual(bodies[0], bodies[1], "тот же вопрос в новом чате — байт в байт")
        let first = try body(0), third = try body(2)
        for key in ["model", "tools", "text", "reasoning", "service_tier", "prompt_cache_options"] {
            XCTAssertEqual(first[key], third[key], "\(key) — часть кэшируемого префикса")
        }
        XCTAssertEqual(first["input"]?.array?.first, third["input"]?.array?.first, "инструкция и опись — те же")
    }

    /// Прогрев: тот же префикс без вопроса и без ответа модели; второй раз —
    /// только когда префикс изменился
    func testOpenAIPrewarmSendsPrefixOnceUntilItChanges() async throws {
        UserDefaults.standard.removeObject(forKey: "chat.warmPrefix.key")
        UserDefaults.standard.removeObject(forKey: "chat.warmPrefix.until")
        let warmed: CloudJSON = ["id": "resp_w", "status": "completed", "output": [],
                                 "usage": ["input_tokens": 2000, "output_tokens": 0,
                                           "input_tokens_details": ["cached_tokens": 0, "cache_write_tokens": 2000,
                                                                    "cache_write_tokens_details": ["ttl_12h_tokens": 1990, "ttl_30m_tokens": 10]]]]
        StubURLProtocol.reset([StubURLProtocol.Reply(status: 200, body: warmed.data), OpenAI.text("Привет!"),
                               StubURLProtocol.Reply(status: 200, body: warmed.data)])
        let chat = engine(.luna)
        chat.genUI = true
        chat.documentIndex = "d1 · passport_ru · Паспорт · Савин И. А. · Паспорта"
        await chat.prewarm()
        await chat.prewarm()
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "префикс уже прогрет")
        XCTAssertEqual(chat.usage.longCacheWriteTokens, 1990)
        _ = try await chat.respond(to: "привет")
        let warm = try body(0), question = try body(1)
        XCTAssertEqual(warm["prompt_cache_options"]?["prewarm"]?.bool, true)
        XCTAssertNil(warm["stream"], "ответа нет — потока тоже")
        XCTAssertEqual(warm["input"]?.array, [try XCTUnwrap(question["input"]?.array?.first)], "только инструкция и опись")
        for key in ["model", "tools", "text", "reasoning", "service_tier"] {
            XCTAssertEqual(warm[key], question[key], "\(key) — как у вопроса, иначе прогрев не пригодится")
        }
        chat.documentIndex += "\nd2 · passport_intl · Загранпаспорт · Савин И. А. · Паспорта"
        await chat.prewarm()
        XCTAssertEqual(StubURLProtocol.requests.count, 3, "опись изменилась — прогрев заново")
    }

    /// Прогрев сам откатывает необязательные поля (summary без верификации
    /// организации) и запоминает это на сессию — первый вопрос идёт без 400
    func testOpenAIPrewarmRelaxesUnsupportedOptionsForFirstQuestion() async throws {
        UserDefaults.standard.removeObject(forKey: "chat.warmPrefix.key")
        UserDefaults.standard.removeObject(forKey: "chat.warmPrefix.until")
        let warmed: CloudJSON = ["id": "resp_w", "status": "completed", "output": []]
        StubURLProtocol.reset([
            OpenAI.error(400, "Your organization must be verified to generate reasoning summaries.", code: "unsupported_value", param: "reasoning.summary"),
            StubURLProtocol.Reply(status: 200, body: warmed.data),
            OpenAI.text("Привет!"),
        ])
        let chat = engine(.luna)
        chat.genUI = true
        chat.documentIndex = "d1 · passport_ru · Паспорт · Савин И. А. · Паспорта"
        await chat.prewarm()
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "прогрев повторил без summary")
        XCTAssertEqual(try body(0)["reasoning"]?["summary"]?.string, "auto")
        XCTAssertNil(try body(1)["reasoning"]?["summary"])

        let reply = try await chat.respond(to: "привет")
        XCTAssertEqual(reply.text, "Привет!")
        XCTAssertEqual(StubURLProtocol.requests.count, 3, "первый вопрос прошёл с первой попытки, без 400")
        XCTAssertNil(try body(2)["reasoning"]?["summary"])
    }

    /// Ответ одной карточкой интерфейса — ответ, а не пустота: в его JSON нет
    /// кириллицы, и прежняя проверка просила модель ответить заново, а та
    /// затирала карточку («Не нашёл, что ответить», 19.11.2026)
    func testInterfaceAnswerWithOnlyCardIsNotEmpty() {
        let card = #"{"version":1,"mode":"ui","text":"","state":[],"computed":[],"blocks":[{"id":"p","type":"app_card","card":{"kind":"fields","document_id":"d1","keys":["full_name"]}}]}"#
        XCTAssertFalse(CloudChatEngine.isEmptyAnswer(card, genUI: true))
        XCTAssertTrue(CloudChatEngine.isEmptyAnswer(#"{"version":1,"mode":"text","text":" ","state":[],"computed":[],"blocks":[]}"#, genUI: true))
        XCTAssertTrue(CloudChatEngine.isEmptyAnswer("", genUI: false))
        XCTAssertTrue(CloudChatEngine.isEmptyAnswer("Done", genUI: false), "ответ по-русски без единой буквы кириллицы — пустой")
        XCTAssertFalse(CloudChatEngine.isEmptyAnswer("Готово", genUI: false))
    }

    func testOpenAIDropsSummaryWhenOrganizationIsNotVerified() async throws {
        StubURLProtocol.reset([
            OpenAI.error(400, "Your organization must be verified to generate reasoning summaries.", code: "unsupported_value", param: "reasoning.summary"),
            OpenAI.text("ок"),
        ])
        let chat = engine(.luna)
        let reply = try await chat.respond(to: "привет")
        XCTAssertEqual(reply.text, "ок")
        XCTAssertEqual(try body(0)["reasoning"]?["summary"]?.string, "auto")
        XCTAssertNil(try body(1)["reasoning"]?["summary"], "повтор — без итогов рассуждения")
    }

    func testOpenAICacheBreakpointFallsBackToInstructions() async throws {
        StubURLProtocol.reset([
            OpenAI.error(400, "Unknown parameter: 'input[0].content[0].prompt_cache_breakpoint'.", code: "unknown_parameter"),
            OpenAI.text("ок"),
        ])
        let reply = try await engine(.luna).respond(to: "привет")
        XCTAssertEqual(reply.text, "ок")
        XCTAssertNotNil(instructions(try body(0)))
        XCTAssertTrue(try body(1)["instructions"]?.string?.hasPrefix(CloudChatPrompt.system) == true, "повтор — прежней инструкцией")
        XCTAssertEqual(conversation(try body(1)).map { $0["type"]?.string ?? $0["role"]?.string }, ["configuration_update", "user"])
    }

    func testOpenAIStreamErrorsMapToCauses() async throws {
        StubURLProtocol.reset([OpenAI.sse([["type": "response.failed", "response": [
            "status": "failed", "error": ["code": "server_error", "message": "The model failed to generate a response."],
        ]]])])
        do {
            _ = try await engine(.luna).respond(to: "привет")
            XCTFail("ждали ошибку")
        } catch {
            XCTAssertEqual(error as? CloudFailure, .overloaded)
        }
        StubURLProtocol.reset([OpenAI.error(401, "Incorrect API key provided", code: "invalid_api_key")])
        do {
            _ = try await engine(.sol).respond(to: "привет")
            XCTFail("ждали ошибку")
        } catch {
            XCTAssertEqual(error as? CloudFailure, .keyRejected)
        }
    }

    // MARK: - Сессия: быстрый путь, опись, сроки, «Стоп»

    /// Сессия с облачным чатом OpenAI по ключу-заглушке
    private func cloudSession(
        reasoning: CloudChatReasoning = .auto,
        silence: Duration = .seconds(20),
        overall: Duration = .seconds(60)
    ) -> (ChatSession, SearchService) {
        let suite = "CloudChatSession-\(UUID().uuidString)"
        let service = "com.ilyaqa.LocalDrive.tests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suite)
            for name in [service, service + ".openai", service + ".gemini"] { Keychain.delete(service: name) }
        }
        let cloud = CloudRecognitionStore(defaults: UserDefaults(suiteName: suite)!, keychainService: service)
        cloud.setKey("k")
        cloud.setChatEnabled(true)
        cloud.setChatReasoning(reasoning)
        let local = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil }, cloud: cloud)
        let session = ChatSession(search: local, cloudSession: StubURLProtocol.session(), cloudTimeout: overall, cloudSilence: silence)
        return (session, local)
    }

    private func finish(_ session: ChatSession) async throws {
        for _ in 0..<500 where session.isAnswering { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.isAnswering)
    }

    /// С облаком на вопрос отвечает агент, а не правила по словам. Владелец
    /// 26.10.2026: правила ответили «Карточками» на «какого числа у ольги день
    /// рождение» — «агенту надо было посмотреть доки, найти паспорт, подумать»
    func testQuestionsGoToAgentWhenCloudIsOn() async throws {
        let (session, local) = cloudSession()
        let id = try await indexPassport(in: local)
        StubURLProtocol.reset([OpenAI.text("Паспорт Ильи — в папке «Паспорта».")])
        session.send("паспорт ильи")
        try await finish(session)
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "вопрос ушёл агенту")
        let answer = try XCTUnwrap(session.messages.last)
        XCTAssertEqual(answer.text, "Паспорт Ильи — в папке «Паспорта».")
        // Агент видит опись: найдёт паспорт сам
        let instructions = try XCTUnwrap(self.instructions(try body(0)))
        XCTAssertTrue(instructions.contains("d\(id) — "), instructions)

        // Облако не ответило — правила его не подменяют: причина и «Повторить»
        // (чат только облачный, владелец 19.11.2026)
        StubURLProtocol.reset([OpenAI.error(500, "Internal error", code: "server_error")])
        session.send("паспорт ильи")
        try await finish(session)
        let failed = try XCTUnwrap(session.messages.last)
        XCTAssertFalse(failed.cards.contains { card in
            if case .fields(let document, _) = card.card { document == id } else { false }
        }, "полей от правил нет: \(failed.text)")
        XCTAssertNotNil(failed.notice)
        XCTAssertTrue(failed.cards.contains { if case .clarify = $0.card { true } else { false } }, "есть «Повторить»")
    }

    func testDeepThinkingAndOpenQuestionsGoToCloud() async throws {
        let (session, local) = cloudSession(reasoning: .deep)
        _ = try await indexPassport(in: local)
        StubURLProtocol.reset([OpenAI.text("Подумал.")])
        session.send("паспорт ильи")
        try await finish(session)
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "«Подумать» — всегда облако")
        XCTAssertEqual(session.messages.last?.text, "Подумал.")
        XCTAssertEqual(effort(try body(0)), "high")

        let (open, openSearch) = cloudSession()
        let id = try await indexPassport(in: openSearch)
        StubURLProtocol.reset([OpenAI.text("Сравнил.")])
        open.send("сравни мои документы")
        try await finish(open)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        let instructions = try XCTUnwrap(self.instructions(try body(0)))
        XCTAssertTrue(instructions.contains("d\(id) — ") && instructions.contains("(passport_ru)"), instructions)
        XCTAssertTrue(instructions.contains("владелец: Савин Илья Андреевич"),
                      "владелец — полным именем: «Ольга» находится по описи, без поиска (19.11.2026)")
        for number in ["4601", "123456", "770-120"] {
            XCTAssertFalse(instructions.contains(number), "в описи нет номеров: \(number)")
        }
    }

    func testConfidenceRules() {
        let fields = ChatReply(text: "", cards: [.fields(documentID: 1, keys: ["full_name"]), .document(documentID: 1)])
        XCTAssertTrue(ChatSession.isConfidentLookup("паспорт ильи", reply: fields))
        let spreads = ChatReply(text: "", cards: [.fields(documentID: 1, keys: ["full_name"]), .fields(documentID: 1, keys: ["issued_by"]),
                                                  .fileList(documentIDs: [1, 2])])
        XCTAssertTrue(ChatSession.isConfidentLookup("паспорт", reply: spreads), "развороты одного паспорта")
        let more = ChatReply(text: "", cards: [.fields(documentID: 1, keys: ["full_name"]),
                                               .clarify(question: "Ещё есть:", options: [ClarifyOption(title: "Загранпаспорт", query: "загран")])])
        XCTAssertTrue(ChatSession.isConfidentLookup("паспорт", reply: more), "чип «Ещё есть:» не делает ответ неуверенным")
        let which = ChatReply(text: "", cards: [.clarify(question: nil, options: [ClarifyOption(title: "Савин", query: "паспорт савина")])])
        XCTAssertFalse(ChatSession.isConfidentLookup("паспорт", reply: which))
        let two = ChatReply(text: "", cards: [.fields(documentID: 1, keys: ["full_name"]), .fields(documentID: 2, keys: ["full_name"])])
        XCTAssertFalse(ChatSession.isConfidentLookup("паспорт", reply: two), "два человека — пусть решает облако")
        XCTAssertFalse(ChatSession.isConfidentLookup("договор аренды", reply: fields), "не личный документ")
        XCTAssertFalse(ChatSession.isConfidentLookup("паспорт", reply: ChatReply(text: "Не нашёл.", cards: [])))
    }

    func testComplexMessageHeuristic() {
        XCTAssertFalse(CloudChatReasoning.isComplex("паспорт ильи"))
        XCTAssertFalse(CloudChatReasoning.isComplex("когда истекает загран"))
        XCTAssertTrue(CloudChatReasoning.isComplex("Сравни сроки моих паспортов"))
        XCTAssertTrue(CloudChatReasoning.isComplex("посчитай расходы по чекам"))
        XCTAssertTrue(CloudChatReasoning.isComplex("разложи файлы по папкам"))
        XCTAssertTrue(CloudChatReasoning.isComplex(String(repeating: "а ", count: 90)), "длинный вопрос")
    }

    func testNoticeNamesTheCause() {
        XCTAssertEqual(ChatSession.notice(for: CloudChatTimeout(seconds: 90)), "Облако не ответило за 90 с")
        XCTAssertEqual(ChatSession.notice(for: CloudFailure.regionUnavailable), "Облако недоступно — проверьте VPN")
        XCTAssertEqual(ChatSession.notice(for: CloudFailure.network), "Облако недоступно — проверьте VPN")
        XCTAssertEqual(ChatSession.notice(for: CloudFailure.keyRejected), "Ключ не подошёл")
        XCTAssertEqual(ChatSession.notice(for: CloudFailure.quotaExceeded), "На счёте облака кончились деньги")
        XCTAssertEqual(ChatSession.notice(for: CloudFailure.badResponse), "Облако недоступно")
    }

    /// Облако молчит дольше обычного — ответ не обрывается: в ленте строка
    /// «отвечает дольше обычного», а ответ облака приходит и показывается
    func testSilentCloudKeepsWaitingAndSaysSo() async throws {
        let (session, _) = cloudSession(silence: .milliseconds(300))
        StubURLProtocol.reset([OpenAI.stalling([], then: [OpenAI.textDelta("поздно"), OpenAI.completed([OpenAI.message("поздно")])], after: 1.5)])
        session.send("мой паспорт")
        try await finish(session)
        let answer = try XCTUnwrap(session.messages.last)
        XCTAssertNil(answer.notice)
        XCTAssertEqual(answer.text, "поздно", "ответ облака, а не правил")
        XCTAssertTrue(answer.steps.contains { $0.text == "Облако отвечает дольше обычного — жду" }, "\(answer.steps.map(\.text))")
    }

    func testOverallDeadlineKeepsStreamedText() async throws {
        // Запас по времени: тест не должен зависеть от нагрузки на машину
        let (session, _) = cloudSession(silence: .seconds(8), overall: .milliseconds(1500))
        StubURLProtocol.reset([OpenAI.stalling([OpenAI.textDelta("Начинаю ответ")], then: [OpenAI.textDelta(" и заканчиваю")], after: 6)])
        session.send("мой паспорт")
        try await finish(session)
        let answer = try XCTUnwrap(session.messages.last)
        XCTAssertEqual(answer.text, "Начинаю ответ", "начатый текст не стирается ответом правил")
        XCTAssertEqual(answer.notice, "Облако думало дольше 2 с — ответ неполный")
    }

    func testStopKeepsWhatArrived() async throws {
        let (session, _) = cloudSession()
        StubURLProtocol.reset([OpenAI.stalling([OpenAI.textDelta("Часть ответа")], then: [OpenAI.textDelta(" и остальное")], after: 5)])
        session.send("мой паспорт")
        for _ in 0..<300 where session.messages.last?.text.isEmpty != false { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.answeringInCloud, "пока отвечает облако — кнопка «Стоп»")
        session.stop()
        try await finish(session)
        let answer = try XCTUnwrap(session.messages.last)
        XCTAssertEqual(answer.text, "Часть ответа")
        XCTAssertNil(answer.notice)
        XCTAssertFalse(session.answeringInCloud)
    }

    func testDocumentIndexHidesNumbersAndHiddenFolders() async throws {
        let id = try await indexPassport()
        store.importData(Data("ДОГОВОР АРЕНДЫ".utf8), preferredName: "договор 1234567.txt", to: try folder("Дом"))
        store.importData(Data(passport.utf8), preferredName: "тайный паспорт.txt", to: try folder("Тайное", hidden: true))
        search.reconcile()
        await search.waitUntilIdle()
        let index = await search.chatDocumentIndex()
        let lines = index.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, index)
        XCTAssertTrue(lines.first?.hasPrefix("d\(id) · passport_ru") == true, index)
        XCTAssertTrue(index.contains("Савин И. А."))
        XCTAssertTrue(index.contains("договор …"), "цифры названия закрыты")
        XCTAssertFalse(index.contains("1234567"))
        XCTAssertFalse(index.contains("Тайное"))
        XCTAssertFalse(index.contains("тайный"))
    }
}

// MARK: - Метаданные

@MainActor
final class DocumentMetadataTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!

    override func setUp() async throws {
        StubURLProtocol.reset()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = VaultStore(rootURL: root.appendingPathComponent("Vault"))
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        store = nil
    }

    private static let contractReply: StubURLProtocol.Reply = {
        let page: CloudJSON = [
            "type": "other", "country": "", "surname": "", "given_name": "", "patronymic": "", "birth_date": "", "issue_date": "",
            "expiry_date": "", "number": "", "department_code": "", "issued_by": "", "birth_place": "", "sex": "", "text": "",
            "meta": [
                "title": "Трудовой договор с ООО «Ромашка»", "summary": "Договор о приёме на работу.", "category": "work",
                "kind": "трудовой договор", "document_date": "01.02.2024", "valid_until": "31.12.2026",
                "people": [["name": "Петров Иван", "role": "работник"]], "organizations": ["ООО «Ромашка»"],
                "identifiers": [["label": "Номер договора", "value": "77-1234567"]],
                "amounts": [["label": "Оклад", "value": "120000", "currency": "RUB"]],
                "tags": ["работа", "договор"], "language": "ru",
            ],
        ]
        let body: CloudJSON = ["candidates": [["content": ["parts": [["text": .string(String(data: page.data, encoding: .utf8)!)]]]]]]
        return StubURLProtocol.Reply(status: 200, body: body.data)
    }()

    private func service(cloudPages: @escaping @Sendable (URL) -> [CloudPage]? = { _ in nil }) -> SearchService {
        let reader = CloudDocumentReader(
            configuration: CloudConfiguration(provider: .gemini, model: "gemini-3.8-flash", baseURL: CloudProvider.gemini.defaultBaseURL, apiKey: "k"),
            session: StubURLProtocol.session(), sleep: { _ in }
        )
        return SearchService(store: store, databaseURL: nil, pageImage: { _ in nil }, cloudReader: reader, cloudPages: cloudPages)
    }

    func testTextDocumentGetsMetadataFromTextOnlyRequest() async throws {
        StubURLProtocol.reset([Self.contractReply])
        let search = service()
        store.createFolder(name: "Работа", icon: "folder.fill", color: "indigo")
        let work = try XCTUnwrap(store.folders.last)
        store.importData(Data("ТРУДОВОЙ ДОГОВОР\nработник обязуется".utf8), preferredName: "договор.txt", to: work)
        search.reconcile()
        await search.waitUntilIdle()

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        let sent = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertFalse(sent.contains("inline_data"), "текстовый файл уходит текстом, без картинки")
        XCTAssertTrue(sent.contains("работник обязуется"))

        let file = try XCTUnwrap(store.files(in: work).first)
        let meta = await search.metadata(for: file, in: work)
        XCTAssertEqual(meta?.title, "Трудовой договор с ООО «Ромашка»")
        XCTAssertEqual(meta?.category, "work")
        XCTAssertEqual(meta?.validUntil, "31.12.2026")

        // Поиск находит документ по организации из метаданных
        let found = await search.search("ромашка")
        XCTAssertEqual(found.first?.file.name, "договор.txt")
    }

    /// Опись для облака: сведения из метаданных — чтобы ответить без поиска;
    /// идентификаторы — никогда. Модели на iPhone — короткая опись
    func testDetailedIndexHasMetadataButNoIdentifiers() async throws {
        StubURLProtocol.reset([Self.contractReply])
        let search = service()
        store.createFolder(name: "Работа", icon: "folder.fill", color: "indigo")
        store.importData(Data("ТРУДОВОЙ ДОГОВОР\nработник обязуется".utf8), preferredName: "договор.txt", to: try XCTUnwrap(store.folders.last))
        search.reconcile()
        await search.waitUntilIdle()

        let index = await search.chatDocumentIndex(details: true)
        for part in ["от 01.02.2024", "до 31.12.2026", "кратко: Договор о приёме на работу.", "люди: Петров Иван — работник",
                     "организации: ООО «Ромашка»", "суммы: Оклад 120 000 RUB", "теги: работа, договор"] {
            XCTAssertTrue(index.contains(part), "\(part) — \(index)")
        }
        XCTAssertFalse(index.contains("1234567"), "номер договора — только маской через инструменты")
        let labeled = LocalAgentPrompt.labeled(index, withType: true)
        XCTAssertTrue(labeled.contains("; действует до 31.12.2026; от 01.02.2024; кратко:"), labeled)
        let short = await search.chatDocumentIndex()
        XCTAssertFalse(short.contains("кратко:"), "модели на iPhone — короткая опись")
    }

    func testIdentifiersAreMaskedInChatText() async throws {
        StubURLProtocol.reset([Self.contractReply])
        let search = service()
        store.createFolder(name: "Работа", icon: "folder.fill", color: "indigo")
        store.importData(Data("ТРУДОВОЙ ДОГОВОР".utf8), preferredName: "договор.txt", to: try XCTUnwrap(store.folders.last))
        search.reconcile()
        await search.waitUntilIdle()
        let documents = await search.documents(ofTypes: DocumentType.allCases)
        let id = try XCTUnwrap(documents.first?.id)

        StubURLProtocol.reset([
            Gemini.call("get_document", ["id": .string("d\(id)")], id: "c1", signature: "s"),
            Gemini.text("Номер договора 77-1234567."),
        ])
        let engine = CloudChatEngine(
            configuration: .init(baseURL: CloudProvider.gemini.defaultBaseURL, apiKey: "k", model: .flash, reasoning: .auto),
            search: search, session: StubURLProtocol.session()
        )
        let reply = try await engine.respond(to: "номер договора")
        XCTAssertFalse(reply.text.contains("1234567"), reply.text)
        let sent = String(data: try XCTUnwrap(StubURLProtocol.requests[1].httpBody), encoding: .utf8) ?? ""
        XCTAssertFalse(sent.contains("77-1234567"), "идентификатор уходит модели маской")
        XCTAssertTrue(sent.contains("Трудовой договор с ООО"))
    }

    func testMigrationFrom3To4KeepsDocuments() throws {
        let url = root.appendingPathComponent("index.sqlite")
        var store: SearchIndexStore? = try SearchIndexStore(url: url)
        let record = DocumentRecord(folderID: UUID(), fileName: "a.txt", type: .other, title: "a", pageCount: 1,
                                    fileSize: 1, fileModified: 1, failed: false, chunks: [], fields: [])
        try store?.save(record, indexVersion: 3)
        store?.close()
        store = nil
        // Снимаем таблицу метаданных и номер схемы — так выглядела база версии 3
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "DROP TABLE document_meta; PRAGMA user_version = 3;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let migrated = try SearchIndexStore(url: url)
        XCTAssertEqual(try migrated.fileStates().count, 1, "документы после перехода на схему 4 на месте")
        XCTAssertEqual(try migrated.metadata(documentIDs: [1]), [:])
    }
}
