import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LocalDrive

// Чей «мой паспорт» и «зайти посмотреть» документ (жалобы владельца
// 13.10.2026) — без сети: распознавание — заглушкой, облачный чат выключен,
// отвечают правила. Данные синтетические: два человека и страница прописки
@MainActor
final class ChatOwnerTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!

    override func setUp() async throws {
        StubURLProtocol.reset()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatOwner-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        search = nil
        store = nil
    }

    private static func page(type: String, surname: String = "", given: String = "", patronymic: String = "",
                             number: String = "", birth: String = "") -> StubURLProtocol.Reply {
        let page: CloudJSON = [
            "type": .string(type), "country": "", "surname": .string(surname), "given_name": .string(given),
            "patronymic": .string(patronymic), "birth_date": .string(birth), "issue_date": "", "expiry_date": "",
            "number": .string(number), "department_code": "", "issued_by": "", "birth_place": "", "sex": "", "text": "",
            "meta": ["title": "", "summary": "", "category": "identity", "kind": "", "document_date": "", "valid_until": "",
                     "people": [], "organizations": [], "identifiers": [], "amounts": [], "tags": [], "language": "ru"],
        ]
        let body: CloudJSON = ["candidates": [["content": ["parts": [["text": .string(String(data: page.data, encoding: .utf8)!)]]]]]]
        return StubURLProtocol.Reply(status: 200, body: body.data)
    }

    /// Паспорта Савина и Трошиной в разных папках и страница прописки Савина
    private func vault() async throws -> (savin: Int64, troshina: Int64, registration: Int64) {
        let reader = CloudDocumentReader(
            configuration: CloudConfiguration(provider: .gemini, model: "gemini-3.8-flash", baseURL: CloudProvider.gemini.defaultBaseURL, apiKey: "stub"),
            session: StubURLProtocol.session(), sleep: { _ in }
        )
        search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil }, cloudReader: reader, cloudPages: { _ in nil })
        func folder(_ name: String) -> VaultFolder {
            store.createFolder(name: name, icon: "folder.fill", color: "indigo")
            return store.folders.last!
        }
        let ilya = folder("Илья"), olga = folder("Ольга")
        let documents: [(String, String, VaultFolder, StubURLProtocol.Reply)] = [
            ("ПАСПОРТ САВИН ИЛЬЯ", "паспорт Ильи.txt", ilya,
             Self.page(type: "passport_ru", surname: "САВИН", given: "ИЛЬЯ", patronymic: "АНДРЕЕВИЧ", number: "4601 123456", birth: "01.01.1990")),
            ("МЕСТО ЖИТЕЛЬСТВА\nЗарегистрирован г. Тверь, ул. Советская, д. 5", "паспорт Ильи стр 5.txt", ilya, Self.page(type: "passport_ru")),
            ("ПАСПОРТ ТРОШИНА ОЛЬГА", "паспорт Ольги.txt", olga,
             Self.page(type: "passport_ru", surname: "ТРОШИНА", given: "ОЛЬГА", patronymic: "ПЕТРОВНА", number: "4602 654321", birth: "02.02.1992")),
        ]
        for (text, name, target, reply) in documents {
            StubURLProtocol.reset([reply])
            store.importData(Data(text.utf8), preferredName: name, to: target)
            search.reconcile()
            await search.waitUntilIdle()
        }
        let all = await search.documents(ofTypes: DocumentType.allCases)
        let fields = await search.fields(for: all.map(\.id))
        func id(_ surname: String) throws -> Int64 {
            try XCTUnwrap(all.first { fields[$0.id]?.contains { $0.key == FieldKey.fullName && $0.value.hasPrefix(surname) } == true }?.id, surname)
        }
        let registration = try XCTUnwrap(all.first { $0.fileName.contains("стр 5") }?.id)
        return (try id("Савин"), try id("Трошина"), registration)
    }

    private func finish(_ session: ChatSession) async throws {
        for _ in 0..<500 where session.isAnswering { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.isAnswering)
    }

    private func fieldsCard(_ message: ChatSession.Message?) -> (id: Int64, keys: [String])? {
        for card in message?.cards ?? [] {
            if case .fields(let id, let keys) = card.card { return (id, keys) }
        }
        return nil
    }

    func testMyPassportAsksWhoseWhenOwnerUnknown() async throws {
        let (savin, troshina, _) = try await vault()
        let session = ChatSession(search: search)
        session.send("мой паспорт")
        try await finish(session)
        let answer = try XCTUnwrap(session.messages.last)
        XCTAssertNil(fieldsCard(answer), "не угадываем, чей паспорт")
        let options = answer.cards.flatMap { card -> [ClarifyOption] in
            if case .clarify(_, let options) = card.card { options } else { [] }
        }
        XCTAssertEqual(Set(options.compactMap(\.documentID)), [savin, troshina])
        XCTAssertTrue(options.allSatisfy { $0.title.contains("Савин") || $0.title.contains("Трошин") }, "\(options.map(\.title))")

        // Выбор чипа — паспорт и предложение запомнить
        let pick = try XCTUnwrap(options.first { $0.documentID == savin })
        session.send(pick.query, documentID: savin)
        try await finish(session)
        XCTAssertEqual(fieldsCard(session.messages.last)?.id, savin)
        XCTAssertEqual(session.messages.last?.ownerSuggestion?.name, "Савин И. А.")
    }

    func testIntroductionRemembersOwnerAndMyPassportIsInstant() async throws {
        let (savin, _, registration) = try await vault()
        let session = ChatSession(search: search)
        session.send("я Илья")
        try await finish(session)
        let introduced = try XCTUnwrap(session.messages.last)
        XCTAssertTrue(introduced.text.contains("Савин И. А."), introduced.text)
        let suggestion = try XCTUnwrap(introduced.ownerSuggestion)
        XCTAssertEqual(fieldsCard(introduced)?.id, savin)

        session.rememberOwner(suggestion)
        XCTAssertEqual(search.owner.owner?.name, "Савин И. А.")
        XCTAssertNil(session.messages.first { $0.ownerSuggestion != nil }, "чип убран")

        session.send("мой паспорт")
        try await finish(session)
        XCTAssertEqual(fieldsCard(session.messages.last)?.id, savin, "«мой паспорт» — паспорт владельца сразу")

        session.send("дай все данные для копирования")
        try await finish(session)
        let all = try XCTUnwrap(fieldsCard(session.messages.last))
        XCTAssertEqual(all.id, savin)
        XCTAssertTrue(all.keys.contains(FieldKey.seriesNumber), "все поля — и серия с номером: карточка закроет их до Face ID")
        XCTAssertFalse(session.messages.last?.text.contains("123456") == true)

        session.send("регистрацию тоже")
        try await finish(session)
        let found = session.messages.last?.cards.contains { $0.card.documentIDs.contains(registration) } == true
        XCTAssertTrue(found, "страница прописки найдена: \(session.messages.last?.text ?? "")")
    }

    /// Владелец известен — «мой паспорт» с облаком отвечает агент: он знает
    /// владельца из инструкции и не угадывает чужой паспорт
    func testKnownOwnerIsToldToAgentWithCloudOn() async throws {
        _ = try await vault()
        search.cloud.useSessionKey("k")
        search.cloud.setChatEnabled(true)
        search.owner.set(fullName: "Савин Илья Андреевич")
        StubURLProtocol.reset()
        let session = ChatSession(search: search, cloudSession: StubURLProtocol.session())
        session.send("мой паспорт")
        try await finish(session)
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "вопрос ушёл агенту")
        let body = try XCTUnwrap(StubURLProtocol.requests.first?.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("Владелец хранилища: Савин И. А."), "агент не знает владельца")
    }

    func testOwnerIsKeptInProtectedFile() throws {
        let url = root.appendingPathComponent("Owner/owner.json")
        let identity = OwnerIdentity(fileURL: url)
        identity.set(fullName: "Савин Илья Андреевич")
        XCTAssertEqual(OwnerIdentity(fileURL: url).owner?.name, "Савин И. А.", "переживает перезапуск")
        XCTAssertTrue(OwnerIdentity(fileURL: url).owns(fullName: "SAVIN ILIA"), "загранпаспорт латиницей — тот же человек")
        identity.clear()
        XCTAssertNil(OwnerIdentity(fileURL: url).owner)
    }

    func testCloudInstructionNamesOwnerOrForbidsGuessing() {
        XCTAssertTrue(CloudChatEngine.system("", owner: "Савин И. А.").contains("Владелец хранилища: Савин И. А."))
        XCTAssertTrue(CloudChatEngine.system("", owner: nil).contains("не угадывай"))
        XCTAssertTrue(CloudChatPrompt.system.contains("серию и номер тоже"), "карточка полей — со всеми полями")
        XCTAssertTrue(CloudChatGenUI.system.contains("series_number тоже"))
    }

    func testSynonymsFindRegistrationByAnotherWord() {
        let variants = CloudChatSynonyms.variants(of: "регистрация")
        XCTAssertTrue(variants.contains("место жительства"))
        XCTAssertTrue(variants.contains("прописка"))
        XCTAssertEqual(CloudChatSynonyms.variants(of: "договор аренды"), ["договор аренды"])
        XCTAssertTrue(CloudChatSynonyms.variants(of: "есть ли отметка о браке").contains("семейное положение"))
    }

    // MARK: - view_document

    private func photo(_ name: String, in folder: VaultFolder) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        store.importData(try Data(contentsOf: url), preferredName: name, to: folder)
    }

    func testViewDocumentSendsPagesAsImagesInCurrentTurnOnly() async throws {
        search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil })
        store.createFolder(name: "Сканы", icon: "folder.fill", color: "indigo")
        try photo("скан.png", in: try XCTUnwrap(store.folders.last))
        search.reconcile()
        await search.waitUntilIdle()
        let documents = await search.documents(ofTypes: DocumentType.allCases)
        let id = try XCTUnwrap(documents.first?.id)

        // OpenAI: картинки — в output вызова, следующий вопрос их не повторяет
        let call: CloudJSON = ["id": "fc_1", "type": "function_call", "status": "completed", "call_id": "call_1", "name": "view_document",
                               "arguments": .string(#"{"id":"d\#(id)","pages":null}"#)]
        func sse(_ events: [CloudJSON]) -> StubURLProtocol.Reply {
            StubURLProtocol.Reply(status: 200, body: Data(events.map { "data: " + String(data: $0.data, encoding: .utf8)! + "\n\n" }.joined().utf8),
                                  headers: ["Content-Type": "text/event-stream"])
        }
        let message: CloudJSON = ["id": "msg_1", "type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Штампа нет."]]]
        StubURLProtocol.reset([
            sse([["type": "response.output_item.done", "output_index": 0, "item": call], ["type": "response.completed", "response": ["output": [call]]]]),
            sse([["type": "response.output_text.delta", "delta": "Штампа нет."], ["type": "response.completed", "response": ["output": [message]]]]),
            sse([["type": "response.output_text.delta", "delta": "Пожалуйста."], ["type": "response.completed", "response": ["output": [message]]]]),
        ])
        let engine = CloudChatEngine(configuration: .init(provider: .openAI, baseURL: CloudProvider.openAI.defaultBaseURL, apiKey: "k",
                                                          model: .luna, reasoning: .auto), search: search, session: StubURLProtocol.session())
        _ = try await engine.respond(to: "посмотри скан")
        let second = try XCTUnwrap(CloudJSON.parse(XCTUnwrap(StubURLProtocol.requests[1].httpBody)))
        let output = try XCTUnwrap(second["input"]?.array?.first { $0["type"]?.string == "function_call_output" }?["output"]?.array)
        XCTAssertEqual(output.first?["type"]?.string, "input_text")
        let image = try XCTUnwrap(output.first { $0["type"]?.string == "input_image" }?["image_url"]?.string)
        XCTAssertTrue(image.hasPrefix("data:image/jpeg;base64,"))
        let jpeg = try XCTUnwrap(Data(base64Encoded: String(image.dropFirst("data:image/jpeg;base64,".count))))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(frame.width, frame.height), 1600, "длинная сторона — 1600 px")

        _ = try await engine.respond(to: "спасибо")
        let third = String(data: try XCTUnwrap(StubURLProtocol.requests[2].httpBody), encoding: .utf8) ?? ""
        XCTAssertFalse(third.contains("data:image/jpeg"), "страницы второй раз не уходят")
        XCTAssertTrue(third.contains("уже показаны"))
    }

    func testViewDocumentOnGeminiAddsInlineParts() async throws {
        search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil })
        store.createFolder(name: "Сканы", icon: "folder.fill", color: "indigo")
        try photo("скан.png", in: try XCTUnwrap(store.folders.last))
        search.reconcile()
        await search.waitUntilIdle()
        let documents = await search.documents(ofTypes: DocumentType.allCases)
        let id = try XCTUnwrap(documents.first?.id)
        func sse(_ parts: [CloudJSON]) -> StubURLProtocol.Reply {
            let chunk: CloudJSON = ["candidates": [["content": ["role": "model", "parts": .array(parts)]]]]
            return StubURLProtocol.Reply(status: 200, body: Data(("data: " + String(data: chunk.data, encoding: .utf8)! + "\r\n\r\n").utf8))
        }
        StubURLProtocol.reset([
            sse([["functionCall": ["name": "view_document", "args": ["id": .string("d\(id)")], "id": "c1"], "thoughtSignature": "s"]]),
            sse([["text": "Посмотрел."]]),
        ])
        let engine = CloudChatEngine(configuration: .init(baseURL: CloudProvider.gemini.defaultBaseURL, apiKey: "k", model: .flash, reasoning: .auto),
                                     search: search, session: StubURLProtocol.session())
        _ = try await engine.respond(to: "посмотри скан")
        let contents = try XCTUnwrap(CloudJSON.parse(XCTUnwrap(StubURLProtocol.requests[1].httpBody))?["contents"]?.array)
        let parts = try XCTUnwrap(contents.last?["parts"]?.array)
        XCTAssertNotNil(parts.first?["functionResponse"])
        XCTAssertNil(parts.first?["functionResponse"]?["response"]?["_images"], "картинки — не в JSON ответа")
        XCTAssertEqual(parts.last?["inline_data"]?["mime_type"]?.string, "image/jpeg", "кадр — частью того же хода")
    }
}
