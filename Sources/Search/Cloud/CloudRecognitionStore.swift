import Foundation

// Настройки облачного распознавания. Выключено по умолчанию: включает
// владелец, со своим ключом. Ключ — только в Keychain, «только на этом
// устройстве»: в резервные копии и на другие устройства он не попадает и
// нигде не пишется в журнал. У каждого сервиса свой ключ, своя модель и свой
// адрес: переключение OpenAI ↔ Gemini ничего не стирает
@MainActor
@Observable
final class CloudRecognitionStore {
    enum TestResult: Equatable {
        case running
        case succeeded
        case failed(String)
    }

    private(set) var isEnabled: Bool
    private(set) var provider: CloudProvider
    /// Модель, адрес и ключ — выбранного сервиса
    private(set) var model: String
    private(set) var baseURL: String
    private(set) var hasKey: Bool
    /// Сколько страниц отправлено за всё время, сколько токенов на них ушло и
    /// во сколько это обошлось по ценам модели, которая их читала
    private(set) var pagesSent: Int
    private(set) var inputTokens: Int
    private(set) var outputTokens: Int
    private(set) var spentDollars: Double
    private(set) var testResult: TestResult?
    /// Чат через облако — свой переключатель, выключен по умолчанию
    private(set) var chatEnabled: Bool
    /// Сколько модели думать — выбор на поле ввода. Только настройка —
    /// содержимого переписки здесь нет
    private(set) var chatReasoning: CloudChatReasoning
    /// Модель чата, как её выбрали на поле ввода; действует — `chatModel`
    private var storedChatModel: CloudChatModel?

    /// Читатель появился, пропал или поменялись настройки
    @ObservationIgnored var onReaderChange: ((any CloudReading)?) -> Void = { _ in }

    /// Ключ только в памяти, на время проверки (живая проверка в тестах): в
    /// Keychain и на диск не попадает
    @ObservationIgnored private var sessionKey: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychainService: String
    @ObservationIgnored private let session: URLSession

    private enum Key {
        static let enabled = "cloud.enabled"
        static let provider = "cloud.provider"
        static func model(_ provider: CloudProvider) -> String { "cloud.model.\(provider.rawValue)" }
        static func baseURL(_ provider: CloudProvider) -> String { "cloud.baseURL.\(provider.rawValue)" }
        /// Прежние сборки: одна модель и один адрес на все сервисы
        static let legacyModel = "cloud.model"
        static let legacyBaseURL = "cloud.baseURL"
        /// Переход на OpenAI по умолчанию уже сделан
        static let openAIDefault = "cloud.openAIDefault"
        static let pages = "cloud.pagesSent"
        static let input = "cloud.inputTokens"
        static let output = "cloud.outputTokens"
        static let spent = "cloud.spentDollars"
        static let chat = "cloud.chatEnabled"
        static let chatModel = "chat.model"
        static let chatReasoning = "chat.reasoning"
    }

    /// Прежний общий ключ. Ключи сервисов — «<этот адрес>.openai» и «….gemini»
    static let defaultKeychainService = "com.ilyaqa.LocalDrive.cloud.apiKey"

    init(defaults: UserDefaults = .standard, keychainService: String = defaultKeychainService, session: URLSession = .shared) {
        self.defaults = defaults
        self.keychainService = keychainService
        self.session = session
        Self.migrate(defaults: defaults, keychainService: keychainService)
        let provider = defaults.string(forKey: Key.provider).flatMap(CloudProvider.init(stored:)) ?? .openAI
        self.provider = provider
        isEnabled = defaults.bool(forKey: Key.enabled)
        model = defaults.string(forKey: Key.model(provider)) ?? provider.defaultModel
        baseURL = defaults.string(forKey: Key.baseURL(provider)) ?? provider.defaultBaseURL
        hasKey = Keychain.get(service: Self.keyService(keychainService, provider)).map { !$0.isEmpty } ?? false
        pagesSent = defaults.integer(forKey: Key.pages)
        inputTokens = defaults.integer(forKey: Key.input)
        outputTokens = defaults.integer(forKey: Key.output)
        spentDollars = defaults.double(forKey: Key.spent)
        chatEnabled = defaults.bool(forKey: Key.chat)
        storedChatModel = defaults.string(forKey: Key.chatModel).flatMap(CloudChatModel.init(rawValue:))
        chatReasoning = defaults.string(forKey: Key.chatReasoning).flatMap(CloudChatReasoning.init(rawValue:)) ?? .auto
    }

    private static func keyService(_ base: String, _ provider: CloudProvider) -> String {
        "\(base).\(provider.rawValue)"
    }

    /// Прежние сборки хранили один ключ, одну модель и один адрес — они
    /// принадлежат сервису, который тогда был выбран (по умолчанию Gemini).
    /// Решение владельца 12.10.2026: облако по умолчанию — OpenAI. Переход
    /// делается один раз; ключ Gemini остаётся на своём месте, и вернуться к
    /// Gemini — одно касание в настройках
    private static func migrate(defaults: UserDefaults, keychainService: String) {
        let legacyProvider = defaults.string(forKey: Key.provider).flatMap(CloudProvider.init(stored:)) ?? .gemini
        if let legacyKey = Keychain.get(service: keychainService) {
            let target = keyService(keychainService, legacyProvider)
            if Keychain.get(service: target) == nil {
                Keychain.set(legacyKey, service: target)
            }
            Keychain.delete(service: keychainService)
        }
        for (legacy, key) in [(Key.legacyModel, Key.model(legacyProvider)), (Key.legacyBaseURL, Key.baseURL(legacyProvider))] {
            guard let value = defaults.string(forKey: legacy) else { continue }
            if defaults.string(forKey: key) == nil { defaults.set(value, forKey: key) }
            defaults.removeObject(forKey: legacy)
        }
        // Расход прежних сборок считался по токенам и цене текущей модели
        if defaults.object(forKey: Key.spent) == nil {
            let model = defaults.string(forKey: Key.model(legacyProvider)) ?? legacyProvider.defaultModel
            let input = Double(defaults.integer(forKey: Key.input)), output = Double(defaults.integer(forKey: Key.output))
            if input + output > 0, let price = price(model: model) {
                defaults.set((input * price.input + output * price.output) / 1_000_000, forKey: Key.spent)
            }
        }
        if !defaults.bool(forKey: Key.openAIDefault) {
            defaults.set(CloudProvider.openAI.rawValue, forKey: Key.provider)
            defaults.set(true, forKey: Key.openAIDefault)
        }
    }

    // MARK: - Чат

    /// Модель чата: выбранная на поле ввода, если она этого сервиса, иначе —
    /// модель сервиса по умолчанию. «iPhone» — всегда «iPhone»
    var chatModel: CloudChatModel {
        guard let storedChatModel else { return CloudChatModel.defaultModel(for: provider) }
        if storedChatModel == .local || storedChatModel.provider == provider { return storedChatModel }
        return CloudChatModel.defaultModel(for: provider)
    }

    /// Можно ли сейчас отвечать в чате облаком: включено, есть ключ, на поле
    /// ввода выбрана облачная модель
    var chatConfiguration: CloudChatEngine.Configuration? {
        guard chatEnabled, chatModel != .local, let key = apiKey, !key.isEmpty else { return nil }
        return CloudChatEngine.Configuration(provider: provider, baseURL: baseURL, apiKey: key, model: chatModel, reasoning: chatReasoning)
    }

    /// Облачный чат включён и с ключом — выбор модели на поле ввода имеет смысл
    var chatAvailable: Bool {
        chatEnabled && hasKey
    }

    func setChatEnabled(_ enabled: Bool) {
        chatEnabled = enabled
        defaults.set(enabled, forKey: Key.chat)
    }

    func setChatModel(_ model: CloudChatModel) {
        storedChatModel = model
        defaults.set(model.rawValue, forKey: Key.chatModel)
    }

    func setChatReasoning(_ reasoning: CloudChatReasoning) {
        chatReasoning = reasoning
        defaults.set(reasoning.rawValue, forKey: Key.chatReasoning)
    }

    /// С чем идти в облако. nil — выключено или нет ключа: тогда не уходит ничего
    var configuration: CloudConfiguration? {
        guard isEnabled, let key = apiKey, !key.isEmpty else { return nil }
        return CloudConfiguration(provider: provider, model: model, baseURL: baseURL, apiKey: key)
    }

    var currentReader: (any CloudReading)? {
        guard let configuration else { return nil }
        let model = configuration.model
        return CloudDocumentReader(configuration: configuration, session: session, onUsage: { [weak self] usage in
            Task { @MainActor in self?.record(usage, model: model) }
        })
    }

    private var apiKey: String? {
        sessionKey ?? Keychain.get(service: Self.keyService(keychainService, provider)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Ключ на время работы — только в памяти
    func useSessionKey(_ key: String) {
        sessionKey = key
        hasKey = true
        changed()
    }

    // MARK: - Настройки

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        changed()
    }

    /// Другой сервис — со своими моделью, адресом и ключом
    func setProvider(_ provider: CloudProvider) {
        guard provider != self.provider else { return }
        self.provider = provider
        defaults.set(provider.rawValue, forKey: Key.provider)
        model = defaults.string(forKey: Key.model(provider)) ?? provider.defaultModel
        baseURL = defaults.string(forKey: Key.baseURL(provider)) ?? provider.defaultBaseURL
        hasKey = Keychain.get(service: Self.keyService(keychainService, provider)).map { !$0.isEmpty } ?? false
        changed()
    }

    func setModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != self.model else { return }
        self.model = trimmed
        defaults.set(trimmed, forKey: Key.model(provider))
        changed()
    }

    func setBaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != baseURL else { return }
        baseURL = trimmed
        defaults.set(trimmed, forKey: Key.baseURL(provider))
        changed()
    }

    /// Ключ выбранного сервиса
    func setKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.set(Data(trimmed.utf8), service: Self.keyService(keychainService, provider))
        hasKey = true
        changed()
    }

    func removeKey() {
        Keychain.delete(service: Self.keyService(keychainService, provider))
        hasKey = false
        changed()
    }

    private func changed() {
        testResult = nil
        onReaderChange(currentReader)
    }

    // MARK: - Проверка и учёт

    /// Проверка без документов: у Gemini — короткий текстовый вопрос, у
    /// OpenAI — бесплатный запрос сведений о модели
    func testConnection() async {
        guard let key = apiKey, !key.isEmpty else {
            testResult = .failed("Сначала сохраните ключ")
            return
        }
        testResult = .running
        let configuration = CloudConfiguration(provider: provider, model: model, baseURL: baseURL, apiKey: key)
        do {
            try await CloudDocumentReader(configuration: configuration, session: session).ping()
            testResult = .succeeded
        } catch let failure as CloudFailure {
            testResult = .failed(failure.message)
        } catch {
            testResult = .failed(CloudFailure.network.message)
        }
    }

    private func record(_ usage: CloudUsage, model: String) {
        pagesSent += usage.pages
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        if let price = Self.price(model: model) {
            spentDollars += (Double(usage.inputTokens) * price.input + Double(usage.outputTokens) * price.output) / 1_000_000
        }
        defaults.set(pagesSent, forKey: Key.pages)
        defaults.set(inputTokens, forKey: Key.input)
        defaults.set(outputTokens, forKey: Key.output)
        defaults.set(spentDollars, forKey: Key.spent)
    }

    /// Цены за миллион токенов на 12.10.2026, обычная обработка: OpenAI —
    /// developers.openai.com/api/docs/pricing, Gemini — платный уровень
    /// ai.google.dev/gemini-api/docs/pricing. У других моделей цену не знаем
    static func price(model: String) -> (input: Double, output: Double)? {
        switch model {
        case "gpt-6-luna": (0.10, 0.50)
        case "gpt-6.1-sol": (2.00, 10.00)
        case "gpt-6-astra": (10.00, 50.00)
        case "gemini-3.8-flash": (0.75, 3.75)
        case "gemini-3.5-flash-lite": (0.30, 2.50)
        default: nil
        }
    }

    /// Примерная цена страницы до отправки. Gemini 3: картинка — 1120 токенов
    /// при разрешении по умолчанию, инструкция и схема — около 500. OpenAI:
    /// кадр 2048 × 1536 с detail «original» — 64 × 48 = 3072 клетки по 32 px,
    /// × 1,2 = 3687 токенов, инструкция и схема — около 900. Ответ с полной
    /// расшифровкой — около 1000 токенов, рассуждение модели — сверху
    static func estimatedPagePrice(model: String) -> Double? {
        let input = model.hasPrefix("gpt-") ? 4600.0 : 1620.0
        return price(model: model).map { (input * $0.input + 1000 * $0.output) / 1_000_000 }
    }
}
