import Foundation

/// Замечание проверки: что выпало и почему. Без содержимого ответа — только
/// путь и причина, такое можно писать в журнал
struct GenUIIssue: Hashable, Sendable, CustomStringConvertible {
    let path: String
    let message: String

    var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

/// Поле ввода привязано к переменной: её тип и значение по умолчанию
struct GenUIBind: Hashable, Sendable {
    let kind: GenUIValueKind
    let defaultValue: GenUIScalar
}

/// Проверенный блок: компонент из реестра и его исходный JSON. По исходному
/// JSON блок сохраняется в истории и проверяется заново при открытии
struct GenUIBlock: Identifiable, Hashable, Sendable {
    let id: String
    let type: String
    let visibleIf: GenUIExpression?
    let component: any GenUIComponent
    let raw: JSONValue
    /// Переменные, к которым привязаны поля ввода этого блока и вложенных
    let binds: [String: GenUIBind]

    static func == (lhs: GenUIBlock, rhs: GenUIBlock) -> Bool {
        lhs.id == rhs.id && lhs.raw == rhs.raw
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(raw)
    }

    /// Блок и все вложенные — для подсчёта и поиска по id
    var flattened: [GenUIBlock] {
        [self] + component.children.flatMap(\.flattened)
    }
}

/// Ответ модели после проверки
struct GenUIDocument: Hashable, Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case text
        case ui
        case mixed
    }

    var version: Int
    var mode: Mode
    var text: String
    /// Начальные значения переменных в порядке объявления
    var state: [(name: String, value: GenUIScalar)]
    var computed: [(name: String, expression: GenUIExpression)]
    var blocks: [GenUIBlock]

    init(
        version: Int = GenUISchema.version,
        mode: Mode,
        text: String,
        state: [(name: String, value: GenUIScalar)] = [],
        computed: [(name: String, expression: GenUIExpression)] = [],
        blocks: [GenUIBlock] = []
    ) {
        self.version = version
        self.mode = mode
        self.text = text
        self.state = state
        self.computed = computed
        self.blocks = blocks
    }

    /// Привязки всех полей ввода ответа
    var binds: [String: GenUIBind] {
        blocks.reduce(into: [:]) { result, block in
            result.merge(block.binds) { first, _ in first }
        }
    }

    var allBlocks: [GenUIBlock] { blocks.flatMap(\.flattened) }

    /// Нечего показать: ни текста, ни блоков — тогда «Не получилось показать ответ»
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && blocks.isEmpty
    }

    /// Каноническая запись в формате схемы — для истории и для модели, когда
    /// ей нужно перестроить блок с учётом текущего состояния
    var json: JSONValue {
        .object([
            "version": .number(Double(version)),
            "mode": .string(mode.rawValue),
            "text": .string(text),
            "state": .array(state.map { .object(["name": .string($0.name), "value": $0.value.json]) }),
            "computed": .array(computed.map { .object(["name": .string($0.name), "expr": .string($0.expression.source)]) }),
            "blocks": .array(blocks.map(\.raw)),
        ])
    }

    static func == (lhs: GenUIDocument, rhs: GenUIDocument) -> Bool {
        lhs.json == rhs.json
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(json)
    }
}

extension GenUIDocument: Codable {
    /// Чтение сохранённого ответа — это повторная проверка: схема могла
    /// устареть, а реестр — измениться
    init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        self = GenUIValidator.document(from: json).document
    }

    func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}

enum GenUISchema {
    static let version = 1
}

/// Итог проверки: что показать и что выпало
struct GenUIValidation: Sendable {
    var document: GenUIDocument
    var issues: [GenUIIssue]
}
