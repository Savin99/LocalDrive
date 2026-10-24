import XCTest

// Чат 24.10.2026: лента шагов ответа, «Вставить» из буфера над полем ввода и
// фото из галереи во вложения. Снимки экрана остаются в результатах теста —
// по ним проверяется вид в светлой и тёмной теме
final class ChatAssistantUITests: XCTestCase {
    /// В буфере фото — над полем ввода «Вставить», и фото встаёт вложением
    func testClipboardPhotoIsOfferedAndPasted() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80))
        UIPasteboard.general.image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        let app = XCUIApplication()
        app.launch()
        unlockIfNeeded(app)

        let bar = app.descendants(matching: .any)["chatClipboardBar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "нет строки «В буфере фото»\n" + app.debugDescription)
        keepScreenshot(app, "clipboard-bar")
        app.buttons["chatClipboardPaste"].firstMatch.tap()
        let strip = app.descendants(matching: .any)["chatAttachmentStrip"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "фото из буфера не встало вложением")
        XCTAssertFalse(bar.exists, "строка «Вставить» осталась после вставки")
        keepScreenshot(app, "clipboard-pasted")
    }

    /// Ответ показывает, что чат делал: строка «Ответ за … · N шагов», по
    /// касанию — сами шаги
    func testAnswerShowsWhatChatDid() throws {
        let app = XCUIApplication()
        app.launch()
        unlockIfNeeded(app)

        let input = app.descendants(matching: .any)["chatInput"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("дата рождения Ольги\n")
        let summary = app.buttons["chatStepsSummary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "под ответом нет строки шагов\n" + app.debugDescription)
        summary.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Понял")).firstMatch.waitForExistence(timeout: 3),
                      "шаги не раскрылись")
        keepScreenshot(app, "steps")
    }

    /// Фото из галереи через «+» встаёт вложением
    func testPhotoFromLibraryBecomesAttachment() throws {
        let app = XCUIApplication()
        app.launch()
        unlockIfNeeded(app)

        app.buttons["chatAttach"].firstMatch.tap()
        let photo = app.buttons["chatAttachPhoto"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()

        // Галерея — отдельный процесс; снимки в ней подписаны «Фото, …» или «Photo, …»
        let pictures = app.images.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
                                                       "Photo", "Фото", "Снимок"))
        XCTAssertTrue(pictures.firstMatch.waitForExistence(timeout: 15), "в галерее нет снимков\n" + app.debugDescription)
        // Верхний ряд прячется под шапкой окна выбора — берём снимок из середины
        let picture = pictures.element(boundBy: min(4, max(0, pictures.count - 1)))
        picture.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Кнопка выбора — «Готово» с идентификатором Add
        let add = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "Add", ["Добавить", "Add"])).firstMatch
        if add.waitForExistence(timeout: 3) { add.tap() }

        let strip = app.descendants(matching: .any)["chatAttachmentStrip"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 20), "фото не встало вложением\n" + app.debugDescription)
        keepScreenshot(app, "photo-attached")
    }

    private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// До сборки 16 приложение открывалось кодом; после — сразу
    private func unlockIfNeeded(_ app: XCUIApplication) {
        if app.staticTexts["Придумайте код"].waitForExistence(timeout: 4) {
            for digit in "1111" { app.buttons[String(digit)].tap() }
            _ = app.staticTexts["Повторите код"].waitForExistence(timeout: 5)
            for digit in "1111" { app.buttons[String(digit)].tap() }
        } else if app.staticTexts["Введите код"].exists {
            for digit in "1111" { app.buttons[String(digit)].tap() }
        }
    }
}
