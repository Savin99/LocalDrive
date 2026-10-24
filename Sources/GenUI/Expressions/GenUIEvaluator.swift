import Foundation

/// Где выражение ищет переменные: состояние сообщения, переменная ряда в
/// `generate`, предыдущая строка ряда (`prev.колонка`)
struct GenUIScope {
    var lookup: (String) -> GenUIScalar?

    static let empty = GenUIScope { _ in nil }

    init(lookup: @escaping (String) -> GenUIScalar?) {
        self.lookup = lookup
    }

    /// Та же область и поверх неё значения ряда
    func with(_ values: [String: GenUIScalar]) -> GenUIScope {
        let base = lookup
        return GenUIScope { name in values[name] ?? base(name) }
    }
}

/// Вычисление выражения. Ошибка — деление на ноль, неверный тип, превышен
/// лимит шагов — даёт nil: в интерфейсе это «—», а не падение
struct GenUIEvaluator {
    /// Шагов на одно вычисление: защищает от выражения, которое считалось бы вечно
    static let maxSteps = 5_000

    var scope: GenUIScope
    var today: () -> GenUIDay = { GenUIDay(date: Date()) }
    private var steps = 0

    init(scope: GenUIScope, today: @escaping () -> GenUIDay = { GenUIDay(date: Date()) }) {
        self.scope = scope
        self.today = today
    }

    static func evaluate(_ expression: GenUIExpression, scope: GenUIScope) -> GenUIScalar? {
        var evaluator = GenUIEvaluator(scope: scope)
        return evaluator.evaluate(expression.root)
    }

    mutating func evaluate(_ expression: GenUIExpression) -> GenUIScalar? {
        steps = 0
        return evaluate(expression.root)
    }

    mutating func evaluate(_ node: GenUIExprNode) -> GenUIScalar? {
        steps += 1
        guard steps <= Self.maxSteps else { return nil }
        switch node {
        case .literal(let value):
            return value
        case .variable(let name):
            return scope.lookup(name)
        case .unary(let op, let operand):
            guard let value = evaluate(operand) else { return nil }
            switch op {
            case .negate: return value.number.map { .number(-$0) }
            case .plus: return value.number.map { .number($0) }
            case .not: return .bool(!value.truthy)
            }
        case .binary(let op, let lhs, let rhs):
            return binary(op, lhs, rhs)
        case .ternary(let condition, let then, let otherwise):
            guard let test = evaluate(condition) else { return nil }
            return evaluate(test.truthy ? then : otherwise)
        case .call(let name, let arguments):
            return call(name, arguments)
        }
    }

    // MARK: - Операторы

    private mutating func binary(_ op: GenUIExprNode.Binary, _ lhsNode: GenUIExprNode, _ rhsNode: GenUIExprNode) -> GenUIScalar? {
        // Логика — с коротким замыканием: «x != 0 && y / x > 1» безопасно
        if op == .and {
            guard let lhs = evaluate(lhsNode) else { return nil }
            guard lhs.truthy else { return .bool(false) }
            return evaluate(rhsNode).map { .bool($0.truthy) }
        }
        if op == .or {
            guard let lhs = evaluate(lhsNode) else { return nil }
            if lhs.truthy { return .bool(true) }
            return evaluate(rhsNode).map { .bool($0.truthy) }
        }
        guard let lhs = evaluate(lhsNode), let rhs = evaluate(rhsNode) else { return nil }
        switch op {
        case .add:
            if let a = lhs.number, let b = rhs.number { return finite(a + b) }
            // Строка с чем угодно — склейка, как в подписях «Итого: » + сумма
            if lhs.string != nil || rhs.string != nil { return .string(GenUIFormat.display(lhs) + GenUIFormat.display(rhs)) }
            return nil
        case .subtract: return numeric(lhs, rhs) { $0 - $1 }
        case .multiply: return numeric(lhs, rhs) { $0 * $1 }
        case .divide:
            guard let b = rhs.number, b != 0 else { return nil }
            return numeric(lhs, rhs) { a, _ in a / b }
        case .remainder:
            guard let b = rhs.number, b != 0 else { return nil }
            return numeric(lhs, rhs) { a, _ in a.truncatingRemainder(dividingBy: b) }
        case .power: return numeric(lhs, rhs) { Foundation.pow($0, $1) }
        case .equal: return .bool(Self.equal(lhs, rhs))
        case .notEqual: return .bool(!Self.equal(lhs, rhs))
        case .less, .lessEqual, .greater, .greaterEqual:
            guard let order = Self.compare(lhs, rhs) else { return nil }
            switch op {
            case .less: return .bool(order < 0)
            case .lessEqual: return .bool(order <= 0)
            case .greater: return .bool(order > 0)
            default: return .bool(order >= 0)
            }
        case .and, .or:
            return nil
        }
    }

    private func numeric(_ lhs: GenUIScalar, _ rhs: GenUIScalar, _ body: (Double, Double) -> Double) -> GenUIScalar? {
        guard let a = lhs.number, let b = rhs.number else { return nil }
        return finite(body(a, b))
    }

    private func finite(_ value: Double) -> GenUIScalar? {
        value.isFinite ? .number(value) : nil
    }

    static func equal(_ lhs: GenUIScalar, _ rhs: GenUIScalar) -> Bool {
        switch (lhs, rhs) {
        case (.number(let a), .number(let b)): return abs(a - b) < 1e-9 * max(1, abs(a), abs(b))
        case (.date(let a), _): return rhs.day == a
        case (_, .date(let b)): return lhs.day == b
        default: return lhs == rhs
        }
    }

    static func compare(_ lhs: GenUIScalar, _ rhs: GenUIScalar) -> Int? {
        if let a = lhs.number, let b = rhs.number { return a < b ? -1 : (a > b ? 1 : 0) }
        if let a = lhs.day, let b = rhs.day { return a < b ? -1 : (a == b ? 0 : 1) }
        if let a = lhs.string, let b = rhs.string { return a < b ? -1 : (a == b ? 0 : 1) }
        return nil
    }

    // MARK: - Функции

    private mutating func call(_ name: String, _ arguments: [GenUIExprNode]) -> GenUIScalar? {
        // Ветви «if» вычисляются лениво: «if(n == 0, 0, x / n)» не делит на ноль
        if name == "if" {
            guard let test = evaluate(arguments[0]) else { return nil }
            return evaluate(arguments[test.truthy ? 1 : 2])
        }
        if name == "coalesce" {
            if let first = evaluate(arguments[0]), !first.isNull { return first }
            return evaluate(arguments[1])
        }
        var values: [GenUIScalar] = []
        for argument in arguments {
            guard let value = evaluate(argument) else { return nil }
            values.append(value)
        }
        func number(_ index: Int) -> Double? { values.indices.contains(index) ? values[index].number : nil }
        func day(_ index: Int) -> GenUIDay? { values.indices.contains(index) ? values[index].day : nil }

        switch name {
        case "round":
            guard let x = number(0) else { return nil }
            let digits = max(0, min(6, Int(number(1) ?? 0)))
            let scale = Foundation.pow(10, Double(digits))
            return finite((x * scale).rounded() / scale)
        case "floor": return number(0).flatMap { finite($0.rounded(.down)) }
        case "ceil": return number(0).flatMap { finite($0.rounded(.up)) }
        case "abs": return number(0).flatMap { finite(Swift.abs($0)) }
        case "min":
            let numbers = values.compactMap(\.number)
            guard numbers.count == values.count else { return nil }
            return numbers.min().map(GenUIScalar.number)
        case "max":
            let numbers = values.compactMap(\.number)
            guard numbers.count == values.count else { return nil }
            return numbers.max().map(GenUIScalar.number)
        case "pow":
            guard let a = number(0), let b = number(1) else { return nil }
            return finite(Foundation.pow(a, b))
        case "sqrt":
            guard let x = number(0), x >= 0 else { return nil }
            return finite(x.squareRoot())
        case "log":
            guard let x = number(0), x > 0 else { return nil }
            return finite(Foundation.log(x))
        case "exp": return number(0).flatMap { finite(Foundation.exp($0)) }
        case "clamp":
            guard let x = number(0), let low = number(1), let high = number(2), low <= high else { return nil }
            return .number(Swift.min(Swift.max(x, low), high))
        case "today":
            return .date(today())
        case "date":
            return day(0).map(GenUIScalar.date)
        case "add_days", "add_months", "add_years":
            guard let start = day(0), let amount = number(1), amount.magnitude < 100_000 else { return nil }
            let component: Calendar.Component = name == "add_days" ? .day : (name == "add_months" ? .month : .year)
            return start.adding(component, Int(amount.rounded())).map(GenUIScalar.date)
        case "days_between":
            guard let a = day(0), let b = day(1),
                  let days = GenUIDay.calendar.dateComponents([.day], from: a.date, to: b.date).day else { return nil }
            return .number(Double(days))
        case "years_between":
            guard let a = day(0), let b = day(1),
                  let years = GenUIDay.calendar.dateComponents([.year], from: a.date, to: b.date).year else { return nil }
            return .number(Double(years))
        case "format_date":
            return day(0).map { .string($0.russian) }
        case "format_number":
            guard let x = number(0) else { return nil }
            return .string(GenUIFormat.number(x, digits: number(1).map { Int($0) }))
        case "format_money":
            guard let x = number(0) else { return nil }
            let currency = values.count > 1 ? (values[1].string ?? "RUB") : "RUB"
            return .string(GenUIFormat.money(x, currency: currency))
        case "percent":
            guard let x = number(0) else { return nil }
            return .string(GenUIFormat.percent(x, digits: number(1).map { Int($0) }))
        case "text":
            return .string(GenUIFormat.display(values[0]))
        case "number":
            if let x = values[0].number { return .number(x) }
            return values[0].coerced(to: .number)
        default:
            return nil
        }
    }
}

/// Русские форматы чисел, денег и дат — те же, что во всём приложении
enum GenUIFormat {
    static let locale = RussianFormat.locale

    /// «1 234,5». Без указания знаков — до двух после запятой
    static func number(_ value: Double, digits: Int? = nil) -> String {
        let style = FloatingPointFormatStyle<Double>.number.locale(locale)
        if let digits {
            let clamped = max(0, min(6, digits))
            return value.formatted(style.precision(.fractionLength(clamped)))
        }
        return value.formatted(style.precision(.fractionLength(0...2)))
    }

    /// «1 234 ₽», «12,5 $». От тысячи — без копеек: «3 602 995 ₽» читается,
    /// а «3 602 995,47 ₽» в показателе не помещается в строку
    static func money(_ value: Double, currency: String = "RUB") -> String {
        let code = currency.uppercased()
        let digits = Swift.abs(value) >= 1000 || value.rounded() == value ? 0...0 : 0...2
        return value.formatted(.currency(code: code).precision(.fractionLength(digits)).locale(locale))
    }

    /// Число уже в процентах: percent(18.5) → «18,5 %»
    static func percent(_ value: Double, digits: Int? = nil) -> String {
        number(value, digits: digits) + "\u{00A0}%"
    }

    static func display(_ value: GenUIScalar?) -> String {
        guard let value else { return "—" }
        switch value {
        case .null: return "—"
        case .bool(let flag): return flag ? "да" : "нет"
        case .number(let number): return self.number(number)
        case .string(let text): return text
        case .date(let day): return day.russian
        }
    }

    /// Значение в колонке таблицы, в показателе или подписи оси
    static func formatted(_ value: GenUIScalar?, as format: GenUIValueFormat?) -> String {
        guard let value else { return "—" }
        switch format ?? .automatic {
        case .automatic, .text: return display(value)
        case .number: return value.number.map { number($0) } ?? display(value)
        case .integer: return value.number.map { number($0.rounded(), digits: 0) } ?? display(value)
        case .money: return value.number.map { money($0) } ?? display(value)
        case .percent: return value.number.map { percent($0) } ?? display(value)
        case .date: return value.day?.russian ?? display(value)
        }
    }
}

/// Как показать значение: в таблице, показателе, ползунке
enum GenUIValueFormat: String, Hashable, Sendable, CaseIterable {
    case automatic = "auto"
    case text
    case number
    case integer
    case money
    case percent
    case date
}
