import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// Облачное распознавание документов (решения владельца от 12.10.2026, см.
// docs/cloud-reader.md). Включается вручную и по ключу самого владельца:
// фото и сканы уходят в OpenAI (по умолчанию) или в Google Gemini. В
// запросе — только кадр страницы и неизменная инструкция: ни имени файла, ни
// названия папки, ни чего-либо ещё

/// Куда отправлять страницы
enum CloudProvider: String, Codable, CaseIterable, Sendable {
    /// OpenAI, Responses API — облако по умолчанию (решение владельца 12.10.2026)
    case openAI = "openai"
    /// Gemini API, метод generateContent
    case gemini

    /// Значение из настроек. Прежние сборки писали «openAICompatible» — это
    /// был Chat Completions; теперь OpenAI ходит через Responses API
    init?(stored: String) {
        if stored == "openAICompatible" {
            self = .openAI
        } else {
            self.init(rawValue: stored)
        }
    }

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .gemini: "Google Gemini"
        }
    }

    /// Кому уходят данные — для честных подписей в настройках и в чате
    var company: String {
        switch self {
        case .openAI: "OpenAI"
        case .gemini: "Google"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    /// Модель распознавания по умолчанию — первая из предложенных
    var defaultModel: String {
        recognitionModels[0].id
    }

    /// Модели распознавания на выбор. У OpenAI по умолчанию GPT-6.1 Sol: для
    /// документов важна точность; GPT-6 Luna — дешёвый вариант
    /// (developers.openai.com/api/docs/models, ai.google.dev — на 12.10.2026)
    var recognitionModels: [(id: String, title: String)] {
        switch self {
        case .openAI: [("gpt-6.1-sol", "GPT-6.1 Sol"), ("gpt-6-luna", "GPT-6 Luna — дешевле")]
        case .gemini: [("gemini-3.8-flash", "Gemini 3.8 Flash"), ("gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite — дешевле")]
        }
    }
}

/// Модели OpenAI, которые знают reasoning.effort, prompt_cache_options и
/// картинку «original»: GPT-6 и GPT-5.6. Для другой модели, вписанной вручную,
/// запрос остаётся без этих полей — старые модели ответили бы на них 400
enum OpenAIModels {
    static func isCurrent(_ model: String) -> Bool {
        model.hasPrefix("gpt-6") || model.hasPrefix("gpt-5.6")
    }
}

/// С чем ходить в облако. Ключ — из Keychain, в UserDefaults его нет
struct CloudConfiguration: Equatable, Sendable {
    var provider: CloudProvider
    var model: String
    var baseURL: String
    var apiKey: String

    /// Отметка в индексе: этим провайдером и этой моделью документ уже прочитан.
    /// «cloud2» — с метаданными, «cloud3» — с регистрацией паспорта РФ:
    /// прочитанное раньше перечитается один раз
    var mark: String { "cloud3:\(provider.rawValue):\(model)" }
}

/// Почему облако не прочитало страницу. Сообщения — для экрана настроек
enum CloudFailure: Error, Equatable, Sendable {
    /// Gemini и OpenAI из России недоступны: нужен включённый VPN
    case regionUnavailable
    /// 401, 403, неверный ключ
    case keyRejected
    /// Модели с таким именем у сервиса нет
    case modelNotFound
    /// Деньги на счёте кончились или достигнут лимит расходов: повторы не
    /// помогут, пока владелец не пополнит счёт (OpenAI, error codes)
    case quotaExceeded
    /// 429 и 5xx не прошли и после повторов
    case overloaded
    /// Нет связи с сервером
    case network
    /// Модель отказалась отвечать на этот запрос
    case refused
    /// Ответ пришёл, но не разобрался
    case badResponse
    /// 4xx с текстом сервера: облако отклонило сам запрос. Текст — для пометки
    /// в чате, чтобы причина была видна, а не «недоступно»
    case rejected(String)

    var message: String {
        switch self {
        case .regionUnavailable: "Облако недоступно из этой сети — включите VPN"
        case .keyRejected: "Ключ не подходит"
        case .modelNotFound: "Модель не найдена — проверьте её имя"
        case .quotaExceeded: "На счёте облака кончились деньги или достигнут лимит расходов"
        case .overloaded: "Облако перегружено — повторю позже"
        case .network: "Нет связи с облаком — проверьте интернет и VPN"
        case .refused: "Облако отказалось читать документ"
        case .badResponse: "Облако ответило непонятно"
        case .rejected(let text): "Облако отклонило запрос: \(text)"
        }
    }

    /// Ошибка всей очереди: читать дальше бессмысленно, пока не поменяется сеть
    /// или настройки. Непонятный ответ и отказ касаются одного документа
    var pausesQueue: Bool {
        switch self {
        case .badResponse, .refused, .rejected: false
        default: true
        }
    }
}

/// Расход на запрос: страницы и токены из ответа — по ним считается цена
struct CloudUsage: Equatable, Sendable {
    var pages = 0
    var inputTokens = 0
    var outputTokens = 0
}

/// Кадр страницы для облака: JPEG, номер страницы в файле
struct CloudPage: Equatable, Sendable {
    let number: Int
    let jpeg: Data
}

/// Что облако прочитало на странице. Поля — те же, что у локальной модели,
/// плюс вид документа и весь текст страницы в порядке чтения
struct CloudPageReadout: Equatable, Sendable, Decodable {
    var readout: DocumentReadout
    var text: String
    /// О чём документ — название, вид, даты, люди, организации
    var meta: DocumentMetadata?

    private enum CodingKeys: String, CodingKey {
        case text, meta
    }

    init(readout: DocumentReadout, text: String, meta: DocumentMetadata? = nil) {
        self.readout = readout
        self.text = text
        self.meta = meta
    }

    init(from decoder: any Decoder) throws {
        readout = try DocumentReadout(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        meta = try? container.decodeIfPresent(DocumentMetadata.self, forKey: .meta)
    }
}

/// Документ целиком: поля — с первой страницы, где они есть, текст — по страницам
struct CloudDocumentReadout: Equatable, Sendable {
    var readout: DocumentReadout
    var pages: [(number: Int, text: String)]
    /// Метаданные первой страницы, где они есть
    var meta: DocumentMetadata?

    static func == (lhs: CloudDocumentReadout, rhs: CloudDocumentReadout) -> Bool {
        lhs.readout == rhs.readout && lhs.pages.map(\.number) == rhs.pages.map(\.number)
            && lhs.pages.map(\.text) == rhs.pages.map(\.text) && lhs.meta == rhs.meta
    }

    init(pages: [(number: Int, page: CloudPageReadout)]) {
        var merged = DocumentReadout()
        for (_, page) in pages {
            merged.fill(from: page.readout)
        }
        merged.takeRegistration(from: pages.map(\.page.readout))
        readout = merged
        self.pages = pages.map { ($0.number, $0.page.text) }
        meta = pages.lazy.compactMap(\.page.meta).first { !$0.isEmpty }?.sanitized
    }
}

private extension DocumentReadout {
    /// Пустое поле берётся со следующей страницы: у паспорта РФ «кем выдан» и
    /// ФИО на разных разворотах
    mutating func fill(from other: DocumentReadout) {
        func take(_ path: WritableKeyPath<DocumentReadout, String?>) {
            if self[keyPath: path] == nil { self[keyPath: path] = other[keyPath: path] }
        }
        if type == nil || type == "other" { type = other.type }
        for path in [\DocumentReadout.surname, \.givenName, \.patronymic, \.birthDate, \.issueDate, \.expiryDate,
                     \.number, \.departmentCode, \.issuedBy, \.birthPlace, \.sex, \.country] {
            take(path)
        }
    }

    /// Действующая регистрация по штампам всех страниц: самый поздний
    /// «Зарегистрирован». Если позже него стоит «Снят с регистрационного
    /// учёта», действующей регистрации нет. Штамп без читаемой даты берётся,
    /// только если датированных нет
    mutating func takeRegistration(from pages: [DocumentReadout]) {
        let stamps = pages.filter { $0.registrationAddress != nil || $0.registrationDate != nil }
        let dated = stamps.compactMap { stamp in DocumentReadingMerge.date(stamp.registrationDate).map { ($0, stamp) } }
        let deregistered = pages.compactMap { DocumentReadingMerge.date($0.deregistrationDate) }.max()
        let current: DocumentReadout?
        if let latest = dated.max(by: { $0.0 < $1.0 }) {
            current = deregistered.map { $0 > latest.0 } == true ? nil : latest.1
        } else {
            current = deregistered == nil ? stamps.first : nil
        }
        registrationAddress = current?.registrationAddress
        registrationDate = current?.registrationDate
        registrationIssuer = current?.registrationIssuer
        deregistrationDate = deregistered.map { DocumentAnalyzer.format(Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: $0)) }
    }
}

/// Облачное чтение. В приложении — `CloudDocumentReader`, в тестах — он же со
/// своей сетью-заглушкой
protocol CloudReading: Sendable {
    var mark: String { get }
    func read(pages: [CloudPage]) async throws -> CloudDocumentReadout
    /// PDF с текстовым слоем и текстовые файлы: их текст и так точный — облако
    /// только заполняет поля и метаданные
    func read(text: String) async throws -> CloudDocumentReadout
}

// MARK: - Инструкция и схема

enum CloudPrompt {
    static let instruction = """
    You are reading a photo or scan of one page of a document. Return JSON only.
    type: passport_ru — Russian internal passport; passport_intl — any passport with an ICAO machine-readable zone, including Russian international passports and passports of other countries; snils; inn; driver_license; diploma; certificate — a certificate (справка); other — anything else.
    country: three-letter ICAO code of the country that issued a passport (RUS, TJK, UZB…), otherwise an empty string.
    surname, given_name, patronymic — the person the document belongs to, exactly as printed; in Cyrillic if printed in Cyrillic.
    Dates as DD.MM.YYYY: birth_date, issue_date, expiry_date.
    number — document series and number as printed. department_code — Russian passport department code 000-000.
    issued_by, birth_place — the full text of all their lines. sex — М or Ж.
    Russian internal passport registration pages («Место жительства»): registration_address — the address of the latest «Зарегистрирован» stamp on this page that is not cancelled on this page by a later «Снят с регистрационного учёта», exactly as printed, all its lines; registration_date — its date DD.MM.YYYY; registration_issuer — the body that made the stamp. deregistration_date — the latest «Снят с регистрационного учёта» date on this page. Empty strings if the page has no such stamps.
    Use an empty string for anything absent or unreadable. Never guess.
    text — the complete transcription of all text on the page in reading order, keeping line breaks. If you were given the document text instead of an image, return an empty string here.
    meta — what the document is, in Russian:
    title — a short title, at most 80 characters, e.g. «Трудовой договор с ООО «Ромашка»»; summary — one or two sentences without any numbers;
    category — one of identity, education, work, finance, medical, property, vehicle, family, legal, travel, receipt, other;
    kind — the document's own name, e.g. «свидетельство о рождении», «полис ОСАГО», «справка 2-НДФЛ»;
    document_date — the date of the document, valid_until — when it expires, both DD.MM.YYYY or empty;
    people — name and role of each person mentioned; organizations — their names; identifiers — contract, policy, account and similar numbers with a label;
    amounts — label, value and currency; tags — up to 8 short Russian tags; language — ISO 639-1 code of the document language.
    """

    static let documentTypes = DocumentType.allCases.map(\.rawValue)

    /// JSON Schema в строгом виде: все поля обязательны, лишних нет, вместо
    /// пропуска — пустая строка. Так требует строгий режим OpenAI, Gemini это
    /// тоже принимает. Порядок ключей — порядок ответа (Structured Outputs):
    /// сначала вид документа и расшифровка страницы, потом поля из неё
    static var schema: OrderedJSONObject {
        func string(_ description: String? = nil) -> OrderedJSONObject {
            description.map { OrderedJSONObject(["type": "string", "description": $0]) } ?? OrderedJSONObject(["type": "string"])
        }
        return object([
            ("type", OrderedJSONObject(["type": "string", "enum": documentTypes])),
            ("country", string("ICAO country code or empty")),
            ("text", string("all text of the page in reading order")),
            ("surname", string()), ("given_name", string()), ("patronymic", string()),
            ("birth_date", string("DD.MM.YYYY or empty")), ("issue_date", string("DD.MM.YYYY or empty")),
            ("expiry_date", string("DD.MM.YYYY or empty")),
            ("number", string()), ("department_code", string()), ("issued_by", string()), ("birth_place", string()),
            ("registration_address", string("current registration address or empty")),
            ("registration_date", string("DD.MM.YYYY or empty")), ("registration_issuer", string()),
            ("deregistration_date", string("DD.MM.YYYY or empty")),
            ("sex", OrderedJSONObject(["type": "string", "enum": ["", "М", "Ж"]])),
            ("meta", metaSchema),
        ])
    }

    static var keys: [String] {
        schema.pairs.first { $0.0 == "properties" }.flatMap { ($0.1 as? OrderedJSONObject)?.pairs.map(\.0) } ?? []
    }

    /// Объект строгой схемы: все поля обязательны, лишних нет
    private static func object(_ properties: [(String, Any)]) -> OrderedJSONObject {
        OrderedJSONObject([
            ("type", "object"),
            ("properties", OrderedJSONObject(properties)),
            ("required", properties.map(\.0)),
            ("additionalProperties", false),
        ])
    }

    static var metaSchema: OrderedJSONObject {
        let string = OrderedJSONObject(["type": "string"])
        func list(_ items: Any) -> OrderedJSONObject { OrderedJSONObject([("type", "array"), ("items", items)]) }
        return object([
            ("title", string), ("summary", string),
            ("category", OrderedJSONObject(["type": "string", "enum": DocumentCategory.allCases.map(\.rawValue)])),
            ("kind", string), ("document_date", string), ("valid_until", string),
            ("people", list(object([("name", string), ("role", string)]))),
            ("organizations", list(string)),
            ("identifiers", list(object([("label", string), ("value", string)]))),
            ("amounts", list(object([("label", string), ("value", string), ("currency", string)]))),
            ("tags", list(string)),
            ("language", string),
        ])
    }

    /// Проверка подключения — без документов, только текст
    static let ping = "Ответь одним словом: готово"
}

// MARK: - Запросы

/// Объект JSON с порядком ключей: JSONSerialization порядок не хранит, а
/// модель отвечает полями в порядке ключей схемы
struct OrderedJSONObject: @unchecked Sendable {
    let pairs: [(String, Any)]

    init(_ pairs: [(String, Any)]) {
        self.pairs = pairs
    }

    init(_ dictionary: [String: Any]) {
        pairs = dictionary.keys.sorted().map { ($0, dictionary[$0]!) }
    }
}

/// Тело запроса в JSON: словари — с ключами по алфавиту, OrderedJSONObject —
/// в своём порядке
enum OrderedJSON {
    static func data(_ value: Any) -> Data {
        Data(text(value).utf8)
    }

    static func text(_ value: Any) -> String {
        switch value {
        case let object as OrderedJSONObject:
            "{" + object.pairs.map { quote($0.0) + ":" + text($0.1) }.joined(separator: ",") + "}"
        case let object as [String: Any]:
            text(OrderedJSONObject(object))
        case let array as [Any]:
            "[" + array.map(text).joined(separator: ",") + "]"
        case let string as String:
            quote(string)
        case let bool as Bool:
            bool ? "true" : "false"
        case let int as Int:
            String(int)
        case let double as Double:
            double.isFinite ? String(double) : "null"
        default:
            "null"
        }
    }

    private static func quote(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}

enum CloudRequestFactory {
    /// Схема ответа Gemini. Документация 12.10.2026 описывает responseFormat;
    /// прежние responseMimeType + responseJsonSchema — запасной вариант, если
    /// сервер или прокси новое поле не знает
    enum GeminiSchemaStyle: Sendable {
        case responseFormat
        case legacy
    }

    /// Что поменялось после отказа сервера: прежние имена полей схемы у Gemini,
    /// картинка «high» вместо «original» у OpenAI
    struct Options: Equatable, Sendable {
        var geminiStyle = GeminiSchemaStyle.responseFormat
        /// Для чтения мелкого текста документация OpenAI советует «original»
        var imageDetail = "original"
    }

    static func page(_ jpeg: Data, config: CloudConfiguration, options: Options = Options()) -> URLRequest {
        switch config.provider {
        case .gemini:
            // Картинка перед текстом — так советует документация для одного изображения
            gemini(parts: [
                ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                ["text": CloudPrompt.instruction],
            ], config: config, style: options.geminiStyle)
        case .openAI:
            openAI(content: [[
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())",
                "detail": OpenAIModels.isCurrent(config.model) ? options.imageDetail : "high",
            ]], config: config)
        }
    }

    /// Текст документа вместо картинки: первые 20 000 знаков
    static func text(_ text: String, config: CloudConfiguration, options: Options = Options()) -> URLRequest {
        let document = "Текст документа:\n" + String(text.prefix(20_000))
        return switch config.provider {
        case .gemini: gemini(parts: [["text": CloudPrompt.instruction], ["text": document]], config: config, style: options.geminiStyle)
        case .openAI: openAI(content: [["type": "input_text", "text": document]], config: config)
        }
    }

    /// Проверка подключения. У OpenAI — бесплатный запрос сведений о модели:
    /// он проверяет ключ, доступ к модели и страну так же, как настоящий
    static func ping(config: CloudConfiguration) -> URLRequest {
        switch config.provider {
        case .gemini:
            request(config: config, path: "models/\(config.model):generateContent", body: [
                "contents": [["parts": [["text": CloudPrompt.ping]]]],
            ])
        case .openAI:
            request(config: config, path: "models/\(config.model)", body: nil)
        }
    }

    private static func gemini(parts: [[String: Any]], config: CloudConfiguration, style: GeminiSchemaStyle) -> URLRequest {
        let generation: [String: Any] = switch style {
        case .responseFormat:
            ["responseFormat": ["text": ["mimeType": "application/json", "schema": CloudPrompt.schema]]]
        case .legacy:
            ["responseMimeType": "application/json", "responseJsonSchema": CloudPrompt.schema]
        }
        return request(config: config, path: "models/\(config.model):generateContent", body: [
            "contents": [["parts": parts]],
            "generationConfig": generation,
        ])
    }

    /// Responses API (developers.openai.com, 12.10.2026). store=false — ответ
    /// не хранится у OpenAI 30 дней. Инструкция — сообщение developer с явной
    /// отметкой кэша: она одна на все страницы, а картинку кэшировать
    /// незачем — запись в кэш стоит 1,25× цены входа
    private static func openAI(content: [[String: Any]], config: CloudConfiguration) -> URLRequest {
        let current = OpenAIModels.isCurrent(config.model)
        var instruction: [String: Any] = ["type": "input_text", "text": CloudPrompt.instruction]
        if current { instruction["prompt_cache_breakpoint"] = ["mode": "explicit"] }
        var body: [String: Any] = [
            "model": config.model,
            "store": false,
            "input": [
                ["role": "developer", "content": [instruction]],
                ["role": "user", "content": content],
            ],
            "text": ["format": OrderedJSONObject([
                ("type", "json_schema"), ("name", "document_page"), ("strict", true), ("schema", CloudPrompt.schema),
            ])],
            // Расшифровка плотной страницы и рассуждение — с запасом
            "max_output_tokens": 20_000,
        ]
        if current {
            // Извлечение данных — low (API deployment checklist)
            body["reasoning"] = ["effort": "low"]
            body["prompt_cache_options"] = ["mode": "explicit"]
        }
        return request(config: config, path: "responses", body: body)
    }

    private static func request(config: CloudConfiguration, path: String, body: [String: Any]?) -> URLRequest {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var request = URLRequest(url: URL(string: "\(base)/\(path)") ?? URL(string: "https://invalid.invalid")!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = 90
        switch config.provider {
        case .gemini: request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .openAI: request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = OrderedJSON.data(body)
        }
        return request
    }
}

// MARK: - Ответы

enum CloudResponseParser {
    /// Текст ответа модели: у Gemini — части первого кандидата, у OpenAI —
    /// output_text сообщений в output (элементов там бывает несколько)
    static func answer(_ data: Data, provider: CloudProvider) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudFailure.badResponse }
        switch provider {
        case .gemini:
            guard let candidate = (object["candidates"] as? [[String: Any]])?.first,
                  let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
                throw CloudFailure.badResponse
            }
            let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw CloudFailure.badResponse }
            return text
        case .openAI:
            guard let output = object["output"] as? [[String: Any]] else { throw CloudFailure.badResponse }
            var text = ""
            for item in output where item["type"] as? String == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] {
                    switch part["type"] as? String {
                    case "output_text": text += part["text"] as? String ?? ""
                    // Отказ не следует схеме — у него своё поле (Structured Outputs)
                    case "refusal": throw CloudFailure.refused
                    default: continue
                    }
                }
            }
            guard !text.isEmpty else { throw CloudFailure.badResponse }
            return text
        }
    }

    static func page(_ data: Data, provider: CloudProvider) throws -> CloudPageReadout {
        let text = try answer(data, provider: provider)
        // Некоторые прокси оборачивают JSON в ```json … ```
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let page = try? JSONDecoder().decode(CloudPageReadout.self, from: Data(text[start...end].utf8)) else {
            throw CloudFailure.badResponse
        }
        return page
    }

    /// Токены из ответа: Gemini — usageMetadata (размышления — тоже выход),
    /// OpenAI — usage (рассуждение входит в output_tokens)
    static func usage(_ data: Data, provider: CloudProvider) -> CloudUsage {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return CloudUsage(pages: 1) }
        switch provider {
        case .gemini:
            let meta = object["usageMetadata"] as? [String: Any] ?? [:]
            let output = (meta["candidatesTokenCount"] as? Int ?? 0) + (meta["thoughtsTokenCount"] as? Int ?? 0)
            return CloudUsage(pages: 1, inputTokens: meta["promptTokenCount"] as? Int ?? 0, outputTokens: output)
        case .openAI:
            let usage = object["usage"] as? [String: Any] ?? [:]
            return CloudUsage(pages: 1, inputTokens: usage["input_tokens"] as? Int ?? 0, outputTokens: usage["output_tokens"] as? Int ?? 0)
        }
    }

    /// Ошибка по коду и телу ответа. nil — не ошибка
    static func failure(status: Int, data: Data) -> CloudFailure? {
        guard !(200..<300).contains(status) else { return nil }
        let message = errorMessage(data).lowercased()
        // GPT-6 Astra: 403 misalignment_policy_violation — не повторять
        if message.contains("misalignment") { return .refused }
        // Gemini из неподдерживаемой страны: 400 «User location is not supported
        // for the API use». OpenAI: 403 «Country, region, or territory not supported»
        if ["location", "region", "country", "territory"].contains(where: message.contains) { return .regionUnavailable }
        // OpenAI: 429 credit_balance_exhausted, *_spend_limit_exceeded,
        // organization_usage_limit_exceeded, insufficient_quota — повторы не помогут
        if ["insufficient_quota", "credit_balance", "spend_limit", "usage_limit"].contains(where: message.contains) { return .quotaExceeded }
        if status == 401 || status == 403 || message.contains("api key") || message.contains("api_key") { return .keyRejected }
        if status == 404 || message.contains("model_not_found") { return .modelNotFound }
        if isTransient(status: status) { return .overloaded }
        let text = errorMessage(data).trimmingCharacters(in: .whitespacesAndNewlines)
        return (400..<500).contains(status) && !text.isEmpty ? .rejected(String(text.prefix(160))) : .badResponse
    }

    /// Повторять ли запрос: 429, 408 и 5xx — временные (документация Gemini и
    /// OpenAI: экспоненциальная задержка с разбросом, не повторять 400 и 403)
    static func isTransient(status: Int) -> Bool {
        status == 429 || status == 408 || (500..<600).contains(status)
    }

    /// Новое поле схемы сервер не знает — стоит попробовать прежние имена
    static func rejectsResponseFormat(status: Int, data: Data) -> Bool {
        status == 400 && errorMessage(data).contains("responseFormat")
    }

    /// Модель не знает картинку «original» — пробуем «high»
    static func rejectsImageDetail(status: Int, data: Data) -> Bool {
        status == 400 && errorMessage(data).lowercased().contains("detail")
    }

    /// Retry-After из ответа, если сервер его прислал: OpenAI советует ждать
    /// не меньше. Больше 30 с не ждём — очередь проверит позже сама
    static func retryAfter(_ response: URLResponse) -> Duration? {
        guard let value = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds > 0 else { return nil }
        return .milliseconds(Int(min(seconds, 30) * 1000))
    }

    static func errorMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(500), encoding: .utf8) ?? ""
        }
        let error = object["error"] as? [String: Any]
        let parts = [error?["message"], error?["status"], error?["code"], error?["type"], error?["param"]].compactMap { $0.map { "\($0)" } }
        return parts.joined(separator: " ")
    }
}

// MARK: - Читатель

/// Задержка между повторами. В тестах — без настоящего ожидания
typealias CloudSleep = @Sendable (Duration) async throws -> Void

actor CloudDocumentReader: CloudReading {
    nonisolated let configuration: CloudConfiguration
    nonisolated var mark: String { configuration.mark }

    private let session: URLSession
    private let sleep: CloudSleep
    private let onUsage: @Sendable (CloudUsage) -> Void
    private var options = CloudRequestFactory.Options()

    /// Повторы при 429 и 5xx: 1, 2, 4 с и немного случайности
    static let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

    init(
        configuration: CloudConfiguration,
        session: URLSession = .shared,
        sleep: @escaping CloudSleep = { try await Task.sleep(for: $0) },
        onUsage: @escaping @Sendable (CloudUsage) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.session = session
        self.sleep = sleep
        self.onUsage = onUsage
    }

    func read(pages: [CloudPage]) async throws -> CloudDocumentReadout {
        var results: [(number: Int, page: CloudPageReadout)] = []
        for page in pages {
            try Task.checkCancellation()
            let data = try await send { [configuration] options in
                CloudRequestFactory.page(page.jpeg, config: configuration, options: options)
            }
            onUsage(CloudResponseParser.usage(data, provider: configuration.provider))
            results.append((page.number, try CloudResponseParser.page(data, provider: configuration.provider)))
        }
        return CloudDocumentReadout(pages: results)
    }

    func read(text: String) async throws -> CloudDocumentReadout {
        let data = try await send { [configuration] options in
            CloudRequestFactory.text(text, config: configuration, options: options)
        }
        onUsage(CloudResponseParser.usage(data, provider: configuration.provider))
        var page = try CloudResponseParser.page(data, provider: configuration.provider)
        // Текст файла и так точный — транскрипцию облака не берём
        page.text = ""
        return CloudDocumentReadout(pages: [(1, page)])
    }

    /// Проверка подключения: без документов
    func ping() async throws {
        _ = try await send { [configuration] _ in CloudRequestFactory.ping(config: configuration) }
    }

    /// Запрос с повторами. Настройки запроса передаются при каждой попытке:
    /// после отказа от нового поля повтор идёт уже без него
    private func send(_ make: (CloudRequestFactory.Options) -> URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: make(options))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw CloudFailure.network
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            if configuration.provider == .gemini, options.geminiStyle == .responseFormat,
               CloudResponseParser.rejectsResponseFormat(status: status, data: data) {
                options.geminiStyle = .legacy
                continue
            }
            if configuration.provider == .openAI, options.imageDetail != "high",
               CloudResponseParser.rejectsImageDetail(status: status, data: data) {
                options.imageDetail = "high"
                continue
            }
            let failure = CloudResponseParser.failure(status: status, data: data) ?? .badResponse
            if failure == .overloaded, attempt < Self.retryDelays.count {
                let jitter = Duration.milliseconds(Int.random(in: 0...250))
                try await sleep(max(Self.retryDelays[attempt], CloudResponseParser.retryAfter(response) ?? .zero) + jitter)
                attempt += 1
                continue
            }
            throw failure
        }
    }
}

// MARK: - Кадры страниц

/// Что отправить в облако из файла. Фото — один кадр. PDF — только страницы
/// без текстового слоя: текст слоя и так точный. Не больше 10 страниц.
/// Длинная сторона — 2048 px, JPEG 0,85: мелкий текст читается, запрос
/// остаётся в пределах 20 МБ инлайн-данных Gemini
enum CloudPageImages {
    static let maxSide = 2048
    static let maxPages = 10
    static let quality = 0.85

    /// nil — файл не фото и не PDF; пустой список — отправлять нечего
    @Sendable static func pages(for url: URL) -> [CloudPage]? {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true { return pdfPages(url) }
        guard type?.conforms(to: .image) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options), let jpeg = jpeg(image) else { return [] }
        return [CloudPage(number: 1, jpeg: jpeg)]
    }

    private static func pdfPages(_ url: URL) -> [CloudPage] {
        guard let document = PDFDocument(url: url) else { return [] }
        var pages: [CloudPage] = []
        for index in 0..<document.pageCount where pages.count < maxPages {
            guard let page = document.page(at: index),
                  !DocumentTextExtractor.hasReadableText(page.string ?? "") else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let rotated = page.rotation % 180 != 0
            let width = rotated ? bounds.height : bounds.width
            let height = rotated ? bounds.width : bounds.height
            let scale = CGFloat(maxSide) / max(width, height)
            let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
            let rendered: Data? = autoreleasepool {
                page.thumbnail(of: size, for: .mediaBox).cgImage.flatMap(jpeg)
            }
            if let rendered { pages.append(CloudPage(number: index + 1, jpeg: rendered)) }
        }
        return pages
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
