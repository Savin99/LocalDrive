import XCTest
@testable import LocalDrive

// Язык выражений Generative UI: чистые функции, ошибки — пустое значение, а не падение
final class GenUIExpressionTests: XCTestCase {
    private let today = GenUIDay(year: 2026, month: 10, day: 12)!

    private func eval(_ source: String, _ variables: [String: GenUIScalar] = [:]) throws -> GenUIScalar? {
        let expression = try GenUIExpression(parsing: source)
        var evaluator = GenUIEvaluator(scope: GenUIScope { variables[$0] }, today: { [today] in today })
        return evaluator.evaluate(expression)
    }

    /// Неразрывные пробелы русских форматов — обычными, чтобы сравнивать строки
    private func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testArithmeticPrecedence() throws {
        XCTAssertEqual(try eval("1 + 2 * 3"), .number(7))
        XCTAssertEqual(try eval("(1 + 2) * 3"), .number(9))
        XCTAssertEqual(try eval("2 ^ 3 ^ 2"), .number(512), "степень правоассоциативна")
        XCTAssertEqual(try eval("-2 ^ 2"), .number(-4), "степень сильнее унарного минуса")
        XCTAssertEqual(try eval("10 % 4"), .number(2))
        XCTAssertEqual(try eval("7 / 2"), .number(3.5))
        XCTAssertEqual(try eval("amount * rate / 100", ["amount": .number(1000), "rate": .number(18.5)]), .number(185))
    }

    func testComparisonsLogicAndTernary() throws {
        XCTAssertEqual(try eval("3 > 2 && 1 == 1"), .bool(true))
        XCTAssertEqual(try eval("!(1 < 0) || false"), .bool(true))
        XCTAssertEqual(try eval("x > 5 ? 'много' : 'мало'", ["x": .number(7)]), .string("много"))
        XCTAssertEqual(try eval("'Итого: ' + 5"), .string("Итого: 5"))
    }

    func testErrorsAreEmptyNotCrashes() throws {
        XCTAssertNil(try eval("1 / 0"))
        XCTAssertNil(try eval("5 % 0"))
        XCTAssertNil(try eval("sqrt(-1)"))
        XCTAssertNil(try eval("unknown + 1"), "неизвестная переменная — пусто")
        // Ветви if и && вычисляются лениво
        XCTAssertEqual(try eval("if(n == 0, 0, 10 / n)", ["n": .number(0)]), .number(0))
        XCTAssertEqual(try eval("n != 0 && 10 / n > 1", ["n": .number(0)]), .bool(false))
    }

    func testFunctions() throws {
        XCTAssertEqual(try eval("round(2.346, 2)"), .number(2.35))
        XCTAssertEqual(try eval("min(3, 1, 2)"), .number(1))
        XCTAssertEqual(try eval("max(3, 1, 2)"), .number(3))
        XCTAssertEqual(try eval("clamp(15, 0, 10)"), .number(10))
        XCTAssertEqual(try eval("pow(2, 10)"), .number(1024))
        XCTAssertEqual(try eval("sqrt(16) + abs(-3) + floor(2.7) + ceil(2.1)"), .number(12))
        XCTAssertEqual(try eval("coalesce(missing, 7)"), .number(7))
    }

    func testDates() throws {
        XCTAssertEqual(try eval("today()"), .date(today))
        XCTAssertEqual(try eval("add_months(date('2026-01-31'), 1)"), .date(GenUIDay(year: 2026, month: 2, day: 28)!), "конец месяца")
        XCTAssertEqual(try eval("add_years('2024-02-29', 1)"), .date(GenUIDay(year: 2025, month: 2, day: 28)!))
        XCTAssertEqual(try eval("days_between('2026-10-12', '2026-12-31')"), .number(80))
        XCTAssertEqual(try eval("years_between('2003-02-16', today())"), .number(23))
        XCTAssertEqual(try eval("format_date(add_days(today(), 30))"), .string("11.11.2026"))
        XCTAssertNil(GenUIDay(iso: "2026-02-30"), "31.02 и 30.02 не бывает")
    }

    func testRussianFormats() throws {
        XCTAssertEqual(plain(try eval("format_number(1234567.891, 2)")?.string), "1 234 567,89")
        XCTAssertEqual(plain(try eval("percent(18.5)")?.string), "18,5 %")
        let money = plain(try eval("format_money(234.5)")?.string) ?? ""
        XCTAssertTrue(money.hasPrefix("234,5") && money.hasSuffix("₽"), money)
        let large = plain(try eval("format_money(3602995.47)")?.string) ?? ""
        XCTAssertTrue(large.hasPrefix("3 602 995 ") && large.hasSuffix("₽"), "от тысячи — без копеек: \(large)")
        XCTAssertEqual(GenUIFormat.display(.bool(true)), "да")
        XCTAssertEqual(GenUIFormat.display(nil), "—")
    }

    func testParseErrors() {
        XCTAssertThrowsError(try GenUIExpression(parsing: "amount * * 2"))
        XCTAssertThrowsError(try GenUIExpression(parsing: "system('ls')")) { error in
            XCTAssertEqual(error as? GenUIExpressionError, .unknownFunction("system"))
        }
        XCTAssertThrowsError(try GenUIExpression(parsing: "round()")) { error in
            XCTAssertEqual(error as? GenUIExpressionError, .wrongArgumentCount("round"))
        }
        XCTAssertThrowsError(try GenUIExpression(parsing: String(repeating: "1+", count: 160) + "1")) { error in
            XCTAssertEqual(error as? GenUIExpressionError, .tooLong)
        }
        XCTAssertThrowsError(try GenUIExpression(parsing: String(repeating: "(", count: 40) + "1" + String(repeating: ")", count: 40))) { error in
            XCTAssertEqual(error as? GenUIExpressionError, .tooComplex)
        }
        XCTAssertThrowsError(try GenUIExpression(parsing: "'незакрытая"))
        XCTAssertThrowsError(try GenUIExpression(parsing: "a; b"))
    }

    func testTemplates() throws {
        let template = try GenUITemplate(parsing: "Платёж — {{ round(x) }} ₽, срок {{ n }}")
        XCTAssertEqual(template.variables, ["x", "n"])
        XCTAssertFalse(template.isConstant)
        XCTAssertThrowsError(try GenUITemplate(parsing: "{{ x "))
        XCTAssertTrue(try GenUITemplate(parsing: "Просто текст").isConstant)
    }
}
