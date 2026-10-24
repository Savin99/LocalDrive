import XCTest

// Две страницы главного экрана — «Чат» и «Файлы»: переключатель вверху
// и свайп между ними. Экрана блокировки нет — приложение открывается сразу
// на чате. С «Файлов» к чату листает свайп вправо из любого места корня
// (решение владельца от 24.10.2026): от левого края — за пальцем, из середины —
// по отпусканию, потому что там же рисуют секретный знак. Внутри папки
// переключателя нет, а свайп от края — системное «назад»
final class PagerUITests: XCTestCase {
    private let folderName = "Страницы QA"

    func testLaunchOpensMainScreenWithoutLock() throws {
        let app = XCUIApplication()
        app.launch()

        let chatPage = app.buttons["pageChat"]
        XCTAssertTrue(chatPage.waitForExistence(timeout: 10), "главный экран не открылся")
        XCTAssertTrue(chatPage.isSelected, "после запуска открыт не чат")
        XCTAssertFalse(app.staticTexts["Придумайте код"].exists, "первый запуск просит код")
        XCTAssertFalse(app.staticTexts["Введите код"].exists, "запуск просит код")

        // Возврат из фона тоже без кода
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(chatPage.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { chatPage.isHittable }, "после возврата из фона главный экран закрыт")
        XCTAssertFalse(app.staticTexts["Введите код"].exists, "возврат из фона просит код")
    }

    func testSwitcherAndSwipesMoveBetweenPages() throws {
        let app = XCUIApplication()
        app.launch()

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

        // Свайп вправо посередине «Файлов» возвращает к чату
        app.swipeRight()
        XCTAssertTrue(waitUntil { chatPage.isSelected && chatInput.isHittable }, "свайп посередине «Файлов» не вернул чат")

        // На чате свайп влево открывает «Файлы»
        app.swipeLeft()
        XCTAssertTrue(waitUntil { filesPage.isSelected && newFolder.isHittable }, "свайп влево не открыл «Файлы»")

        // Прокрутка «Файлов» страницу не листает
        app.swipeUp()
        app.swipeDown()
        XCTAssertFalse(waitUntil(timeout: 1.5) { chatPage.isSelected }, "прокрутка «Файлов» увела на чат")

        // Свайп из середины, начатый на карточке папки, ведёт к чату и папку
        // не открывает: ниже «Файлы» обязаны открыться на корне
        createFolder(in: app)
        let card = app.staticTexts[folderName].firstMatch
        bringToMiddle(card, in: app)
        // От начала подписи до правого края, быстро: карточка может стоять
        // в правом столбце, и путь выйдет короче трети ширины — тогда листает
        // взмах быстрее 600 pt/с
        let cardPoint = card.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        let travel = app.windows.firstMatch.frame.maxX - 8 - (card.frame.minX + card.frame.width * 0.05)
        cardPoint.press(
            forDuration: 0.05,
            thenDragTo: cardPoint.withOffset(CGVector(dx: travel, dy: 0)),
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
        XCTAssertTrue(waitUntil { chatPage.isSelected && chatInput.isHittable }, "свайп с карточки папки не вернул чат")
        app.swipeLeft()
        XCTAssertTrue(
            waitUntil { filesPage.isSelected && newFolder.isHittable },
            "свайп влево не открыл «Файлы» или свайп с карточки открыл папку под пальцем"
        )

        // От левого края — за пальцем, как раньше
        swipeFromLeftEdge(app)
        XCTAssertTrue(waitUntil { chatPage.isSelected && chatInput.isHittable }, "свайп от края не вернул чат")
        app.swipeLeft()
        XCTAssertTrue(waitUntil { filesPage.isSelected && newFolder.isHittable }, "свайп от края открыл папку под пальцем")

        app.staticTexts[folderName].firstMatch.tap()
        XCTAssertTrue(waitUntil { !filesPage.exists }, "переключатель виден внутри папки")

        swipeFromLeftEdge(app)
        XCTAssertTrue(waitUntil { newFolder.isHittable }, "свайп от края не вернул из папки")
        XCTAssertTrue(filesPage.isSelected, "свайп от края в папке увёл на чат, а не назад")

        deleteFolder(in: app)
    }

    // MARK: - Хелперы

    /// Карточку — на середину экрана: в симуляторе остаются папки других
    /// тестов, и новая может оказаться ниже края. Штрих оттуда начался бы на
    /// полоске «домой» и увёл бы приложение в фон. Вертикальные протяжки
    /// заодно проверяют, что прокрутка «Файлов» страницу не листает
    private func bringToMiddle(_ element: XCUIElement, in app: XCUIApplication) {
        let height = app.windows.firstMatch.frame.height
        for _ in 0..<8 {
            let middle = element.frame.midY
            if middle > height * 0.3 && middle < height * 0.7 { return }
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: middle > height * 0.7 ? 0.35 : 0.85))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        XCTAssertFalse(app.buttons["pageChat"].isSelected, "прокрутка «Файлов» увела на чат")
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
