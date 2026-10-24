import CoreGraphics
import CoreImage
import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon
import MLXVLM
import os

/// Второе чтение документов моделью. Пока выключено, приложение ведёт себя
/// как сборка 6: нет пункта в настройках, индекс не зовёт модель, чат — на Qwen3 4B
enum DocumentReaderFeature {
    static let isEnabled = true
}

/// Модель для документов. На стенде (docs/doc-reader.md, 12.10.2026) вместе с
/// правилами лучшими по ФИО были Qwen3.5 4B и Qwen3-VL 4B; Gemma 4 E2B — худшей.
/// Qwen3.5 4B как планировщик чата не подошла (план 88 % против 91 % у Qwen3 4B),
/// поэтому это отдельная, необязательная загрузка. На iPhone 16 Pro Max без
/// increased-memory-limit приложению доступно 3,24 ГБ — 4B туда не помещается,
/// для таких iPhone есть облегчённая 2B. Ревизии закреплены хэшем коммита:
/// только так клиент Hugging Face берёт скачанное из кэша без сети
enum DocumentModelChoice: String, CaseIterable, Sendable {
    case standard
    case light

    var repository: String {
        switch self {
        case .standard: "mlx-community/Qwen3.5-4B-4bit"
        case .light: "mlx-community/Qwen3.5-2B-4bit"
        }
    }

    var revision: String {
        switch self {
        case .standard: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c"
        case .light: "674aaa7240b91e8012fcad5d791b7dfe5ba90207"
        }
    }

    var modelName: String {
        switch self {
        case .standard: "Qwen3.5 4B"
        case .light: "Qwen3.5 2B"
        }
    }

    /// Файлы по шаблонам ChatModelChoice.filePatterns — из API Hugging Face
    var downloadBytes: Int64 {
        switch self {
        case .standard: 3_061_129_077
        case .light: 1_749_079_691
        }
    }

    /// Пик MLX на M4 с кадром 1024 px, все 34 кадра стенда, в МиБ
    var measuredPeakMiB: Int64 {
        switch self {
        case .standard: Self.standardPeakMiB
        case .light: Self.lightPeakMiB
        }
    }

    static let standardPeakMiB: Int64 = 3896
    static let lightPeakMiB: Int64 = 2643

    /// Сколько свободной памяти нужно перед загрузкой: пик плюс 200 МиБ.
    /// Повышенный лимит памяти не запрошен (см. ChatModelChoice.requiredMemoryBytes)
    var requiredMemoryBytes: Int64 {
        (measuredPeakMiB + 200) * 1_048_576
    }

    /// Какую из установленных моделей читать сейчас: 4B, если помещается, иначе
    /// 2B. Если не помещается ни одна — самая лёгкая: индекс покажет «не хватает
    /// памяти». `available == 0` — память узнать нельзя
    static func best(installed: Set<DocumentModelChoice>, available: Int64) -> DocumentModelChoice? {
        if installed.contains(.standard), available == 0 || available >= standard.requiredMemoryBytes { return .standard }
        if installed.contains(.light), available == 0 || available >= light.requiredMemoryBytes { return .light }
        return installed.contains(.light) ? .light : (installed.contains(.standard) ? .standard : nil)
    }

    /// Что советовать скачать на этом iPhone: 4B — только если помещается
    static func recommended(available: Int64) -> DocumentModelChoice {
        available == 0 || available >= standard.requiredMemoryBytes ? .standard : .light
    }
}

/// Инструкция и грамматика — со стенда (scratchpad doc-bench, DocBench):
/// английская инструкция дала те же ФИО и даты и меньше ложных значений.
/// Менять — только с новым прогоном стенда
enum DocumentReaderPrompt {
    static let instruction = """
    This is a photo of an identity document. Copy the fields exactly as printed. Do not guess: if a field is absent or unreadable, use an empty string.
    type: passport_ru — Russian internal passport, passport_intl — Russian international passport, passport_foreign — passport of another country, driver_license, other.
    surname, given_name, patronymic — write them in Cyrillic if they are printed in Cyrillic, otherwise in Latin letters. No patronymic — empty string.
    Dates as DD.MM.YYYY: birth_date, issue_date, expiry_date.
    number — document series and number as printed (Russian passport: 4-digit series and 6-digit number). department_code — Russian department code (000-000).
    issued_by — issuing authority, birth_place — place of birth, sex — М or Ж (Cyrillic), country — three-letter country code (RUS, TJK, UZB…).
    Answer with JSON only.
    """

    /// Тип и даты — из перечня и по маске, строки — белый список символов
    static let grammar = #"""
    root ::= "{\"type\": " type ", \"surname\": " text ", \"given_name\": " text ", \"patronymic\": " text ", \"birth_date\": " date ", \"issue_date\": " date ", \"expiry_date\": " date ", \"number\": " text ", \"department_code\": " text ", \"issued_by\": " text ", \"birth_place\": " text ", \"sex\": " sex ", \"country\": " text "}"
    type ::= "\"passport_ru\"" | "\"passport_intl\"" | "\"passport_foreign\"" | "\"driver_license\"" | "\"other\""
    date ::= "\"\"" | "\"" [0-3] [0-9] "." [0-1] [0-9] "." [1-2] [0-9] [0-9] [0-9] "\""
    sex ::= "\"\"" | "\"М\"" | "\"Ж\""
    text ::= "\"" [а-яА-ЯёЁa-zA-Z0-9 .,№/'()\-ҲҳҶҷҚқҒғӢӣӮӯ]* "\""
    """#

    /// На стенде самый длинный ответ — около 200 токенов
    static let maxTokens = 360

    static func readout(fromJSON json: String) throws -> DocumentReadout {
        try JSONDecoder().decode(DocumentReadout.self, from: Data(json.utf8))
    }
}

// Читатель удостоверений на локальной модели MLXVLM. Модель загружается при
// первом документе и выгружается, когда приложение уходит в фон или чату
// нужна своя модель. Генерация идёт вне главного потока
actor LocalDocumentReader: DocumentReading {
    nonisolated let choice: DocumentModelChoice
    nonisolated let revision: String
    let snapshot: URL

    private var container: ModelContainer?
    private var grammarTokenizer: GrammarTokenizer?
    private var generation: Task<String, Error>?
    private var loading: Task<(ModelContainer, GrammarTokenizer), Error>?
    /// Растёт при каждой выгрузке: загрузка, закончившаяся после неё, не должна
    /// вернуть модель в память
    private var epoch = 0

    private let log = Logger(subsystem: "com.ilyaqa.LocalDrive", category: "document-model")

    init(choice: DocumentModelChoice, snapshot: URL) {
        self.choice = choice
        revision = choice.revision
        self.snapshot = snapshot
    }

    func read(_ image: PageImage, kind: DocumentType) async throws -> DocumentReadout {
        #if targetEnvironment(simulator)
        throw DocumentReaderUnavailable(reason: "В симуляторе модель не работает: ей нужен GPU iPhone.")
        #else
        let (container, grammarTokenizer) = try await loaded()
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) {
            try await Self.generate(image: image, container: container, grammarTokenizer: grammarTokenizer)
        }
        generation = task
        defer { generation = nil }
        let json: String
        do {
            json = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch GuidedGenerationError.incompleteOutput {
            // Не уложилась в грамматику — значений нет. Без грамматики заново
            // не генерируем: так модель могла бы написать что угодно
            throw DocumentReaderIncomplete()
        }
        guard !json.isEmpty else { throw DocumentReaderIncomplete() }
        do {
            return try DocumentReaderPrompt.readout(fromJSON: json)
        } catch {
            throw DocumentReaderIncomplete()
        }
        #endif
    }

    /// Приложение уходит в фон или чату нужна память: чтение останавливается,
    /// модель выгружается. Ждём задачу — команды GPU не должны уйти из фона
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
        await ModelResidency.shared.release(ObjectIdentifier(self))
    }

    // MARK: - Загрузка

    private func loaded() async throws -> (ModelContainer, GrammarTokenizer) {
        if let container, let grammarTokenizer { return (container, grammarTokenizer) }
        if let loading { return try await loading.value }

        // Даже без модели чата памяти не хватит — её и не выгружаем
        let before = DeviceMemory.available
        if before > 0, before + ChatModelChoice.standard.requiredMemoryBytes < choice.requiredMemoryBytes {
            throw Self.notEnoughMemory(before, choice: choice)
        }

        let startedEpoch = epoch
        // Человек переписывается с чатом — его модель не вытесняем. Пока ждали,
        // приложение могло уйти в фон
        try await ModelResidency.shared.waitForChatPause()
        guard epoch == startedEpoch else { throw CancellationError() }
        // Одна модель в памяти: модель чата выгружается до загрузки этой
        await ModelResidency.shared.acquire(ObjectIdentifier(self)) { [weak self] in
            await self?.suspend()
        }
        guard epoch == startedEpoch else { throw CancellationError() }
        if let container, let grammarTokenizer { return (container, grammarTokenizer) }
        if let loading { return try await loading.value }

        Memory.clearCache()
        let available = DeviceMemory.available
        guard available == 0 || available >= choice.requiredMemoryBytes else {
            await ModelResidency.shared.release(ObjectIdentifier(self))
            throw Self.notEnoughMemory(available, choice: choice)
        }

        let started = Date()
        let snapshot = self.snapshot
        let task = Task { try await Self.load(snapshot: snapshot) }
        loading = task
        defer { if epoch == startedEpoch { loading = nil } }
        let result = try await task.value
        // Пока модель грузилась, приложение ушло в фон или чат забрал память
        guard epoch == startedEpoch else { throw CancellationError() }
        container = result.0
        grammarTokenizer = result.1
        log.info("модель для документов загружена за \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) с")
        return result
    }

    private static func notEnoughMemory(_ available: Int64, choice: DocumentModelChoice) -> DocumentReaderUnavailable {
        let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .memory)
        let needed = ByteCountFormatter.string(fromByteCount: choice.requiredMemoryBytes, countStyle: .memory)
        return DocumentReaderUnavailable(reason: "Не хватает памяти: приложению доступно \(free), \(choice.modelName) нужно \(needed).")
    }

    private static func load(snapshot: URL) async throws -> (ModelContainer, GrammarTokenizer) {
        // Буферный кэш MLX маленький: память важнее скорости повторов
        Memory.cacheLimit = 20 * 1024 * 1024
        let container = try await VLMModelFactory.shared.loadContainer(from: snapshot, using: HuggingFaceTokenizerLoader())
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
        image: PageImage,
        container: ModelContainer,
        grammarTokenizer: GrammarTokenizer
    ) async throws -> String {
        try await container.perform { context in
            let side = DocumentPageImage.maxSide
            var input = UserInput(
                chat: [.user(DocumentReaderPrompt.instruction, images: [.ciImage(CIImage(cgImage: image.cgImage))])],
                additionalContext: ["enable_thinking": false]
            )
            // Бюджет картинки задаёт размер кадра: потолок модели не должен его срезать
            input.processing = .init(maxPixels: side * side)
            let prepared = try await context.processor.prepare(input: input)
            let constraint = try GrammarConstraint(
                tokenizer: grammarTokenizer,
                grammar: DocumentReaderPrompt.grammar,
                fastForward: true,
                hostTokenizer: context.tokenizer
            )
            var output = ""
            // Жадное декодирование по грамматике, как на стенде
            try GuidedGenerationLoop.run(
                input: prepared,
                context: context,
                constraint: constraint,
                maxTokens: DocumentReaderPrompt.maxTokens,
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
