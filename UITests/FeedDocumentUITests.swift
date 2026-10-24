import XCTest

// Инлайн-правка ленты: Enter режет абзац, Backspace в начале склеивает обратно.
// Логика живёт в UITextView и в SwiftUI-состоянии одновременно, поэтому
// юнит-тестами она не покрывается — только сквозным проходом.
final class FeedDocumentUITests: XCTestCase {
    func testEnterSplitsParagraphAndBackspaceMergesItBack() throws {
        let app = XCUIApplication()
        app.launch()
        unlock(app)

        createFeedFolder(named: "Лента QA", in: app)
        app.staticTexts["Лента QA"].firstMatch.tap()

        let blocks = app.textViews.matching(identifier: "feedTextBlock")
        let tail = app.buttons["feedTail"]
        XCTAssertTrue(tail.waitForExistence(timeout: 10), "Страница ленты не открылась\n" + app.debugDescription)
        tail.tap()

        XCTAssertTrue(blocks.firstMatch.waitForExistence(timeout: 5))
        app.typeText("Первый")
        XCTAssertEqual(blocks.count, 1)

        // Enter в конце строки открывает следующий абзац
        app.typeText("\n")
        XCTAssertTrue(waitFor(blocks, count: 2), "Enter не создал второй блок")

        // Каретка уже в начале пустого абзаца — Backspace убирает его
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(waitFor(blocks, count: 1), "Backspace не убрал пустой абзац")
        XCTAssertEqual(blocks.firstMatch.value as? String, "Первый")

        // Тап внутрь строки ставит каретку по месту нажатия, Enter режет там же
        blocks.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5)).tap()
        app.typeText("\n")
        XCTAssertTrue(waitFor(blocks, count: 2), "Enter не разрезал строку по каретке")

        let head = blocks.element(boundBy: 0).value as? String ?? ""
        let tailText = blocks.element(boundBy: 1).value as? String ?? ""
        XCTAssertEqual(head + tailText, "Первый", "Разрез потерял или продублировал текст")
        XCTAssertFalse(head.isEmpty, "Каретка встала в начало строки, а не по месту тапа")
        XCTAssertFalse(tailText.isEmpty, "Каретка встала в конец строки, а не по месту тапа")

        // Backspace в начале второго абзаца склеивает их обратно
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(waitFor(blocks, count: 1), "Backspace не склеил абзацы")
        XCTAssertEqual(blocks.firstMatch.value as? String, "Первый")
    }

    // Перестановка блоков живёт в режиме выделения: contextMenu и draggable
    // на одном вью в SwiftUI не уживаются, поэтому жесты разведены по режимам.
    //
    // Само перетаскивание XCUITest воспроизвести не может — press(forDuration:
    // thenDragTo:) не поднимает drag-сессию UIKit, — поэтому тест проверяет
    // режим выделения и доступную замену перетаскиванию («Ещё» → «Ниже»),
    // а сам жест проверяется вручную в симуляторе.
    func testSelectionModeReordersParagraphs() throws {
        let app = XCUIApplication()
        app.launch()
        unlock(app)

        createFeedFolder(named: "Лента DnD", in: app)
        app.staticTexts["Лента DnD"].firstMatch.tap()

        let blocks = app.textViews.matching(identifier: "feedTextBlock")
        let tail = app.buttons["feedTail"]
        XCTAssertTrue(tail.waitForExistence(timeout: 10))
        tail.tap()
        XCTAssertTrue(blocks.firstMatch.waitForExistence(timeout: 5))

        // Каждый абзац начинаем тапом по «хвосту» страницы
        app.typeText("Раз")
        tail.tap()
        XCTAssertTrue(waitFor(blocks, count: 2), "Тап по хвосту не начал второй абзац")
        app.typeText("Два")
        tail.tap()
        XCTAssertTrue(waitFor(blocks, count: 3), "Тап по хвосту не начал третий абзац")
        app.typeText("Три")
        XCTAssertTrue(waitForValues(blocks, equal: ["Раз", "Два", "Три"]))

        app.buttons["Выбрать"].tap()
        let toggles = app.buttons.matching(identifier: "feedBlockToggle")
        XCTAssertTrue(waitFor(toggles, count: 3), "Кружки выделения не появились")
        toggles.element(boundBy: 0).tap()

        // Движение вниз раньше промахивалось мимо соседа на один индекс
        app.buttons["Ещё"].tap()
        app.buttons["Переместить ниже"].tap()
        XCTAssertTrue(
            waitForValues(blocks, equal: ["Два", "Раз", "Три"]),
            "Порядок после перестановки: \(values(of: blocks))"
        )

        // Выделение переезжает вместе с блоком и остаётся активным
        app.buttons["Ещё"].tap()
        app.buttons["Переместить выше"].tap()
        XCTAssertTrue(
            waitForValues(blocks, equal: ["Раз", "Два", "Три"]),
            "Порядок после возврата: \(values(of: blocks))"
        )
    }

    // MARK: - Хелперы

    private func unlock(_ app: XCUIApplication) {
        if app.staticTexts["Придумайте код"].waitForExistence(timeout: 10) {
            enterPin("1111", in: app)
            XCTAssertTrue(app.staticTexts["Повторите код"].waitForExistence(timeout: 5))
            enterPin("1111", in: app)
        } else if app.staticTexts["Введите код"].waitForExistence(timeout: 5) {
            enterPin("1111", in: app)
        }
        // Главная страница — чат, папки — на странице «Файлы»
        let filesPage = app.buttons["pageFiles"]
        XCTAssertTrue(filesPage.waitForExistence(timeout: 10))
        filesPage.tap()
        XCTAssertTrue(app.buttons["Новая папка"].waitForExistence(timeout: 10))
    }

    private func enterPin(_ pin: String, in app: XCUIApplication) {
        for digit in pin {
            app.buttons[String(digit)].tap()
        }
    }

    private func createFeedFolder(named name: String, in app: XCUIApplication) {
        app.buttons["Новая папка"].tap()
        let field = app.textFields["Например, Документы"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)

        app.buttons["folderKind-feed"].tap()
        app.buttons["Готово"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
    }

    private func values(of query: XCUIElementQuery) -> [String] {
        query.allElementsBoundByIndex.map { $0.value as? String ?? "" }
    }

    private func waitForValues(
        _ query: XCUIElementQuery,
        equal expected: [String],
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if values(of: query) == expected { return true }
            // 0.5 с — заведомо больше окна двойного тапа (~0.35 с)
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func waitFor(_ query: XCUIElementQuery, count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if query.count == count { return true }
            // 0.5 с — заведомо больше окна двойного тапа (~0.35 с)
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
