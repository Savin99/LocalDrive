import Foundation

/// JSON с сохранённым порядком ключей. Порядок важен: в строгом режиме
/// Structured Outputs ключи ответа идут в порядке схемы, а `text` должен
/// прийти в потоке раньше `blocks`. Словарь `JSONValue` порядок теряет —
/// поэтому схему отдаём готовой строкой и вставляем в запрос как есть
indirect enum GenUIOrderedJSON: Sendable {
    case object([(String, GenUIOrderedJSON)])
    case array([GenUIOrderedJSON])
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case null

    func serialized() -> String {
        switch self {
        case .object(let pairs):
            return "{" + pairs.map { Self.quote($0.0) + ":" + $0.1.serialized() }.joined(separator: ",") + "}"
        case .array(let items):
            return "[" + items.map { $0.serialized() }.joined(separator: ",") + "]"
        case .string(let text):
            return Self.quote(text)
        case .number(let value):
            return value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .integer(let value):
            return String(value)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .null:
            return "null"
        }
    }

    /// Без порядка ключей — для проверок и тестов
    var jsonValue: JSONValue {
        switch self {
        case .object(let pairs): .object(Dictionary(pairs.map { ($0.0, $0.1.jsonValue) }, uniquingKeysWith: { first, _ in first }))
        case .array(let items): .array(items.map(\.jsonValue))
        case .string(let text): .string(text)
        case .number(let value): .number(value)
        case .integer(let value): .number(Double(value))
        case .bool(let flag): .bool(flag)
        case .null: .null
        }
    }

    private static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

/// Схема ответа модели. Собирается из реестра — один источник правды для
/// модели и для проверки. Строгий режим OpenAI: корень — объект, у каждого
/// объекта все свойства в `required` и `additionalProperties: false`,
/// необязательное — с `null`; анонимные словари запрещены
enum GenUIJSONSchema {
    /// Схема для `response_format` OpenAI (строгий режим). Вставлять строкой
    /// как есть: ключи идут в нужном порядке
    static var openAIStrict: GenUIOrderedJSON { schema(registry: .standard) }

    static var openAIStrictString: String { openAIStrict.serialized() }

    /// Та же схема для Gemini: `anyOf`, `$ref` и `null` там тоже понимаются
    static var gemini: GenUIOrderedJSON { openAIStrict }

    static func schema(registry: GenUIComponentRegistry) -> GenUIOrderedJSON {
        let root: GenUISchemaNode = .object([
            .required("version", .integer(minimum: 1, maximum: 1)),
            .required("mode", .choice(GenUIDocument.Mode.allCases.map(\.rawValue),
                                      description: "text — только текст; ui — только интерфейс; mixed — текст и интерфейс")),
            .required("text", .string(description: "Ответ текстом; в ui — короткая подпись или пусто")),
            .required("state", .array(.object([
                .required("name", .variable),
                .required("value", .anyOf([.number(), .string(), .boolean()])),
            ]), maxItems: GenUILimits.maxStateVariables, description: "Начальные значения переменных; дата — ГГГГ-ММ-ДД")),
            .required("computed", .array(.object([
                .required("name", .variable),
                .required("expr", .string(description: "Выражение над состоянием и другими computed")),
            ]), maxItems: GenUILimits.maxComputed)),
            .required("blocks", .array(.ref("block"), maxItems: 40)),
        ])
        var root_ = strict(root)
        guard case .object(var pairs) = root_ else { return root_ }
        pairs.append(("$defs", .object(definitions(registry: registry).map { ($0.0, strict($0.1)) })))
        root_ = .object(pairs)
        return root_
    }

    /// Определения, на которые ссылаются блоки
    static func definitions(registry: GenUIComponentRegistry) -> [(String, GenUISchemaNode)] {
        let blocks: [GenUISchemaNode] = registry.types.compactMap { type in
            guard let component = registry.component(type) else { return nil }
            let common: [GenUISchemaProperty] = [
                .required("id", .string(description: "Уникальный id: a-z, 0-9, - и _")),
                .required("type", .choice([type])),
                .optional("visible_if", .string(description: "Выражение: блок виден, пока оно истинно")),
            ]
            return .object(common + component.properties, description: component.guide)
        }
        return [
            ("block", .anyOf(blocks)),
            ("value", .anyOf([
                .number(), .string(), .boolean(),
                .object([.required("expr", .string(description: "Выражение над состоянием"))]),
            ])),
            ("cell", .anyOf([.number(), .string(), .boolean()])),
            ("generate", .object([
                .required("var", .variable),
                .required("from", .value),
                .required("to", .value),
                .optional("step", .value),
                .required("columns", .array(.object([
                    .required("key", .variable),
                    .required("expr", .string(description: "Выражение строки: переменная ряда, prev.<колонка>, состояние")),
                ]), minItems: 1, maxItems: GenUILimits.maxTableColumns)),
            ], description: "Ряд, вычисляемый на iPhone: не больше 500 строк")),
            ("action", .anyOf(actionShapes)),
            ("source", .anyOf(sourceShapes)),
            ("file_action", .anyOf(fileActionShapes)),
        ]
    }

    private static let documentID: GenUISchemaNode = .string(description: "id документа из инструментов, вида d42")

    private static var actionShapes: [GenUISchemaNode] {
        func shape(_ kind: GenUIAction.Kind, _ properties: [GenUISchemaProperty], _ description: String) -> GenUISchemaNode {
            .object([.required("kind", .choice([kind.rawValue]))] + properties, description: description)
        }
        return [
            shape(.set, [.required("var", .variable), .required("value", .value)], "Изменить переменную состояния"),
            shape(.reset, [.optional("vars", .array(.variable))], "Вернуть переменные к начальным значениям"),
            shape(.submit, [.optional("include", .array(.variable)), .optional("message", .string())],
                  "Отправить значения переменных модели новым сообщением"),
            shape(.regenerate, [.required("block_id", .string()), .optional("instruction", .string())],
                  "Перестроить блок моделью с учётом текущего состояния"),
            shape(.ask, [.required("text", .string())], "Задать вопрос в чат от имени человека"),
            shape(.openDocument, [.required("document_id", documentID)], "Открыть файл документа"),
            shape(.showFields, [.required("document_id", documentID), .required("keys", .array(.string()))],
                  "Показать поля документа карточкой из базы"),
            shape(.copyField, [.required("document_id", documentID), .required("key", .string())],
                  "Скопировать поле документа"),
            shape(.openFolder, [.required("folder_id", .string(description: "id папки из инструментов"))], "Открыть папку"),
            shape(.remind, [.required("document_id", documentID)], "Напомнить о сроке — с подтверждением"),
            shape(.proposeFileActions, [.required("summary", .string()), .required("actions", .array(.ref("file_action"), minItems: 1, maxItems: 20))],
                  "Предложить файловые действия карточкой — выполняет человек кнопкой"),
        ]
    }

    private static var sourceShapes: [GenUISchemaNode] {
        func shape(_ kind: GenUIDataSourceSpec.Kind, _ properties: [GenUISchemaProperty], _ description: String) -> GenUISchemaNode {
            .object([.required("kind", .choice([kind.rawValue]))] + properties, description: description)
        }
        let filters: [GenUISchemaProperty] = [
            .optional("types", .array(.string())),
            .optional("categories", .array(.string())),
            .optional("folder_id", .string()),
            .optional("owner", .string()),
        ]
        return [
            shape(.documents, filters + [
                .optional("query", .string()),
                .optional("columns", .array(.choice(GenUIDataSourceSpec.documentColumns))),
            ], "Документы приложения: строки с колонками columns"),
            shape(.documentStats, [
                .required("group_by", .choice(GenUIDataSourceSpec.groupings)),
                .required("metric", .choice(GenUIDataSourceSpec.metrics)),
                .optional("currency", .string()),
            ] + filters, "Сводка по документам: строки key, value"),
            shape(.expiring, [.optional("within_days", .value)], "Документы со сроком: id, title, type, owner, valid_until, days_left"),
            shape(.amounts, [
                .optional("categories", .array(.string())),
                .optional("from", .value),
                .optional("to", .value),
                .optional("currency", .string()),
            ], "Суммы из документов: date, label, value, currency, document_id"),
            shape(.fields, [.required("document_id", documentID), .required("keys", .array(.string()))],
                  "Поля документа: key, title, value; номера — маской"),
        ]
    }

    private static var fileActionShapes: [GenUISchemaNode] {
        let fileRef: GenUISchemaNode = .object([.required("folder_id", .string()), .required("name", .string())])
        return [
            .object([
                .required("kind", .choice(["save_attachment"])),
                .required("attachment_id", .string()),
                .optional("folder_id", .string()),
                .optional("new_folder_name", .string()),
                .optional("name", .string()),
            ]),
            .object([
                .required("kind", .choice(["move_files"])),
                .required("files", .array(fileRef, minItems: 1)),
                .optional("folder_id", .string()),
                .optional("new_folder_name", .string()),
            ]),
            .object([
                .required("kind", .choice(["rename_file"])),
                .required("file", fileRef),
                .required("new_name", .string()),
            ]),
            .object([
                .required("kind", .choice(["create_folder"])),
                .required("name", .string()),
            ]),
        ]
    }

    // MARK: - Строгая форма узлов

    /// Узел в строгом виде. `nullable` — свойство необязательное: тип с `null`
    static func strict(_ node: GenUISchemaNode, nullable: Bool = false) -> GenUIOrderedJSON {
        func typed(_ type: String, _ extra: [(String, GenUIOrderedJSON)]) -> GenUIOrderedJSON {
            let typeValue: GenUIOrderedJSON = nullable ? .array([.string(type), .string("null")]) : .string(type)
            return .object([("type", typeValue)] + extra)
        }
        func withNull(_ schema: GenUIOrderedJSON) -> GenUIOrderedJSON {
            nullable ? .object([("anyOf", .array([schema, .object([("type", .string("null"))])]))]) : schema
        }
        func describe(_ description: String?) -> [(String, GenUIOrderedJSON)] {
            description.map { [("description", .string($0))] } ?? []
        }

        switch node {
        case .string(let values, let format, let description):
            if let values {
                // Перечень с null — через anyOf: «enum» без null запретил бы пустое значение
                return withNull(.object([("type", .string("string")), ("enum", .array(values.map(GenUIOrderedJSON.string)))] + describe(description)))
            }
            return typed("string", (format.map { [("format", .string($0))] } ?? []) + describe(description))
        case .number(let minimum, let maximum, let description):
            return typed("number", (minimum.map { [("minimum", .number($0))] } ?? []) + (maximum.map { [("maximum", .number($0))] } ?? []) + describe(description))
        case .integer(let minimum, let maximum, let description):
            return typed("integer", (minimum.map { [("minimum", .integer($0))] } ?? []) + (maximum.map { [("maximum", .integer($0))] } ?? []) + describe(description))
        case .boolean(let description):
            return typed("boolean", describe(description))
        case .array(let items, let minItems, let maxItems, let description):
            // Необязательный массив — через anyOf: строгий режим OpenAI отклоняет
            // {"type": ["array", "null"]} целиком, 400 invalid_json_schema
            // (проверено на gpt-6-luna 13.10.2026, docs/genui.md)
            return withNull(.object([("type", .string("array")), ("items", strict(items))]
                + (minItems.map { [("minItems", .integer($0))] } ?? [])
                + (maxItems.map { [("maxItems", .integer($0))] } ?? [])
                + describe(description)))
        case .object(let properties, let description):
            let schema: GenUIOrderedJSON = .object([
                ("type", .string("object")),
                ("properties", .object(properties.map { ($0.name, strict($0.node, nullable: $0.optional)) })),
                ("required", .array(properties.map { .string($0.name) })),
                ("additionalProperties", .bool(false)),
            ] + describe(description))
            return withNull(schema)
        case .ref(let name):
            return withNull(.object([("$ref", .string("#/$defs/\(name)"))]))
        case .anyOf(let options, let description):
            var items = options.map { strict($0) }
            if nullable { items.append(.object([("type", .string("null"))])) }
            return .object([("anyOf", .array(items))] + describe(description))
        }
    }

    // MARK: - Подсказка модели

    /// Каталог для системной инструкции: когда какой блок уместен, его поля,
    /// действия, источники и функции выражений. Собирается из реестра
    static func promptCatalog(registry: GenUIComponentRegistry = .standard) -> String {
        var lines: [String] = []
        lines.append("Блоки (у всех: id, type, visible_if):")
        for type in registry.types {
            guard let component = registry.component(type) else { continue }
            let fields = component.properties.map { $0.optional ? "\($0.name)?" : $0.name }.joined(separator: ", ")
            lines.append("- \(type) {\(fields)} — \(component.guide)")
        }
        lines.append("Значение: число, строка, логическое или {\"expr\": \"…\"}. В строках — подстановка {{ выражение }}.")
        lines.append("Действия (kind): set, reset, submit, regenerate, ask, open_document, show_fields, copy_field, open_folder, remind, propose_file_actions. Других нет.")
        lines.append("Источники данных (kind): documents, document_stats, expiring, amounts, fields. Данные приложения — только через source; литералы rows — только числа человека и расчёты.")
        lines.append("Функции выражений: " + GenUIFunctions.arity.keys.sorted().joined(separator: ", ") + ". percent(x) — x уже в процентах. В generate: переменная ряда и prev.<колонка> (на первой строке 0).")
        return lines.joined(separator: "\n")
    }
}
