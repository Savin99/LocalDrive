import XCTest

// Документ из «Файлов» должен оказаться в папке. Раньше ошибка копирования
// молча пропускалась, и «Открыть» в окне выбора выглядела нерабочей.
// Источник — подсказка «Куда положить копию.txt», которую приложение кладёт
// в свою папку в «Файлах» при запуске: она есть на любом симуляторе
final class ImportUITests: XCTestCase {
    func testDocumentFromFilesAppearsInFolder() throws {
        let app = XCUIApplication()
        app.launch()

        let files = app.buttons["pageFiles"]
        XCTAssertTrue(files.waitForExistence(timeout: 10))
        files.tap()
        app.buttons["Новая папка"].tap()
        let name = app.textFields["Например, Документы"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Импорт QA")
        app.buttons["Готово"].tap()
        app.staticTexts["Импорт QA"].firstMatch.tap()

        app.buttons["Добавить файл"].tap()
        app.buttons["Документ из «Файлов»"].tap()

        // Окно выбора открывается на «Недавних» или на последней папке
        // Окно выбора помнит прошлую папку: тогда «Обзор» — и вкладка, и кнопка «назад»
        let browse = app.buttons["Обзор"].firstMatch
        if browse.waitForExistence(timeout: 5) { browse.tap() }
        // В системной подписи «На iPhone» неразрывный пробел — точное
        // сравнение строк его не находит
        // Чип модели на поле ввода тоже подписан «iPhone», но место в «Файлах» —
        // «На iPhone» (On My iPhone)
        let onDevice = NSPredicate(format: "(label BEGINSWITH %@ OR label BEGINSWITH %@) AND label CONTAINS %@", "На", "On", "iPhone")
        let place = app.buttons.matching(onDevice).firstMatch.exists
            ? app.buttons.matching(onDevice).firstMatch
            : app.staticTexts.matching(onDevice).firstMatch
        if place.waitForExistence(timeout: 3) { place.tap() }
        let appFolder = app.staticTexts["LocalDrive"].firstMatch
        if appFolder.waitForExistence(timeout: 5) { appFolder.tap() }

        let hint = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Куда положить")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "в окне выбора нет файла-подсказки\n" + app.debugDescription)
        hint.tap()
        let open = app.buttons["Открыть"]
        if open.waitForExistence(timeout: 3), open.isEnabled { open.tap() }

        let imported = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Куда положить")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 10), "файл не появился в папке после «Открыть»")
        XCTAssertFalse(app.alerts["Файл не добавлен"].exists)
    }
}
