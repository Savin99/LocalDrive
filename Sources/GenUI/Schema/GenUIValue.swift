import Foundation

/// Лимиты ответа (docs/genui.md). Больше этого модель не прислала бы для
/// полезного ответа — а рендер и выражения остаются быстрыми и предсказуемыми
enum GenUILimits {
    static let maxBlocks = 80
    static let maxDepth = 6
    static let maxStateVariables = 30
    static let maxComputed = 20
    static let maxTableRows = 200
    static let maxTableColumns = 8
    static let maxChartPoints = 500
    static let maxTextLength = 4000
    static let maxExpressionLength = 300
    static let maxTemplateExpressions = 10
    static let maxOptions = 50
    static let maxIDLength = 40
    static let maxListItems = 50
    static let maxTabs = 8
    static let maxLabelLength = 200
}

/// Значение свойства: готовое или выражение над состоянием
enum GenUIValue: Hashable, Sendable {
    case literal(GenUIScalar)
    case expression(GenUIExpression)

    var expression: GenUIExpression? {
        if case .expression(let expression) = self { return expression }
        return nil
    }
}

/// Строка с подстановками «{{ выражение }}»: «Платёж — {{ format_money(payment) }}»
struct GenUITemplate: Hashable, Sendable, CustomStringConvertible {
    enum Part: Hashable, Sendable {
        case text(String)
        case expression(GenUIExpression)
    }

    let parts: [Part]

    init(text: String) {
        parts = [.text(text)]
    }

    init(parsing source: String) throws {
        var parts: [Part] = []
        var rest = Substring(source)
        var expressions = 0
        while let open = rest.range(of: "{{") {
            if open.lowerBound > rest.startIndex { parts.append(.text(String(rest[..<open.lowerBound]))) }
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                throw GenUIExpressionError.unexpectedToken("{{")
            }
            expressions += 1
            guard expressions <= GenUILimits.maxTemplateExpressions else { throw GenUIExpressionError.tooComplex }
            parts.append(.expression(try GenUIExpression(parsing: String(rest[open.upperBound..<close.lowerBound]))))
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { parts.append(.text(String(rest))) }
        self.parts = parts
    }

    var isConstant: Bool {
        parts.allSatisfy { if case .text = $0 { true } else { false } }
    }

    var variables: Set<String> {
        parts.reduce(into: Set<String>()) { names, part in
            if case .expression(let expression) = part { names.formUnion(expression.variables) }
        }
    }

    /// Строка без подстановок — для журналов и проверки
    var description: String {
        parts.map { part in
            switch part {
            case .text(let text): text
            case .expression(let expression): "{{ \(expression.source) }}"
            }
        }.joined()
    }
}
