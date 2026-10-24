import XCTest
@testable import LocalDrive

final class FactLinksTests: XCTestCase {
    // MARK: - Карты

    func testAddressOpensAppleMapsSearch() throws {
        let url = try XCTUnwrap(FactLinks.mapsURL(for: "Москва, Тверская 5"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host(), "maps.apple.com")
        XCTAssertEqual(url.path(), "/search")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }
        XCTAssertEqual(query?.value, "Москва, Тверская 5")
    }

    func testAddressWithAmpersandAndLineBreaksStaysOneParameter() throws {
        let url = try XCTUnwrap(FactLinks.mapsURL(for: "ул. Ленина 1 & 2\nподъезд #3 +"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.count, 1, url.absoluteString)
        XCTAssertEqual(items.first?.value, "ул. Ленина 1 & 2 подъезд #3 +")
        XCTAssertFalse(url.absoluteString.contains("+"), "Плюс в запросе читается как пробел")
    }

    func testCoordinateOpensPlace() throws {
        let url = try XCTUnwrap(FactLinks.mapsURL(for: "55.7558, 37.6173"))
        XCTAssertEqual(url.absoluteString, "https://maps.apple.com/place?coordinate=55.7558,37.6173")
        XCTAssertNil(FactLinks.coordinate(in: "Тверская 5, 12"))
        XCTAssertNil(FactLinks.coordinate(in: "95.0, 37.0"), "Широта больше 90")
    }

    func testEmptyAddressHasNoURL() {
        XCTAssertNil(FactLinks.mapsURL(for: "   "))
    }

    // MARK: - Ссылки

    func testLinkWithoutSchemeGetsHTTPS() {
        XCTAssertEqual(FactLinks.webURL(for: "ya.ru/maps")?.absoluteString, "https://ya.ru/maps")
        XCTAssertEqual(FactLinks.webURL(for: " www.gosuslugi.ru ")?.absoluteString, "https://www.gosuslugi.ru")
        XCTAssertEqual(FactLinks.webURL(for: "http://example.com/a?b=1")?.absoluteString, "http://example.com/a?b=1")
        XCTAssertEqual(FactLinks.webURL(for: "tg://resolve?domain=durov")?.scheme, "tg")
    }

    func testCyrillicDomainIsAccepted() throws {
        let url = try XCTUnwrap(FactLinks.webURL(for: "госуслуги.рф"))
        XCTAssertEqual(url.scheme, "https")
    }

    func testUnsafeOrBrokenLinksAreRejected() {
        XCTAssertNil(FactLinks.webURL(for: "javascript:alert(1)"))
        XCTAssertNil(FactLinks.webURL(for: "javascript://alert(1)"))
        XCTAssertNil(FactLinks.webURL(for: "file:///etc/passwd"))
        XCTAssertNil(FactLinks.webURL(for: "позвоню позже"))
        XCTAssertNil(FactLinks.webURL(for: "localhost"))
        XCTAssertNil(FactLinks.webURL(for: ""))
    }

    func testDisplayLinkDropsSchemeAndWWW() {
        XCTAssertEqual(FactLinks.displayLink("https://www.ya.ru/maps/"), "ya.ru/maps")
        XCTAssertEqual(FactLinks.displayLink("ya.ru"), "ya.ru")
    }

    // MARK: - Телефон и почта

    func testPhoneNumbersBecomeTelLinks() {
        XCTAssertEqual(FactLinks.phoneURL(for: "+7 (916) 123-45-67")?.absoluteString, "tel:+79161234567")
        XCTAssertEqual(FactLinks.phoneURL(for: "8 916 123 45 67 доб. 12")?.absoluteString, "tel:89161234567")
        XCTAssertEqual(FactLinks.phoneURL(for: "Камила: +7 916 123 45 67")?.absoluteString, "tel:+79161234567")
        XCTAssertEqual(FactLinks.phoneURL(for: "112")?.absoluteString, "tel:112")
        XCTAssertNil(FactLinks.phoneURL(for: "позвоню позже"))
        XCTAssertNil(FactLinks.phoneURL(for: "12"))
    }

    func testEmailBecomesMailto() {
        XCTAssertEqual(FactLinks.mailURL(for: " kamila@example.com ")?.absoluteString, "mailto:kamila@example.com")
        XCTAssertEqual(FactLinks.mailURL(for: "mailto:a+b@mail.ru")?.absoluteString, "mailto:a+b@mail.ru")
        XCTAssertNil(FactLinks.mailURL(for: "kamila at example"))
        XCTAssertNil(FactLinks.mailURL(for: "a@b"))
        XCTAssertNil(FactLinks.mailURL(for: "@example.com"))
    }

    // MARK: - Действие касания

    func testPrimaryActionByKind() {
        func action(_ kind: FactItem.Kind, _ value: String) -> FactItemAction {
            FactLinks.primaryAction(for: FactItem(kind: kind, label: "", value: value))
        }
        XCTAssertEqual(action(.address, "Тверская 5"), .openMaps)
        XCTAssertEqual(action(.link, "ya.ru"), .openLink)
        XCTAssertEqual(action(.phone, "+7 916 123-45-67"), .call)
        XCTAssertEqual(action(.email, "a@b.ru"), .mail)
        for kind in [FactItem.Kind.code, .text, .date, .number, .wifi, .note] {
            XCTAssertEqual(action(kind, "45К1234"), .copy, "\(kind)")
        }
        // Не ссылка в поле ссылки — копируется, а не открывается
        XCTAssertEqual(action(.link, "спросить у Камилы"), .copy)
    }

    // MARK: - Значки

    func testEverySymbolExistsOnThisSystem() {
        let missing = FactSymbols.allNames.filter { UIImage(systemName: $0) == nil }.sorted()
        XCTAssertEqual(missing, [], "Нет в SF Symbols этой iOS")
        XCTAssertGreaterThanOrEqual(FactSymbols.cardChoices.count, 30)
    }

    func testDefaultSymbolsByRussianLabel() {
        let expected: [String: String] = [
            "Домофон": "bell.and.waves.left.and.right.fill",
            "Код домофона": "bell.and.waves.left.and.right.fill",
            "Этаж": "stairs",
            "Подъезд": "door.left.hand.open",
            "Квартира": "door.left.hand.closed",
            "кв.": "door.left.hand.closed",
            "Пароль": "lock.fill",
            "Пароль Wi-Fi": "wifi",
            "Wi-Fi": "wifi",
            "Адрес": "mappin.and.ellipse",
            "Ссылка": "link",
            "Телефон": "phone.fill",
            "Городской телефон": "phone.fill",
            "E-mail": "envelope.fill",
            "Дата": "calendar",
            "День рождения": "gift.fill",
            "Заметка": "note.text",
            "Код": "number.square.fill",
            "Парковка": "parkingsign.circle.fill",
        ]
        for (label, symbol) in expected {
            XCTAssertEqual(FactSymbols.labelSymbol(label), symbol, label)
        }
        XCTAssertNil(FactSymbols.labelSymbol("Любимый цвет"))
    }

    func testSymbolFallbackOrder() {
        // Выбор агента — если такой значок есть
        XCTAssertEqual(FactSymbols.symbol(for: FactItem(kind: .code, label: "Домофон", value: "1", symbol: "key.fill")), "key.fill")
        // Выдуманное имя — по подписи
        XCTAssertEqual(FactSymbols.symbol(for: FactItem(kind: .code, label: "Домофон", value: "1", symbol: "no.such.symbol")),
                       "bell.and.waves.left.and.right.fill")
        // Подпись незнакомая — по виду
        XCTAssertEqual(FactSymbols.symbol(for: FactItem(kind: .address, label: "Где живёт", value: "1")), "mappin.and.ellipse")
        for kind in FactItem.Kind.allCases {
            XCTAssertEqual(FactSymbols.symbol(for: FactItem(kind: kind, label: "", value: "1")), FactSymbols.kindSymbol(kind))
        }
        let card = FactCard(title: "Дача", symbol: "made.up", items: [])
        XCTAssertEqual(FactSymbols.symbol(for: card), FactCard.defaultSymbol)
    }

    func testPlainTextForCopyAll() {
        let card = FactCard(title: "Дом Камилы", items: [
            FactItem(kind: .code, label: "Домофон", value: "45"),
            FactItem(kind: .number, label: "", value: "3"),
            FactItem(kind: .text, label: "Пусто", value: "  "),
        ])
        XCTAssertEqual(card.plainText, "Дом Камилы\nДомофон: 45\nЧисло: 3")
    }
}
