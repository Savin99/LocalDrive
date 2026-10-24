import Foundation

/// JSON без потерь: части ответа Gemini возвращаются в историю дословно —
/// с thoughtSignature, иначе Gemini 3 отвечает 400, а элементы ответа OpenAI —
/// с зашифрованным рассуждением (docs/cloud-chat.md)
enum CloudJSON: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CloudJSON])
    case object([String: CloudJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CloudJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CloudJSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Целые — без «.0»: идентификаторы и счётчики
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> CloudJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .number(let value) = self { return Int(value) }
        if case .string(let value) = self { return Int(value) }
        return nil
    }

    var array: [CloudJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var object: [String: CloudJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Без null в объектах: строгая схема OpenAI шлёт null вместо
    /// пропущенного поля, а инструменты и FileProposalBuilder ждут пропуск
    var withoutNulls: CloudJSON {
        switch self {
        case .object(let object): .object(object.compactMapValues { $0 == .null ? nil : $0.withoutNulls })
        case .array(let array): .array(array.map(\.withoutNulls))
        default: self
        }
    }

    static func parse(_ data: Data) -> CloudJSON? {
        try? JSONDecoder().decode(CloudJSON.self, from: data)
    }

    var data: Data {
        (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
    }
}

extension CloudJSON: ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: CloudJSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, CloudJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
}
