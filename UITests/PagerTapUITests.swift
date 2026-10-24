import XCTest

// Нажатие на карточку папки сразу после листания страниц открывает именно её,
// а жест, начатый на карточке, папку не открывает. Владелец, сборка 17:
// «свайпаю между экранами — на странице папок ложные нажатия: нажимаю одну
// папку, открывается другая». Шесть папок в два столбца; после
// переключателя, свайпов, недотянутого свайпа и штриха по карточке нажатие
// приходится в середину заранее известной карточки — открыться должна она.
// Первый круг жмёт сразу, пока страницы ещё могут доезжать, второй — когда
// они встали. Штрих по карточке сразу после свайпа с чата открывал её:
// штрих «Файлов» не слушал касания, пока не затихнет пружина листания
final class PagerTapUITests: XCTestCase {
    private let names = (1...6).map { "Тап \($0)" }

    func testFolderTapRightAfterPagingOpensTappedFolder() throws {
        let app = XCUIApplication()
        app.launch()

        let chatPage = app.buttons["pageChat"]
        let filesPage = app.buttons["pageFiles"]
        let cardsPage = app.buttons["pageCards"]
        let newFolder = app.buttons["Новая папка"]
        XCTAssertTrue(chatPage.waitForExistence(timeout: 10), "главный экран не открылся")

        filesPage.tap()
        XCTAssertTrue(waitUntil { newFolder.isHittable }, "переключатель не открыл «Файлы»")
        for name in names where !app.staticTexts[name].firstMatch.exists {
            createFolder(name, in: app)
        }

        // Середины подписей карточек в покое — сюда и жмём
        var targets: [String: CGPoint] = [:]
        for name in names {
            let label = app.staticTexts[name].firstMatch
            XCTAssertTrue(label.isHittable, "карточка «\(name)» не видна целиком\n" + app.debugDescription)
            targets[name] = CGPoint(x: label.frame.midX, y: label.frame.midY)
        }
        let width = app.windows.firstMatch.frame.width
        XCTAssertEqual(Set(targets.values.map { $0.x < width / 2 }).count, 2, "папки не в два столбца")

        // Свайп с карточки начинается на ней, а жмём потом другую: нажатие,
        // прерванное свайпом, не должно достаться следующему касанию
        let scenarios: [(name: String, startCard: String?, run: () -> Void)] = [
            ("переключатель с чата", nil, {
                chatPage.tap()
                XCTAssertTrue(self.waitUntil { chatPage.isSelected })
                filesPage.tap()
            }),
            ("свайп влево с чата", nil, {
                chatPage.tap()
                XCTAssertTrue(self.waitUntil { chatPage.isSelected })
                app.swipeLeft()
            }),
            ("недотянутый свайп от левого края", nil, {
                self.drag(app, from: CGPoint(x: 3, y: targets["Тап 3"]!.y), by: CGVector(dx: width * 0.2, dy: 0))
            }),
            ("недотянутый свайп от правого края", nil, {
                self.drag(app, from: CGPoint(x: width - 3, y: targets["Тап 4"]!.y), by: CGVector(dx: -width * 0.2, dy: 0))
            }),
            ("свайп вправо с «Карточек»", nil, {
                cardsPage.tap()
                XCTAssertTrue(self.waitUntil { cardsPage.isSelected })
                app.swipeRight()
            }),
            ("свайп с карточки к чату и обратно", "Тап 3", {
                let start = targets["Тап 3"]!
                self.drag(app, from: start, by: CGVector(dx: width - 8 - start.x, dy: 0), velocity: .fast)
                XCTAssertTrue(self.waitUntil { chatPage.isSelected })
                app.swipeLeft()
            }),
            ("свайп с карточки к «Карточкам» и обратно", "Тап 4", {
                let start = targets["Тап 4"]!
                self.drag(app, from: start, by: CGVector(dx: 8 - start.x, dy: 0), velocity: .fast)
                XCTAssertTrue(self.waitUntil { cardsPage.isSelected })
                app.swipeRight()
            }),
            ("короткий штрих по карточке без листания", "Тап 5", {
                self.drag(app, from: targets["Тап 5"]!, by: CGVector(dx: 60, dy: 0))
            }),
            ("протяжка вниз с карточки", "Тап 2", {
                self.drag(app, from: targets["Тап 2"]!, by: CGVector(dx: 0, dy: 80))
            }),
            // Страница уже стоит, но пружина ещё не затихла
            ("штрих по карточке сразу после переключателя", "Тап 5", {
                chatPage.tap()
                XCTAssertTrue(self.waitUntil { chatPage.isSelected })
                filesPage.tap()
                self.drag(app, from: targets["Тап 5"]!, by: CGVector(dx: 60, dy: 0))
            }),
            ("штрих по карточке сразу после свайпа с чата", "Тап 6", {
                chatPage.tap()
                XCTAssertTrue(self.waitUntil { chatPage.isSelected })
                app.swipeLeft()
                self.drag(app, from: targets["Тап 6"]!, by: CGVector(dx: -60, dy: 0))
            }),
        ]

        // Цели чередуют столбцы и ряды: сдвиг на столбец открыл бы соседнюю
        let order = [1, 0, 3, 2, 5, 4]
        var misses: [String] = []
        for (round, waitsForSettle) in [false, true].enumerated() {
            for (index, scenario) in scenarios.enumerated() {
                var target = names[order[(index + round) % order.count]]
                if target == scenario.startCard {
                    target = names[order[(index + round + 1) % order.count]]
                }
                scenario.run()
                if waitsForSettle { Thread.sleep(forTimeInterval: 1) }
                let early = app.navigationBars.matching(NSPredicate(format: "identifier IN %@", names)).firstMatch
                if early.exists {
                    misses.append("\(scenario.name): папку «\(early.identifier)» открыл сам жест")
                    swipeFromLeftEdge(app)
                    XCTAssertTrue(waitUntil { newFolder.isHittable })
                }
                let point = targets[target]!
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: point.x, dy: point.y))
                    .tap()

                let opened = openedFolder(in: app)
                if opened != target {
                    let when = waitsForSettle ? "после остановки" : "сразу"
                    misses.append("\(scenario.name), \(when): жали «\(target)», открылась \(opened.map { "«\($0)»" } ?? "ни одна")")
                }
                if opened != nil {
                    swipeFromLeftEdge(app)
                }
                XCTAssertTrue(
                    waitUntil { filesPage.exists && filesPage.isSelected && newFolder.isHittable },
                    "после «\(scenario.name)» не вернулись на корень «Файлов»"
                )
            }
        }
        XCTAssertTrue(misses.isEmpty, "нажатие открыло не ту папку:\n" + misses.joined(separator: "\n"))
    }

    // MARK: - Хелперы

    /// Какая из папок теста открылась: её имя — заголовок шапки
    private func openedFolder(in app: XCUIApplication) -> String? {
        let bars = app.navigationBars.matching(NSPredicate(format: "identifier IN %@", names))
        guard bars.firstMatch.waitForExistence(timeout: 3) else { return nil }
        return bars.firstMatch.identifier
    }

    /// Протяжка из точки окна. Медленная от края не дотягивает до порога —
    /// страницы едут за пальцем и возвращаются
    private func drag(
        _ app: XCUIApplication,
        from point: CGPoint,
        by offset: CGVector,
        velocity: XCUIGestureVelocity = .slow
    ) {
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(offset), withVelocity: velocity, thenHoldForDuration: 0)
    }

    private func swipeFromLeftEdge(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 3, dy: 0))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func createFolder(_ name: String, in app: XCUIApplication) {
        app.buttons["Новая папка"].tap()
        let field = app.textFields["Например, Документы"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["Готово"].tap()
        XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 5), "папка «\(name)» не появилась")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }
}
