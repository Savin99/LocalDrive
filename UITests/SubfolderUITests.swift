import XCTest

// Вложенные папки: «+» → «Новая папка» внутри папки, переход внутрь и обратно
// по крошкам. Крошки видны со второго уровня: «Мои файлы › Документы › Паспорта»
final class SubfolderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testCreateSubfolderOpenItAndReturnByBreadcrumb() throws {
        let app = XCUIApplication()
        app.launch()
        unlock(app)

        // Имена с номером: папки прошлых запусков остаются на симуляторе
        let suffix = String(Int.random(in: 100...999))
        let parent = "Документы \(suffix)"
        let child = "Паспорта \(suffix)"
        let grandchild = "Старые \(suffix)"

        createFolder(parent, in: app)
        folderCard(parent, in: app).tap()
        XCTAssertTrue(app.navigationBars[parent].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["breadcrumb-root"].exists, "на первом уровне крошек нет — хватает «назад»")

        createSubfolder(child, in: app)
        app.buttons["subfolder-\(child)"].tap()
        XCTAssertTrue(app.navigationBars[child].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["breadcrumb-root"].waitForExistence(timeout: 5), "нет крошек\n" + app.debugDescription)
        XCTAssertTrue(app.buttons["breadcrumb-\(parent)"].exists)

        createSubfolder(grandchild, in: app)
        app.buttons["subfolder-\(grandchild)"].tap()
        XCTAssertTrue(app.navigationBars[grandchild].waitForExistence(timeout: 5))

        // Средняя крошка обрезает путь до своего уровня
        let middle = app.buttons["breadcrumb-\(parent)"]
        XCTAssertTrue(middle.waitForExistence(timeout: 5))
        middle.tap()
        XCTAssertTrue(app.navigationBars[parent].waitForExistence(timeout: 5), "крошка не вернула в «\(parent)»\n" + app.debugDescription)
        XCTAssertTrue(app.buttons["subfolder-\(child)"].exists, "вложенная папка на месте")

        // «Мои файлы» — сразу на главный экран
        app.buttons["subfolder-\(child)"].tap()
        let home = app.buttons["breadcrumb-root"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        XCTAssertTrue(app.buttons["Новая папка"].waitForExistence(timeout: 5), "крошка не вернула на главный экран")
        XCTAssertTrue(folderCard(parent, in: app).exists)
        XCTAssertFalse(app.staticTexts[child].exists, "на главном — только верхний уровень")
    }

    // MARK: - Шаги

    private func unlock(_ app: XCUIApplication) {
        if app.staticTexts["Придумайте код"].waitForExistence(timeout: 10) {
            enterPin(in: app)
            XCTAssertTrue(app.staticTexts["Повторите код"].waitForExistence(timeout: 5))
            enterPin(in: app)
        } else if app.staticTexts["Введите код"].waitForExistence(timeout: 5) {
            enterPin(in: app)
        }
        let page = app.buttons["pageFiles"]
        if page.waitForExistence(timeout: 5) { page.tap() }
        XCTAssertTrue(app.buttons["Новая папка"].waitForExistence(timeout: 10))
    }

    private func enterPin(in app: XCUIApplication) {
        for digit in "1111" { app.buttons[String(digit)].tap() }
    }

    private func createFolder(_ name: String, in app: XCUIApplication) {
        app.buttons["Новая папка"].tap()
        fillEditor(name, in: app)
        XCTAssertTrue(folderCard(name, in: app).exists, "папка «\(name)» не появилась\n" + app.debugDescription)
    }

    /// «+» в шапке папки → «Новая папка»
    private func createSubfolder(_ name: String, in app: XCUIApplication) {
        app.buttons["Добавить файл"].tap()
        let item = app.buttons["newSubfolder"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "в меню «+» нет «Новая папка»\n" + app.debugDescription)
        item.tap()
        fillEditor(name, in: app)
        XCTAssertTrue(app.buttons["subfolder-\(name)"].waitForExistence(timeout: 5), "вложенная «\(name)» не появилась\n" + app.debugDescription)
    }

    private func fillEditor(_ name: String, in app: XCUIApplication) {
        let field = app.textFields["Например, Документы"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["Готово"].tap()
    }

    /// Новые папки — в конце сетки: на заполненном симуляторе до них надо долистать
    @discardableResult
    private func folderCard(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let card = app.staticTexts[name].firstMatch
        if card.waitForExistence(timeout: 3) && card.isHittable { return card }
        for _ in 0..<10 where !(card.exists && card.isHittable) {
            app.swipeUp()
        }
        for _ in 0..<10 where !(card.exists && card.isHittable) {
            app.swipeDown()
        }
        return card
    }
}
