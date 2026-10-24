import XCTest
@testable import LocalDrive

final class FactSearchTests: XCTestCase {
    private let intercom = FactItem(kind: .code, label: "Домофон", value: "45К1234")
    private let floor = FactItem(kind: .number, label: "Этаж", value: "3")
    private let address = FactItem(kind: .address, label: "Адрес", value: "Москва, Тверская 5")

    private var kamila: FactCard {
        FactCard(title: "Дом Камилы", symbol: "house.fill", items: [intercom, floor, address],
                 updatedAt: Date(timeIntervalSince1970: 1_000))
    }

    /// Камила упомянута только в значении поля чужой карточки
    private var dacha: FactCard {
        FactCard(title: "Дача", items: [
            FactItem(kind: .text, label: "Ключи", value: "запасные у Камилы"),
            FactItem(kind: .wifi, label: "Сеть", value: "dacha-2024"),
        ], updatedAt: Date(timeIntervalSince1970: 2_000))
    }

    private var petya: FactCard {
        FactCard(title: "Петя", items: [
            FactItem(kind: .phone, label: "Телефон", value: "+7 916 000-00-00"),
        ], updatedAt: Date(timeIntervalSince1970: 3_000))
    }

    private var cards: [FactCard] { [kamila, dacha, petya] }

    private func titles(_ query: String) -> [String] {
        FactSearch.matches(query, in: cards).map(\.card.title)
    }

    private func match(_ query: String, title: String = "Дом Камилы") throws -> FactSearch.Match {
        try XCTUnwrap(FactSearch.matches(query, in: cards).first { $0.card.title == title }, "«\(query)» не нашёл «\(title)»")
    }

    // MARK: - Морфология

    func testOwnerQueriesFindKamilasHome() throws {
        for query in ["дом Камилы", "Камила", "домофон Камилы", "где живёт Камила", "Камилин дом", "у Камилы этаж"] {
            XCTAssertEqual(titles(query).first, "Дом Камилы", "«\(query)»")
        }
    }

    func testFieldWordsHighlightTheAskedField() throws {
        XCTAssertEqual(try match("домофон Камилы").itemIDs, [intercom.id])
        XCTAssertEqual(try match("какой этаж у Камилы").itemIDs, [floor.id])
        // «живёт» — не подпись, а вид поля «адрес»
        XCTAssertEqual(try match("где живёт Камила").itemIDs, [address.id])
        XCTAssertEqual(try match("адрес Камилы").itemIDs, [address.id])
    }

    func testTitleWordsShowTheWholeCard() throws {
        // «дом» есть в названии: спросили о карточке, а не о поле
        XCTAssertEqual(try match("дом Камилы").itemIDs, [])
        XCTAssertEqual(try match("Камила").itemIDs, [])
    }

    // MARK: - Отбор и порядок

    func testTitleHitsRankAboveItemHits() {
        // Дача новее, но Камила у неё только в значении поля
        XCTAssertEqual(titles("Камила"), ["Дом Камилы", "Дача"])
    }

    func testFieldWordAloneDoesNotPickSomeoneElsesCard() {
        // Слово «дом» общее: «дом Петра» не должен показать дом Камилы
        XCTAssertEqual(titles("дом Петра"), [])
        XCTAssertEqual(titles("телефон Пети"), ["Петя"])
    }

    func testFieldWordsWithoutNameSearchFields() {
        XCTAssertEqual(titles("домофон"), ["Дом Камилы"])
        XCTAssertEqual(titles("пароль от вайфая"), ["Дача"])
    }

    func testExtraUnknownWordFallsBackToBestPartialMatch() {
        // «срочно» не стоп-слово и нигде не встречается — Камила всё равно находится
        XCTAssertEqual(titles("срочно домофон Камилы").first, "Дом Камилы")
    }

    func testStopWordsAndFillersAreIgnored() {
        let terms = FactSearch.terms(in: "скажи пожалуйста какой у Камилы код от домофона").map(\.word)
        XCTAssertEqual(terms, ["камилы", "код", "домофона"])
        XCTAssertEqual(titles("скажи пожалуйста какой у Камилы код от домофона").first, "Дом Камилы")
    }

    func testUnrelatedQueryFindsNothing() {
        XCTAssertEqual(titles("паспорт"), [])
        XCTAssertEqual(titles(""), [])
    }

    func testValueSearch() {
        XCTAssertEqual(titles("Тверская"), ["Дом Камилы"])
        XCTAssertEqual(titles("45К1234"), ["Дом Камилы"])
    }

    @MainActor
    func testStoreSearchReturnsAllForEmptyQuery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FactSearch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FactStore(rootURL: root)
        cards.forEach(store.add)
        XCTAssertEqual(store.search("  ").count, 3)
        XCTAssertEqual(store.search("домофон Камилы").map(\.title), ["Дом Камилы"])
        XCTAssertEqual(store.matches("домофон Камилы").first?.itemIDs, [intercom.id])
    }
}
