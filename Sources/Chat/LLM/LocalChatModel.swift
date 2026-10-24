import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os

enum LocalChatModelError: LocalizedError {
    /// В симуляторе MLX не работает: нужен настоящий GPU iPhone
    case unavailableOnSimulator
    case notEnoughMemory(available: Int64, required: Int64)

    var errorDescription: String? {
        switch self {
        case .unavailableOnSimulator:
            "Модель работает только на iPhone, не в симуляторе."
        case .notEnoughMemory(let available, let required):
            "Не хватает памяти: свободно \(ByteCountFormatter.string(fromByteCount: available, countStyle: .memory)), нужно \(ByteCountFormatter.string(fromByteCount: required, countStyle: .memory))."
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

// Модель чата на iPhone (Qwen3 4B через MLX) — мозг агента, когда облака нет
// (LocalAgentEngine). Загружается при первом вопросе, генерация идёт вне
// главного потока и отменяется, когда приложение уходит в фон: iOS отклоняет
// работу GPU в фоне. Раньше модель только составляла «план» из четырёх
// действий; с 24.10.2026 она сама зовёт инструменты в несколько шагов
actor LocalChatModel {
    let choice: ChatModelChoice
    let snapshot: URL

    private var container: ModelContainer?
    /// Идущий ход агента: уход в фон его останавливает и ждёт
    private var agentTask: Task<AgentTurn, Error>?
    /// Разговор агента: сессия MLX держит кэш промпта между шагами и между
    /// вопросами — инструкция, инструменты и опись разбираются один раз
    private var agentSession: MLXLMCommon.ChatSession?
    /// С какой инструкцией открыт разговор: опись поменялась — новый
    private var agentInstructions = ""
    /// Вопросы, которые уже в разговоре: по ним видно, что из истории чата
    /// модель ещё не слышала (на что ответили правила)
    private var agentQuestions: [String] = []
    /// Идущая загрузка. Второй вопрос во время неё ждёт эту же загрузку: актор
    /// реентерабелен, и без этого вторая копия модели заняла бы ещё 2+ ГБ
    private var loading: Task<ModelContainer, Error>?
    /// Растёт при каждом уходе в фон: загрузка, закончившаяся после него,
    /// не должна вернуть модель в память
    private var epoch = 0

    private let log = Logger(subsystem: "com.ilyaqa.LocalDrive", category: "chat-model")

    init(choice: ChatModelChoice, snapshot: URL) {
        self.choice = choice
        self.snapshot = snapshot
    }

    /// Приложение уходит в фон: генерация останавливается, модель выгружается.
    /// Ждём завершения задачи — команды GPU не должны уйти уже из фона
    func suspend() async {
        epoch += 1
        loading?.cancel()
        loading = nil
        if let agentTask {
            agentTask.cancel()
            _ = try? await agentTask.value
        }
        agentTask = nil
        agentSession = nil
        agentQuestions = []
        container = nil
        Memory.clearCache()
        if DocumentReaderFeature.isEnabled {
            await ModelResidency.shared.release(ObjectIdentifier(self))
        }
    }

    // MARK: - Загрузка

    private func loaded() async throws -> ModelContainer {
        if let container { return container }
        if let loading { return try await loading.value }

        let startedEpoch = epoch
        // Одна модель в памяти: модель для документов выгружается до загрузки
        // этой — вопрос в чате важнее фонового чтения документов
        if DocumentReaderFeature.isEnabled {
            await ModelResidency.shared.acquire(ObjectIdentifier(self)) { [weak self] in
                await self?.suspend()
            }
            guard epoch == startedEpoch else { throw CancellationError() }
            if let container { return container }
            if let loading { return try await loading.value }
        }

        let available = DeviceMemory.available
        guard available == 0 || available >= choice.requiredMemoryBytes else {
            if DocumentReaderFeature.isEnabled {
                await ModelResidency.shared.release(ObjectIdentifier(self))
            }
            throw LocalChatModelError.notEnoughMemory(available: available, required: choice.requiredMemoryBytes)
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
        container = result
        log.info("модель загружена за \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) с")
        return result
    }

    private static func load(snapshot: URL) async throws -> ModelContainer {
        // Буферный кэш MLX держим маленьким: память важнее скорости повторов
        Memory.cacheLimit = 20 * 1024 * 1024
        let container = try await LLMModelFactory.shared.loadContainer(from: snapshot, using: HuggingFaceTokenizerLoader())
        Memory.clearCache()
        return container
    }
}

// MARK: - Агент

extension LocalChatModel: LocalAgentModel {
    func beginAgent(instructions: String, toolsJSON: String, history: [AgentMessage], question: String) async throws -> AgentTurn {
        #if targetEnvironment(simulator)
        throw LocalChatModelError.unavailableOnSimulator
        #else
        let container = try await loaded()
        try Task.checkCancellation()
        // Тот же разговор — модель уже знает инструкцию и прошлые вопросы:
        // дописываем только то, чего она не слышала
        var missed = history
        var session = agentSession
        if session != nil, instructions == agentInstructions, let last = agentQuestions.last,
           let index = history.lastIndex(where: { $0.role == .user && $0.content == last }) {
            missed = Array(history.dropFirst(index + 2))
        } else {
            // Жадная генерация: выбор инструмента не должен зависеть от случая
            session = MLXLMCommon.ChatSession(
                container,
                instructions: instructions,
                generateParameters: GenerateParameters(maxTokens: Self.agentMaxTokens, temperature: 0),
                additionalContext: ["enable_thinking": false],
                tools: Self.toolSpecs(toolsJSON)
            )
            agentInstructions = instructions
            agentQuestions = []
        }
        guard let session else { throw CancellationError() }
        agentSession = session
        agentQuestions.append(question)
        var messages: [Chat.Message] = missed.map { message in
            message.role == .user ? .user(message.content) : .assistant(message.content)
        }
        messages.append(.user(question))
        return try await run(session.streamDetails(to: messages))
        #endif
    }

    func resetAgent() {
        agentSession = nil
        agentQuestions = []
    }

    func continueAgent(results: [AgentToolResult]) async throws -> AgentTurn {
        guard let agentSession else { throw CancellationError() }
        return try await run(agentSession.streamDetails(to: results.map { .tool($0.content, id: $0.id, name: $0.name) }))
    }

    /// Ход как задача: уход в фон отменяет её и дожидается, пока GPU затихнет
    private func run(_ stream: AsyncThrowingStream<Generation, Error>) async throws -> AgentTurn {
        let task = Task { try await collect(stream) }
        agentTask = task
        defer { agentTask = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Ход модели целиком: текст и вызовы, которые сессия разобрала по формату Qwen
    private func collect(_ stream: AsyncThrowingStream<Generation, Error>) async throws -> AgentTurn {
        var turn = AgentTurn()
        for try await item in stream {
            try Task.checkCancellation()
            switch item {
            case .chunk(let text):
                turn.text += text
            case .toolCall(let call):
                let arguments = (try? JSONEncoder().encode(call.function.arguments)) ?? Data("{}".utf8)
                turn.calls.append(AgentCall(id: call.id, name: call.function.name, arguments: arguments))
            case .rejectedToolCall:
                turn.rejected = true
            default:
                break
            }
        }
        return turn
    }

    /// Текст ответа и вызова — не длиннее: пара фраз или вызов с переносом
    /// нескольких файлов
    static let agentMaxTokens = 800

    /// Инструменты для шаблона Qwen: JSON → словари, которые ждёт MLX
    static func toolSpecs(_ json: String) -> [ToolSpec] {
        guard let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return list.map { $0.mapValues(sendable) }
    }

    private static func sendable(_ value: Any) -> any Sendable {
        switch value {
        case let object as [String: Any]: object.mapValues(sendable)
        case let array as [Any]: array.map(sendable)
        case let string as String: string
        // Логические значения JSONSerialization тоже отдаёт числами
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): number.boolValue
        case let number as NSNumber: number.doubleValue.rounded() == number.doubleValue ? number.intValue : number.doubleValue
        default: String(describing: value)
        }
    }
}
