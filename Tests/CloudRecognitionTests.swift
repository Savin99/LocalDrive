import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LocalDrive

// Облачное распознавание без сети: запросы уходят в заглушку URLProtocol.
// Проверяется, что и как отправляется, как разбираются ответы и ошибки и
// что из папок вне поиска не уходит ничего. Данные синтетические

/// Заглушка сети: отвечает по очереди заданными ответами и запоминает запросы
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
        /// Тело кусками, с паузой перед каждым: поток, который думает или
        /// замолкает, — для сроков ответа и «Стопа»
        var parts: [(delay: TimeInterval, data: Data)] = []
    }

    private let stateLock = NSLock()
    private var stopped = false

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func reset(_ queued: [Reply] = []) {
        lock.lock(); defer { lock.unlock() }
        replies = queued
        recorded = []
    }

    static func enqueue(_ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        replies.append(reply)
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        // Тело запроса URLSession передаёт протоколу потоком
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            var body = Data()
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
            captured.httpBody = body
        }
        Self.lock.lock()
        Self.recorded.append(captured)
        let reply = Self.replies.isEmpty ? Reply(status: 500, body: Data()) : Self.replies.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard !reply.parts.isEmpty else {
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // Куски без паузы — сразу: поток уже начался и стоит
        var pending = reply.parts[...]
        while let part = pending.first, part.delay == 0 {
            client?.urlProtocol(self, didLoad: part.data)
            pending = pending.dropFirst()
        }
        guard !pending.isEmpty else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var fireAt = DispatchTime.now()
        for (index, part) in pending.enumerated() {
            fireAt = fireAt + part.delay
            let last = index == pending.count - 1
            DispatchQueue.global().asyncAfter(deadline: fireAt) { [self] in
                guard !isStopped else { return }
                client?.urlProtocol(self, didLoad: part.data)
                if last { client?.urlProtocolDidFinishLoading(self) }
            }
        }
    }

    private var isStopped: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopped
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }
}

private enum Replies {
    static let page = #"{"type": "passport_ru", "country": "", "surname": "ПЕТРОВ", "given_name": "ИВАН", "patronymic": "СЕРГЕЕВИЧ", "birth_date": "12.05.1985", "issue_date": "15.03.2012", "expiry_date": "", "number": "4509 123456", "department_code": "690-001", "issued_by": "ОТДЕЛОМ УФМС РОССИИ ПО ТВЕРСКОЙ ОБЛ.", "birth_place": "ГОР. ТВЕРЬ", "sex": "М", "text": "ПАСПОРТ\nОБЛАЧНЫЙТЕКСТ ПЕТРОВ ИВАН"}"#

    static func gemini(_ text: String = page) -> StubURLProtocol.Reply {
        let body: [String: Any] = [
            "candidates": [["content": ["parts": [["text": text]]]]],
            "usageMetadata": ["promptTokenCount": 1600, "candidatesTokenCount": 700, "thoughtsTokenCount": 100],
        ]
        return StubURLProtocol.Reply(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
    }

    /// Ответ Responses API: в output рассуждение и сообщение с output_text
    static func openAI(_ text: String = page, refusal: Bool = false) -> StubURLProtocol.Reply {
        let content: [String: Any] = refusal
            ? ["type": "refusal", "refusal": "I can't help with that."]
            : ["type": "output_text", "text": text, "annotations": []]
        let body: [String: Any] = [
            "id": "resp_1", "object": "response", "status": "completed",
            "output": [
                ["id": "rs_1", "type": "reasoning", "summary": [], "encrypted_content": "enc"],
                ["id": "msg_1", "type": "message", "role": "assistant", "status": "completed", "content": [content]],
            ],
            "usage": ["input_tokens": 4600, "output_tokens": 900, "output_tokens_details": ["reasoning_tokens": 200]],
        ]
        return StubURLProtocol.Reply(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
    }

    static func error(_ status: Int, _ message: String, code: Any = 400, statusText: String? = nil, param: String? = nil,
                      headers: [String: String] = [:]) -> StubURLProtocol.Reply {
        var error: [String: Any] = ["code": code, "message": message]
        if let statusText { error["status"] = statusText }
        if let param { error["param"] = param }
        return StubURLProtocol.Reply(status: status, body: try! JSONSerialization.data(withJSONObject: ["error": error]), headers: headers)
    }
}

private actor UsageLog {
    var usages: [CloudUsage] = []
    func record(_ usage: CloudUsage) { usages.append(usage) }
}

private actor SleepLog {
    var count = 0
    var durations: [Duration] = []
    func record(_ duration: Duration = .zero) {
        count += 1
        durations.append(duration)
    }
}

final class CloudRequestTests: XCTestCase {
    private let gemini = CloudConfiguration(provider: .gemini, model: "gemini-3.8-flash", baseURL: CloudProvider.gemini.defaultBaseURL, apiKey: "test-key")
    private let openAI = CloudConfiguration(provider: .openAI, model: "gpt-6.1-sol", baseURL: "https://relay.example/v1/", apiKey: "test-key")
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])

    override func setUp() {
        StubURLProtocol.reset()
    }

    private func reader(_ configuration: CloudConfiguration, sleeps: SleepLog = SleepLog()) -> CloudDocumentReader {
        CloudDocumentReader(configuration: configuration, session: StubURLProtocol.session(), sleep: { await sleeps.record($0) })
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testGeminiRequestCarriesOnlyImageAndInstruction() async throws {
        StubURLProtocol.reset([Replies.gemini()])
        let result = try await reader(gemini).read(pages: [CloudPage(number: 1, jpeg: jpeg)])
        XCTAssertEqual(result.readout.surname, "ПЕТРОВ")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let json = try body(request)
        XCTAssertEqual(Set(json.keys), ["contents", "generationConfig"], "ни имени файла, ни папки — только кадр и инструкция")
        let parts = try XCTUnwrap(((json["contents"] as? [[String: Any]])?.first)?["parts"] as? [[String: Any]])
        let inline = try XCTUnwrap(parts.first?["inline_data"] as? [String: Any])
        XCTAssertEqual(inline["mime_type"] as? String, "image/jpeg")
        XCTAssertEqual(inline["data"] as? String, jpeg.base64EncodedString())
        XCTAssertEqual(parts.last?["text"] as? String, CloudPrompt.instruction, "текст после картинки, как советует документация")
        let format = ((json["generationConfig"] as? [String: Any])?["responseFormat"] as? [String: Any])?["text"] as? [String: Any]
        XCTAssertEqual(format?["mimeType"] as? String, "application/json")
        XCTAssertNotNil(format?["schema"])
    }

    func testOpenAIResponsesRequest() async throws {
        StubURLProtocol.reset([Replies.openAI()])
        let result = try await reader(openAI).read(pages: [CloudPage(number: 1, jpeg: jpeg)])
        XCTAssertEqual(result.readout.number, "4509 123456")
        XCTAssertEqual(result.pages.first?.text, "ПАСПОРТ\nОБЛАЧНЫЙТЕКСТ ПЕТРОВ ИВАН")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let json = try body(request)
        XCTAssertEqual(Set(json.keys), ["model", "store", "input", "text", "reasoning", "prompt_cache_options", "max_output_tokens"],
                       "ни имени файла, ни папки — только кадр и инструкция")
        XCTAssertEqual(json["store"] as? Bool, false, "ответ у OpenAI не хранится")
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual((json["prompt_cache_options"] as? [String: Any])?["mode"] as? String, "explicit")
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["role"] as? String }, ["developer", "user"])
        let instruction = try XCTUnwrap((input[0]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(instruction["text"] as? String, CloudPrompt.instruction)
        XCTAssertEqual((instruction["prompt_cache_breakpoint"] as? [String: Any])?["mode"] as? String, "explicit",
                       "в кэш — только общая для всех страниц инструкция")
        let image = try XCTUnwrap((input[1]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(image["type"] as? String, "input_image")
        XCTAssertEqual(image["image_url"] as? String, "data:image/jpeg;base64,\(jpeg.base64EncodedString())")
        XCTAssertEqual(image["detail"] as? String, "original", "мелкий текст документа — original, как советует документация")
        let format = try XCTUnwrap((json["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        try assertStrict(XCTUnwrap(format["schema"] as? [String: Any]))
        // Ответ идёт в порядке ключей схемы: вид и расшифровка — до полей
        let raw = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
        let properties = try XCTUnwrap(raw.range(of: "\"schema\":{\"type\":\"object\",\"properties\":{")).upperBound
        let schema = raw[properties...]
        let order = ["\"type\":{", "\"text\":{", "\"surname\":{", "\"meta\":{"].compactMap { schema.range(of: $0)?.lowerBound }
        XCTAssertEqual(order.count, 4)
        XCTAssertEqual(order, order.sorted())
    }

    /// Строгая схема OpenAI: у каждого объекта все поля обязательны и лишних нет
    private func assertStrict(_ schema: [String: Any], path: String = "schema") throws {
        if let properties = schema["properties"] as? [String: Any] {
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false, path)
            XCTAssertEqual(Set(schema["required"] as? [String] ?? []), Set(properties.keys), path)
            for (key, value) in properties {
                try assertStrict(XCTUnwrap(value as? [String: Any]), path: "\(path).\(key)")
            }
        }
        if let items = schema["items"] as? [String: Any] { try assertStrict(items, path: path + "[]") }
    }

    func testOpenAITextDocumentAndUsage() async throws {
        let usage = UsageLog()
        StubURLProtocol.reset([Replies.openAI()])
        let reader = CloudDocumentReader(configuration: openAI, session: StubURLProtocol.session(), sleep: { _ in },
                                         onUsage: { value in Task { await usage.record(value) } })
        _ = try await reader.read(text: "ТРУДОВОЙ ДОГОВОР")
        let input = try XCTUnwrap(body(XCTUnwrap(StubURLProtocol.requests.first))["input"] as? [[String: Any]])
        let content = try XCTUnwrap((input[1]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["type"] as? String, "input_text")
        XCTAssertTrue((content["text"] as? String)?.contains("ТРУДОВОЙ ДОГОВОР") == true)
        XCTAssertEqual(CloudResponseParser.usage(Replies.openAI().body, provider: .openAI), CloudUsage(pages: 1, inputTokens: 4600, outputTokens: 900))
    }

    func testOpenAIRefusalIsNotAPause() {
        XCTAssertThrowsError(try CloudResponseParser.page(Replies.openAI(refusal: true).body, provider: .openAI)) { error in
            XCTAssertEqual(error as? CloudFailure, .refused)
        }
        XCTAssertFalse(CloudFailure.refused.pausesQueue, "отказ касается одного документа")
        XCTAssertTrue(CloudFailure.quotaExceeded.pausesQueue)
    }

    func testOpenAIFallsBackToHighDetail() async throws {
        StubURLProtocol.reset([
            Replies.error(400, "Invalid value: 'original'. Supported values are: 'low', 'high', and 'auto'.", code: "invalid_value", param: "input[1].content[0].detail"),
            Replies.openAI(),
        ])
        _ = try await reader(openAI).read(pages: [CloudPage(number: 1, jpeg: jpeg)])
        let input = try XCTUnwrap(body(XCTUnwrap(StubURLProtocol.requests.last))["input"] as? [[String: Any]])
        XCTAssertEqual((input[1]["content"] as? [[String: Any]])?.first?["detail"] as? String, "high")
    }

    func testOtherOpenAIModelGetsPlainRequest() async throws {
        let older = CloudConfiguration(provider: .openAI, model: "gpt-4.1-mini", baseURL: CloudProvider.openAI.defaultBaseURL, apiKey: "k")
        StubURLProtocol.reset([Replies.openAI()])
        _ = try await reader(older).read(pages: [CloudPage(number: 1, jpeg: jpeg)])
        let json = try body(XCTUnwrap(StubURLProtocol.requests.first))
        XCTAssertNil(json["reasoning"], "старые модели отвечают 400 на reasoning.effort")
        XCTAssertNil(json["prompt_cache_options"])
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual((input[1]["content"] as? [[String: Any]])?.first?["detail"] as? String, "high")
    }

    func testOpenAIPingIsFreeModelLookup() async throws {
        StubURLProtocol.reset([StubURLProtocol.Reply(status: 200, body: Data(#"{"id": "gpt-6.1-sol", "object": "model"}"#.utf8))])
        try await reader(openAI).ping()
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example/v1/models/gpt-6.1-sol")
        XCTAssertNil(request.httpBody)
    }

    func testRetryAfterIsHonoured() async throws {
        StubURLProtocol.reset([Replies.error(429, "Rate limit reached for requests", code: "rate_limit_exceeded", headers: ["Retry-After": "7"]), Replies.openAI()])
        let sleeps = SleepLog()
        _ = try await reader(openAI, sleeps: sleeps).read(pages: [CloudPage(number: 1, jpeg: jpeg)])
        let slept = await sleeps.durations
        XCTAssertEqual(slept.count, 1)
        XCTAssertGreaterThanOrEqual(slept.first ?? .zero, .seconds(7), "ждём не меньше Retry-After")
    }

    func testQuotaIsNotRetried() async throws {
        StubURLProtocol.reset([Replies.error(429, "You exceeded your current quota", code: "credit_balance_exhausted"), Replies.openAI()])
        let sleeps = SleepLog()
        do {
            _ = try await reader(openAI, sleeps: sleeps).read(pages: [CloudPage(number: 1, jpeg: jpeg)])
            XCTFail("ждали ошибку")
        } catch {
            XCTAssertEqual(error as? CloudFailure, .quotaExceeded)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "повторы не вернут деньги на счёт")
    }

    func testErrorsMapToStates() {
        func failure(_ reply: StubURLProtocol.Reply) -> CloudFailure? {
            CloudResponseParser.failure(status: reply.status, data: reply.body)
        }
        XCTAssertEqual(failure(Replies.error(400, "User location is not supported for the API use.", statusText: "FAILED_PRECONDITION")), .regionUnavailable)
        XCTAssertEqual(failure(Replies.error(403, "Country, region, or territory not supported", code: "unsupported_country_region_territory")), .regionUnavailable)
        XCTAssertEqual(failure(Replies.error(400, "API key not valid. Please pass a valid API key.", statusText: "INVALID_ARGUMENT")), .keyRejected)
        XCTAssertEqual(failure(Replies.error(401, "Incorrect API key provided")), .keyRejected)
        XCTAssertEqual(failure(Replies.error(404, "models/nope is not found")), .modelNotFound)
        XCTAssertEqual(failure(Replies.error(503, "The service is temporarily overloaded")), .overloaded)
        XCTAssertEqual(failure(Replies.error(503, "Model temporarily overloaded", code: "server_is_overloaded")), .overloaded)
        XCTAssertEqual(failure(Replies.error(429, "Rate limit reached for requests", code: "rate_limit_exceeded")), .overloaded)
        XCTAssertEqual(failure(Replies.error(429, "Credit balance exhausted", code: "credit_balance_exhausted")), .quotaExceeded)
        XCTAssertEqual(failure(Replies.error(429, "Project spend limit reached", code: "project_spend_limit_exceeded")), .quotaExceeded)
        XCTAssertEqual(failure(Replies.error(429, "You exceeded your current quota", code: "insufficient_quota")), .quotaExceeded)
        XCTAssertEqual(failure(Replies.error(404, "The model `gpt-7` does not exist or you do not have access to it.", code: "model_not_found")), .modelNotFound)
        XCTAssertEqual(failure(Replies.error(403, "Request blocked", code: "misalignment_policy_violation")), .refused)
        XCTAssertNil(CloudResponseParser.failure(status: 200, data: Data()))
    }

    func testTransientErrorIsRetriedWithBackoff() async throws {
        StubURLProtocol.reset([Replies.error(503, "overloaded"), Replies.gemini()])
        let sleeps = SleepLog()
        _ = try await reader(gemini, sleeps: sleeps).read(pages: [CloudPage(number: 1, jpeg: jpeg)])
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        let slept = await sleeps.count
        XCTAssertEqual(slept, 1)
    }

    func testGivesUpAfterRetries() async throws {
        StubURLProtocol.reset(Array(repeating: Replies.error(429, "rate limit"), count: 5))
        let sleeps = SleepLog()
        do {
            _ = try await reader(gemini, sleeps: sleeps).read(pages: [CloudPage(number: 1, jpeg: jpeg)])
            XCTFail("ждали ошибку")
        } catch {
            XCTAssertEqual(error as? CloudFailure, .overloaded)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 4, "первая попытка и три повтора")
        let slept = await sleeps.count
        XCTAssertEqual(slept, 3)
    }

    func testFallsBackToLegacySchemaFields() async throws {
        StubURLProtocol.reset([
            Replies.error(400, #"Invalid JSON payload received. Unknown name "responseFormat" at 'generation_config': Cannot find field."#),
            Replies.gemini(),
        ])
        _ = try await reader(gemini).read(pages: [CloudPage(number: 1, jpeg: jpeg)])
        let second = try body(XCTUnwrap(StubURLProtocol.requests.last))
        let generation = try XCTUnwrap(second["generationConfig"] as? [String: Any])
        XCTAssertEqual(generation["responseMimeType"] as? String, "application/json")
        XCTAssertNotNil(generation["responseJsonSchema"])
    }

    func testBrokenAnswerIsBadResponse() {
        let reply = Replies.gemini("{\"type\": \"passport_ru\", \"surname\": \"ПЕТ")
        XCTAssertThrowsError(try CloudResponseParser.page(reply.body, provider: .gemini)) { error in
            XCTAssertEqual(error as? CloudFailure, .badResponse)
        }
    }

    func testPageImageIsDownscaledAndOnlyImagesOrScansAreSent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudPages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("скан.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let pages = try XCTUnwrap(CloudPageImages.pages(for: url))
        XCTAssertEqual(pages.count, 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(pages[0].jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(image.width, image.height), 2048)

        let text = root.appendingPathComponent("заметка.txt")
        try Data("текст".utf8).write(to: text)
        XCTAssertNil(CloudPageImages.pages(for: text), "текстовый файл не отправляется")
    }
}

final class CloudMergeTests: XCTestCase {
    private let today = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 12).date!

    private func field(_ key: String, _ value: String, _ confidence: Double, _ source: FieldSource = .regex, verified: Bool = false) -> DocumentField {
        DocumentField(key: key, value: value, confidence: confidence, source: source, verified: verified)
    }

    func testVerifiedMRZAndManualWinValidCloudGetsConfidence() {
        let rules = [
            field(FieldKey.seriesNumber, "4509 123456", 0.99, .mrz),
            field(FieldKey.issueDate, "15.03.2012", 1.0, .manual, verified: true),
            field(FieldKey.fullName, "Петров Иван", 0.6),
        ]
        let cloud = DocumentReadout(
            surname: "ПЕТРОВ", givenName: "ИВАН", patronymic: "СЕРГЕЕВИЧ", issueDate: "16.03.2012",
            expiryDate: "16.03.2030", number: "4509 654321", departmentCode: "69-001"
        )
        let merged = Dictionary(CloudMerge.merge(rules: rules, cloud: cloud, type: .passportRU, today: today).map { ($0.key, $0) },
                                uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(merged[FieldKey.seriesNumber]?.value, "4509 123456", "MRZ с контрольной цифрой главнее")
        XCTAssertEqual(merged[FieldKey.issueDate]?.value, "15.03.2012", "правка человека главнее")
        XCTAssertEqual(merged[FieldKey.fullName]?.value, "Петров Иван Сергеевич")
        XCTAssertEqual(merged[FieldKey.fullName]?.confidence, 0.9)
        XCTAssertEqual(merged[FieldKey.fullName]?.source, .cloud)
        XCTAssertEqual(merged[FieldKey.fullName]?.needsReview, false)
        XCTAssertNil(merged[FieldKey.departmentCode], "код не по маске отброшен")
        XCTAssertNil(merged[FieldKey.expiryDate], "у паспорта РФ нет срока действия")
    }

    func testKindComesFromMRZFirst() {
        let mrz = [field(FieldKey.seriesNumber, "4509 123456", 0.99, .mrz)]
        XCTAssertEqual(CloudMerge.resolvedType(rules: .passportRU, fields: mrz, cloud: DocumentReadout(type: "diploma")), .passportRU)
        XCTAssertEqual(CloudMerge.resolvedType(rules: .other, fields: [], cloud: DocumentReadout(type: "diploma")), .diploma)
    }

    func testSnilsAndInnMasks() {
        let snils = Dictionary(DocumentReadingMerge.validated(DocumentReadout(number: "12345678901"), type: .snils, rules: [], today: today), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(snils[FieldKey.seriesNumber], "123-456-789 01")
        let inn = Dictionary(DocumentReadingMerge.validated(DocumentReadout(number: "7707083893"), type: .inn, rules: [], today: today), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(inn[FieldKey.seriesNumber], "7707083893")
    }
}

// MARK: - Индекс и приватность

@MainActor
final class CloudPassTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var defaults: UserDefaults!
    private var suite: String!
    private var keychainService: String!

    private let page = """
    ПАСПОРТ
    Паспорт выдан ОТДЕЛОМ УФМС РОССИИ ПО ТВЕРСКОЙ ОБЛ.
    Дата выдачи 15.03.2012 Код подразделения 690-001
    Фамилия ПЕТРОВ
    """

    /// Текстовый файл кадра не имеет — подставляем кадр-заглушку
    private static let onePage: @Sendable (URL) -> [CloudPage]? = { _ in [CloudPage(number: 1, jpeg: Data([0xFF, 0xD8]))] }
    private static let blankPage: @Sendable (URL) -> PageImage? = { _ in
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage().map(PageImage.init)
    }
    private let configuration = CloudConfiguration(provider: .gemini, model: "gemini-3.8-flash", baseURL: CloudProvider.gemini.defaultBaseURL, apiKey: "k")

    override func setUp() async throws {
        StubURLProtocol.reset()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudPass-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
        suite = "CloudPassTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        keychainService = "com.ilyaqa.LocalDrive.tests.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        if let suite { UserDefaults().removePersistentDomain(forName: suite) }
        if let keychainService {
            for service in [keychainService, keychainService + ".openai", keychainService + ".gemini"] { Keychain.delete(service: service) }
        }
        store = nil
    }

    private func folder(_ name: String, hidden: Bool = false, searchable: Bool = true) throws -> VaultFolder {
        store.createFolder(name: name, icon: "folder.fill", color: "indigo", isSuperHidden: hidden, searchable: searchable)
        return try XCTUnwrap(store.folders.last)
    }

    private func reader() -> CloudDocumentReader {
        CloudDocumentReader(configuration: configuration, session: StubURLProtocol.session(), sleep: { _ in })
    }

    func testCloudReplacesTextMergesFieldsAndSkipsLocalModel() async throws {
        StubURLProtocol.reset([Replies.gemini()])
        let local = CloudLocalReaderSpy()
        // Кадр для локальной модели есть: если бы она читала, шпион бы это увидел
        let search = SearchService(store: store, databaseURL: nil, reader: local, pageImage: Self.blankPage,
                                   cloud: CloudRecognitionStore(defaults: defaults, keychainService: keychainService),
                                   cloudReader: reader(), cloudPages: Self.onePage)
        let passports = try folder("Паспорта")
        store.importData(Data(page.utf8), preferredName: "паспорт.txt", to: passports)
        search.reconcile()
        await search.waitUntilIdle()

        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        let found = await search.search("облачныйтекст")
        XCTAssertEqual(found.first?.file.name, "паспорт.txt", "текст облака заменил фрагменты поиска")
        // XCTUnwrap принимает автозамыкание без поддержки await
        let passportsFound = await search.documents(ofTypes: [.passportRU])
        let document = try XCTUnwrap(passportsFound.first)
        let fields = await search.fields(for: [document.id])[document.id] ?? []
        let name = try XCTUnwrap(fields.first { $0.key == FieldKey.fullName })
        XCTAssertEqual(name.value, "Петров Иван Сергеевич")
        XCTAssertEqual(name.source, .cloud)
        XCTAssertFalse(name.needsReview)
        let file = try XCTUnwrap(store.files(in: passports).first)
        let state = await search.cloudState(for: file, in: passports)
        XCTAssertEqual(state, .read)
        XCTAssertEqual(search.progress.cloudRead, 1)
        let localCalls = await local.calls
        XCTAssertEqual(localCalls, 0, "пока облако включено, локальная модель не читает")
    }

    func testNothingIsSentWhenOffOrWithoutKey() async throws {
        let settings = CloudRecognitionStore(defaults: defaults, keychainService: keychainService, session: StubURLProtocol.session())
        XCTAssertNil(settings.currentReader, "по умолчанию выключено")
        settings.setEnabled(true)
        XCTAssertNil(settings.currentReader, "без ключа не уходит ничего")
        let search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil }, cloud: settings, cloudPages: Self.onePage)
        store.importData(Data(page.utf8), preferredName: "паспорт.txt", to: try folder("Паспорта"))
        search.reconcile()
        await search.waitUntilIdle()
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)

        settings.setKey("secret")
        XCTAssertNotNil(settings.currentReader)
        settings.setEnabled(false)
        XCTAssertNil(settings.currentReader)
    }

    func testHiddenAndNonSearchableFoldersAreNeverSent() async throws {
        let search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil },
                                   cloud: CloudRecognitionStore(defaults: defaults, keychainService: keychainService),
                                   cloudReader: reader(), cloudPages: Self.onePage)
        store.importData(Data(page.utf8), preferredName: "тайное.txt", to: try folder("Тайное", hidden: true))
        store.importData(Data(page.utf8), preferredName: "архив.txt", to: try folder("Архив", searchable: false))
        search.reconcile()
        await search.waitUntilIdle()
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testRegionErrorPausesUntilAppIsActiveAgain() async throws {
        StubURLProtocol.reset([Replies.error(400, "User location is not supported for the API use.", statusText: "FAILED_PRECONDITION")])
        let search = SearchService(store: store, databaseURL: nil, pageImage: { _ in nil },
                                   cloud: CloudRecognitionStore(defaults: defaults, keychainService: keychainService),
                                   cloudReader: reader(), cloudPages: Self.onePage)
        store.importData(Data(page.utf8), preferredName: "паспорт.txt", to: try folder("Паспорта"))
        search.reconcile()
        await search.waitUntilIdle()
        XCTAssertEqual(search.progress.cloudPaused, CloudFailure.regionUnavailable.message)
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "без VPN очередь стоит, а не стучится по кругу")

        StubURLProtocol.enqueue(Replies.gemini())
        search.resume()
        await search.waitUntilIdle()
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertNil(search.progress.cloudPaused)
        XCTAssertEqual(search.progress.cloudRead, 1)
    }

    func testKeyIsKeptInKeychainOnlyPerProvider() {
        let settings = CloudRecognitionStore(defaults: defaults, keychainService: keychainService)
        XCTAssertEqual(settings.provider, .openAI, "облако по умолчанию — OpenAI")
        XCTAssertEqual(settings.model, "gpt-6.1-sol")
        settings.setKey("  my-key  ")
        settings.setEnabled(true)
        XCTAssertTrue(settings.hasKey)
        XCTAssertEqual(settings.configuration?.apiKey, "my-key")
        XCTAssertEqual(Keychain.get(service: keychainService + ".openai").flatMap { String(data: $0, encoding: .utf8) }, "my-key")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { "\($0)".contains("my-key") }, "в UserDefaults ключа нет")

        // У Gemini — свой ключ: переключение сервиса ничего не стирает
        settings.setProvider(.gemini)
        XCTAssertFalse(settings.hasKey)
        XCTAssertNil(settings.configuration)
        settings.setKey("gemini-key")
        settings.setModel("gemini-3.5-flash-lite")
        settings.setProvider(.openAI)
        XCTAssertEqual(settings.configuration?.apiKey, "my-key")
        XCTAssertEqual(settings.model, "gpt-6.1-sol")

        let reopened = CloudRecognitionStore(defaults: defaults, keychainService: keychainService)
        XCTAssertTrue(reopened.hasKey)
        reopened.removeKey()
        XCTAssertFalse(reopened.hasKey)
        XCTAssertNil(Keychain.get(service: keychainService + ".openai"))
        XCTAssertNotNil(Keychain.get(service: keychainService + ".gemini"))
        reopened.setProvider(.gemini)
        XCTAssertEqual(reopened.model, "gemini-3.5-flash-lite")
    }

    func testOldSettingsMoveToGeminiAndOpenAIBecomesDefault() {
        // Так хранила настройки сборка 9: один ключ, модель и расход Gemini
        Keychain.set(Data("old-gemini-key".utf8), service: keychainService)
        defaults.set("gemini-3.8-flash", forKey: "cloud.model")
        defaults.set(1_000_000, forKey: "cloud.inputTokens")
        defaults.set(true, forKey: "cloud.enabled")
        let settings = CloudRecognitionStore(defaults: defaults, keychainService: keychainService)
        XCTAssertEqual(settings.provider, .openAI, "решение владельца: облако — OpenAI")
        XCTAssertFalse(settings.hasKey, "ключа OpenAI ещё нет")
        XCTAssertNil(Keychain.get(service: keychainService), "общий ключ разнесён по сервисам")
        XCTAssertEqual(settings.spentDollars, 0.75, accuracy: 0.0001, "расход прежних сборок — по цене Gemini 3.8 Flash")
        settings.setProvider(.gemini)
        XCTAssertTrue(settings.hasKey)
        XCTAssertEqual(settings.configuration?.apiKey, "old-gemini-key")
        XCTAssertEqual(settings.model, "gemini-3.8-flash")

        // Выбор владельца после перехода сохраняется
        let reopened = CloudRecognitionStore(defaults: defaults, keychainService: keychainService)
        XCTAssertEqual(reopened.provider, .gemini)
    }
}

/// Локальная модель-шпион: облако должно её отключать
private actor CloudLocalReaderSpy: DocumentReading {
    nonisolated let revision = "spy"
    private(set) var calls = 0

    func read(_ image: PageImage, kind: DocumentType) async throws -> DocumentReadout {
        calls += 1
        return DocumentReadout()
    }
}
