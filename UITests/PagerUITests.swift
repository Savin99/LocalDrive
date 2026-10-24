import XCTest

// Две страницы главного экрана — «Чат» и «Файлы»: переключатель вверху
// и свайп между ними. С «Файлов» к чату листает только свайп от левого края:
// посередине страницы живут жест Z и лента «Недавнее». Внутри папки
// переключателя нет, а свайп от края — системное «назад»
final class PagerUITests: XCTestCase {
    private let folderName = "Страницы QA"

    func testSwitcherAndSwipesMoveBetweenPages() throws {
        let app = XCUIApplication()
        app.launch()
        unlock(app)

        let chatPage = app.buttons["pageChat"]
        let filesPage = app.buttons["pageFiles"]
        let newFolder = app.buttons["Новая папка"]
        let chatInput = app.descendants(matching: .any)["chatInput"].firstMatch

        XCTAssertTrue(chatPage.waitForExistence(timeout: 10))
        XCTAssertTrue(chatPage.isSelected, "после входа открыт не чат")

        // Над полем ввода горизонтальный свайп листает подсказки, а не страницы
        let suggestion = app.buttons.matching(identifier: "chatSuggestion").firstMatch
        if suggestion.waitForExistence(timeout: 3) {
            suggestion.swipeLeft()
            XCTAssertFalse(waitUntil(timeout: 1.5) { filesPage.isSelected }, "свайп по подсказкам увёл на «Файлы»")
        }

        filesPage.tap()
        XCTAssertTrue(waitUntil { filesPage.isSelected && newFolder.isHittable }, "переключатель не открыл «Файлы»")

        // Свайп посередине «Файлов» страницу не листает
        app.swipeRight()
        XCTAssertFalse(waitUntil(timeout: 1.5) { chatPage.isSelected }, "свайп посередине «Файлов» увёл на чат")

        // От левого края — назад к чату. Жест начинается у карточки папки,
        // и открыться она не должна: ниже «Файлы» обязаны открыться на корне
        swipeFromLeftEdge(app)
        XCTAssertTrue(waitUntil { chatPage.isSelected && chatInput.isHittable }, "свайп от края не вернул чат")

        // На чате свайп влево открывает «Файлы»
        app.swipeLeft()
        XCTAssertTrue(
            waitUntil { filesPage.isSelected && newFolder.isHittable },
            "свайп влево не открыл «Файлы» или свайп от края открыл папку под пальцем"
        )

        createFolder(in: app)
        app.staticTexts[folderName].firstMatch.tap()
        XCTAssertTrue(waitUntil { !filesPage.exists }, "переключатель виден внутри папки")

        swipeFromLeftEdge(app)
        XCTAssertTrue(waitUntil { newFolder.isHittable }, "свайп от края не вернул из папки")
        XCTAssertTrue(filesPage.isSelected, "свайп от края в папке увёл на чат, а не назад")

        deleteFolder(in: app)
    }

    // MARK: - Хелперы

    private func unlock(_ app: XCUIApplication) {
        if app.staticTexts["Придумайте код"].waitForExistence(timeout: 10) {
            enterPin(in: app)
            XCTAssertTrue(app.staticTexts["Повторите код"].waitForExistence(timeout: 5))
            enterPin(in: app)
        } else if app.staticTexts["Введите код"].waitForExistence(timeout: 5) {
            enterPin(in: app)
        }
    }

    private func enterPin(in app: XCUIApplication) {
        for digit in "1111" { app.buttons[String(digit)].tap() }
    }

    private func swipeFromLeftEdge(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 3, dy: 0))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func createFolder(in app: XCUIApplication) {
        app.buttons["Новая папка"].tap()
        let field = app.textFields["Например, Документы"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(folderName)
        app.buttons["Готово"].tap()
        XCTAssertTrue(app.staticTexts[folderName].firstMatch.waitForExistence(timeout: 5))
    }

    /// Уборка за собой, чтобы папки не копились в симуляторе от прогона к прогону
    private func deleteFolder(in app: XCUIApplication) {
        let card = app.staticTexts[folderName].firstMatch
        guard card.waitForExistence(timeout: 5) else { return }
        card.press(forDuration: 1.2)
        let delete = app.buttons["Удалить папку"]
        guard delete.waitForExistence(timeout: 5) else { return }
        delete.tap()
        let confirm = app.buttons["Удалить вместе с файлами"]
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }
}
