import XCTest
@testable import LocalDrive

@MainActor
final class AppTelemetryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        StubURLProtocol.reset()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppTelemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testConfigValidatesStrictHTTPSAndTokenLength() {
        XCTAssertNil(AppLogsConfig(host: nil, token: "12345678901234567890"))
        XCTAssertNil(AppLogsConfig(host: "$(APP_LOGS_HOST)", token: "12345678901234567890"))
        XCTAssertNil(AppLogsConfig(host: "https://logs.example.com", token: "12345678901234567890"), "схема в хосте запрещена")
        XCTAssertNil(AppLogsConfig(host: "logs.example.com", token: "short"))
        let valid = AppLogsConfig(host: "logs.193.233.87.211.sslip.io", token: "ioiD4RYn8Df8u9jYVAROgXbYAK_busif_GWKVch4yhI")
        XCTAssertEqual(valid?.ingestURL.absoluteString, "https://logs.193.233.87.211.sslip.io/v1/ingest")
    }

    func testRedactorStripsSecretsAPIKeysAndDocumentNumbers() {
        let raw = "Authorization: Bearer abcdef1234567890 key=sk-proj-1234567890abcdefghij AIzaSyD1234567890abcdefghij паспорт 4601123456"
        let clean = AppLogRedactor.redact(raw)
        XCTAssertFalse(clean.contains("abcdef1234567890"))
        XCTAssertFalse(clean.contains("sk-proj-"))
        XCTAssertFalse(clean.contains("AIzaSyD"))
        XCTAssertFalse(clean.contains("4601123456"))
        XCTAssertTrue(clean.contains("[REDACTED]"))
        XCTAssertTrue(clean.contains("[REDACTED_KEY]"))
        XCTAssertTrue(clean.contains("[NUM]"))

        let meta = AppLogRedactor.redactMeta([
            "api_key": "sk-proj-secretvalue12345678",
            "question": "мой паспорт 4601123456",
            "model": "gpt-6-luna",
            "tools": "view_attachment",
        ])
        XCTAssertEqual(meta?["api_key"], "[REDACTED]")
        XCTAssertEqual(meta?["question"], "[REDACTED]")
        XCTAssertEqual(meta?["model"], "gpt-6-luna")
        XCTAssertEqual(meta?["tools"], "view_attachment")
    }

    func testUploadSendsV1PayloadAndDrainsQueue() async throws {
        let suite = "AppTelemetry-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let config = try XCTUnwrap(AppLogsConfig(host: "logs.193.233.87.211.sslip.io", token: "tok_123456789012345678901234"))
        let queueURL = root.appendingPathComponent("telemetry-queue.json")
        let telemetry = AppTelemetry(
            config: config,
            queueURL: queueURL,
            defaults: defaults,
            session: StubURLProtocol.session(),
            registerAsLive: false
        )

        telemetry.recordScreen("Chat")
        telemetry.recordTiming("cloud-chat", code: "turn_ok", message: "Ответ за 1.2 с", meta: ["model": "gpt-6-luna", "tools": "view_attachment"])
        try await Task.sleep(for: .milliseconds(50))

        StubURLProtocol.reset([StubURLProtocol.Reply(status: 200, body: Data(#"{"ok":true}"#.utf8))])
        let sent = try await telemetry.reportUserIssue(note: "Тест заметки с ключом sk-proj-1234567890abcdefghij")
        XCTAssertEqual(sent, 3)
        XCTAssertEqual(telemetry.pendingCount, 0)
        XCTAssertNotNil(telemetry.lastSentAt)
        XCTAssertNil(telemetry.lastFailure)

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://logs.193.233.87.211.sslip.io/v1/ingest")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok_123456789012345678901234")
        let payload = try JSONDecoder().decode(TelemetryBatchPayload.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(payload.trigger, .userFlag)
        XCTAssertEqual(payload.events.count, 3)
        XCTAssertEqual(payload.events.last?.kind, .userFlag)
        XCTAssertFalse(payload.events.last?.message.contains("sk-proj-") == true)
    }

    func testFailedUploadKeepsEventsInDiskQueue() async throws {
        let suite = "AppTelemetryFail-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let config = try XCTUnwrap(AppLogsConfig(host: "logs.193.233.87.211.sslip.io", token: "tok_123456789012345678901234"))
        let queueURL = root.appendingPathComponent("telemetry-queue.json")
        let telemetry = AppTelemetry(
            config: config,
            queueURL: queueURL,
            defaults: defaults,
            session: StubURLProtocol.session(),
            registerAsLive: false
        )

        telemetry.recordAction("chat", message: "Событие")
        try await Task.sleep(for: .milliseconds(50))

        StubURLProtocol.reset([StubURLProtocol.Reply(status: 503, body: Data())])
        do {
            _ = try await telemetry.flushNow(trigger: .manual)
            XCTFail("ждали ошибку 503")
        } catch {
            XCTAssertEqual(error as? TelemetryUploadError, .httpStatus(503))
        }
        XCTAssertEqual(telemetry.pendingCount, 1)
        XCTAssertNotNil(telemetry.lastFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueURL.path))
    }
}
