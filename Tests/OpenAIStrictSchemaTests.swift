import XCTest
@testable import LocalDrive

// OpenAI отклонил схему Generative UI целиком: 400 invalid_json_schema «Invalid
// schema for response_format 'genui_answer'» (живой запрос 13.10.2026). Причина —
// необязательные массивы в виде {"type": ["array", "null"]}: та же схема с anyOf
// принимается. Чат при этом писал «Облако недоступно», и причина терялась
@MainActor
final class OpenAIStrictSchemaTests: XCTestCase {
    func testNullableArraysUseAnyOf() throws {
        let schema = try JSONSerialization.jsonObject(with: Data(GenUIJSONSchema.openAIStrictString.utf8))
        var offenders: [String] = []
        func walk(_ node: Any, _ path: String) {
            if let object = node as? [String: Any] {
                if let types = object["type"] as? [String], types.contains("null"), types.contains("array") || types.contains("object") {
                    offenders.append(path)
                }
                for (key, value) in object { walk(value, path + "/" + key) }
            } else if let array = node as? [Any] {
                for (index, value) in array.enumerated() { walk(value, path + "[\(index)]") }
            }
        }
        walk(schema, "#")
        XCTAssertEqual(offenders, [], "необязательный массив или объект — только через anyOf с null")
    }

    func testBadRequestCarriesServerText() {
        let body = Data(#"{"error": {"message": "Invalid schema for response_format 'genui_answer'. Please ensure it is a valid JSON Schema.", "code": "invalid_json_schema"}}"#.utf8)
        let failure = CloudResponseParser.failure(status: 400, data: body)
        guard case .rejected(let text)? = failure else { return XCTFail("ждали rejected, пришло \(String(describing: failure))") }
        XCTAssertTrue(text.hasPrefix("Invalid schema for response_format"))
        XCTAssertTrue(ChatSession.notice(for: failure!).hasPrefix("Облако отклонило запрос: Invalid schema"))
        XCTAssertFalse(failure!.pausesQueue, "отказ в одном запросе не останавливает распознавание")
    }

    func testRejectedSchemaFallsBackToPlainAnswer() throws {
        let body = Data(#"{"error": {"message": "Invalid schema for response_format 'genui_answer'. Please ensure it is a valid JSON Schema.", "param": "text.format.schema", "code": "invalid_json_schema"}}"#.utf8)
        let relaxed = try XCTUnwrap(OpenAIChatDialect().relaxing(CloudChatOptions(), status: 400, body: body))
        XCTAssertFalse(relaxed.genUI)
        XCTAssertTrue(relaxed.summaries && relaxed.fastTier && relaxed.configurationUpdates, "прочее не трогаем")
    }
}
