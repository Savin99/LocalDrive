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
    /// Имена с номером прогона: папки прошлых запусков остаются на симуляторе
    private let names: [String] = {
        let run = Int.random(in: 100...999)
        return (1...6).map { "Тап \($0)-\(run)" }
    }()

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
        for name in names {
            createFolder(name, in: app)
        }

        // Середины подписей карточек в покое — сюда и жмём. Меряются заново
        // перед каждым сценарием: папки других тестов сдвигают сетку, и
        // первая папка теста может встать в любой столбец
        let names = self.names
        let width = app.windows.firstMatch.frame.width
        var targets = measureCards(in: app)
        XCTAssertEqual(Set(targets.values.map { $0.x < width / 2 }).count, 2, "папки не в два столбца")
        /// Карточки столбца сверху вниз
        func column(left: Bool) -> [String] {
            names.filter { (targets[$0]!.x < width / 2) == left }.sorted { targets[$0]!.y < targets[$1]!.y }
        }

        // Сценарий возвращает карточку, на которой начался жест: жмём потом
        // другую — нажатие, прерванное жестом, не должно достаться следующему
        // касанию. Свайп к чату — из левого столбца, к «Карточкам» — из
        // правого: иначе путь до края короче порога листания
        let scenarios: [(name: String, scrolls: Bool, run: () -> String?)] = [
            ("переключатель с чата", false, {
                chatPage.tap()
                XCTAssertTrue(self.waitUntil { chatPage.isSelected })
                filesPage.tap()
                return nil
            }),
            ("свайп влево с чата", false, {
                chatPage.tap()
                XCTAssertTrue(self.waitUntil { chatPage.isSelected })
                app.swipeLeft()
                return nil
            }),
            ("недотянутый свайп от левого края", false, {
                let y = targets[column(left: true)[1]]!.y
                self.drag(app, from: CGPoint(x: 3, y: y), by: CGVector(dx: width * 0.2, dy: 0))
                return nil
            }),
            ("недотянутый свайп от правого края", false, {
                let y = targets[column(left: false)[1]]!.y
                self.drag(app, from: CGPoint(x: width - 3, y: y), by: CGVector(dx: -width * 0.2, dy: 0))
                return nil
            }),
            ("свайп вправо с «Карточек»", false, {
                cardsPage.tap()
                XCTAssertTrue(self.waitUntil { cardsPage.isSelected })
                app.swipeRight()
                return nil
            }),
            ("свайп с карточки к чату и обратно", false, {
                let card = column(left: true)[1]
                let start = targets[card]!
                self.drag(app, from: start, by: CGVector(dx: width - 8 - start.x, dy: 0), velocity: .fast)
                XCTAssertTrue(self.waitUntil { chatPage.isSelected }, "свайп с карточки не увёл к чату")
                app.swipeLeft()
                return card
            }),
            ("свайп с карточки к «Карточкам» и обратно", false, {
                let card = column(left: false)[1]
                let start = targets[card]!
                self.drag(app, from: start, by: CGVector(dx: 8 - start.x, dy: 0), velocity: .fast)
                XCTAssertTrue(self.waitUntil { cardsPage.isSelected }, "свайп с карточки не открыл «Карточки»")
                app.swipeRight()
                return card
            }),
            ("короткий штрих по карточке без листания", false, {
                let card = column(left: true)[2]
                self.drag(app, from: targets[card]!, by: CGVector(dx: 60, dy: 0))
                return card
            }),
            ("протяжка вниз с карточки", true, {
                let card = column(left: false)[0]
                self.drag(app, from: targets[card]!, by: CGVector(dx: 0, dy: 80))
                return card
            }),
            // Страница уже стоит, но пружина ещё не затихла
            ("штрих по карточке сразу после переключателя", false, {
                let card = column(left: true)[0]
                chatPage.tap()
                XCTAssertTrue(self.waitUntil { chatPage.isSelected })
                filesPage.tap()
                self.drag(app, from: targets[card]!, by: CGVector(dx: 60, dy: 0))
                return card
            }),
            ("штрих по карточке сразу после свайпа с чата", false, {
                let card = column(left: false)[2]
                chatPage.tap()
                XCTAssertTrue(self.waitUntil { chatPage.isSelected })
                app.swipeLeft()
                self.drag(app, from: targets[card]!, by: CGVector(dx: -60, dy: 0))
                return card
            }),
        ]

        // Цели чередуют столбцы и ряды: сдвиг на столбец открыл бы соседнюю
        let order = [1, 0, 3, 2, 5, 4]
        var misses: [String] = []
        for (round, waitsForSettle) in [false, true].enumerated() {
            for (index, scenario) in scenarios.enumerated() {
                targets = measureCards(in: app)
                let startCard = scenario.run()
                var target = names[order[(index + round) % order.count]]
                if target == startCard {
                    target = names[order[(index + round + 1) % order.count]]
                }
                if waitsForSettle || scenario.scrolls { Thread.sleep(forTimeInterval: 1) }
                // Протяжка вниз прокручивает сетку, если папок много
                if scenario.scrolls { targets = measureCards(in: app) }
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

    /// Карточки теста — в кадр, и середины их подписей. В симуляторе остаются
    /// папки других тестов, и папки теста оказываются в конце сетки
    private func measureCards(in app: XCUIApplication) -> [String: CGPoint] {
        let labels = names.map { app.staticTexts[$0].firstMatch }
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        let height = app.windows.firstMatch.frame.height
        // Под шапкой и над нижним полем поиска: подпись под стеклянным полем
        // XCTest считает доступной, а нажатие достаётся полю
        func inView(_ label: XCUIElement) -> Bool {
            label.isHittable && label.frame.minY > 120 && label.frame.maxY < height - 80
        }
        var attempts = 0
        while attempts < 20, !labels.allSatisfy(inView) {
            attempts += 1
            if !labels.last!.exists {
                // Сетка ещё не дошла до конца — быстрее взмахом
                app.swipeUp()
                continue
            }
            // Последняя не видна — листаем вниз, первая ушла за верх — назад
            let offset: CGFloat = inView(labels.last!) ? 150 : -150
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: offset)))
        }
        var points: [String: CGPoint] = [:]
        for (name, label) in zip(names, labels) {
            XCTAssertTrue(inView(label), "карточка «\(name)» не видна целиком\n" + app.debugDescription)
            points[name] = CGPoint(x: label.frame.midX, y: label.frame.midY)
        }
        return points
    }

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
        // Карточка встаёт в конец сетки и может быть за краем: её ищет measureCards
        XCTAssertTrue(waitUntil { !field.exists && app.buttons["Новая папка"].isHittable }, "редактор папки «\(name)» не закрылся")
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
