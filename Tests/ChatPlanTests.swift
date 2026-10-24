import XCTest
@testable import LocalDrive

// План ответа от модели: JSON ровно в том виде, в каком его выдаёт грамматика
// со стенда (scratchpad/llm-bench/final/plan.ebnf), и его исполнение роутером
@MainActor
final class ChatPlanTests: XCTestCase {
    func testDecodesGrammarOutput() throws {
        let json = #"{"action": "document", "types": ["passport_intl"], "fields": ["series_number"], "expiry": false, "owner": [], "query": "", "reply": ""}"#
        let plan = try JSONDecoder().decode(ChatPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.action, .document)
        XCTAssertEqual(plan.types, [.passportIntl])
        XCTAssertEqual(plan.fields, [FieldKey.seriesNumber])
        XCTAssertEqual(plan.text, "")
    }

    func testReplyKeyBecomesText() throws {
        let json = #"{"action": "answer", "types": [], "fields": [], "expiry": false, "owner": [], "query": "", "reply": "Пожалуйста!"}"#
        let plan = try JSONDecoder().decode(ChatPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.text, "Пожалуйста!")
        let encoded = String(data: try JSONEncoder().encode(plan), encoding: .utf8) ?? ""
        XCTAssertTrue(encoded.contains(#""reply""#), "история для модели пишется в её же формате")
    }

    func testMissingKeysAreDefaults() throws {
        let plan = try JSONDecoder().decode(ChatPlan.self, from: Data(#"{"action": "search"}"#.utf8))
        XCTAssertEqual(plan, ChatPlan(action: .search))
    }

    func testSanitizedDropsUnknownFieldsAndDigits() {
        let plan = ChatPlan(
            action: .answer,
            fields: ["series_number", "card_cvv"],
            owner: ["Савина", "", "ильи", "андреевича", "лишнее"],
            text: "Номер 4601 123456 не покажу"
        ).sanitized()
        XCTAssertEqual(plan.fields, ["series_number"])
        XCTAssertEqual(plan.owner, ["савина", "ильи", "андреевича"])
        XCTAssertEqual(plan.text, "Номер не покажу")
    }

    func testSearchQueryMustShareAStemWithTheMessage() {
        let message = "справка о принятии статьи"
        XCTAssertEqual(ChatRouter.searchQuery("", message: message), message)
        XCTAssertEqual(ChatRouter.searchQuery(nil, message: message), message)
        // Модель вписала в query имя соседнего ключа
        XCTAssertEqual(ChatRouter.searchQuery("reply", message: message), message)
        XCTAssertEqual(ChatRouter.searchQuery("справку принятия статей", message: message), "справку принятия статей")
    }

    func testIntentFromPlanCarriesEverything() {
        let plan = ChatPlan(action: .list, types: [.diploma], fields: ["issue_date"], expiry: true, owner: ["савина"])
        let intent = ChatIntent(plan: plan)
        XCTAssertEqual(intent.types, [.diploma])
        XCTAssertEqual(intent.fieldKeys, ["issue_date"])
        XCTAssertTrue(intent.wantsExpiry)
        XCTAssertTrue(intent.wantsList)
        XCTAssertEqual(intent.nameWords, ["савина"])
    }

    // MARK: - Исполнение плана

    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDrivePlanTests-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
        search = SearchService(store: store, databaseURL: nil)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        search = nil
        store = nil
        root = nil
    }

    private func indexPassport() async throws -> Int64 {
        store.createFolder(name: "Паспорта", icon: "folder.fill", color: "indigo")
        let folder = try XCTUnwrap(store.folders.last)
        // Векторы MRZ из PassportFieldsTests, посчитаны независимо
        let text = """
        PNRUSSAVIN<<IL98<ANDREEVI3<<<<<<<<<<<<<<<<<<
        4601234561RUS9001011M<<<<<<<1100620770120<34
        """
        store.importData(Data(text.utf8), preferredName: "паспорт.txt", to: folder)
        search.reconcile()
        await search.waitUntilIdle()
        // XCTUnwrap принимает автозамыкание без поддержки await
        let passports = await search.documents(ofTypes: [.passportRU])
        return try XCTUnwrap(passports.first?.id)
    }

    func testDocumentPlanAnswersWithCards() async throws {
        let id = try await indexPassport()
        let plan = ChatPlan(action: .document, types: [.passportRU], fields: ["series_number"])
        let (reply, _) = await ChatRouter(search: search).reply(plan: plan, text: "скинь номер паспорта")
        XCTAssertEqual(reply.cards, [.fields(documentID: id, keys: ["series_number"])])
    }

    func testAnswerPlanNeverCarriesDigits() async throws {
        _ = try await indexPassport()
        let plan = ChatPlan(action: .answer, text: "Ваш номер 4601 123456")
        let (reply, _) = await ChatRouter(search: search).reply(plan: plan, text: "напиши номер цифрами")
        XCTAssertFalse(reply.text.contains { $0.isNumber }, "модель не должна напечатать номер: \(reply.text)")
    }

    func testEmptyAnswerFallsBackToSearch() async throws {
        _ = try await indexPassport()
        let plan = ChatPlan(action: .answer, text: "")
        let (reply, _) = await ChatRouter(search: search).reply(plan: plan, text: "паспорт")
        XCTAssertFalse(reply.cards.isEmpty, "пустой ответ модели — значит, ищем по тексту")
    }
}
