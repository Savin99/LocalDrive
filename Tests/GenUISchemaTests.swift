import XCTest
@testable import LocalDrive

// Проверка ответа модели и экспорт схемы. Ответы — в формате строгого режима:
// все поля на месте, ненужные — null
final class GenUISchemaTests: XCTestCase {
    private func validate(_ json: String) -> GenUIValidation {
        GenUIValidator.document(from: Data(json.utf8))
    }

    private func ids(_ validation: GenUIValidation) -> [String] {
        validation.document.blocks.map(\.id)
    }

    // MARK: - Деградация по блокам

    func testCalculatorScenarioIsValid() {
        let validation = validate(GenUIGallery.calculator)
        XCTAssertEqual(validation.issues, [], "\(validation.issues)")
        XCTAssertEqual(validation.document.mode, .mixed)
        XCTAssertEqual(ids(validation), ["amount", "rate", "years", "results", "balance", "schedule"])
        XCTAssertEqual(validation.document.computed.map(\.name), ["r", "n", "payment", "overpay"])
    }

    func testUnknownComponentAndBadExpressionDropOnlyThoseBlocks() {
        let validation = validate(GenUIGallery.unknownComponent)
        XCTAssertEqual(ids(validation), ["ok"])
        XCTAssertTrue(validation.issues.contains { $0.message.contains("неизвестный компонент «video_player»") })
        XCTAssertTrue(validation.issues.contains { $0.message.contains("ошибка в выражении") })
    }

    func testBrokenJSONFallsBackToEmptyDocument() {
        let validation = validate(GenUIGallery.brokenJSON)
        XCTAssertTrue(validation.document.isEmpty)
        XCTAssertEqual(validation.issues.first?.message, "ответ — не JSON")
    }

    func testForbiddenActionsDropTheirButtons() {
        let validation = validate(GenUIGallery.forbiddenAction)
        XCTAssertEqual(ids(validation), ["ask"])
        XCTAssertTrue(validation.issues.contains { $0.message.contains("«run_js» не разрешено") })
        XCTAssertTrue(validation.issues.contains { $0.message.contains("«open_url» не разрешено") })
    }

    func testInvalidAndDuplicateIDsAreRenamed() {
        let validation = validate(#"""
        {"version":1,"mode":"ui","text":"","state":[],"computed":[],"blocks":[
         {"id":"a","type":"text","visible_if":null,"text":"один","style":null},
         {"id":"a","type":"text","visible_if":null,"text":"два","style":null},
         {"id":"Bad ID!","type":"divider","visible_if":null}]}
        """#)
        XCTAssertEqual(ids(validation), ["a", "a-2", "auto-1"])
        XCTAssertEqual(validation.document.blocks[1].raw["id"]?.string, "a-2", "в истории блок хранится с новым id")
    }

    func testDepthAndCountLimits() {
        var nested = #"{"id":"leaf","type":"text","visible_if":null,"text":"глубоко","style":null}"#
        for level in 0..<8 {
            nested = #"{"id":"s\#(level)","type":"stack","visible_if":null,"axis":null,"spacing":null,"blocks":[\#(nested)]}"#
        }
        let deep = validate(#"{"version":1,"mode":"ui","text":"","state":[],"computed":[],"blocks":[\#(nested)]}"#)
        XCTAssertTrue(deep.issues.contains { $0.message.contains("вложенность") })
        XCTAssertLessThanOrEqual(deep.document.allBlocks.count, GenUILimits.maxDepth)

        let many = (0..<90).map { #"{"id":"t\#($0)","type":"text","visible_if":null,"text":"\#($0)","style":null}"# }.joined(separator: ",")
        let wide = validate(#"{"version":1,"mode":"ui","text":"","state":[],"computed":[],"blocks":[\#(many)]}"#)
        XCTAssertEqual(wide.document.blocks.count, GenUILimits.maxBlocks)
    }

    func testBindsDeclareAndCoerceState() {
        let validation = validate(#"""
        {"version":1,"mode":"ui","text":"","state":[{"name":"years","value":"10"},{"name":"flag","value":"нет"}],"computed":[],"blocks":[
         {"id":"y","type":"slider","visible_if":null,"label":"Срок","bind":"years","min":1,"max":30,"step":1,"format":null},
         {"id":"s","type":"slider","visible_if":null,"label":"Сумма","bind":"sum","min":100,"max":900,"step":null,"format":null},
         {"id":"f","type":"toggle","visible_if":null,"label":"Флаг","bind":"flag"}]}
        """#)
        let state = Dictionary(validation.document.state.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(state["years"], .number(10), "строка «10» в ползунке — число")
        XCTAssertEqual(state["sum"], .number(100), "без начального значения — минимум ползунка")
        XCTAssertEqual(state["flag"], .bool(false), "несовместимое значение — значение поля по умолчанию")
    }

    func testRangesAndRequiredFields() {
        let validation = validate(#"""
        {"version":1,"mode":"ui","text":"","state":[],"computed":[],"blocks":[
         {"id":"bad-slider","type":"slider","visible_if":null,"label":"Ставка","bind":"rate","min":30,"max":5,"step":null,"format":null},
         {"id":"no-label","type":"metric","visible_if":null,"label":null,"value":1,"format":null,"unit":null,"caption":null,"trend":null,"source":null,"aggregate":null},
         {"id":"grid","type":"grid","visible_if":null,"columns":9,"blocks":[{"id":"inner","type":"divider","visible_if":null}]},
         {"id":"chart","type":"chart","visible_if":null,"kind":"radar","title":null,"x":{"key":"x","title":null,"kind":"number"},"y":{"key":"y","title":null,"format":null},"series":null,"columns":null,"rows":[[1,2]],"source":null,"generate":null,"height":null}]}
        """#)
        XCTAssertEqual(ids(validation), ["grid"], "\(validation.issues)")
        XCTAssertTrue(validation.issues.contains { $0.message.contains("приведено") }, "9 колонок приведены к 4")
    }

    func testModeFollowsContent() {
        let textWithBlocks = validate(#"{"version":1,"mode":"text","text":"Итог","state":[],"computed":[],"blocks":[{"id":"d","type":"divider","visible_if":null}]}"#)
        XCTAssertEqual(textWithBlocks.document.mode, .mixed)
        let uiWithoutBlocks = validate(#"{"version":1,"mode":"ui","text":"Только текст","state":[],"computed":[],"blocks":[]}"#)
        XCTAssertEqual(uiWithoutBlocks.document.mode, .text)
    }

    func testLenientFormsOutsideStrictMode() {
        // Словари вместо массивов и пропущенные поля — так пишут модели без строгого режима
        let validation = validate(#"""
        {"mode":"ui","state":{"x":2},"blocks":[
         {"id":"t","type":"table","columns":[{"key":"a","title":"A"},{"key":"b","title":"B"}],"rows":[{"a":1,"b":2},[3,4]]},
         {"id":"g","type":"chart","kind":"line","x":{"key":"i","kind":"number"},"y":{"key":"v"},"generate":{"var":"i","from":1,"to":3,"columns":{"v":"i * x"}}}]}
        """#)
        XCTAssertEqual(ids(validation), ["t", "g"], "\(validation.issues)")
        XCTAssertEqual(validation.document.state.first?.value, .number(2))
    }

    func testStreamingBlockSeesUsedIDs() {
        let json = try! JSONValue(parsing: #"{"id":"a","type":"divider","visible_if":null}"#)
        let (block, issues) = GenUIValidator.block(from: json, usedIDs: ["a"])
        XCTAssertEqual(block?.id, "a-2")
        XCTAssertFalse(issues.isEmpty)
    }

    func testDocumentCodableRoundTripRevalidates() throws {
        let document = validate(GenUIGallery.mixed).document
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(GenUIDocument.self, from: data)
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.allBlocks.count, document.allBlocks.count)
    }

    func testGalleryScenariosValidate() {
        for scenario in GenUIGallery.scenarios where scenario.id != "broken" && scenario.id != "forbidden" {
            for payload in scenario.payloads {
                let validation = validate(payload)
                XCTAssertFalse(validation.document.isEmpty, scenario.id)
                XCTAssertEqual(validation.issues, [], "\(scenario.id): \(validation.issues)")
            }
        }
    }

    // MARK: - Схема ответа

    func testSchemaListsEveryRegisteredBlockType() throws {
        let schema = GenUIJSONSchema.openAIStrict.jsonValue
        let blocks = try XCTUnwrap(schema["$defs"]?["block"]?["anyOf"]?.array)
        let types = blocks.compactMap { $0["properties"]?["type"]?["enum"]?[0]?.string }
        XCTAssertEqual(types, GenUIComponentRegistry.standard.types)
        XCTAssertEqual(types.count, 24)
    }

    /// Правила строгого режима OpenAI: корень — объект без anyOf; у каждого
    /// объекта все свойства в required и additionalProperties: false; нет
    /// allOf, not, if/then/else; вложенность не больше 10
    func testSchemaIsStrictModeCompatible() throws {
        let schema = GenUIJSONSchema.openAIStrict.jsonValue
        XCTAssertEqual(schema["type"]?.string, "object")
        XCTAssertNil(schema["anyOf"])
        let forbidden: Set<String> = ["allOf", "not", "if", "then", "else", "oneOf", "patternProperties", "maxLength", "minLength", "const", "propertyOrdering"]
        var objects = 0
        var maxDepth = 0

        func walk(_ node: JSONValue, depth: Int) {
            guard let object = node.object else {
                node.array?.forEach { walk($0, depth: depth) }
                return
            }
            maxDepth = max(maxDepth, depth)
            for key in object.keys {
                XCTAssertFalse(forbidden.contains(key), "запрещённое ключевое слово \(key)")
            }
            if object["type"]?.string == "object" || object["type"]?.array?.contains(.string("object")) == true {
                objects += 1
                let properties = object["properties"]?.object ?? [:]
                let required = Set(object["required"]?.array?.compactMap(\.string) ?? [])
                XCTAssertEqual(required, Set(properties.keys), "все свойства обязательны: \(properties.keys.sorted())")
                XCTAssertEqual(object["additionalProperties"], .bool(false))
                for value in properties.values { walk(value, depth: depth + 1) }
            }
            if let items = object["items"] { walk(items, depth: depth + 1) }
            object["anyOf"]?.array?.forEach { walk($0, depth: depth + 1) }
        }

        walk(schema, depth: 1)
        for definition in schema["$defs"]?.object?.values.map({ $0 }) ?? [] {
            walk(definition, depth: 1)
        }
        XCTAssertGreaterThan(objects, 40)
        XCTAssertLessThanOrEqual(maxDepth, 10)
    }

    func testSchemaKeyOrderPutsTextBeforeBlocks() throws {
        let text = GenUIJSONSchema.openAIStrictString
        let properties = try XCTUnwrap(text.range(of: "\"properties\":{\"version\""))
        let tail = text[properties.lowerBound...]
        let textKey = try XCTUnwrap(tail.range(of: "\"text\":"))
        let blocksKey = try XCTUnwrap(tail.range(of: "\"blocks\":"))
        XCTAssertLessThan(textKey.lowerBound, blocksKey.lowerBound)
        XCTAssertNoThrow(try JSONValue(parsing: text), "схема — корректный JSON")
    }

    func testPromptCatalogMentionsEveryType() {
        let catalog = GenUIJSONSchema.promptCatalog()
        for type in GenUIComponentRegistry.standard.types {
            XCTAssertTrue(catalog.contains("- \(type) {"), type)
        }
    }
}
