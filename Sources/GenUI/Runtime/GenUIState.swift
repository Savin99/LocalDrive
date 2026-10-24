import Foundation
import Observation

/// Состояние одного сообщения с интерфейсом: переменные, к которым привязаны
/// поля ввода, и именованные выражения `computed`. Зависимостей вручную не
/// строим: вью вычисляют выражения в `body`, и Observation сам перерисует
/// всё, что читало изменившуюся переменную
@MainActor
@Observable
final class GenUIState {
    private(set) var values: [String: GenUIScalar] = [:]
    private(set) var kinds: [String: GenUIValueKind] = [:]
    /// Вкладка, раскрытый раздел, «показать все строки» — переживают
    /// перерисовку, но модели не отправляются
    private(set) var interface: [String: GenUIScalar] = [:]
    /// Растёт при каждом изменении переменных. Через него вью следят за
    /// `computed`, чьи значения берутся из кэша
    private(set) var revision = 0

    @ObservationIgnored private var initial: [String: GenUIScalar] = [:]
    @ObservationIgnored private(set) var computed: [String: GenUIExpression] = [:]
    @ObservationIgnored private var computedOrder: [String] = []
    @ObservationIgnored private var evaluating: Set<String> = []
    /// Кэш `computed` на текущую ревизию: цепочка «a = b + b, b = c + c…»
    /// без него считалась бы экспоненциально
    @ObservationIgnored private var cache: [String: GenUIScalar?] = [:]
    @ObservationIgnored private var cacheRevision = -1
    @ObservationIgnored var today: () -> GenUIDay = { GenUIDay(date: Date()) }

    init() {}

    init(document: GenUIDocument) {
        apply(document)
    }

    /// Состояние из ответа. `keepingChanges` — при окончании потока: то, что
    /// человек уже подвигал, не сбрасывается на начальное
    func apply(_ document: GenUIDocument, keepingChanges: Bool = false) {
        for (name, value) in document.state {
            initial[name] = value
            if !keepingChanges || values[name] == nil { values[name] = value }
            if let kind = value.kind, kinds[name] == nil { kinds[name] = kind }
        }
        merge(binds: document.binds)
        setComputed(document.computed)
        revision &+= 1
    }

    /// Начальные значения, пришедшие в потоке раньше блоков
    func declare(_ state: [(name: String, value: GenUIScalar)]) {
        for (name, value) in state {
            initial[name] = value
            if values[name] == nil { values[name] = value }
            if let kind = value.kind, kinds[name] == nil { kinds[name] = kind }
        }
        revision &+= 1
    }

    /// Поля ввода задают тип переменной; без значения — значение поля по умолчанию
    func merge(binds: [String: GenUIBind]) {
        for (name, bind) in binds {
            kinds[name] = bind.kind
            if let value = values[name] {
                if value.kind != bind.kind { values[name] = value.coerced(to: bind.kind) ?? bind.defaultValue }
            } else {
                values[name] = bind.defaultValue
            }
            if initial[name] == nil { initial[name] = values[name] }
        }
        revision &+= 1
    }

    func setComputed(_ list: [(name: String, expression: GenUIExpression)]) {
        computed = Dictionary(list.map { ($0.name, $0.expression) }, uniquingKeysWith: { first, _ in first })
        computedOrder = list.map(\.name)
        revision &+= 1
    }

    /// Значение от поля ввода или действия `set`: приводится к типу переменной
    func set(_ name: String, _ value: GenUIScalar) {
        guard GenUIParser.isValidVariable(name) else { return }
        if let kind = kinds[name] {
            guard let coerced = value.coerced(to: kind) else { return }
            values[name] = coerced
        } else {
            guard values.count < GenUILimits.maxStateVariables * 2 else { return }
            values[name] = value
            if let kind = value.kind { kinds[name] = kind }
        }
        revision &+= 1
    }

    /// К начальным значениям — все или перечисленные
    func reset(_ names: [String]? = nil) {
        for name in names ?? Array(initial.keys) {
            if let value = initial[name] { values[name] = value }
        }
        revision &+= 1
    }

    /// Переменная состояния или `computed`. Цикл в `computed` даёт nil
    func value(_ name: String) -> GenUIScalar? {
        if let value = values[name] { return value }
        guard let expression = computed[name] else { return nil }
        // Чтение ревизии — подписка вью на любые изменения, от которых
        // зависит `computed`
        let current = revision
        if cacheRevision != current {
            cache.removeAll(keepingCapacity: true)
            cacheRevision = current
        }
        if let cached = cache[name] { return cached }
        guard !evaluating.contains(name), evaluating.count < GenUILimits.maxComputed else { return nil }
        evaluating.insert(name)
        defer { evaluating.remove(name) }
        var evaluator = GenUIEvaluator(scope: scope, today: today)
        let result = evaluator.evaluate(expression)
        cache[name] = .some(result)
        return result
    }

    var scope: GenUIScope {
        GenUIScope { [unowned self] name in self.value(name) }
    }

    func evaluate(_ value: GenUIValue, extra: [String: GenUIScalar] = [:]) -> GenUIScalar? {
        switch value {
        case .literal(let scalar): scalar
        case .expression(let expression): evaluate(expression, extra: extra)
        }
    }

    func evaluate(_ expression: GenUIExpression, extra: [String: GenUIScalar] = [:]) -> GenUIScalar? {
        var evaluator = GenUIEvaluator(scope: extra.isEmpty ? scope : scope.with(extra), today: today)
        return evaluator.evaluate(expression)
    }

    func text(_ template: GenUITemplate, extra: [String: GenUIScalar] = [:]) -> String {
        template.parts.map { part in
            switch part {
            case .text(let text): text
            case .expression(let expression): GenUIFormat.display(evaluate(expression, extra: extra))
            }
        }.joined()
    }

    func interfaceValue(_ key: String) -> GenUIScalar? {
        interface[key]
    }

    func setInterface(_ key: String, _ value: GenUIScalar) {
        interface[key] = value
    }

    /// Значения для приложения и модели: перечисленные или все, вместе с `computed`
    func snapshot(include names: [String]? = nil) -> GenUIStateSnapshot {
        let keys = names ?? (values.keys.sorted() + computedOrder)
        var result: [String: GenUIScalar] = [:]
        for name in keys {
            if let value = value(name) { result[name] = value }
        }
        return GenUIStateSnapshot(values: result)
    }
}

/// Значения состояния, переданные приложению или модели
struct GenUIStateSnapshot: Hashable, Sendable {
    let values: [String: GenUIScalar]

    var json: JSONValue {
        .object(values.mapValues(\.json))
    }

    /// Для текста сообщения: «amount: 3 000 000; rate: 18,5»
    var summary: String {
        values.keys.sorted().map { "\($0): \(GenUIFormat.display(values[$0]))" }.joined(separator: "; ")
    }
}
