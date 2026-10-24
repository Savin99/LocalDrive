import XCTest

// Generative UI в отладочной галерее (-GenUIGallery): интерфейс из JSON
// отвечает на действия человека настоящими жестами, а не только в юнит-тестах
final class GenUIGalleryUITests: XCTestCase {
    private func open(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-GenUIGallery"]
        app.launch()
        let row = app.descendants(matching: .any)["genui-scenario-\(scenario)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        return app
    }

    func testCalculatorSliderRecomputesPayment() {
        let app = open("calculator")
        let payment = app.staticTexts["genui-payment-value"]
        XCTAssertTrue(payment.waitForExistence(timeout: 5))
        let before = payment.label
        let slider = app.sliders["genui-amount"]
        XCTAssertTrue(slider.exists)
        slider.adjust(toNormalizedSliderPosition: 0.9)
        XCTAssertNotEqual(payment.label, before, "платёж пересчитан после ползунка")
        XCTAssertTrue(app.descendants(matching: .any)["genui-balance"].exists, "график остатка на месте")
    }

    func testTabsSwitchContent() {
        let app = open("mixed")
        let tab = app.buttons["genui-views-tab-expiring"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["genui-expiring-table"].waitForExistence(timeout: 5))
    }

    func testFormSubmitReachesPerformer() {
        let app = open("form")
        let field = app.textFields["genui-country"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(" и Грузия")
        app.buttons["genui-trip"].tap()
        let log = app.staticTexts["genui-log"]
        XCTAssertTrue(log.waitForExistence(timeout: 5))
        XCTAssertTrue(log.label.contains("submit"), log.label)
        XCTAssertTrue(app.descendants(matching: .any)["genui-trip-outcome"].waitForExistence(timeout: 5))
    }

    func testBrokenAnswerShowsFallbackAndValidPart() {
        let app = open("broken")
        XCTAssertTrue(app.descendants(matching: .any)["genui-fallback"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["genui-ok"].exists, "уцелевший блок показан")
        XCTAssertFalse(app.descendants(matching: .any)["genui-video"].exists)
    }

    func testForbiddenActionsAreNotShown() {
        let app = open("forbidden")
        XCTAssertTrue(app.buttons["genui-ask"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["genui-js"].exists)
        XCTAssertFalse(app.buttons["genui-url"].exists)
    }
}
