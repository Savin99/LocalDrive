import XCTest
@testable import LocalDrive

// Ответ облачного чата интерфейсом (docs/genui.md) без сети: запросы уходят
// в заглушку, ответы — в формате схемы, как их присылает модель. Данные
// синтетические: те же Савин и «Ромашка», что в других тестах

/// Ответ Responses API потоком: один JSON интерфейса дельтами
private enum Interface {
    static let stream = ["Content-Type": "text/event-stream"]

    static func events(_ json: String, pieces: Int = 4) -> [CloudJSON] {
        let size = max(1, json.count / pieces)
        let deltas = stride(from: 0, to: json.count, by: size).map { start -> CloudJSON in
            ["type": "response.output_text.delta", "item_id": "msg_1", "output_index": 0, "content_index": 0,
             "delta": .string(String(json.dropFirst(start).prefix(size)))]
        }
        let message: CloudJSON = ["id": "msg_1", "type": "message", "role": "assistant", "status": "completed",
                                  "content": [["type": "output_text", "text": .string(json), "annotations": []]]]
        return deltas + [
            ["type": "response.output_item.done", "output_index": 0, "item": message],
            ["type": "response.completed", "response": ["id": "resp_1", "status": "completed", "output": [message]]],
        ]
    }

    static func lines(_ events: [CloudJSON]) -> Data {
        Data(events.map { "event: \($0["type"]?.string ?? "")\ndata: " + String(data: $0.data, encoding: .utf8)! + "\n\n" }.joined().utf8)
    }

    static func answer(_ json: String) -> StubURLProtocol.Reply {
        StubURLProtocol.Reply(status: 200, body: lines(events(json)), headers: stream)
    }

    /// Поток стоит после первых `split` знаков
    static func stalling(_ json: String, split: Int, delay: TimeInterval) -> StubURLProtocol.Reply {
        let all = events(json, pieces: 1)
        let first: CloudJSON = ["type": "response.output_text.delta", "item_id": "msg_1", "output_index": 0, "content_index": 0,
                                "delta": .string(String(json.prefix(split)))]
        let rest: CloudJSON = ["type": "response.output_text.delta", "item_id": "msg_1", "output_index": 0, "content_index": 0,
                               "delta": .string(String(json.dropFirst(split)))]
        return StubURLProtocol.Reply(status: 200, body: Data(), headers: stream,
                                     parts: [(0, lines([first])), (delay, lines([rest] + all.suffix(2)))])
    }
}

@MainActor
final class GenUIChatTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!

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
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GenUIChat-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        store = nil
    }

    private func folder(_ name: String, hidden: Bool = false) throws -> VaultFolder {
        store.createFolder(name: name, icon: "folder.fill", color: "indigo", isSuperHidden: hidden)
        return try XCTUnwrap(store.folders.last)
    }

    private func body(_ index: Int) throws -> CloudJSON {
        try XCTUnwrap(CloudJSON.parse(XCTUnwrap(StubURLProtocol.requests[index].httpBody)))
    }

    /// Сессия с облачным чатом OpenAI по ключу-заглушке
    private func session(search: SearchService? = nil) -> (ChatSession, SearchService) {
        let suite = "GenUIChat-\(UUID().uuidString)"
        let service = "com.ilyaqa.LocalDrive.tests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suite)
            for name in [service, service + ".openai", service + ".gemini"] { Keychain.delete(service: name) }
        }
        let cloud = CloudRecognitionStore(defaults: UserDefaults(suiteName: suite)!, keychainService: service)
        cloud.setKey("k")
        cloud.setChatEnabled(true)
        let local = search ?? SearchService(store: store, databaseURL: nil, pageImage: { _ in nil }, cloud: cloud)
        return (ChatSession(search: local, cloudSession: StubURLProtocol.session()), local)
    }

    private func finish(_ session: ChatSession) async throws {
        for _ in 0..<500 where session.isAnswering { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.isAnswering)
    }

    private func indexPassport(_ search: SearchService) async throws -> Int64 {
        store.importData(Data(passport.utf8), preferredName: "паспорт.txt", to: try folder("Паспорта"))
        search.reconcile()
        await search.waitUntilIdle()
        // XCTUnwrap принимает автозамыкание без поддержки await
        let passports = await search.documents(ofTypes: [.passportRU])
        return try XCTUnwrap(passports.first?.id)
    }

    // MARK: - Запрос

    func testRequestAsksForStrictInterfaceAndDropsShowCards() async throws {
        StubURLProtocol.reset([Interface.answer(#"{"version":1,"mode":"text","text":"Привет!","state":[],"computed":[],"blocks":[]}"#)])
        let search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil })
        let engine = CloudChatEngine(configuration: .init(provider: .openAI, baseURL: CloudProvider.openAI.defaultBaseURL, apiKey: "k",
                                                          model: .luna, reasoning: .auto),
                                     search: search, session: StubURLProtocol.session())
        engine.genUI = true
        var deltas = ""
        let reply = try await engine.respond(to: "привет") { event in
            if case .answerDelta(let delta) = event { deltas += delta }
            if case .text = event { XCTFail("ответ интерфейсом не идёт текстом") }
        }
        XCTAssertEqual(deltas, reply.text, "JSON — как есть, без маски")

        let raw = try XCTUnwrap(String(data: XCTUnwrap(StubURLProtocol.requests.first?.httpBody), encoding: .utf8))
        XCTAssertTrue(raw.contains(GenUIJSONSchema.openAIStrictString), "схема вставлена строкой — с порядком ключей")
        let json = try body(0)
        let format = try XCTUnwrap(json["text"]?["format"])
        XCTAssertEqual(format["type"]?.string, "json_schema")
        XCTAssertEqual(format["name"]?.string, CloudChatGenUI.schemaName)
        XCTAssertEqual(format["strict"]?.bool, true)
        XCTAssertNotNil(format["schema"]?["$defs"])
        let tools = Set(json["tools"]?.array?.compactMap { $0["name"]?.string } ?? [])
        XCTAssertFalse(tools.contains("show_cards"), "карточки документов — блоки app_card")
        XCTAssertTrue(tools.contains("propose_file_actions"))
        let instructions = try XCTUnwrap(json["input"]?.array?.first { $0["role"]?.string == "developer" }?["content"]?.array?.first?["text"]?.string)
        XCTAssertTrue(instructions.contains("app_card"))
        XCTAssertFalse(instructions.contains("show_cards"))
    }

    // MARK: - Сессия

    func testInterfaceAnswerStreamsIntoMessage() async throws {
        let (chat, search) = session()
        let id = try await indexPassport(search)
        let answer = #"{"version":1,"mode":"mixed","text":"Вот паспорт и сколько у вас документов:","state":[],"computed":[],"blocks":["#
            + #"{"id":"card","type":"app_card","visible_if":null,"card":{"kind":"fields","document_id":"d\#(id)","document_ids":null,"keys":["full_name"],"page":null}},"#
            + #"{"id":"total","type":"metric","visible_if":null,"label":"Документов","value":null,"format":"integer","unit":null,"caption":null,"trend":null,"source":{"kind":"documents","types":null,"categories":null,"folder_id":null,"owner":null,"query":null,"columns":null},"aggregate":{"op":"count","column":null}}]}"#
        let split = try XCTUnwrap(answer.range(of: #""page":null}},"#)).upperBound.utf16Offset(in: answer)
        StubURLProtocol.reset([Interface.stalling(answer, split: split, delay: 0.6)])
        // Без вида документа в вопросе: быстрый путь правил не сработает
        chat.send("сколько у меня документов")

        // Первый блок закрыт — уже виден, пока поток стоит
        for _ in 0..<300 where chat.messages.last?.genui?.blocks.isEmpty != false { try await Task.sleep(for: .milliseconds(10)) }
        let streaming = try XCTUnwrap(chat.messages.last)
        XCTAssertTrue(streaming.isPending)
        XCTAssertEqual(streaming.genui?.blocks.map(\.id), ["card"])
        XCTAssertEqual(streaming.text, "Вот паспорт и сколько у вас документов:")

        try await finish(chat)
        let message = try XCTUnwrap(chat.messages.last)
        let genui = try XCTUnwrap(message.genui)
        XCTAssertEqual(genui.phase, .finished)
        XCTAssertEqual(genui.blocks.map(\.id), ["card", "total"])
        XCTAssertEqual(genui.mode, .mixed)
        XCTAssertTrue(genui.issues.isEmpty, "\(genui.issues)")
        XCTAssertNotNil(message.genuiPerformer)
        XCTAssertEqual(message.text, "Вот паспорт и сколько у вас документов:")
        XCTAssertNil(message.notice)
    }

    func testPerformerActions() async throws {
        let (chat, search) = session()
        let id = try await indexPassport(search)
        var sent: [String] = []
        chat.useGenUIHooks(GenUIChatHooks(
            send: { sent.append($0) }, open: { _ in }, copy: { _, _ in true },
            remind: { _, _ in "Напомню" }, confirm: { _ in false }
        ))
        let answer = #"{"version":1,"mode":"ui","text":"","state":[{"name":"days","value":10}],"computed":[],"blocks":[{"id":"days","type":"slider","visible_if":null,"label":"Дней","bind":"days","min":1,"max":60,"step":1,"format":"integer"}]}"#
        StubURLProtocol.reset([Interface.answer(answer)])
        chat.send("сравни мои документы")
        try await finish(chat)
        let message = try XCTUnwrap(chat.messages.last)
        let performer = try XCTUnwrap(message.genuiPerformer)
        let state = try XCTUnwrap(message.genui?.state)

        let ask = try GenUITemplate(parsing: "Что взять на {{ days }} дней?")
        _ = await performer.perform(.ask(text: ask), block: "b", state: state.snapshot())
        XCTAssertEqual(sent.last, "Что взять на 10 дней?", "вопрос — с подстановкой состояния")
        _ = await performer.perform(.submit(include: nil, message: GenUITemplate(text: "Готово")), block: "b", state: state.snapshot())
        XCTAssertEqual(sent.last, "Готово\ndays: 10", "значения формы — следующим сообщением")

        _ = await performer.perform(.showFields(documentID: id, keys: ["full_name"]), block: "b", state: state.snapshot())
        XCTAssertEqual(chat.messages.last?.cards.map(\.card), [.fields(documentID: id, keys: ["full_name"])])
        let folderID = try XCTUnwrap(store.folders.first?.id)
        _ = await performer.perform(.openFolder(folderID: folderID), block: "b", state: state.snapshot())
        XCTAssertEqual(chat.messages.last?.cards.last?.card, .fileList(documentIDs: [id]), "папка — карточкой её документов")

        let refused = await performer.perform(.remind(documentID: id), block: "b", state: state.snapshot())
        XCTAssertNotEqual(refused, .done("Напомню"), "без подтверждения напоминания нет")

        // Перестройка блока: модель присылает блок с тем же id
        let rebuilt = #"{"version":1,"mode":"ui","text":"","state":[],"computed":[],"blocks":[{"id":"days","type":"slider","visible_if":null,"label":"Ночей","bind":"days","min":1,"max":30,"step":1,"format":"integer"}]}"#
        StubURLProtocol.reset([Interface.answer(rebuilt)])
        let outcome = await performer.perform(.regenerate(blockID: "days", instruction: "в ночах"), block: "days", state: state.snapshot())
        XCTAssertEqual(outcome, .done(nil))
        XCTAssertEqual(message.genui?.blocks.first?.raw["label"]?.string, "Ночей")
        let request = try XCTUnwrap(body(0)["input"]?.array?.last?["content"]?.array?.first?["text"]?.string)
        XCTAssertTrue(request.contains("days: 10"), "модель видит значения состояния")
        XCTAssertTrue(request.contains("в ночах"))
    }

    // MARK: - Данные из индекса

    /// Ответ облачного распознавания с метаданными — для синтетического индекса
    private static func recognized(type: String = "other", surname: String = "", given: String = "", patronymic: String = "",
                                   number: String = "", meta: CloudJSON) -> StubURLProtocol.Reply {
        let page: CloudJSON = [
            "type": .string(type), "country": "", "surname": .string(surname), "given_name": .string(given),
            "patronymic": .string(patronymic), "birth_date": "", "issue_date": "", "expiry_date": "", "number": .string(number),
            "department_code": "", "issued_by": "", "birth_place": "", "sex": "", "text": "", "meta": meta,
        ]
        let body: CloudJSON = ["candidates": [["content": ["parts": [["text": .string(String(data: page.data, encoding: .utf8)!)]]]]]]
        return StubURLProtocol.Reply(status: 200, body: body.data)
    }

    private static func meta(title: String, category: String, kind: String, date: String, until: String = "",
                             amounts: [CloudJSON] = [], identifiers: [CloudJSON] = []) -> CloudJSON {
        ["title": .string(title), "summary": "", "category": .string(category), "kind": .string(kind),
         "document_date": .string(date), "valid_until": .string(until), "people": [], "organizations": [],
         "identifiers": .array(identifiers), "amounts": .array(amounts), "tags": [], "language": "ru"]
    }

    private func indexedVault() async throws -> (SearchService, contract: Int64, receipt: Int64, passport: Int64) {
        let reader = CloudDocumentReader(
            configuration: CloudConfiguration(provider: .gemini, model: "gemini-3.8-flash", baseURL: CloudProvider.gemini.defaultBaseURL, apiKey: "k"),
            session: StubURLProtocol.session(), sleep: { _ in }
        )
        let search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil }, cloudReader: reader, cloudPages: { _ in nil })
        func add(_ text: String, name: String, to folder: VaultFolder, reply: StubURLProtocol.Reply) async {
            StubURLProtocol.reset([reply])
            store.importData(Data(text.utf8), preferredName: name, to: folder)
            search.reconcile()
            await search.waitUntilIdle()
        }
        await add("ТРУДОВОЙ ДОГОВОР 77-1234567", name: "договор 1234567.txt", to: try folder("Работа"), reply: Self.recognized(meta: Self.meta(
            title: "Трудовой договор № 77-1234567", category: "work", kind: "трудовой договор", date: "01.02.2024", until: "31.12.2026",
            amounts: [["label": "Оклад", "value": "120 000", "currency": "RUB"]],
            identifiers: [["label": "Номер договора", "value": "77-1234567"]])))
        await add("КАССОВЫЙ ЧЕК", name: "чек.txt", to: try folder("Чеки"), reply: Self.recognized(meta: Self.meta(
            title: "Чек из «Пятёрочки»", category: "receipt", kind: "кассовый чек", date: "05.03.2026",
            amounts: [["label": "Итого", "value": "1 500,50", "currency": "RUB"]])))
        await add(passport, name: "паспорт.txt", to: try folder("Паспорта"), reply: Self.recognized(
            type: "passport_ru", surname: "САВИН", given: "ИЛЬЯ", patronymic: "АНДРЕЕВИЧ", number: "4601 123456",
            meta: Self.meta(title: "Паспорт РФ", category: "identity", kind: "паспорт", date: "")))
        store.importData(Data("ТАЙНЫЙ ДОГОВОР".utf8), preferredName: "тайное.txt", to: try folder("Тайное", hidden: true))
        search.reconcile()
        await search.waitUntilIdle()
        let all = await search.documents(ofTypes: DocumentType.allCases)
        let fields = await search.fields(for: all.map(\.id))
        let metadata = await search.metadata(for: all.map(\.id))
        func id(_ title: String) throws -> Int64 { try XCTUnwrap(all.first { metadata[$0.id]?.title == title }?.id, title) }
        let passportID = try XCTUnwrap(all.first { $0.type == .passportRU }?.id)
        XCTAssertNotNil(fields[passportID])
        return (search, try id("Трудовой договор № 77-1234567"), try id("Чек из «Пятёрочки»"), passportID)
    }

    func testDataSourcesComeFromIndexWithoutNumbers() async throws {
        let (search, contract, receipt, passport) = try await indexedVault()
        let today = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 12, hour: 12).date!
        let provider = GenUIIndexDataProvider(search: search, today: { today })

        let documents = try await provider.rows(for: GenUIDataSource(kind: .documents))
        XCTAssertEqual(documents.rows.count, 3, "скрытая папка не видна")
        XCTAssertEqual(documents.columns, GenUIDataSourceSpec.documentColumns)
        let contractRow = try XCTUnwrap(documents.rows.first { $0["id"] == .string("d\(contract)") })
        XCTAssertEqual(contractRow["title"], .string("Трудовой договор № 77-…"), "длинные цифры в названии закрыты")
        XCTAssertEqual(contractRow["category"], .string("Работа"))
        XCTAssertEqual(contractRow["document_date"], .date(GenUIDay(year: 2024, month: 2, day: 1)!))
        XCTAssertEqual(contractRow["valid_until"], .date(GenUIDay(year: 2026, month: 12, day: 31)!))
        let flat = "\(documents.rows)"
        XCTAssertFalse(flat.contains("1234567"))
        XCTAssertFalse(flat.contains("123456"))

        var receipts = GenUIDataSource(kind: .documents)
        receipts.categories = ["receipt"]
        receipts.columns = ["title", "number"]
        let onlyReceipts = try await provider.rows(for: receipts)
        XCTAssertEqual(onlyReceipts.rows.map { $0["title"] }, [.string("Чек из «Пятёрочки»")])
        XCTAssertEqual(onlyReceipts.columns, ["title"], "колонки не из списка отбрасываются")

        var count = GenUIDataSource(kind: .documentStats)
        count.groupBy = "category"
        count.metric = "count"
        let byCategory = try await provider.rows(for: count)
        XCTAssertEqual(Set(byCategory.rows.compactMap { $0["key"]?.string }), ["Работа", "Чек или квитанция", "Удостоверение личности"])

        var sums = GenUIDataSource(kind: .documentStats)
        sums.groupBy = "category"
        sums.metric = "amount_sum"
        sums.currency = "rub"
        let totals = try await provider.rows(for: sums)
        XCTAssertEqual(totals.rows.first?["key"], .string("Работа"))
        XCTAssertEqual(totals.rows.first?["value"], .number(120_000))
        XCTAssertEqual(totals.rows.last?["value"], .number(1500.5))

        let amounts = try await provider.rows(for: GenUIDataSource(kind: .amounts))
        XCTAssertEqual(amounts.rows.map { $0["document_id"] }, [.string("d\(contract)"), .string("d\(receipt)")], "по дате документа")

        var soon = GenUIDataSource(kind: .expiring)
        soon.withinDays = 120
        let expiring = try await provider.rows(for: soon)
        XCTAssertEqual(expiring.rows.first?["id"], .string("d\(contract)"))
        XCTAssertEqual(expiring.rows.first?["days_left"], .number(80))

        var fields = GenUIDataSource(kind: .fields)
        fields.documentID = passport
        fields.keys = [FieldKey.fullName, FieldKey.seriesNumber]
        let values = try await provider.rows(for: fields)
        let series = try XCTUnwrap(values.rows.first { $0["key"] == .string(FieldKey.seriesNumber) }?["value"]?.string)
        XCTAssertEqual(series, "•••• ••••56", "серия и номер — маской")
        XCTAssertEqual(values.rows.first?["value"], .string("Савин Илья Андреевич"))
    }
}
