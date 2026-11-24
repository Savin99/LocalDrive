import PDFKit
import UIKit
import XCTest
@testable import LocalDrive

/// Проверки чистого агентного харнеса: AGENT.md, многостраничные PDF и текст вложений,
/// отсутствие навязанного «Куда положить эти файлы?», повторный просмотр вложений через
/// view_attachment/view_document, продолжение хода после propose_file_actions и передача
/// решений пользователя (Принять/Отклонить) в историю агента.
@MainActor
final class AgentHarnessTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var inbox: ChatAttachmentInbox!

    override func setUp() async throws {
        StubURLProtocol.reset()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = VaultStore(rootURL: root.appendingPathComponent("Vault"))
        inbox = ChatAttachmentInbox(directory: root.appendingPathComponent("Inbox"))
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        inbox = nil
        store = nil
    }

    // MARK: - Хелперы

    private func cloudSession() -> (ChatSession, SearchService) {
        let suite = "AgentHarness-\(UUID().uuidString)"
        let service = "com.ilyaqa.LocalDrive.tests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suite)
            for name in [service, service + ".openai", service + ".gemini"] { Keychain.delete(service: name) }
        }
        let cloud = CloudRecognitionStore(defaults: UserDefaults(suiteName: suite)!, keychainService: service)
        cloud.setKey("k")
        cloud.setChatEnabled(true)
        let search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil }, cloud: cloud)
        let session = ChatSession(search: search, cloudSession: StubURLProtocol.session(), inbox: inbox)
        session.useFiles(store)
        return (session, search)
    }

    private func finish(_ session: ChatSession) async throws {
        for _ in 0..<500 where session.isAnswering { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.isAnswering)
    }

    private func body(_ index: Int) throws -> CloudJSON {
        try XCTUnwrap(CloudJSON.parse(XCTUnwrap(StubURLProtocol.requests[index].httpBody)))
    }

    private func makePDF(pages: [String]) throws -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        return renderer.pdfData { ctx in
            for text in pages {
                ctx.beginPage()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 22),
                    .foregroundColor: UIColor.black,
                ]
                (text as NSString).draw(in: CGRect(x: 40, y: 40, width: 500, height: 700), withAttributes: attrs)
            }
        }
    }

    private func makePNG() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 180))
        return renderer.pngData { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 20, y: 20, width: 100, height: 30))
        }
    }

    private static func sse(_ events: [CloudJSON]) -> StubURLProtocol.Reply {
        let raw = events.map { "event: \($0["type"]?.string ?? "")\ndata: " + String(data: $0.data, encoding: .utf8)! + "\n\n" }.joined()
        return StubURLProtocol.Reply(status: 200, body: Data(raw.utf8), headers: ["Content-Type": "text/event-stream"])
    }

    private static func genUIReply(_ text: String) -> StubURLProtocol.Reply {
        let json = String(data: (["version": 1, "mode": "text", "text": .string(text), "state": [], "computed": [], "blocks": [], "sources": [], "followups": []] as CloudJSON).data, encoding: .utf8)!
        let msg: CloudJSON = ["id": "msg_1", "type": "message", "role": "assistant", "status": "completed",
                              "content": [["type": "output_text", "text": .string(json), "annotations": []]]]
        return sse([
            ["type": "response.output_text.delta", "item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": .string(json)],
            ["type": "response.output_item.done", "output_index": 0, "item": msg],
            ["type": "response.completed", "response": ["id": "resp_1", "status": "completed", "output": [msg]]],
        ])
    }

    private static func toolCall(_ name: String, _ args: CloudJSON, callID: String = "call_1") -> StubURLProtocol.Reply {
        let rawArgs = String(data: args.data, encoding: .utf8) ?? "{}"
        let call: CloudJSON = ["id": .string("fc_\(callID)"), "type": "function_call", "status": "completed", "call_id": .string(callID),
                               "name": .string(name), "arguments": .string(rawArgs)]
        return sse([
            ["type": "response.output_item.done", "output_index": 0, "item": call],
            ["type": "response.completed", "response": ["id": "resp_c", "status": "completed", "output": [call]]],
        ])
    }

    private func attach(_ data: Data, named name: String) async throws -> ChatAttachment {
        let added = await inbox.add(data: data, named: name)
        return try XCTUnwrap(added)
    }

    // MARK: - AGENT.md

    func testAgentMDIsBundledAndClean() throws {
        XCTAssertNotNil(AgentIdentity.resourceURL, "AGENT.md должен попадать ресурсом в бандл")
        XCTAssertTrue(AgentIdentity.instructions.contains("LocalDrive"))
        XCTAssertTrue(CloudChatGenUI.system.hasPrefix(AgentIdentity.instructions))
        XCTAssertTrue(CloudChatPrompt.system.hasPrefix(AgentIdentity.instructions))
        // Никаких старых принудительных шаблонов и приказа «всегда предлагай папку»
        XCTAssertFalse(CloudChatGenUI.system.contains("Предлагай, в какую папку их положить"))
        XCTAssertFalse(CloudChatGenUI.system.contains("Правило 1:"))
        XCTAssertFalse(CloudChatPrompt.system.contains("коротко: одна-три фразы"))
    }

    // MARK: - Вложения без навязанного промпта и многостраничный PDF

    func testEmptyCaptionWithAttachmentsDoesNotInjectPlacementQuestion() async throws {
        let (session, _) = cloudSession()
        let png = try makePNG()
        let item = try await attach(png, named: "Фото.png")

        StubURLProtocol.reset([Self.genUIReply("Вижу бланк, подскажу поля для заполнения.")])
        session.send("", attaching: [item])
        try await finish(session)

        let req = try body(0)
        let userTurn = try XCTUnwrap(req["input"]?.array?.last { $0["role"]?.string == "user" })
        let content = try XCTUnwrap(userTurn["content"]?.array)
        let text = content.first { $0["type"]?.string == "input_text" }?["text"]?.string ?? ""
        XCTAssertFalse(text.contains("Куда положить эти файлы?"), "приложение не должно дописывать выдуманный вопрос за пользователя")
        XCTAssertTrue(text.contains("\(item.id) — «Фото.png»"), text)
        let images = content.filter { $0["type"]?.string == "input_image" }
        XCTAssertEqual(images.count, 1)
        XCTAssertTrue(images.first?["image_url"]?.string?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    func testMultiPagePDFAttachmentSendsAllPagesAndExtractedText() async throws {
        let (session, _) = cloudSession()
        let pdf = try makePDF(pages: [
            "ЗАЯВЛЕНИЕ — Титульная страница",
            "Страница 2: ФИО ребёнка и родителя",
            "Страница 3: Даты отсутствия и подпись",
        ])
        let item = try await attach(pdf, named: "Бланк_заявления.pdf")

        StubURLProtocol.reset([Self.genUIReply("Прочитал все три страницы бланка.")])
        session.send("Мне надо заполнить ребенок тася мама ольга", attaching: [item])
        try await finish(session)

        let req = try body(0)
        let userTurn = try XCTUnwrap(req["input"]?.array?.last { $0["role"]?.string == "user" })
        let content = try XCTUnwrap(userTurn["content"]?.array)
        let images = content.filter { $0["type"]?.string == "input_image" }
        XCTAssertEqual(images.count, 3, "модель должна получить все 3 страницы PDF, а не только первую")
        let text = content.first { $0["type"]?.string == "input_text" }?["text"]?.string ?? ""
        XCTAssertTrue(text.contains("(3 стр.)"), text)
        XCTAssertTrue(text.contains("Титульная страница"), "текст 1-й страницы извлечён")
        XCTAssertTrue(text.contains("Даты отсутствия"), "текст 3-й страницы извлечён")
    }

    // MARK: - Повторный просмотр вложения (view_attachment и view_document("a1"))

    func testAgentCanReopenAttachmentOnLaterTurnViaViewAttachmentAndViewDocument() async throws {
        let (session, _) = cloudSession()
        let pdf = try makePDF(pages: ["Бланк заявления страница 1", "Бланк заявления страница 2"])
        let item = try await attach(pdf, named: "Бланк.pdf")

        // Ход 1: отправляем бланк
        StubURLProtocol.reset([Self.genUIReply("Принял бланк.")])
        session.send("вот бланк", attaching: [item])
        try await finish(session)

        // Ход 2: просим пересмотреть; модель вызывает view_attachment(id: a1)
        StubURLProtocol.reset([
            Self.toolCall("view_attachment", ["id": .string(item.id), "pages": .null], callID: "call_va"),
            Self.genUIReply("Вот какие поля нужно заполнить."),
        ])
        session.send("Прочитай и дай заполнить чем")
        try await finish(session)

        // В первом запросе 2-го хода старые картинки вырезаны с подсказкой view_attachment
        let firstTurn2JSON = try body(0)
        let firstTurn2Images = (firstTurn2JSON["input"]?.array ?? [])
            .flatMap { $0["content"]?.array ?? [] }
            .filter { $0["type"]?.string == "input_image" }
        XCTAssertTrue(firstTurn2Images.isEmpty, "картинка прошлого хода не уходит повторно")
        let firstOfTurn2 = try XCTUnwrap(String(data: XCTUnwrap(StubURLProtocol.requests[0].httpBody), encoding: .utf8))
        XCTAssertTrue(firstOfTurn2.contains("view_attachment"))

        // Во втором запросе 2-го хода инструмент вернул картинки обеих страниц и текст
        let secondOfTurn2 = try body(1)
        let toolOutput = try XCTUnwrap(secondOfTurn2["input"]?.array?.last { $0["type"]?.string == "function_call_output" }?["output"]?.array)
        let returnedImages = toolOutput.filter { $0["type"]?.string == "input_image" }
        XCTAssertEqual(returnedImages.count, 2, "view_attachment должен вернуть страницы вложения картинками")
        let returnedText = toolOutput.first { $0["type"]?.string == "input_text" }?["text"]?.string ?? ""
        let parsedTool = try XCTUnwrap(CloudJSON.parse(Data(returnedText.utf8)))
        let extracted = parsedTool["text"]?.string ?? ""
        XCTAssertTrue(extracted.contains("заявления страница 1") && extracted.contains("заявления страница 2"), "ожидали текст PDF, пришло: \(returnedText)")

        // Также проверяем, что view_document("a1") прозрачно открывает вложение
        StubURLProtocol.reset([
            Self.toolCall("view_document", ["id": .string(item.id), "pages": [2]], callID: "call_vd"),
            Self.genUIReply("На второй странице — подпись."),
        ])
        session.send("Посмотри на док")
        try await finish(session)

        let delegatedOutput = try XCTUnwrap(body(1)["input"]?.array?.last { $0["type"]?.string == "function_call_output" }?["output"]?.array)
        XCTAssertEqual(delegatedOutput.filter { $0["type"]?.string == "input_image" }.count, 1)
    }

    // MARK: - propose_file_actions не обрывает ход, а «Отклонить» видно агенту

    func testProposeFileActionsLetsAgentFinishTurnAndRecordsDecline() async throws {
        let (session, _) = cloudSession()
        store.createFolder(name: "Документы", icon: "folder.fill", color: "indigo")
        let folder = try XCTUnwrap(store.folders.last)
        let png = try makePNG()
        let item = try await attach(png, named: "Скан.png")

        StubURLProtocol.reset([
            Self.toolCall("propose_file_actions", [
                "summary": "Сохранить скан в Документы",
                "actions": [["action": "save_attachment", "attachment_id": .string(item.id), "folder_id": .string(folder.id.uuidString)]],
            ], callID: "call_prop"),
            Self.genUIReply("Подготовил карточку сохранения, а заодно разобрал поля бланка."),
        ])
        session.send("разбери и сохрани", attaching: [item])
        try await finish(session)

        XCTAssertEqual(StubURLProtocol.requests.count, 2, "после propose_file_actions агент продолжает ход и пишет ответ")
        let answer = try XCTUnwrap(session.messages.last)
        XCTAssertEqual(answer.text, "Подготовил карточку сохранения, а заодно разобрал поля бланка.")
        XCTAssertEqual(answer.cards.count, 1, "карточка предложения сохранилась вместе с текстом ответа")

        // Пользователь отклонил карточку — агент видит это в следующем запросе
        session.recordProposalDecision("Действие пользователя: отклонил предложение «Сохранить скан в Документы» — ничего не изменилось", kind: "file_declined")
        StubURLProtocol.reset([Self.genUIReply("Хорошо, сохранять не будем.")])
        session.send("не надо сохранять, только прочитай")
        try await finish(session)

        let nextRaw = try XCTUnwrap(String(data: XCTUnwrap(StubURLProtocol.requests.first?.httpBody), encoding: .utf8))
        XCTAssertTrue(nextRaw.contains("отклонил предложение"), "агент должен видеть, что пользователь отклонил карточку")
    }

    // MARK: - Облачный чат не перехватывается локальными правилами

    func testCloudModeIsNotHijackedByLocalFileCommandOrAttachmentAnswer() async throws {
        let (session, _) = cloudSession()
        store.createFolder(name: "Семья", icon: "folder.fill", color: "indigo")
        let png = try makePNG()
        let item = try await attach(png, named: "бланк.png")

        StubURLProtocol.reset([Self.genUIReply("Понял, сначала помогу заполнить, потом решим с папкой.")])
        session.send("положи в семью после того как проверишь", attaching: [item])
        try await finish(session)

        XCTAssertEqual(StubURLProtocol.requests.count, 1, "в облачном режиме команды не перехватываются локальным ChatFileCommand")
        XCTAssertEqual(session.messages.last?.text, "Понял, сначала помогу заполнить, потом решим с папкой.")
    }
}
