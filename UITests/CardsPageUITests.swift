import XCTest

// «Карточки» — третья страница (владелец 24.10.2026): «запомни …» в чате →
// «Сохранить» → карточка на странице → «домофон Камилы» в чате показывает её.
// И листание: с «Карточек» свайпом вправо — к «Файлам»
final class CardsPageUITests: XCTestCase {
    func testRememberInChatThenFindOnCardsPageAndAskAgain() throws {
        let app = XCUIApplication()
        app.launch()

        let input = app.descendants(matching: .any)["chatInput"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("запомни: у Камилы домофон 45К, этаж 3, адрес Москва Тверская 5\n")

        let save = app.buttons["factSave"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "чат не предложил карточку\n" + app.debugDescription)
        keepScreenshot(app, "chat-fact-proposal")
        save.tap()
        XCTAssertTrue(app.descendants(matching: .any)["factSaved"].firstMatch.waitForExistence(timeout: 5), "карточка не сохранилась")

        app.buttons["pageCards"].tap()
        let card = app.descendants(matching: .any)["factCard-Дом Камилы"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "на странице «Карточки» нет «Дом Камилы»\n" + app.debugDescription)
        keepScreenshot(app, "cards-page")

        // Свайп вправо по «Карточкам» — к «Файлам»
        app.swipeRight()
        XCTAssertTrue(waitUntil { app.buttons["pageFiles"].isSelected }, "свайп вправо не открыл «Файлы»")

        app.buttons["pageChat"].tap()
        XCTAssertTrue(waitUntil { app.buttons["pageChat"].isSelected })
        input.tap()
        input.typeText("домофон Камилы\n")
        let answer = app.descendants(matching: .any).matching(identifier: "factCard-Дом Камилы").element(boundBy: 1)
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "в ответе нет карточки\n" + app.debugDescription)
        keepScreenshot(app, "chat-fact-answer")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
