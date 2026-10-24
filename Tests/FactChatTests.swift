import XCTest
@testable import LocalDrive

// Карточки-факты в чате: «запомни …» без облака и ответы «дом Камилы»,
// «домофон Камилы», «где живёт Камила». Владелец 24.10.2026: «что я прошу
// запомнить и чего нет в документах — и чтобы быстро спросить»
@MainActor
final class FactChatTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!
    private var facts: FactStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDriveFactChat-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
        search = SearchService(store: store, databaseURL: nil)
        facts = FactStore(rootURL: root)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        facts = nil
        search = nil
        store = nil
        root = nil
    }

    // MARK: - Разбор «запомни»

    func testRememberHomeBecomesHomeCard() throws {
        let card = try XCTUnwrap(FactDraftParser.draft(from: "запомни: у Камилы домофон 45К, этаж 3, адрес Москва Тверская 5, кв 12"))
        XCTAssertEqual(card.title, "Дом Камилы")
        XCTAssertEqual(card.symbol, "house.fill")
        XCTAssertEqual(card.items.map(\.label), ["Домофон", "Этаж", "Адрес", "Квартира"])
        XCTAssertEqual(card.items.map(\.value), ["45К", "3", "Москва Тверская 5", "12"])
        XCTAssertEqual(card.items.first { $0.label == "Адрес" }?.kind, .address)
        XCTAssertEqual(card.items.first { $0.label == "Домофон" }?.kind, .code)
    }

    func testRememberWithTitleAndMixedValues() throws {
        let card = try XCTUnwrap(FactDraftParser.draft(from: "Запиши Дача — код калитки 2580; wifi Dacha2024, сайт https://snt-rassvet.ru, телефон председателя +7 916 123-45-67"))
        XCTAssertEqual(card.title, "Дача")
        XCTAssertEqual(card.items.first { $0.kind == .link }?.value, "https://snt-rassvet.ru")
        XCTAssertEqual(card.items.first { $0.kind == .phone }?.value, "+7 916 123-45-67")
        XCTAssertEqual(card.items.first { $0.label == "Калитка" }?.value, "2580")
        XCTAssertEqual(card.items.first { $0.kind == .wifi }?.value, "Dacha2024")
    }

    func testNotARememberRequest() {
        XCTAssertNil(FactDraftParser.draft(from: "я запомнил домофон"))
        XCTAssertNil(FactDraftParser.draft(from: "дом Камилы"))
        XCTAssertNil(FactDraftParser.draft(from: "запомни"))
    }

    func testFemaleGenitiveBecomesNominative() {
        XCTAssertEqual(FactDraftParser.nominative("Камилы"), "Камила")
        XCTAssertEqual(FactDraftParser.nominative("Ольги"), "Ольга")
        XCTAssertEqual(FactDraftParser.nominative("Марии"), "Мария")
    }

    // MARK: - Ответы карточками

    private func kamila() -> FactCard {
        FactCard(title: "Дом Камилы", symbol: "house.fill", items: [
            FactItem(kind: .address, label: "Адрес", value: "Москва, Тверская 5"),
            FactItem(kind: .code, label: "Домофон", value: "45К"),
            FactItem(kind: .text, label: "Этаж", value: "3"),
        ])
    }

    private func reply(_ text: String) async -> ChatReply {
        var router = ChatRouter(search: search)
        router.facts = facts
        return await router.reply(to: text).0
    }

    private func shown(_ answer: ChatReply) -> (UUID, [UUID])? {
        guard case .fact(let id, let items) = answer.cards.first else { return nil }
        return (id, items)
    }

    func testHomeQuestionShowsCard() async {
        let card = kamila()
        facts.add(card)
        let answer = await reply("дом Камилы")
        XCTAssertEqual(shown(answer)?.0, card.id)
        XCTAssertTrue(answer.isConfident)
    }

    func testFieldQuestionHighlightsField() async throws {
        let card = kamila()
        facts.add(card)
        let intercom = try XCTUnwrap(card.items.first { $0.label == "Домофон" })
        let answer = await reply("код домофона Камилы")
        XCTAssertEqual(shown(answer)?.0, card.id)
        XCTAssertEqual(shown(answer)?.1, [intercom.id])
    }

    func testWhereLivesShowsAddressFromCard() async throws {
        let card = kamila()
        facts.add(card)
        let address = try XCTUnwrap(card.items.first { $0.kind == .address })
        let answer = await reply("где живёт Камила")
        XCTAssertEqual(shown(answer)?.0, card.id, "ответ не карточкой: \(answer.text)")
        XCTAssertTrue(shown(answer)?.1.contains(address.id) == true)
    }

    func testNameAloneFindsCardWhenNoDocuments() async {
        let card = kamila()
        facts.add(card)
        let answer = await reply("Камила")
        XCTAssertEqual(shown(answer)?.0, card.id)
    }

    func testUnknownNameIsNotAnotherHome() async {
        facts.add(kamila())
        let answer = await reply("дом Петра")
        XCTAssertNil(shown(answer), "«дом Петра» показал чужой дом")
    }

    func testRememberInChatProposesCardAndSaves() async throws {
        let session = ChatSession(search: search)
        session.useFacts(facts)
        session.send("запомни: у Камилы домофон 45К, этаж 3")
        for _ in 0..<300 where session.isAnswering { try await Task.sleep(for: .milliseconds(10)) }
        let answer = try XCTUnwrap(session.messages.last)
        guard case .factProposal(let draft) = answer.cards.first?.content else { return XCTFail("нет черновика: \(answer.text)") }
        XCTAssertEqual(draft.title, "Дом Камилы")
        XCTAssertTrue(facts.cards.isEmpty, "карточка сохранилась без «Сохранить»")
    }
}
