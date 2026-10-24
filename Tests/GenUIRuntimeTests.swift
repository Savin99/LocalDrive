import XCTest
@testable import LocalDrive

// Состояние, поток и действия Generative UI
@MainActor
final class GenUIRuntimeTests: XCTestCase {
    private func model(_ json: String) -> GenUIMessageModel {
        GenUIMessageModel(json: Data(json.utf8))
    }

    /// Аннуитет, посчитанный независимо от языка выражений
    private func annuity(amount: Double, rate: Double, years: Double) -> Double {
        let r = rate / 1200
        let n = years * 12
        return amount * r / (1 - pow(1 + r, -n))
    }

    func testSliderChangeRecomputesComputedValues() throws {
        let message = model(GenUIGallery.calculator)
        let before = try XCTUnwrap(message.state.value("payment")?.number)
        XCTAssertEqual(before, annuity(amount: 3_000_000, rate: 18.5, years: 10), accuracy: 0.01)

        message.state.set("amount", .number(4_000_000))
        let after = try XCTUnwrap(message.state.value("payment")?.number)
        XCTAssertEqual(after, annuity(amount: 4_000_000, rate: 18.5, years: 10), accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(message.state.value("overpay")?.number), after * 120 - 4_000_000, accuracy: 0.01)
    }

    func testGeneratedRowsFollowState() throws {
        let message = model(GenUIGallery.calculator)
        let table = try XCTUnwrap(message.blocks.first { $0.id == "schedule" }?.component as? GenUITableComponent)
        let generate = try XCTUnwrap(table.generate)
        XCTAssertEqual(generate.rows(with: message.state)?.rows.count, 10)
        message.state.set("years", .number(15))
        let rows = try XCTUnwrap(generate.rows(with: message.state)?.rows)
        XCTAssertEqual(rows.count, 15)
        XCTAssertEqual(try XCTUnwrap(rows.last?["left"]?.number), 0, accuracy: 1, "к концу срока долг выплачен")
    }

    func testGenerateRespectsPointLimit() throws {
        let message = model(#"""
        {"version":1,"mode":"ui","text":"","state":[{"name":"n","value":10}],"computed":[],"blocks":[
         {"id":"c","type":"chart","visible_if":null,"kind":"line","title":null,"x":{"key":"i","title":null,"kind":"number"},"y":{"key":"v","title":null,"format":null},"series":null,"columns":null,"rows":null,"source":null,
          "generate":{"var":"i","from":1,"to":{"expr":"n"},"step":null,"columns":[{"key":"v","expr":"prev.v + i"}]},"height":null}]}
        """#)
        let chart = try XCTUnwrap(message.blocks.first?.component as? GenUIChartComponent)
        let rows = try XCTUnwrap(chart.generate?.rows(with: message.state)?.rows)
        XCTAssertEqual(rows.last?["v"], .number(55), "prev.v накапливает: 1 + 2 + … + 10")
        message.state.set("n", .number(10_000))
        XCTAssertNil(chart.generate?.rows(with: message.state), "больше 500 точек — пусто, а не зависание")
    }

    func testComputedCycleIsEmptyAndChainIsFast() {
        let cycle = model(#"{"version":1,"mode":"text","text":"x","state":[],"computed":[{"name":"a","expr":"b + 1"},{"name":"b","expr":"a + 1"}],"blocks":[]}"#)
        XCTAssertNil(cycle.state.value("a"))

        // Цепочка a0 = a1 + a1, a1 = a2 + a2 … без кэша считалась бы 2^19 раз
        let chain = (0..<19).map { #"{"name":"a\#($0)","expr":"a\#($0 + 1) + a\#($0 + 1)"}"# }.joined(separator: ",")
        let deep = model(#"{"version":1,"mode":"text","text":"x","state":[{"name":"a19","value":1}],"computed":[\#(chain)],"blocks":[]}"#)
        let start = Date()
        XCTAssertEqual(deep.state.value("a0"), .number(pow(2, 19)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testStreamingKeepsUserChangesOnFinish() throws {
        let message = GenUIMessageModel()
        message.setPartialText("Посчитал")
        XCTAssertEqual(message.phase, .streaming)
        message.setState(try JSONValue(parsing: #"[{"name":"amount","value":3000000}]"#))
        XCTAssertTrue(message.append(try JSONValue(parsing: #"{"id":"amount","type":"slider","visible_if":null,"label":"Сумма","bind":"amount","min":0,"max":9000000,"step":null,"format":"money"}"#)))
        XCTAssertFalse(message.append(try JSONValue(parsing: #"{"id":"x","type":"unknown","visible_if":null}"#)), "неизвестный блок не показывается")
        message.state.set("amount", .number(5_000_000))

        message.finish(json: Data(GenUIGallery.calculator.utf8))
        XCTAssertEqual(message.phase, .finished)
        XCTAssertEqual(message.state.value("amount"), .number(5_000_000), "подвинутое человеком не сбрасывается")
        XCTAssertEqual(message.blocks.count, 6)
    }

    func testAppendRejectsDuplicateIDs() throws {
        let message = GenUIMessageModel()
        let block = try JSONValue(parsing: #"{"id":"d","type":"divider","visible_if":null}"#)
        XCTAssertTrue(message.append(block))
        XCTAssertTrue(message.append(block), "повтор переименован в d-2")
        XCTAssertEqual(message.blocks.map(\.id), ["d", "d-2"])
    }

    func testFailedStreamKeepsWhatArrived() throws {
        let message = GenUIMessageModel()
        message.setPartialText("Начало ответа")
        message.fail("обрыв сети")
        XCTAssertEqual(message.phase, .failed("обрыв сети"))
        XCTAssertEqual(message.text, "Начало ответа")
        XCTAssertFalse(message.isEmpty)
    }

    func testReplaceNestedBlockKeepsState() throws {
        let message = model(GenUIGallery.calculator)
        message.state.set("years", .number(20))
        let replaced = message.replace(blockID: "payment", with: try JSONValue(parsing: #"""
        {"type":"metric","visible_if":null,"label":"Платёж с учётом страховки","value":{"expr":"payment * 1.01"},"format":"money","unit":null,"caption":null,"trend":null,"source":null,"aggregate":null}
        """#))
        XCTAssertTrue(replaced)
        let metric = try XCTUnwrap(message.document.allBlocks.first { $0.id == "payment" }?.component as? GenUIMetricComponent)
        XCTAssertEqual(metric.label.description, "Платёж с учётом страховки")
        XCTAssertEqual(message.state.value("years"), .number(20))
        XCTAssertFalse(message.replace(blockID: "missing", with: .object([:])))
    }

    func testLocalActionsAndForwardedSubmit() async throws {
        let message = model(GenUIGallery.form)
        let performer = GenUIFakePerformer()
        await message.runner.run(.set(variable: "days", value: .literal(.number(14))), block: "x", state: message.state, performer: performer)
        XCTAssertEqual(message.state.value("days"), .number(14))
        XCTAssertTrue(performer.calls.isEmpty, "set выполняется без приложения")

        let form = try XCTUnwrap(message.blocks.first?.component as? GenUIFormComponent)
        await message.runner.run(form.action, block: "trip", state: message.state, performer: performer)
        XCTAssertEqual(performer.calls, ["submit: children, country, days, departure"])
        XCTAssertEqual(message.runner.outcomes["trip"], .done("Передано модели: children, country, days, departure"))

        await message.runner.run(.reset(variables: ["days"]), block: "x", state: message.state, performer: performer)
        XCTAssertEqual(message.state.value("days"), .number(10))
    }

    func testForwardedActionWithoutPerformerFailsVisibly() async {
        let message = model(GenUIGallery.forbiddenAction)
        await message.runner.run(.ask(text: GenUITemplate(text: "вопрос")), block: "ask", state: message.state, performer: nil)
        XCTAssertEqual(message.runner.outcomes["ask"], .failed("Действие недоступно"))
    }

    func testSourceParametersFollowState() throws {
        let message = model(GenUIGallery.mixed)
        let soon = try XCTUnwrap(message.document.allBlocks.first { $0.id == "soon" }?.component as? GenUIMetricComponent)
        let spec = try XCTUnwrap(soon.source)
        XCTAssertEqual(spec.resolved(with: message.state).withinDays, 365)
        message.state.set("horizon", .number(30))
        XCTAssertEqual(spec.resolved(with: message.state).withinDays, 30)
    }

    func testFakeProviderAndAggregates() async throws {
        let provider = GenUIFakeDataProvider()
        let stats = try await provider.rows(for: GenUIDataSource(kind: .documentStats))
        XCTAssertEqual(stats.columns, ["key", "value"])
        XCTAssertEqual(GenUIMetricComponent.aggregate(stats, .init(op: "sum", column: "value")), .number(Double(GenUIFakeDataProvider.documents.count)))
        XCTAssertEqual(GenUIMetricComponent.aggregate(stats, nil), .number(Double(stats.rows.count)))
        var expiring = GenUIDataSource(kind: .expiring)
        expiring.withinDays = 60
        let soon = try await provider.rows(for: expiring)
        XCTAssertEqual(soon.rows.compactMap { $0["title"]?.string }, ["Полис ОСАГО"])
    }

    func testVisibilityConditionFollowsState() throws {
        let message = model(GenUIGallery.form)
        let note = try XCTUnwrap(message.document.allBlocks.first { $0.id == "children-note" })
        let condition = try XCTUnwrap(note.visibleIf)
        XCTAssertEqual(message.state.evaluate(condition)?.truthy, false)
        message.state.set("children", .bool(true))
        XCTAssertEqual(message.state.evaluate(condition)?.truthy, true)
    }
}
