import Foundation

// Маленький язык выражений: арифметика, сравнения, логика, тернарный
// оператор и белый список чистых функций. Не код: разбирается один раз при
// проверке ответа и вычисляется над переменными состояния. Ни присваиваний,
// ни циклов, ни доступа к чему-либо, кроме переданных значений

/// Разобранное выражение. Равенство — по исходному тексту
struct GenUIExpression: Hashable, Sendable, CustomStringConvertible {
    let source: String
    let root: GenUIExprNode

    init(parsing source: String) throws {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GenUIExpressionError.empty }
        guard trimmed.count <= GenUILimits.maxExpressionLength else { throw GenUIExpressionError.tooLong }
        var parser = GenUIExprParser(tokens: try GenUIExprLexer.tokens(trimmed))
        root = try parser.parseExpression()
        self.source = trimmed
    }

    var description: String { source }

    /// Имена переменных в выражении — для проверки и автоматического объявления
    var variables: Set<String> {
        var names = Set<String>()
        root.collectVariables(into: &names)
        return names
    }

    static func == (lhs: GenUIExpression, rhs: GenUIExpression) -> Bool { lhs.source == rhs.source }
    func hash(into hasher: inout Hasher) { hasher.combine(source) }
}

enum GenUIExpressionError: Error, Equatable, CustomStringConvertible {
    case empty
    case tooLong
    case tooComplex
    case unexpectedCharacter(Character)
    case unterminatedString
    case unexpectedToken(String)
    case unknownFunction(String)
    case wrongArgumentCount(String)

    var description: String {
        switch self {
        case .empty: "пустое выражение"
        case .tooLong: "выражение длиннее \(GenUILimits.maxExpressionLength) знаков"
        case .tooComplex: "выражение слишком сложное"
        case .unexpectedCharacter(let character): "недопустимый символ «\(character)»"
        case .unterminatedString: "незакрытая строка"
        case .unexpectedToken(let token): "неожиданное «\(token)»"
        case .unknownFunction(let name): "неизвестная функция \(name)"
        case .wrongArgumentCount(let name): "неверное число аргументов у \(name)"
        }
    }
}

indirect enum GenUIExprNode: Hashable, Sendable {
    enum Unary: Hashable, Sendable { case negate, not, plus }
    enum Binary: Hashable, Sendable {
        case add, subtract, multiply, divide, remainder, power
        case equal, notEqual, less, lessEqual, greater, greaterEqual
        case and, or
    }

    case literal(GenUIScalar)
    case variable(String)
    case unary(Unary, GenUIExprNode)
    case binary(Binary, GenUIExprNode, GenUIExprNode)
    case ternary(GenUIExprNode, GenUIExprNode, GenUIExprNode)
    case call(String, [GenUIExprNode])

    func collectVariables(into names: inout Set<String>) {
        switch self {
        case .literal: break
        case .variable(let name): names.insert(name)
        case .unary(_, let operand): operand.collectVariables(into: &names)
        case .binary(_, let lhs, let rhs):
            lhs.collectVariables(into: &names)
            rhs.collectVariables(into: &names)
        case .ternary(let condition, let then, let otherwise):
            condition.collectVariables(into: &names)
            then.collectVariables(into: &names)
            otherwise.collectVariables(into: &names)
        case .call(_, let arguments):
            for argument in arguments { argument.collectVariables(into: &names) }
        }
    }
}

/// Функции языка: имя → допустимое число аргументов. Только чистые функции
enum GenUIFunctions {
    static let arity: [String: ClosedRange<Int>] = [
        "round": 1...2, "floor": 1...1, "ceil": 1...1, "abs": 1...1,
        "min": 1...20, "max": 1...20, "pow": 2...2, "sqrt": 1...1,
        "log": 1...1, "exp": 1...1, "clamp": 3...3, "if": 3...3, "coalesce": 2...2,
        "today": 0...0, "date": 1...1, "add_days": 2...2, "add_months": 2...2, "add_years": 2...2,
        "days_between": 2...2, "years_between": 2...2,
        "format_date": 1...1, "format_number": 1...2, "format_money": 1...2, "percent": 1...2,
        "text": 1...1, "number": 1...1,
    ]
}

// MARK: - Лексер

enum GenUIExprToken: Equatable {
    case number(Double)
    case string(String)
    case identifier(String)
    case symbol(String)
    case end

    var text: String {
        switch self {
        case .number(let value): GenUIFormat.number(value)
        case .string(let value): "'\(value)'"
        case .identifier(let name): name
        case .symbol(let symbol): symbol
        case .end: "конец выражения"
        }
    }
}

enum GenUIExprLexer {
    private static let twoCharacterSymbols: Set<String> = ["==", "!=", "<=", ">=", "&&", "||"]
    private static let oneCharacterSymbols: Set<Character> = ["+", "-", "*", "/", "%", "^", "<", ">", "!", "?", ":", "(", ")", ","]

    static func tokens(_ source: String) throws -> [GenUIExprToken] {
        var tokens: [GenUIExprToken] = []
        let characters = Array(source)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            if character.isNumber || (character == "." && index + 1 < characters.count && characters[index + 1].isNumber) {
                var end = index
                var seenExponent = false
                while end < characters.count {
                    let current = characters[end]
                    if current.isNumber || current == "." {
                        end += 1
                    } else if (current == "e" || current == "E"), !seenExponent {
                        seenExponent = true
                        end += 1
                        if end < characters.count, characters[end] == "-" || characters[end] == "+" { end += 1 }
                    } else {
                        break
                    }
                }
                guard let value = Double(String(characters[index..<end])), value.isFinite else {
                    throw GenUIExpressionError.unexpectedCharacter(character)
                }
                tokens.append(.number(value))
                index = end
                continue
            }
            if character == "'" || character == "\"" {
                var value = ""
                var end = index + 1
                var closed = false
                while end < characters.count {
                    let current = characters[end]
                    if current == "\\", end + 1 < characters.count {
                        value.append(characters[end + 1])
                        end += 2
                        continue
                    }
                    if current == character {
                        closed = true
                        break
                    }
                    value.append(current)
                    end += 1
                }
                guard closed else { throw GenUIExpressionError.unterminatedString }
                tokens.append(.string(value))
                index = end + 1
                continue
            }
            if character.isLetter || character == "_" {
                var end = index
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" || characters[end] == "." {
                    end += 1
                }
                tokens.append(.identifier(String(characters[index..<end])))
                index = end
                continue
            }
            if index + 1 < characters.count, twoCharacterSymbols.contains(String(characters[index...index + 1])) {
                tokens.append(.symbol(String(characters[index...index + 1])))
                index += 2
                continue
            }
            guard oneCharacterSymbols.contains(character) else { throw GenUIExpressionError.unexpectedCharacter(character) }
            tokens.append(.symbol(String(character)))
            index += 1
        }
        tokens.append(.end)
        return tokens
    }
}

// MARK: - Парсер Пратта

struct GenUIExprParser {
    private let tokens: [GenUIExprToken]
    private var position = 0
    private var nodes = 0
    private var depth = 0

    private static let maxNodes = 200
    private static let maxDepth = 32

    init(tokens: [GenUIExprToken]) {
        self.tokens = tokens
    }

    mutating func parseExpression() throws -> GenUIExprNode {
        let node = try expression(0)
        guard peek == .end else { throw GenUIExpressionError.unexpectedToken(peek.text) }
        return node
    }

    private var peek: GenUIExprToken { tokens[min(position, tokens.count - 1)] }

    private mutating func advance() -> GenUIExprToken {
        let token = peek
        position += 1
        return token
    }

    private mutating func expect(_ symbol: String) throws {
        guard advance() == .symbol(symbol) else { throw GenUIExpressionError.unexpectedToken(tokens[position - 1].text) }
    }

    private mutating func count() throws {
        nodes += 1
        guard nodes <= Self.maxNodes else { throw GenUIExpressionError.tooComplex }
    }

    /// Сила связывания инфиксных операторов. «^» правоассоциативен и сильнее
    /// унарного минуса: -2^2 = -4, как в математике
    private func infix(_ token: GenUIExprToken) -> (power: Int, op: GenUIExprNode.Binary?)? {
        guard case .symbol(let symbol) = token else { return nil }
        switch symbol {
        case "?": return (1, nil)
        case "||": return (2, .or)
        case "&&": return (3, .and)
        case "==": return (4, .equal)
        case "!=": return (4, .notEqual)
        case "<": return (5, .less)
        case "<=": return (5, .lessEqual)
        case ">": return (5, .greater)
        case ">=": return (5, .greaterEqual)
        case "+": return (6, .add)
        case "-": return (6, .subtract)
        case "*": return (7, .multiply)
        case "/": return (7, .divide)
        case "%": return (7, .remainder)
        case "^": return (9, .power)
        default: return nil
        }
    }

    private mutating func expression(_ minimum: Int) throws -> GenUIExprNode {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else { throw GenUIExpressionError.tooComplex }
        var lhs = try prefix()
        while let (power, op) = infix(peek), power > minimum {
            _ = advance()
            try count()
            if let op {
                // «^» правоассоциативен: правую часть разбираем с той же силой
                let rhs = try expression(op == .power ? power - 1 : power)
                lhs = .binary(op, lhs, rhs)
            } else {
                let then = try expression(0)
                try expect(":")
                let otherwise = try expression(power - 1)
                lhs = .ternary(lhs, then, otherwise)
            }
        }
        return lhs
    }

    private mutating func prefix() throws -> GenUIExprNode {
        try count()
        let token = advance()
        switch token {
        case .number(let value):
            return .literal(.number(value))
        case .string(let value):
            return .literal(.string(value))
        case .identifier(let name):
            switch name {
            case "true": return .literal(.bool(true))
            case "false": return .literal(.bool(false))
            case "null": return .literal(.null)
            default: break
            }
            guard peek == .symbol("(") else { return .variable(name) }
            _ = advance()
            var arguments: [GenUIExprNode] = []
            if peek != .symbol(")") {
                repeat {
                    arguments.append(try expression(0))
                } while peek == .symbol(",") && advance() == .symbol(",")
            }
            try expect(")")
            guard let arity = GenUIFunctions.arity[name] else { throw GenUIExpressionError.unknownFunction(name) }
            guard arity.contains(arguments.count) else { throw GenUIExpressionError.wrongArgumentCount(name) }
            return .call(name, arguments)
        case .symbol("("):
            let inner = try expression(0)
            try expect(")")
            return inner
        case .symbol("-"):
            return .unary(.negate, try expression(8))
        case .symbol("+"):
            return .unary(.plus, try expression(8))
        case .symbol("!"):
            return .unary(.not, try expression(8))
        default:
            throw GenUIExpressionError.unexpectedToken(token.text)
        }
    }
}
