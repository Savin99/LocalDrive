import XCTest
@testable import LocalDrive

// Инструменты агента на iPhone: те же, что у облака, без страниц картинками.
// С переменной AGENT_BENCH_DUMP тест кладёт инструкцию и инструменты в файлы —
// их дословно берёт стенд на Mac (docs/agent.md)
@MainActor
final class LocalAgentPromptTests: XCTestCase {
    /// Каждый инструмент iPhone исполняет код облака: имя должно быть среди
    /// объявленных облаку, иначе вызов модели уйдёт в «нет такого инструмента»
    func testToolsAreCloudToolsWithoutViewing() throws {
        let tools = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(LocalAgentPrompt.toolsJSON.utf8)) as? [[String: Any]])
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        let cloud = Set((CloudChatPrompt.tools.array ?? []).compactMap { $0["name"]?.string })
        XCTAssertTrue(Set(names).isSubset(of: cloud), "у iPhone есть инструмент, которого нет у облака: \(Set(names).subtracting(cloud))")
        XCTAssertFalse(names.contains("view_document"))
        XCTAssertTrue(names.contains("search_documents"))
        XCTAssertTrue(names.contains("propose_file_actions"))
        XCTAssertTrue(names.contains("propose_fact_card"))
        XCTAssertEqual(Set(tools.compactMap { $0["type"] as? String }), ["function"])
        XCTAssertEqual(LocalAgentPrompt.toolNames, Set(names))

        if let path = ProcessInfo.processInfo.environment["AGENT_BENCH_DUMP"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try LocalAgentPrompt.toolsJSON.write(to: directory.appendingPathComponent("tools.json"), atomically: true, encoding: .utf8)
            try LocalAgentPrompt.base.write(to: directory.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
            // Начало инструкции с владельцем — стенд дописывает свою опись
            let head = LocalAgentPrompt.instructions(index: "", facts: "", owner: "Савин И. А.")
            try head.write(to: directory.appendingPathComponent("head.txt"), atomically: true, encoding: .utf8)
        }
    }

    func testInstructionsCarryIndexAndOwner() {
        let index = (1...100).map { "d\($0) · passport_ru · Паспорт · Савин И. А. · Паспорта" }.joined(separator: "\n")
        let text = LocalAgentPrompt.instructions(index: index, facts: "fX · Дом Камилы · Домофон", owner: "Савин И. А.")
        XCTAssertTrue(text.contains("Владелец хранилища: Савин И. А."))
        XCTAssertTrue(text.contains("d60 — Паспорт; владелец: Савин И. А.; папка: Паспорта"))
        XCTAssertFalse(text.contains("d61 —"), "опись не обрезана: каждый токен — время разбора на iPhone")
        XCTAssertTrue(text.contains("Дом Камилы"))
    }
}
