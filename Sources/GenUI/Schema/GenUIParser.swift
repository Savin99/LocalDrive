import Foundation

/// Разбор и проверка ответа модели. Неверный блок выпадает с замечанием,
/// остальные показываются: один неудачный график не должен прятать ответ
struct GenUIParser {
    let registry: GenUIComponentRegistry
    private(set) var issues: [GenUIIssue] = []
    private(set) var usedIDs: Set<String>
    private(set) var blockCount = 0
    /// Привязки полей ввода к переменным — по ним объявляется состояние
    private(set) var binds: [String: GenUIBind] = [:]
    let blockLimit: Int

    private var path: [String] = []
    private var depth = 0
    private var autoIDs = 0

    init(registry: GenUIComponentRegistry = .standard, usedIDs: Set<String> = [], blockLimit: Int = GenUILimits.maxBlocks) {
        self.registry = registry
        self.usedIDs = usedIDs
        self.blockLimit = blockLimit
    }

    mutating func issue(_ message: String, field: String? = nil) {
        let location = (path + (field.map { [$0] } ?? [])).joined(separator: ".")
        issues.append(GenUIIssue(path: location, message: message))
    }

    static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= GenUILimits.maxIDLength else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_"
        }
    }

    static func isValidVariable(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 40,
              ("a"..."z").contains(first) || ("A"..."Z").contains(first) || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
        }
    }

    // MARK: - Блоки

    mutating func blocks(_ props: GenUIProps, _ key: String = "blocks") -> [GenUIBlock] {
        blocks(json: props[key], field: key)
    }

    mutating func blocks(json: JSONValue?, field: String) -> [GenUIBlock] {
        guard let json else { return [] }
        guard let items = json.array else {
            issue("ожидался массив блоков", field: field)
            return []
        }
        return items.compactMap { block($0) }
    }

    mutating func block(_ json: JSONValue) -> GenUIBlock? {
        guard var object = json.object else {
            issue("блок — не объект")
            return nil
        }
        let props = GenUIProps(object)
        guard let type = props["type"]?.string else {
            issue("у блока нет type")
            return nil
        }
        guard let component = registry.component(type) else {
            issue("неизвестный компонент «\(type)»")
            return nil
        }
        guard depth < GenUILimits.maxDepth else {
            issue("вложенность больше \(GenUILimits.maxDepth)")
            return nil
        }
        guard blockCount < blockLimit else {
            issue("блоков больше \(blockLimit)")
            return nil
        }

        var id = props["id"]?.string ?? ""
        if !Self.isValidID(id) {
            autoIDs += 1
            let replacement = "auto-\(autoIDs)"
            issue("неверный id «\(id)», заменён на \(replacement)")
            id = replacement
        }
        if usedIDs.contains(id) {
            var suffix = 2
            while usedIDs.contains("\(id)-\(suffix)") { suffix += 1 }
            issue("id «\(id)» повторяется, заменён на \(id)-\(suffix)")
            id = "\(id)-\(suffix)"
        }
        object["id"] = .string(id)

        var visibleIf: GenUIExpression?
        if let condition = props["visible_if"] {
            if let source = condition.string {
                path.append(id)
                visibleIf = expression(source, field: "visible_if")
                path.removeLast()
            } else {
                issue("visible_if — не строка", field: "visible_if")
            }
        }

        usedIDs.insert(id)
        blockCount += 1
        let bindsBefore = binds
        path.append(id)
        depth += 1
        let parsed = component.init(props, parser: &self)
        depth -= 1
        path.removeLast()

        guard let parsed else {
            // Выпавший блок не занимает места и не объявляет переменные
            blockCount -= 1
            usedIDs.remove(id)
            binds = bindsBefore
            issue("блок «\(id)» (\(type)) не показан")
            return nil
        }
        let own = binds.filter { bindsBefore[$0.key] == nil }
        return GenUIBlock(id: id, type: type, visibleIf: visibleIf, component: parsed, raw: .object(object), binds: own)
    }

    // MARK: - Простые свойства

    mutating func string(_ props: GenUIProps, _ key: String, required: Bool = false, maxLength: Int = GenUILimits.maxLabelLength) -> String? {
        guard let json = props[key] else {
            if required { issue("нет обязательного поля", field: key) }
            return nil
        }
        guard let text = json.string else {
            issue("ожидалась строка", field: key)
            return nil
        }
        guard text.count <= maxLength else {
            issue("строка длиннее \(maxLength), обрезана", field: key)
            return String(text.prefix(maxLength))
        }
        return text
    }

    mutating func template(_ props: GenUIProps, _ key: String, required: Bool = false, maxLength: Int = GenUILimits.maxLabelLength) -> GenUITemplate? {
        guard let text = string(props, key, required: required, maxLength: maxLength) else { return nil }
        do {
            return try GenUITemplate(parsing: text)
        } catch {
            issue("ошибка в подстановке: \(error)", field: key)
            return nil
        }
    }

    mutating func expression(_ source: String, field: String) -> GenUIExpression? {
        do {
            return try GenUIExpression(parsing: source)
        } catch {
            issue("ошибка в выражении: \(error)", field: field)
            return nil
        }
    }

    /// Литерал или `{"expr": "…"}`
    mutating func value(_ json: JSONValue?, field: String, required: Bool = false) -> GenUIValue? {
        guard let json, !json.isNull else {
            if required { issue("нет обязательного значения", field: field) }
            return nil
        }
        if let object = json.object {
            guard let source = object["expr"]?.string else {
                issue("значение-объект без expr", field: field)
                return nil
            }
            return expression(source, field: field).map(GenUIValue.expression)
        }
        guard let scalar = GenUIScalar(json: json) else {
            issue("недопустимое значение", field: field)
            return nil
        }
        if case .string(let text) = scalar, text.count > GenUILimits.maxTextLength {
            issue("строка слишком длинная", field: field)
            return nil
        }
        return .literal(scalar)
    }

    mutating func value(_ props: GenUIProps, _ key: String, required: Bool = false) -> GenUIValue? {
        value(props[key], field: key, required: required)
    }

    mutating func number(_ props: GenUIProps, _ key: String, required: Bool = false) -> Double? {
        guard let json = props[key] else {
            if required { issue("нет обязательного числа", field: key) }
            return nil
        }
        guard let number = json.number, number.isFinite else {
            issue("ожидалось число", field: key)
            return nil
        }
        return number
    }

    mutating func integer(_ props: GenUIProps, _ key: String, in range: ClosedRange<Int>) -> Int? {
        guard let number = number(props, key) else { return nil }
        let rounded = Int(number.rounded())
        guard range.contains(rounded) else {
            issue("значение вне \(range.lowerBound)…\(range.upperBound), приведено", field: key)
            return min(max(rounded, range.lowerBound), range.upperBound)
        }
        return rounded
    }

    mutating func bool(_ props: GenUIProps, _ key: String) -> Bool? {
        guard let json = props[key] else { return nil }
        guard let flag = json.bool else {
            issue("ожидалось true или false", field: key)
            return nil
        }
        return flag
    }

    /// Значение из перечня; неизвестное — значение по умолчанию с замечанием
    mutating func choice(_ props: GenUIProps, _ key: String, _ allowed: [String], default fallback: String) -> String {
        guard let json = props[key] else { return fallback }
        guard let text = json.string, allowed.contains(text) else {
            issue("недопустимое значение, взято «\(fallback)»", field: key)
            return fallback
        }
        return text
    }

    mutating func strings(_ props: GenUIProps, _ key: String, max: Int = 20) -> [String]? {
        guard let json = props[key] else { return nil }
        guard let items = json.array else {
            issue("ожидался массив строк", field: key)
            return nil
        }
        let strings = items.compactMap(\.string).filter { !$0.isEmpty && $0.count <= GenUILimits.maxLabelLength }
        if strings.count != items.count { issue("часть значений отброшена", field: key) }
        if strings.count > max { issue("больше \(max) значений, лишние отброшены", field: key) }
        return Array(strings.prefix(max))
    }

    mutating func documentID(_ json: JSONValue?, field: String) -> Int64? {
        guard let id = GenUIDocumentID.parse(json) else {
            issue("неверный document_id", field: field)
            return nil
        }
        return id
    }

    mutating func folderID(_ json: JSONValue?, field: String) -> UUID? {
        guard let text = json?.string, let id = UUID(uuidString: text) else {
            issue("неверный folder_id", field: field)
            return nil
        }
        return id
    }

    // MARK: - Привязки

    /// Поле ввода привязано к переменной `bind`. Без начального значения в
    /// `state` переменная получит значение по умолчанию этого поля
    mutating func bind(_ props: GenUIProps, kind: GenUIValueKind, default fallback: GenUIScalar, key: String = "bind") -> String? {
        guard let name = string(props, key, required: true, maxLength: 40) else { return nil }
        guard Self.isValidVariable(name) else {
            issue("недопустимое имя переменной «\(name)»", field: key)
            return nil
        }
        declare(name, kind: kind, default: fallback)
        return name
    }

    mutating func declare(_ name: String, kind: GenUIValueKind, default fallback: GenUIScalar) {
        if let existing = binds[name] {
            if existing.kind != kind { issue("переменная «\(name)» привязана к полям разных типов") }
            return
        }
        binds[name] = GenUIBind(kind: kind, defaultValue: fallback)
    }

    // MARK: - Действия

    mutating func action(_ json: JSONValue?, field: String) -> GenUIAction? {
        guard let json else { return nil }
        guard let object = json.object else {
            issue("действие — не объект", field: field)
            return nil
        }
        let props = GenUIProps(object)
        let name = props["kind"]?.string ?? props["type"]?.string ?? ""
        guard let kind = GenUIAction.Kind(rawValue: name) else {
            issue("действие «\(name)» не разрешено", field: field)
            return nil
        }
        path.append(field)
        defer { path.removeLast() }
        switch kind {
        case .set:
            guard let variable = string(props, "var", required: true, maxLength: 40), Self.isValidVariable(variable),
                  let value = value(props, "value", required: true) else { return nil }
            return .set(variable: variable, value: value)
        case .reset:
            return .reset(variables: strings(props, "vars", max: GenUILimits.maxStateVariables))
        case .submit:
            return .submit(include: strings(props, "include", max: GenUILimits.maxStateVariables),
                           message: template(props, "message", maxLength: 1000))
        case .regenerate:
            guard let blockID = string(props, "block_id", required: true, maxLength: GenUILimits.maxIDLength) else { return nil }
            return .regenerate(blockID: blockID, instruction: string(props, "instruction", maxLength: 1000))
        case .ask:
            guard let text = template(props, "text", required: true, maxLength: 1000) else { return nil }
            return .ask(text: text)
        case .openDocument:
            guard let id = documentID(props["document_id"], field: "document_id") else { return nil }
            return .openDocument(documentID: id)
        case .showFields:
            guard let id = documentID(props["document_id"], field: "document_id"),
                  let keys = strings(props, "keys", max: 12), !keys.isEmpty else {
                issue("нужны document_id и keys")
                return nil
            }
            return .showFields(documentID: id, keys: keys)
        case .copyField:
            guard let id = documentID(props["document_id"], field: "document_id"),
                  let key = string(props, "key", required: true, maxLength: 40) else { return nil }
            return .copyField(documentID: id, key: key)
        case .openFolder:
            guard let id = folderID(props["folder_id"], field: "folder_id") else { return nil }
            return .openFolder(folderID: id)
        case .remind:
            guard let id = documentID(props["document_id"], field: "document_id") else { return nil }
            return .remind(documentID: id)
        case .proposeFileActions:
            guard let actions = props["actions"]?.array, !actions.isEmpty, actions.count <= 20 else {
                issue("propose_file_actions без действий или их больше 20")
                return nil
            }
            return .proposeFileActions(arguments: json)
        }
    }

    // MARK: - Источники данных

    mutating func source(_ json: JSONValue?, field: String) -> GenUIDataSourceSpec? {
        guard let json else { return nil }
        guard let object = json.object else {
            issue("источник — не объект", field: field)
            return nil
        }
        let props = GenUIProps(object)
        let name = props["kind"]?.string ?? props["type"]?.string ?? ""
        guard let kind = GenUIDataSourceSpec.Kind(rawValue: name) else {
            issue("источник «\(name)» не поддерживается", field: field)
            return nil
        }
        path.append(field)
        defer { path.removeLast() }
        var spec = GenUIDataSourceSpec(kind: kind)
        func filters(_ parser: inout GenUIParser) {
            spec.types = parser.strings(props, "types", max: 10)
            spec.categories = parser.strings(props, "categories", max: 12)
            spec.owner = parser.string(props, "owner", maxLength: 100)
            if props["folder_id"] != nil { spec.folderID = parser.folderID(props["folder_id"], field: "folder_id") }
        }
        switch kind {
        case .documents:
            filters(&self)
            spec.query = string(props, "query", maxLength: 200)
            if let columns = strings(props, "columns", max: GenUILimits.maxTableColumns + 2) {
                let allowed = columns.filter(GenUIDataSourceSpec.documentColumns.contains)
                if allowed.count != columns.count { issue("неизвестные колонки отброшены", field: "columns") }
                spec.columns = allowed
            }
        case .documentStats:
            filters(&self)
            spec.groupBy = choice(props, "group_by", GenUIDataSourceSpec.groupings, default: "category")
            spec.metric = choice(props, "metric", GenUIDataSourceSpec.metrics, default: "count")
            spec.currency = string(props, "currency", maxLength: 3)
        case .expiring:
            spec.withinDays = value(props, "within_days")
        case .amounts:
            spec.categories = strings(props, "categories", max: 12)
            spec.from = value(props, "from")
            spec.to = value(props, "to")
            spec.currency = string(props, "currency", maxLength: 3)
        case .fields:
            guard let id = documentID(props["document_id"], field: "document_id"),
                  let keys = strings(props, "keys", max: 12), !keys.isEmpty else { return nil }
            spec.documentID = id
            spec.keys = keys
        }
        return spec
    }

    // MARK: - Ряды и строки

    mutating func generate(_ json: JSONValue?, field: String) -> GenUIGenerate? {
        guard let json else { return nil }
        guard let object = json.object else {
            issue("generate — не объект", field: field)
            return nil
        }
        let props = GenUIProps(object)
        path.append(field)
        defer { path.removeLast() }
        guard let variable = string(props, "var", required: true, maxLength: 40), Self.isValidVariable(variable),
              let from = value(props, "from", required: true),
              let to = value(props, "to", required: true) else { return nil }
        var columns: [GenUIGenerate.Column] = []
        if let items = props["columns"]?.array {
            for item in items.prefix(GenUILimits.maxTableColumns) {
                guard let key = item["key"]?.string, Self.isValidVariable(key),
                      let source = item["expr"]?.string,
                      let expression = expression(source, field: "columns.\(key)") else {
                    issue("колонка ряда без key или expr", field: "columns")
                    continue
                }
                columns.append(.init(key: key, expression: expression))
            }
        } else if let map = props["columns"]?.object {
            // Словарь «колонка → выражение» — так пишут вне строгого режима
            for key in map.keys.sorted().prefix(GenUILimits.maxTableColumns) {
                guard Self.isValidVariable(key), let source = map[key]?.string,
                      let expression = expression(source, field: "columns.\(key)") else { continue }
                columns.append(.init(key: key, expression: expression))
            }
        }
        guard !columns.isEmpty else {
            issue("у ряда нет колонок")
            return nil
        }
        return GenUIGenerate(variable: variable, from: from, to: to, step: value(props, "step"), columns: columns)
    }

    /// Строки-массивы в порядке колонок; строки-объекты тоже понимаются
    mutating func cells(_ json: JSONValue?, columns: [String], limit: Int, field: String) -> [[GenUIScalar]]? {
        guard let json else { return nil }
        guard let rows = json.array else {
            issue("ожидался массив строк", field: field)
            return nil
        }
        if rows.count > limit { issue("строк больше \(limit), лишние отброшены", field: field) }
        return rows.prefix(limit).map { row in
            if let cells = row.array {
                return columns.indices.map { index in
                    index < cells.count ? (GenUIScalar(json: cells[index]) ?? .null) : .null
                }
            }
            if let object = row.object {
                return columns.map { key in object[key].flatMap(GenUIScalar.init(json:)) ?? .null }
            }
            return columns.map { _ in .null }
        }
    }
}
