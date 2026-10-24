import Foundation

/// Разбор ответа модели по мере прихода. Ответ — JSON по схеме, ключи в её
/// порядке: version, mode, text, state, computed, blocks (Structured Outputs:
/// «outputs will be produced in the same order as the ordering of keys in the
/// schema»). Пока JSON не закрыт, разбор отдаёт:
/// - текст `text` — по мере роста строки;
/// - массивы `state` и `computed` — когда они закрыты;
/// - каждый элемент `blocks` — когда закрыт его объект.
///
/// Разбор не полагается на порядок ключей и пропускает незнакомые. Кусок
/// может оборваться где угодно: посреди escape-последовательности, буквы UTF-8
/// или числа. Целиком закрытый ответ отдаёт `complete` — его проверяет
/// `GenUIValidator`, как ответ без потока
struct GenUIStreamParser {
    enum Event: Equatable {
        /// Текст ответа целиком на этот момент
        case text(String)
        case state(JSONValue)
        case computed(JSONValue)
        case block(JSONValue)
    }

    /// Ответ закрыт: весь JSON — для окончательной проверки
    private(set) var complete: Data?
    /// Ответ не JSON-объект (например, модель ответила простым текстом)
    private(set) var isNotJSON = false
    /// Сколько байт ответа пришло
    var receivedBytes: Int { bytes.count }
    /// Всё, что пришло, — для ответа простым текстом
    var raw: String { String(decoding: bytes, as: UTF8.self) }

    private var bytes: [UInt8] = []
    private var index = 0
    private var stage = Stage.root

    private enum Stage {
        /// До «{» корня
        case root
        /// Ждём ключ или «}»
        case key
        /// Внутри строки ключа: начало, escape
        case keyString(start: Int, escaped: Bool)
        /// Ждём «:»
        case colon(key: String)
        /// Ждём начало значения
        case value(key: String)
        /// Внутри строки `text`
        case text
        /// Значение целиком: state, computed или пропускаемое
        case scalar(key: String, start: Int, scanner: ValueScanner)
        /// Внутри массива `blocks`: ждём элемент, «,» или «]»
        case blocks
        /// Элемент `blocks`
        case block(start: Int, scanner: ValueScanner)
        /// После значения: «,» или «}»
        case afterValue
        case done
        case broken
    }

    // Текст: декодированные байты UTF-8 и состояние escape
    private var textBytes: [UInt8] = []
    private var textEscape = false
    private var unicodeHex: [UInt8]?
    private var pendingHighSurrogate: UInt32?
    private var lastText: String?

    init() {}

    /// Новый кусок ответа. Возвращает то, что стало известно
    mutating func feed(_ chunk: String) -> [Event] {
        bytes.append(contentsOf: chunk.utf8)
        var events: [Event] = []
        scan(into: &events)
        if case .text = stage { emitText(into: &events) }
        return events
    }

    // MARK: - Разбор

    private mutating func scan(into events: inout [Event]) {
        while index < bytes.count {
            let byte = bytes[index]
            switch stage {
            case .root:
                if Self.isSpace(byte) { index += 1; continue }
                guard byte == UInt8(ascii: "{") else {
                    isNotJSON = true
                    stage = .broken
                    return
                }
                index += 1
                stage = .key

            case .key:
                if Self.isSpace(byte) || byte == UInt8(ascii: ",") { index += 1; continue }
                if byte == UInt8(ascii: "}") {
                    index += 1
                    stage = .done
                    complete = Data(bytes[..<index])
                    continue
                }
                guard byte == UInt8(ascii: "\"") else { stage = .broken; return }
                index += 1
                stage = .keyString(start: index, escaped: false)

            case .keyString(let start, let escaped):
                index += 1
                if escaped {
                    stage = .keyString(start: start, escaped: false)
                } else if byte == UInt8(ascii: "\\") {
                    stage = .keyString(start: start, escaped: true)
                } else if byte == UInt8(ascii: "\"") {
                    // Ключи схемы — латиница без escape; с escape — через разбор JSON
                    let content = bytes[start..<(index - 1)]
                    let key = content.contains(UInt8(ascii: "\\"))
                        ? ((try? JSONValue(Data("[".utf8) + Data(bytes[(start - 1)..<index]) + Data("]".utf8)))?[0]?.string ?? "")
                        : String(decoding: content, as: UTF8.self)
                    stage = .colon(key: key)
                }

            case .colon(let key):
                if Self.isSpace(byte) { index += 1; continue }
                guard byte == UInt8(ascii: ":") else { stage = .broken; return }
                index += 1
                stage = .value(key: key)

            case .value(let key):
                if Self.isSpace(byte) { index += 1; continue }
                if key == "text", byte == UInt8(ascii: "\"") {
                    index += 1
                    stage = .text
                } else if key == "blocks", byte == UInt8(ascii: "[") {
                    index += 1
                    stage = .blocks
                } else {
                    stage = .scalar(key: key, start: index, scanner: ValueScanner(first: byte))
                    index += 1
                    if case .scalar(let key, let start, let scanner) = stage, scanner.isComplete {
                        finishScalar(key: key, start: start, end: index, into: &events)
                    }
                }

            case .text:
                index += 1
                if consumeText(byte) {
                    emitText(into: &events)
                    stage = .afterValue
                }

            case .scalar(let key, let start, var scanner):
                // Число, true, false, null кончаются разделителем — он не их часть
                if scanner.endsBefore(byte) {
                    finishScalar(key: key, start: start, end: index, into: &events)
                    continue
                }
                scanner.consume(byte)
                index += 1
                if scanner.isComplete {
                    finishScalar(key: key, start: start, end: index, into: &events)
                } else {
                    stage = .scalar(key: key, start: start, scanner: scanner)
                }

            case .blocks:
                if Self.isSpace(byte) || byte == UInt8(ascii: ",") { index += 1; continue }
                if byte == UInt8(ascii: "]") {
                    index += 1
                    stage = .afterValue
                    continue
                }
                stage = .block(start: index, scanner: ValueScanner(first: byte))
                index += 1

            case .block(let start, var scanner):
                // Не объект, а число или литерал — пропускаем: блоком он не станет
                if scanner.endsBefore(byte) {
                    stage = .blocks
                    continue
                }
                scanner.consume(byte)
                index += 1
                if scanner.isComplete {
                    if let json = try? JSONValue(Data(bytes[start..<index])) { events.append(.block(json)) }
                    stage = .blocks
                } else {
                    stage = .block(start: start, scanner: scanner)
                }

            case .afterValue:
                if Self.isSpace(byte) { index += 1; continue }
                if byte == UInt8(ascii: ",") {
                    index += 1
                    stage = .key
                } else if byte == UInt8(ascii: "}") {
                    index += 1
                    stage = .done
                    complete = Data(bytes[..<index])
                } else {
                    stage = .broken
                    return
                }

            case .done, .broken:
                // После закрытого ответа — ничего: второй документ не разбираем
                index = bytes.count
            }
        }
    }

    private mutating func finishScalar(key: String, start: Int, end: Int, into events: inout [Event]) {
        stage = .afterValue
        guard key == "state" || key == "computed",
              let json = try? JSONValue(Data(bytes[start..<end])) else { return }
        events.append(key == "state" ? .state(json) : .computed(json))
    }

    // MARK: - Строка text

    /// Байт строки `text`. true — строка закрыта
    private mutating func consumeText(_ byte: UInt8) -> Bool {
        if var hex = unicodeHex {
            hex.append(byte)
            if hex.count < 4 {
                unicodeHex = hex
                return false
            }
            unicodeHex = nil
            if let code = UInt32(String(decoding: hex, as: UTF8.self), radix: 16) { appendCodeUnit(code) }
            return false
        }
        if textEscape {
            textEscape = false
            switch byte {
            case UInt8(ascii: "n"): appendScalar(0x0A)
            case UInt8(ascii: "t"): appendScalar(0x09)
            case UInt8(ascii: "r"): appendScalar(0x0D)
            case UInt8(ascii: "b"): appendScalar(0x08)
            case UInt8(ascii: "f"): appendScalar(0x0C)
            case UInt8(ascii: "u"): unicodeHex = []
            default: appendScalar(UInt32(byte))   // \" \\ \/
            }
            return false
        }
        switch byte {
        case UInt8(ascii: "\\"):
            textEscape = true
            return false
        case UInt8(ascii: "\""):
            return true
        default:
            flushSurrogate()
            textBytes.append(byte)
            return false
        }
    }

    /// \uXXXX: суррогатная пара собирается в одну букву
    private mutating func appendCodeUnit(_ code: UInt32) {
        if (0xD800...0xDBFF).contains(code) {
            flushSurrogate()
            pendingHighSurrogate = code
        } else if (0xDC00...0xDFFF).contains(code), let high = pendingHighSurrogate {
            pendingHighSurrogate = nil
            appendScalar(0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00))
        } else {
            appendScalar(code)
        }
    }

    private mutating func appendScalar(_ value: UInt32) {
        flushSurrogate()
        guard let scalar = Unicode.Scalar(value) else { return }
        textBytes.append(contentsOf: String(Character(scalar)).utf8)
    }

    /// Одинокая половина суррогатной пары — заменой, как это делает JSONDecoder
    private mutating func flushSurrogate() {
        guard pendingHighSurrogate != nil else { return }
        pendingHighSurrogate = nil
        textBytes.append(contentsOf: "\u{FFFD}".utf8)
    }

    private mutating func emitText(into events: inout [Event]) {
        let text = String(decoding: Self.completeUTF8Prefix(textBytes), as: UTF8.self)
        guard text != lastText else { return }
        lastText = text
        events.append(.text(text))
    }

    /// Без недописанной последней буквы UTF-8: кусок мог оборваться посреди неё
    static func completeUTF8Prefix(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        var start = bytes.count - 1
        var continuation = 0
        while start >= 0, bytes.count - start <= 4 {
            let byte = bytes[start]
            if byte & 0b1100_0000 == 0b1000_0000 {
                continuation += 1
                start -= 1
                continue
            }
            let length = byte & 0b1000_0000 == 0 ? 1 : byte & 0b1110_0000 == 0b1100_0000 ? 2 : byte & 0b1111_0000 == 0b1110_0000 ? 3 : 4
            return continuation + 1 < length ? bytes[..<start] : bytes[...]
        }
        return bytes[...]
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}

/// Граница одного значения JSON: строки — до закрывающей кавычки, объекта и
/// массива — до парной скобки с учётом строк внутри, числа и литерала — до
/// разделителя
struct ValueScanner {
    private enum Kind {
        case string
        case container
        case literal
    }

    private let kind: Kind
    private var depth = 0
    private var inString = false
    private var escaped = false
    private(set) var isComplete = false

    init(first byte: UInt8) {
        switch byte {
        case UInt8(ascii: "\""):
            kind = .string
            inString = true
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            kind = .container
            depth = 1
        default:
            kind = .literal
        }
    }

    /// Разделитель после числа или литерала: значение кончилось до него
    func endsBefore(_ byte: UInt8) -> Bool {
        guard kind == .literal else { return false }
        return byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]")
            || byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    mutating func consume(_ byte: UInt8) {
        switch kind {
        case .literal:
            return
        case .string:
            if escaped {
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                isComplete = true
            }
        case .container:
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                return
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 { isComplete = true }
            default: break
            }
        }
    }
}
