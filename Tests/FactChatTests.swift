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

    /// Карточки владельца: в них есть поля-числа и адреса, но не дни рождения
    private func ownersCards() -> [FactCard] {
        [
            FactCard(title: "Логопед Николая", symbol: "figure.child", items: [
                FactItem(kind: .address, label: "Адрес", value: "Москва, проспект Маршала Жукова, 28"),
                FactItem(kind: .number, label: "Подъезд", value: "1"),
                FactItem(kind: .number, label: "Квартира", value: "19"),
                FactItem(kind: .code, label: "Домофон", value: "19#7088"),
                FactItem(kind: .number, label: "Длительность занятия, минут", value: "30"),
                FactItem(kind: .link, label: "Открыть в Яндекс.Картах", value: "yandex.ru/maps?text=55.776072,37.475585"),
            ]),
            FactCard(title: "Квартира Камиллы", symbol: "house.fill", items: [
                FactItem(kind: .number, label: "Квартира", value: "178"),
                FactItem(kind: .number, label: "Этаж", value: "8"),
            ]),
        ]
    }

    /// Иванова Анна Сергеевна, родилась 12.05.1985 — вектор ChatFieldFixTests
    private static let ivanovaRussian = """
    ПАСПОРТ
    PNRUSIVANOVA<<ANNA<SERGEEVNA<<<<<<<<<<<<<<<<
    4516543213RUS8505121F<<<<<<<0120315690001<44
    """

    /// Владелец 26.10.2026: «Какого числа у ольги день рождение» — показались
    /// «Логопед Николая» и «Квартира Камиллы»: «числа» нашлось видом поля
    /// «число», «день» — видом «дата». Вопрос о человеке из документов —
    /// ответ его паспортом
    func testBirthdayQuestionIsNotAnsweredByCardsWithNumbers() async throws {
        ownersCards().forEach(facts.add)
        store.createFolder(name: "Паспорта", icon: "folder.fill", color: "indigo")
        let folder = try XCTUnwrap(store.folders.last)
        store.importData(Data(Self.ivanovaRussian.utf8), preferredName: "иванова.txt", to: folder)
        search.reconcile()
        await search.waitUntilIdle()
        let passports = await search.documents(ofTypes: [.passportRU])
        let passport = try XCTUnwrap(passports.first)

        for question in ["Какого числа у анны день рождение", "какого числа у Анны день рождения", "когда день рождения у Анны"] {
            let answer = await reply(question)
            XCTAssertNil(shown(answer), "«\(question)» — ответ карточками: \(answer.text)")
            XCTAssertEqual(answer.cards.first, .fields(documentID: passport.id, keys: [FieldKey.birthDate]), "«\(question)»: \(answer.text)")
        }
        // Слова-понятия сами по себе карточку не выбирают
        XCTAssertTrue(FactSearch.matches("какого числа день", in: facts.cards).isEmpty)
        // А вопрос о карточке — по-прежнему карточкой
        let floor = await reply("какой этаж у Камиллы")
        XCTAssertEqual(shown(floor)?.0, facts.cards.first { $0.title == "Квартира Камиллы" }?.id, floor.text)
    }

    /// «Запомни» о том, у кого карточка уже есть, — черновик, а не ответ ею
    func testRememberAboutKnownPersonIsNotALookup() async throws {
        ownersCards().forEach(facts.add)
        let session = ChatSession(search: search)
        session.useFacts(facts)
        session.send("запомни: у Камиллы домофон 45К1234, этаж 8")
        for _ in 0..<300 where session.isAnswering { try await Task.sleep(for: .milliseconds(10)) }
        let answer = try XCTUnwrap(session.messages.last)
        guard case .factProposal = answer.cards.first?.content else { return XCTFail("не черновик: \(answer.text)") }
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
