import Foundation

/// Проверка ответа модели перед показом. Никогда не бросает: в худшем случае
/// документ пустой, а интерфейс показывает «Не получилось показать ответ»
enum GenUIValidator {
    static func document(from data: Data, registry: GenUIComponentRegistry = .standard) -> GenUIValidation {
        guard let json = try? JSONValue(data) else {
            return GenUIValidation(document: GenUIDocument(mode: .text, text: ""), issues: [GenUIIssue(path: "", message: "ответ — не JSON")])
        }
        return document(from: json, registry: registry)
    }

    static func document(from json: JSONValue, registry: GenUIComponentRegistry = .standard) -> GenUIValidation {
        guard let object = json.object else {
            return GenUIValidation(document: GenUIDocument(mode: .text, text: ""), issues: [GenUIIssue(path: "", message: "ответ — не объект")])
        }
        let props = GenUIProps(object)
        var issues: [GenUIIssue] = []

        let version = props["version"]?.number.map { Int($0) } ?? GenUISchema.version
        if version != GenUISchema.version {
            issues.append(GenUIIssue(path: "version", message: "версия \(version), разбираю как \(GenUISchema.version)"))
        }

        var text = props["text"]?.string ?? ""
        if text.count > GenUILimits.maxTextLength {
            issues.append(GenUIIssue(path: "text", message: "текст длиннее \(GenUILimits.maxTextLength), обрезан"))
            text = String(text.prefix(GenUILimits.maxTextLength))
        }

        let (declared, stateIssues) = state(from: props["state"])
        issues += stateIssues
        let (computed, computedIssues) = computed(from: props["computed"])
        issues += computedIssues

        var parser = GenUIParser(registry: registry)
        let blocks = parser.blocks(json: props["blocks"], field: "blocks")
        issues += parser.issues

        // Режим по факту: модель могла назвать «text» ответ с блоками
        let requested = props["mode"]?.string.flatMap(GenUIDocument.Mode.init(rawValue:))
        let mode: GenUIDocument.Mode = switch (blocks.isEmpty, text.isEmpty) {
        case (true, _): .text
        case (false, true): .ui
        case (false, false): requested == .ui ? .ui : .mixed
        }
        if let requested, requested != mode {
            issues.append(GenUIIssue(path: "mode", message: "режим «\(requested.rawValue)», показан как «\(mode.rawValue)»"))
        }

        let state = reconcile(declared, binds: parser.binds, issues: &issues)
        let document = GenUIDocument(version: GenUISchema.version, mode: mode, text: text, state: state, computed: computed, blocks: blocks)
        return GenUIValidation(document: document, issues: issues)
    }

    /// Один элемент `blocks` — для потока: показывать блоки по мере прихода.
    /// `usedIDs` — id уже показанных блоков ответа
    static func block(from data: Data, registry: GenUIComponentRegistry = .standard, usedIDs: Set<String> = []) -> GenUIBlock? {
        guard let json = try? JSONValue(data) else { return nil }
        return block(from: json, registry: registry, usedIDs: usedIDs).block
    }

    static func block(
        from json: JSONValue,
        registry: GenUIComponentRegistry = .standard,
        usedIDs: Set<String> = [],
        blockLimit: Int = GenUILimits.maxBlocks
    ) -> (block: GenUIBlock?, issues: [GenUIIssue]) {
        var parser = GenUIParser(registry: registry, usedIDs: usedIDs, blockLimit: blockLimit)
        let block = parser.block(json)
        return (block, parser.issues)
    }

    /// `state`: массив `{name, value}`; словарь «имя → значение» тоже понимается
    static func state(from json: JSONValue?) -> (state: [(name: String, value: GenUIScalar)], issues: [GenUIIssue]) {
        guard let json else { return ([], []) }
        var pairs: [(String, JSONValue)] = []
        if let items = json.array {
            for item in items {
                guard let name = item["name"]?.string, let value = item["value"] else { continue }
                pairs.append((name, value))
            }
        } else if let map = json.object {
            pairs = map.keys.sorted().map { ($0, map[$0]!) }
        }
        var issues: [GenUIIssue] = []
        var result: [(name: String, value: GenUIScalar)] = []
        var seen = Set<String>()
        for (name, value) in pairs {
            guard GenUIParser.isValidVariable(name) else {
                issues.append(GenUIIssue(path: "state", message: "недопустимое имя «\(name)»"))
                continue
            }
            guard !seen.contains(name) else { continue }
            guard result.count < GenUILimits.maxStateVariables else {
                issues.append(GenUIIssue(path: "state", message: "переменных больше \(GenUILimits.maxStateVariables)"))
                break
            }
            guard let scalar = GenUIScalar(json: value), !scalar.isNull else {
                issues.append(GenUIIssue(path: "state.\(name)", message: "недопустимое значение"))
                continue
            }
            seen.insert(name)
            result.append((name, scalar))
        }
        return (result, issues)
    }

    /// `computed`: массив `{name, expr}`
    static func computed(from json: JSONValue?) -> (computed: [(name: String, expression: GenUIExpression)], issues: [GenUIIssue]) {
        guard let items = json?.array else { return ([], []) }
        var issues: [GenUIIssue] = []
        var result: [(name: String, expression: GenUIExpression)] = []
        for item in items.prefix(GenUILimits.maxComputed) {
            guard let name = item["name"]?.string, GenUIParser.isValidVariable(name),
                  let source = item["expr"]?.string else {
                issues.append(GenUIIssue(path: "computed", message: "элемент без name или expr"))
                continue
            }
            do {
                result.append((name, try GenUIExpression(parsing: source)))
            } catch {
                issues.append(GenUIIssue(path: "computed.\(name)", message: "ошибка в выражении: \(error)"))
            }
        }
        if items.count > GenUILimits.maxComputed {
            issues.append(GenUIIssue(path: "computed", message: "выражений больше \(GenUILimits.maxComputed)"))
        }
        return (result, issues)
    }

    /// Начальные значения против полей ввода: тип поля главнее. «5» в
    /// ползунке станет 5, а слово в поле даты — значением по умолчанию
    static func reconcile(
        _ declared: [(name: String, value: GenUIScalar)],
        binds: [String: GenUIBind],
        issues: inout [GenUIIssue]
    ) -> [(name: String, value: GenUIScalar)] {
        var result = declared.map { pair -> (name: String, value: GenUIScalar) in
            guard let bind = binds[pair.name], pair.value.kind != bind.kind else { return pair }
            if let coerced = pair.value.coerced(to: bind.kind) { return (pair.name, coerced) }
            issues.append(GenUIIssue(path: "state.\(pair.name)", message: "тип не совпадает с полем ввода, взято значение по умолчанию"))
            return (pair.name, bind.defaultValue)
        }
        let names = Set(result.map(\.name))
        for name in binds.keys.sorted() where !names.contains(name) {
            result.append((name, binds[name]!.defaultValue))
        }
        return result
    }
}
