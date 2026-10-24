import XCTest

final class BackupFlowUITests: XCTestCase {
    func testRestoreEntryAndBackupSettingsScreens() throws {
        let app = XCUIApplication()
        app.launch()

        // Кода входа нет, и восстановление больше не предлагает первый запуск:
        // вход в него — в настройках
        XCTAssertTrue(app.buttons["Настройки"].waitForExistence(timeout: 10))
        app.buttons["Настройки"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 5))

        let restoreButton = app.buttons["restore-files"]
        XCTAssertTrue(restoreButton.waitForExistence(timeout: 5))
        restoreButton.tap()
        // Если на iPhone уже есть папки, сначала спрашивают, заменить ли их
        let proceed = app.buttons["Продолжить"]
        if proceed.waitForExistence(timeout: 2) { proceed.tap() }
        XCTAssertTrue(app.navigationBars["Восстановление файлов"].waitForExistence(timeout: 5))
        attachScreenshot(named: "restore-entry", app: app)

        tap(app.buttons["restore-cancel"], until: app.navigationBars["Настройки"])
        XCTAssertTrue(waitForDisappearance(app.navigationBars["Восстановление файлов"], timeout: 5))

        tap(
            app.buttons["Защита и восстановление"],
            until: app.navigationBars["Защита и восстановление"]
        )
        attachScreenshot(named: "backup-settings", app: app)

        // Регрессия: выбор папки должен продолжать настройку. Раньше через строку
        // «Хранилище» сохранялось только имя папки — ни кода восстановления, ни
        // копии, и экран выглядел так, будто нажатие не сработало.
        let storageRow = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Хранилище"))
            .firstMatch
        XCTAssertTrue(storageRow.waitForExistence(timeout: 5), "Строка «Хранилище» не найдена")
        storageRow.tap()

        let openButton = app.buttons["Открыть"]
        if !openButton.waitForExistence(timeout: 10) || !openButton.isEnabled {
            // Окно выбора помнит прошлую папку: тогда «Обзор» — и вкладка, и кнопка «назад».
            // На чистом симуляторе оно открывается на «Недавних», где «Открыть»
            // неактивна: папку выбираем в «Обзоре» — «На iPhone»
            app.buttons["Обзор"].firstMatch.tap()
            let onDevice = NSPredicate(format: "(label BEGINSWITH %@ OR label BEGINSWITH %@) AND label CONTAINS %@", "На", "On", "iPhone")
            let place = app.buttons.matching(onDevice).firstMatch.exists
                ? app.buttons.matching(onDevice).firstMatch
                : app.staticTexts.matching(onDevice).firstMatch
            if !openButton.isEnabled, place.waitForExistence(timeout: 3) { place.tap() }
            XCTAssertTrue(openButton.waitForExistence(timeout: 10), "Выбор папки не открылся")
        }
        openButton.tap()

        // Либо просят сохранить код восстановления, либо копия уже создана
        let recoveryPrompt = app.staticTexts["Сохраните код восстановления"]
        let backupDone = app.staticTexts["Копия актуальна"]
        var continued = false
        for _ in 0..<30 {
            if recoveryPrompt.exists || backupDone.exists {
                continued = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(continued, "После выбора папки настройка не продолжилась")
        attachScreenshot(named: "backup-setup-continued", app: app)
    }

    private func tap(_ button: XCUIElement, until destination: XCUIElement) {
        for _ in 0..<3 {
            button.tap()
            if destination.waitForExistence(timeout: 2) { return }
        }
        XCTFail("Экран не открылся после трёх нажатий")
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
