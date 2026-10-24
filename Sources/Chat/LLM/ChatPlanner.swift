import Foundation
import MLX
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
import os

/// Составляет план ответа по вопросу. В приложении это локальная модель,
/// в тестах — подделка. Ошибка или долгий ответ — повод ответить правилами
protocol ChatPlanning: Sendable {
    func plan(question: String, history: [ChatTurn], inventory: ChatInventory) async throws -> ChatPlan
}

enum ChatPlannerError: LocalizedError {
    /// В симуляторе MLX не работает: нужен настоящий GPU iPhone
    case unavailableOnSimulator
    case notEnoughMemory(available: Int64, required: Int64)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .unavailableOnSimulator:
            "Модель работает только на iPhone, не в симуляторе."
        case .notEnoughMemory(let available, let required):
            "Не хватает памяти: свободно \(ByteCountFormatter.string(fromByteCount: available, countStyle: .memory)), нужно \(ByteCountFormatter.string(fromByteCount: required, countStyle: .memory))."
        case .emptyOutput:
            "Модель ничего не ответила."
        }
    }
}

/// Свободная память до лимита приложения. На симуляторе и вне приложения — 0
enum DeviceMemory {
    static var available: Int64 {
        #if targetEnvironment(simulator)
        return 0
        #else
        return Int64(os_proc_available_memory())
        #endif
    }
}

// Планировщик на локальной модели MLX. Модель загружается при первом вопросе,
// грамматика JSON компилируется один раз, генерация идёт вне главного потока
// и отменяется, когда приложение уходит в фон: iOS отклоняет работу GPU в фоне
actor LocalModelPlanner: ChatPlanning {
    let choice: ChatModelChoice
    let snapshot: URL

    private var container: ModelContainer?
    /// Словарь модели для грамматики: строится один раз на загруженную модель.
    /// Само ограничение собирается на каждый запрос — clone() в вендорной
    /// xgrammar 0.1.30 не работает (forkFailed), а компиляция занимает 20–36 мс
    private var grammarTokenizer: GrammarTokenizer?
    private var generation: Task<String, Error>?
    /// Идущая загрузка. Второй вопрос во время неё ждёт эту же загрузку: актор
    /// реентерабелен, и без этого вторая копия модели заняла бы ещё 2+ ГБ
    private var loading: Task<(ModelContainer, GrammarTokenizer), Error>?
    /// Растёт при каждом уходе в фон: загрузка, закончившаяся после него,
    /// не должна вернуть модель в память
    private var epoch = 0

    private let log = Logger(subsystem: "com.ilyaqa.LocalDrive", category: "chat-model")

    init(choice: ChatModelChoice, snapshot: URL) {
        self.choice = choice
        self.snapshot = snapshot
    }

    func plan(question: String, history: [ChatTurn], inventory: ChatInventory) async throws -> ChatPlan {
        #if targetEnvironment(simulator)
        throw ChatPlannerError.unavailableOnSimulator
        #else
        let (container, grammarTokenizer) = try await loaded()
        // Пока модель грузилась, чат мог уже ответить правилами
        try Task.checkCancellation()
        let messages = ChatModelPrompt.messages(question: question, history: history, inventory: inventory)
        let task = Task.detached(priority: .userInitiated) {
            try await Self.generate(messages: messages, container: container, grammarTokenizer: grammarTokenizer)
        }
        generation = task
        defer { generation = nil }
        let json = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard !json.isEmpty else { throw ChatPlannerError.emptyOutput }
        return try ChatModelPrompt.plan(fromJSON: json)
        #endif
    }

    /// Приложение уходит в фон: генерация останавливается, модель выгружается.
    /// Ждём завершения задачи — команды GPU не должны уйти уже из фона
    func suspend() async {
        epoch += 1
        loading?.cancel()
        loading = nil
        if let generation {
            generation.cancel()
            _ = try? await generation.value
        }
        generation = nil
        grammarTokenizer = nil
        container = nil
        Memory.clearCache()
        if DocumentReaderFeature.isEnabled {
            await ModelResidency.shared.release(ObjectIdentifier(self))
        }
    }

    // MARK: - Загрузка

    private func loaded() async throws -> (ModelContainer, GrammarTokenizer) {
        if let container, let grammarTokenizer { return (container, grammarTokenizer) }
        if let loading { return try await loading.value }

        let startedEpoch = epoch
        // Одна модель в памяти: модель для документов выгружается до загрузки
        // этой — вопрос в чате важнее фонового чтения документов
        if DocumentReaderFeature.isEnabled {
            await ModelResidency.shared.acquire(ObjectIdentifier(self)) { [weak self] in
                await self?.suspend()
            }
            guard epoch == startedEpoch else { throw CancellationError() }
            if let container, let grammarTokenizer { return (container, grammarTokenizer) }
            if let loading { return try await loading.value }
        }

        let available = DeviceMemory.available
        guard available == 0 || available >= choice.requiredMemoryBytes else {
            if DocumentReaderFeature.isEnabled {
                await ModelResidency.shared.release(ObjectIdentifier(self))
            }
            throw ChatPlannerError.notEnoughMemory(available: available, required: choice.requiredMemoryBytes)
        }

        let started = Date()
        let snapshot = self.snapshot
        // Загрузка не привязана к вопросу: если чат ответил правилами по
        // таймеру, она доработает и пригодится к следующему вопросу
        let task = Task { try await Self.load(snapshot: snapshot) }
        loading = task
        defer { if epoch == startedEpoch { loading = nil } }
        let result = try await task.value
        // Пока модель грузилась, приложение ушло в фон
        guard epoch == startedEpoch else { throw CancellationError() }
        container = result.0
        grammarTokenizer = result.1
        log.info("модель загружена за \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) с")
        return result
    }

    private static func load(snapshot: URL) async throws -> (ModelContainer, GrammarTokenizer) {
        // Буферный кэш MLX держим маленьким: память важнее скорости повторов
        Memory.cacheLimit = 20 * 1024 * 1024
        let container = try await LLMModelFactory.shared.loadContainer(from: snapshot, using: HuggingFaceTokenizerLoader())
        Memory.clearCache()
        let grammarTokenizer = try await container.perform { context in
            let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
            return try GrammarTokenizer(
                vocab: vocab.vocab,
                vocabType: vocab.vocabType,
                eosTokenId: Int32(context.tokenizer.eosTokenId ?? 0)
            )
        }
        return (container, grammarTokenizer)
    }

    // MARK: - Генерация

    private static func generate(
        messages: [ChatModelMessage],
        container: ModelContainer,
        grammarTokenizer: GrammarTokenizer
    ) async throws -> String {
        try await container.perform { context in
            let constraint = try GrammarConstraint(
                tokenizer: grammarTokenizer,
                grammar: ChatModelPrompt.grammar,
                fastForward: true,
                hostTokenizer: context.tokenizer
            )
            // Сообщения MLX собираются внутри: сами они не Sendable
            let chat: [Chat.Message] = messages.map { message in
                switch message.role {
                case .system: .system(message.content)
                case .user: .user(message.content)
                case .assistant: .assistant(message.content)
                }
            }
            let input = try await context.processor.prepare(
                input: UserInput(chat: chat, additionalContext: ["enable_thinking": false])
            )
            var output = ""
            // Жадное декодирование по грамматике, без смещений к закрытию JSON:
            // на стенде они только мешали. Не хватило токенов — ошибка, и чат
            // отвечает правилами
            try GuidedGenerationLoop.run(
                input: input,
                context: context,
                constraint: constraint,
                maxTokens: ChatModelPrompt.maxTokens,
                vocabSize: grammarTokenizer.vocabSize
            ) { delta in
                output += delta
                return !Task.isCancelled
            }
            try Task.checkCancellation()
            return output
        }
    }
}
