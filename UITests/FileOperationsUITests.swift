import XCTest

// Хранилище как у нормальных файловых приложений: выбрать файл и перенести его
// в другую папку, скопировать и вставить в другую папку, посмотреть сведения.
// Файл попадает в папку так же, как в ImportUITests: подсказка «Куда положить
// копию.txt» из своей папки приложения в «Файлах» есть на любом симуляторе
final class FileOperationsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSelectFileAndMoveItToAnotherFolder() throws {
        let app = XCUIApplication()
        app.launch()
        unlock(app)

        // Имена с номером: папки прошлых запусков остаются на симуляторе
        let suffix = String(Int.random(in: 100...999))
        let target = "Цель \(suffix)"
        let source = "Источник \(suffix)"
        createFolder(target, in: app)
        createFolder(source, in: app)
        openFolder(source, in: app)
        importHint(in: app)

        app.buttons["fileSelect"].tap()
        XCTAssertTrue(app.navigationBars["Выберите файлы"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["bulkMove"].isEnabled, "без выбора переносить нечего")
        hint(in: app).tap()
        XCTAssertTrue(app.navigationBars["Выбрано: 1"].waitForExistence(timeout: 5))

        app.buttons["bulkMove"].tap()
        XCTAssertTrue(app.navigationBars["Переместить в папку"].waitForExistence(timeout: 5))
        // Новые папки — в конце списка: лист открывается наполовину, ячейки ниже ещё не созданы
        let destination = app.buttons["moveDestination-\(target)"]
        for _ in 0..<8 where !destination.exists {
            app.swipeUp()
        }
        XCTAssertTrue(destination.waitForExistence(timeout: 5), "в листе нет папки «\(target)»\n" + app.debugDescription)
        XCTAssertFalse(app.buttons["moveDestination-\(source)"].exists, "текущей папки в листе быть не должно")
        destination.tap()

        XCTAssertTrue(app.staticTexts["Папка пуста"].waitForExistence(timeout: 5), "файл остался в исходной папке")

        goBack(in: app)
        openFolder(target, in: app)
        XCTAssertTrue(hint(in: app).waitForExistence(timeout: 5), "файл не появился в папке назначения")
    }

    func testCopyThenPasteIntoAnotherFolderAndShowInfo() throws {
        let app = XCUIApplication()
        app.launch()
        unlock(app)

        let suffix = String(Int.random(in: 100...999))
        let empty = "Пустая \(suffix)"
        let source = "Буфер \(suffix)"
        createFolder(empty, in: app)
        createFolder(source, in: app)
        openFolder(source, in: app)
        importHint(in: app)

        // Сведения: имя и состояние поиска, без содержимого документа
        hint(in: app).press(forDuration: 1.0)
        let info = app.buttons["fileInfo"]
        XCTAssertTrue(info.waitForExistence(timeout: 5), "в меню файла нет «Сведения»\n" + app.debugDescription)
        info.tap()
        XCTAssertTrue(app.navigationBars["Сведения"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Размер"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["fileInfoSearch"].exists, "нет строки о поиске\n" + app.debugDescription)
        app.navigationBars["Сведения"].buttons["Готово"].tap()

        hint(in: app).press(forDuration: 1.0)
        let copy = app.buttons["Скопировать"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()

        goBack(in: app)
        openFolder(empty, in: app)
        XCTAssertTrue(app.staticTexts["Папка пуста"].waitForExistence(timeout: 5))
        let paste = pasteButton(in: app)
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "нет кнопки «Вставить»\n" + app.debugDescription)
        paste.tap()

        XCTAssertTrue(hint(in: app).waitForExistence(timeout: 10), "вставка не добавила файл")
        XCTAssertFalse(app.alerts["Файл не добавлен"].exists)
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
        openFilesPage(in: app)
        XCTAssertTrue(app.buttons["Новая папка"].waitForExistence(timeout: 10))
    }

    /// Папки — на странице «Файлы»: сверху переключатель страниц, а до него
    /// была вкладка внизу. Помощник понимает оба варианта
    private func openFilesPage(in app: XCUIApplication) {
        let page = app.buttons["pageFiles"]
        if page.waitForExistence(timeout: 5) {
            page.tap()
            return
        }
        let tab = app.tabBars.buttons["Файлы"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "не нашёл переход к папкам\n" + app.debugDescription)
        tab.tap()
    }

    private func enterPin(in app: XCUIApplication) {
        for digit in "1111" { app.buttons[String(digit)].tap() }
    }

    private func createFolder(_ name: String, in app: XCUIApplication) {
        app.buttons["Новая папка"].tap()
        let field = app.textFields["Например, Документы"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["Готово"].tap()
        XCTAssertTrue(folderCard(name, in: app).exists, "папка «\(name)» не появилась\n" + app.debugDescription)
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

    private func openFolder(_ name: String, in app: XCUIApplication) {
        folderCard(name, in: app).tap()
    }

    private func hint(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Куда положить")).firstMatch
    }

    /// Документ из «Файлов» → На iPhone → LocalDrive → подсказка → «Открыть».
    /// Окно выбора помнит последнюю папку и на нагруженном Mac наполняется
    /// не сразу, поэтому каждый шаг ждёт своё и пропускается, если уже пройден
    private func importHint(in app: XCUIApplication) {
        app.buttons["Добавить файл"].tap()
        app.buttons["Документ из «Файлов»"].tap()

        let picked = hint(in: app)
        // Окно выбора помнит прошлую папку: тогда «Обзор» — и вкладка, и кнопка «назад»
        let browse = app.buttons["Обзор"].firstMatch
        _ = picked.waitForExistence(timeout: 5) || browse.waitForExistence(timeout: 5)
        if !picked.exists {
            if browse.exists { browse.tap() }
            // В подписи «На iPhone» неразрывный пробел (U+00A0) — обычной
            // строкой она не находится, поэтому ищем по «iPhone»
            let device = app.cells
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "DOC.sidebar.item", "iPhone"))
                .firstMatch
            if device.waitForExistence(timeout: 15) { device.tap() }
            let appFolder = app.staticTexts["LocalDrive"].firstMatch
            if !picked.waitForExistence(timeout: 3), appFolder.waitForExistence(timeout: 15) {
                appFolder.tap()
            }
        }

        XCTAssertTrue(picked.waitForExistence(timeout: 15), "в окне выбора нет файла-подсказки\n" + app.debugDescription)
        picked.tap()
        let open = app.buttons["Открыть"]
        if open.waitForExistence(timeout: 3), open.isEnabled { open.tap() }
        XCTAssertTrue(hint(in: app).waitForExistence(timeout: 10), "файл не появился в папке")
    }

    private func goBack(in app: XCUIApplication) {
        let back = app.navigationBars.buttons["BackButton"]
        if back.waitForExistence(timeout: 3) {
            back.tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.buttons["Новая папка"].waitForExistence(timeout: 5))
    }

    /// Системная кнопка «Вставить»: подпись у неё своя, системная
    private func pasteButton(in app: XCUIApplication) -> XCUIElement {
        let byID = app.buttons["filePaste"]
        if byID.waitForExistence(timeout: 2) { return byID }
        let byLabel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Вставить", "Paste"])).firstMatch
        return byLabel
    }
}
