import XCTest

// «Настройки» → «Скрытые папки»: строка знака ведёт на экран знака, запись
// своего знака открывается на весь экран и не принимает прямую линию.
// Сложный штрих XCUITest нарисовать не умеет (только прямые), поэтому
// распознавание знака проверяют модульные тесты SecretSymbolTests
final class HiddenFoldersUITests: XCTestCase {
    func testHiddenFoldersSettingsScreens() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Настройки"].waitForExistence(timeout: 10))
        app.buttons["Настройки"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 5))

        let symbolRow = app.buttons["settingsHiddenSymbol"]
        XCTAssertTrue(symbolRow.waitForExistence(timeout: 5), "нет строки «Знак»")
        XCTAssertTrue(app.buttons["settingsHiddenPassword"].exists, "нет строки «Открыть по паролю»")
        attachScreenshot(named: "settings", app: app)

        symbolRow.tap()
        XCTAssertTrue(app.navigationBars["Знак"].waitForExistence(timeout: 5))
        attachScreenshot(named: "hidden-symbol", app: app)

        app.buttons["drawSymbol"].tap()
        let canvas = app.descendants(matching: .any)["symbolCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "запись знака не открылась")
        attachScreenshot(named: "symbol-recorder", app: app)

        // Прямая — не знак: так выглядит обычный свайп
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        let warning = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Слишком просто")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5), "прямая линия принята за знак")
        attachScreenshot(named: "symbol-too-simple", app: app)

        app.buttons["Отмена"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Знак"].waitForExistence(timeout: 5))
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
