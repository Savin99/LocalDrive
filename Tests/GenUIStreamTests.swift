import XCTest
@testable import LocalDrive

// Поток ответа интерфейсом: разбор по кускам и наполнение сообщения. Ответы —
// в формате схемы, как их присылает модель; данные синтетические
final class GenUIStreamParserTests: XCTestCase {
    private let document = #"{"version":1,"mode":"mixed","text":"Привет, \"мир\"\nЗ 😀!","state":[{"name":"a","value":1}],"computed":[{"name":"b","expr":"a * 2"}],"blocks":[{"id":"x","type":"text","visible_if":null,"text":"скобки }{][ внутри","style":null},{"id":"y","type":"divider","visible_if":null}]}"#

    private func feed(_ chunks: [String]) -> ([GenUIStreamParser.Event], GenUIStreamParser) {
        var parser = GenUIStreamParser()
        var events: [GenUIStreamParser.Event] = []
        for chunk in chunks { events += parser.feed(chunk) }
        return (events, parser)
    }

    private func texts(_ events: [GenUIStreamParser.Event]) -> [String] {
        events.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }

    private func blocks(_ events: [GenUIStreamParser.Event]) -> [JSONValue] {
        events.compactMap { if case .block(let block) = $0 { block } else { nil } }
    }

    func testCharacterByCharacter() {
        let (events, parser) = feed(document.map { String($0) })
        XCTAssertEqual(texts(events).last, "Привет, \"мир\"\nЗ 😀!")
        XCTAssertGreaterThan(texts(events).count, 5, "текст растёт по мере прихода")
        XCTAssertFalse(texts(events).contains { $0.contains("\\") }, "escape-последовательности не видны")
        XCTAssertEqual(blocks(events).map { $0["id"]?.string }, ["x", "y"])
        XCTAssertEqual(blocks(events).first?["text"]?.string, "скобки }{][ внутри", "скобки в строке не ломают границу блока")
        let state = events.firstIndex { if case .state = $0 { true } else { false } }
        let computed = events.firstIndex { if case .computed = $0 { true } else { false } }
        let block = events.firstIndex { if case .block = $0 { true } else { false } }
        XCTAssertNotNil(state)
        XCTAssertNotNil(computed)
        XCTAssertLessThan(state ?? .max, block ?? .min, "состояние — до первого блока")
        XCTAssertEqual(parser.complete.map { String(decoding: $0, as: UTF8.self) }, document)
    }

    func testChunksBreakAnywhere() {
        // Число, escape и \u — на границах кусков
        let (events, parser) = feed(["{\"version\":1", "2,\"text\":\"a\\", "\"b\\u04", "1", "7\"}"])
        XCTAssertEqual(texts(events).last, "a\"bЗ")
        XCTAssertNotNil(parser.complete)

        let pieces = stride(from: 0, to: document.count, by: 7).map { start in
            String(document.dropFirst(start).prefix(7))
        }
        let (sevens, closed) = feed(pieces)
        XCTAssertEqual(blocks(sevens).count, 2)
        XCTAssertNotNil(closed.complete)
    }

    func testTruncatedAnswerKeepsClosedBlocks() {
        let (events, parser) = feed([String(document.dropLast(30))])
        XCTAssertNil(parser.complete)
        XCTAssertEqual(blocks(events).map { $0["id"]?.string }, ["x"])
    }

    func testPlainTextAndOddShapes() {
        let (_, plain) = feed(["Просто ", "текст"])
        XCTAssertTrue(plain.isNotJSON)
        XCTAssertEqual(plain.raw, "Просто текст")

        // Ключи не по порядку, пробелы, null вместо массива
        let shuffled = "  {\n \"blocks\" : [ {\"id\":\"z\",\"type\":\"divider\",\"visible_if\":null} ] ,\n \"text\" : \"после\" , \"version\" : 1 , \"mode\":\"ui\", \"state\": null, \"computed\": [] }  "
        let (events, parser) = feed(shuffled.map { String($0) })
        XCTAssertEqual(blocks(events).first?["id"]?.string, "z")
        XCTAssertEqual(texts(events).last, "после")
        XCTAssertNotNil(parser.complete)

        // Элементы blocks не объекты: число и литерал пропускаются
        let (odd, oddParser) = feed(["{\"blocks\":[1, true, {\"id\":\"ok\"}],\"text\":\"\"}"])
        XCTAssertEqual(blocks(odd).map { $0["id"]?.string }, ["ok"])
        XCTAssertNotNil(oddParser.complete)
    }

    func testUTF8PrefixDropsHalfLetter() {
        let bytes = Array("Жук".utf8)
        XCTAssertEqual(String(decoding: GenUIStreamParser.completeUTF8Prefix(Array(bytes.dropLast())), as: UTF8.self), "Жу")
        XCTAssertEqual(String(decoding: GenUIStreamParser.completeUTF8Prefix(bytes), as: UTF8.self), "Жук")
        XCTAssertEqual(GenUIStreamParser.completeUTF8Prefix([]).count, 0)
    }
}

@MainActor
final class GenUIStreamFeedTests: XCTestCase {
    private let calculator = #"""
    {"version":1,"mode":"mixed","text":"Посчитал платёж:","state":[{"name":"amount","value":3000000},{"name":"rate","value":18.5},{"name":"years","value":10}],"computed":[{"name":"r","expr":"rate / 1200"},{"name":"n","expr":"years * 12"},{"name":"payment","expr":"amount * r / (1 - pow(1 + r, -n))"}],"blocks":[{"id":"amount","type":"slider","visible_if":null,"label":"Сумма","bind":"amount","min":500000,"max":20000000,"step":100000,"format":"money"},{"id":"payment","type":"metric","visible_if":null,"label":"Платёж","value":{"expr":"payment"},"format":"money","unit":null,"caption":null,"trend":null,"source":null,"aggregate":null}]}
    """#

    func testBlocksAppearAsTheyClose() {
        let feed = GenUIStreamFeed()
        let closeOfFirstBlock = calculator.range(of: "\"format\":\"money\"}")!.upperBound
        feed.feed(String(calculator[..<closeOfFirstBlock]))
        XCTAssertEqual(feed.model.text, "Посчитал платёж:")
        XCTAssertEqual(feed.model.blocks.map(\.id), ["amount"], "первый блок закрыт — уже виден")
        XCTAssertEqual(feed.model.state.value("amount"), .number(3_000_000))
        XCTAssertEqual(feed.model.phase, .streaming)

        feed.feed(String(calculator[closeOfFirstBlock...]))
        feed.finish()
        XCTAssertEqual(feed.model.phase, .finished)
        XCTAssertEqual(feed.model.blocks.map(\.id), ["amount", "payment"])
        XCTAssertEqual(feed.model.mode, .mixed)
        guard case .number(let payment)? = feed.model.state.value("payment") else { return XCTFail("платёж не посчитан") }
        XCTAssertEqual(payment, 55_025, accuracy: 50, "аннуитет 3 млн, 18,5 %, 10 лет")
    }

    func testBrokenStreamKeepsWhatArrived() {
        let feed = GenUIStreamFeed()
        feed.feed(String(calculator.dropLast(40)))
        feed.finish()
        XCTAssertEqual(feed.model.blocks.map(\.id), ["amount"])
        XCTAssertEqual(feed.model.text, "Посчитал платёж:")
        if case .failed = feed.model.phase {} else { XCTFail("оборванный ответ — failed") }
    }

    func testPlainTextBecomesTextAnswer() {
        let feed = GenUIStreamFeed()
        feed.feed("Паспорт действует до 2031 года.")
        feed.finish()
        XCTAssertEqual(feed.model.mode, .text)
        XCTAssertEqual(feed.model.text, "Паспорт действует до 2031 года.")
        XCTAssertTrue(feed.model.blocks.isEmpty)
    }

    func testNumbersAreMaskedInsideValues() {
        // Маска — по разобранным значениям: JSON с числом остаётся JSON
        let feed = GenUIStreamFeed(mask: { CloudChatMask.apply($0, sensitive: ["4601123456"]) })
        let answer = #"{"version":1,"mode":"mixed","text":"Номер 4601 123456","state":[],"computed":[],"blocks":[{"id":"n","type":"metric","visible_if":null,"label":"Номер","value":4601123456,"format":null,"unit":null,"caption":null,"trend":null,"source":null,"aggregate":null}]}"#
        feed.feed(answer)
        feed.finish()
        XCTAssertFalse(feed.model.text.contains("123456"), feed.model.text)
        XCTAssertEqual(feed.model.phase, .finished)
        let raw = feed.model.blocks.first?.raw
        XCTAssertEqual(raw?["value"], .string("••••"), "число-номер стало маской")
    }
}
