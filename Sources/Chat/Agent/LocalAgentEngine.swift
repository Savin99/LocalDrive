import Foundation

// Агент на iPhone: модель чата сама зовёт инструменты в несколько шагов —
// ищет, открывает документ, смотрит папки, предлагает перенос или карточку, —
// пока не ответит. Инструменты и их исполнение те же, что у облачного агента
// (CloudChatTools): номера — маской, файлы и карточки — только предложением.
// Раньше модель на iPhone возвращала один «план» из четырёх действий
// (ChatPlan); владелец 24.10.2026: «нормального агента, а не ограниченный план»

/// Ход модели: текст и вызовы инструментов
struct AgentTurn: Sendable, Equatable {
    var text = ""
    var calls: [AgentCall] = []
    /// Модель начала вызов, но он не разобрался: оборван или кривой JSON
    var rejected = false
}

struct AgentCall: Sendable, Equatable {
    let id: String?
    let name: String
    /// Аргументы — JSON-объект
    let arguments: Data
}

/// Результат инструмента — следующей репликой модели
struct AgentToolResult: Sendable, Equatable {
    let id: String?
    let name: String
    let content: String
}

/// Прошлая реплика разговора — для «а у неё?» после ответа
struct AgentMessage: Sendable, Equatable {
    enum Role: Sendable {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

/// Модель агента. В приложении — Qwen3 через MLX (`LocalChatModel`):
/// разговор живёт в её сессии, и кэш промпта переиспользуется между шагами.
/// В тестах — подделка с заготовленными ходами
protocol LocalAgentModel: Sendable {
    /// Новый разговор агента: инструкция, инструменты, прошлые реплики, вопрос
    func beginAgent(instructions: String, toolsJSON: String, history: [AgentMessage], question: String) async throws -> AgentTurn
    /// Результаты инструментов — следующий ход того же разговора
    func continueAgent(results: [AgentToolResult]) async throws -> AgentTurn
    /// «Новый чат»: разговор агента начинается с нуля
    func resetAgent() async
}

@MainActor
final class LocalAgentEngine {
    /// Шагов на вопрос. Каждый шаг на iPhone — секунды, а настоящие вопросы
    /// укладываются в два-три: найти, посмотреть, показать
    static let maxSteps = 5
    /// Результат инструмента для модели — не длиннее: это токены разбора
    static let resultLimit = 2000

    private let model: any LocalAgentModel
    private let search: SearchService
    private let tools: CloudChatTools

    init(model: any LocalAgentModel, search: SearchService, proposals: FileProposalMaker?, facts: FactStore?) {
        self.model = model
        self.search = search
        tools = CloudChatTools(search: search, proposals: proposals)
        tools.facts = facts
    }

    /// Ответ на вопрос. Шаги и карточки — событиями, как у облака: экран
    /// показывает их по мере работы
    func respond(
        to text: String,
        history: [AgentMessage],
        owner: String?,
        onEvent: @MainActor (CloudChatEvent) -> Void
    ) async throws -> CloudChatReply {
        let instructions = LocalAgentPrompt.instructions(
            index: await search.chatDocumentIndex(limit: LocalAgentPrompt.indexLimit),
            facts: CloudChatFactTools.index(tools.facts),
            owner: owner
        )
        var turn = try await model.beginAgent(instructions: instructions, toolsJSON: LocalAgentPrompt.toolsJSON,
                                              history: history, question: text)
        var cards: [ChatCard] = []
        var answer = ""
        var retried = false
        for step in 1...Self.maxSteps {
            // Вызов, записанный словами: «search_documents(query="…")»
            if turn.calls.isEmpty, let recovered = Self.recoverCall(from: turn.text) {
                turn = AgentTurn(text: "", calls: [recovered])
            }
            // Вызов оборвался или JSON кривой — пусть модель повторит, но один
            // раз: на стенде три повтора подряд заняли 38 с
            if turn.calls.isEmpty, turn.rejected, !retried, step < Self.maxSteps {
                retried = true
                turn = try await model.continueAgent(results: [AgentToolResult(
                    id: nil, name: "error", content: #"{"error": "Вызов не разобрался. Повтори его короче, валидным JSON."}"#
                )])
                continue
            }
            answer += Self.clean(turn.text)
            guard !turn.calls.isEmpty else { break }
            var results: [AgentToolResult] = []
            var shownByTerminal = false
            for call in turn.calls {
                let arguments = CloudJSON.parse(call.arguments)?.withoutNulls ?? [:]
                if let (kind, label) = await CloudChatSteps.step(for: call.name, arguments: arguments, search: search, facts: tools.facts) {
                    onEvent(.step(kind, label))
                }
                let before = cards.count
                let result = await tools.run(call.name, arguments: arguments, cards: &cards)
                if cards.count > before { onEvent(.cards(Array(cards[before...]))) }
                results.append(AgentToolResult(id: call.id, name: call.name, content: Self.compact(result)))
                // Карточка показана — ответ готов, как у облака
                if CloudChatEngine.terminalTools.contains(call.name), cards.count > before { shownByTerminal = true }
            }
            if shownByTerminal || step == Self.maxSteps { break }
            turn = try await model.continueAgent(results: results)
        }
        var reply = tools.mask(answer.trimmingCharacters(in: .whitespacesAndNewlines))
        if reply.isEmpty {
            reply = cards.contains { if case .proposal = $0 { true } else if case .factProposal = $0 { true } else { false } }
                ? ChatSession.proposalLead
                : (cards.isEmpty ? "Не нашёл, что ответить, — уточните вопрос." : "")
        }
        return CloudChatReply(text: reply, cards: cards, thoughts: "", thinkingSeconds: nil)
    }

    /// «search_documents(query="справка", owner="Илья")» или
    /// «show_fact_card({"id": "f…"})» — вызов, который модель написала текстом,
    /// а не в своём формате. Только точное имя объявленного инструмента и
    /// только если больше в ответе ничего нет: случайное упоминание не исполняется
    static func recoverCall(from text: String) -> AgentCall? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "`")))
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else { return nil }
        let name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
        guard LocalAgentPrompt.toolNames.contains(name) else { return nil }
        let inner = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]).trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("{"), let data = inner.data(using: .utf8), CloudJSON.parse(data)?.object != nil {
            return AgentCall(id: nil, name: name, arguments: data)
        }
        // key="value", key2="value"
        var arguments: [String: CloudJSON] = [:]
        let pattern = #"(\w+)\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in regex.matches(in: inner, range: NSRange(inner.startIndex..., in: inner)) {
            guard let key = Range(match.range(at: 1), in: inner), let value = Range(match.range(at: 2), in: inner) else { continue }
            arguments[String(inner[key])] = .string(String(inner[value]))
        }
        guard !arguments.isEmpty || inner.isEmpty else { return nil }
        return AgentCall(id: nil, name: name, arguments: CloudJSON.object(arguments).data)
    }

    /// Текст модели без служебных тегов: рассуждение и недоразобранный вызов
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<tool_call>[\s\S]*?(</tool_call>|$)"#, with: "", options: .regularExpression)
    }

    /// Результат инструмента строкой JSON — без картинок и не длиннее предела
    static func compact(_ result: CloudJSON) -> String {
        var object = result.object ?? [:]
        object.removeValue(forKey: "_images")
        let text = String(data: CloudJSON.object(object).data, encoding: .utf8) ?? "{}"
        return String(text.prefix(resultLimit))
    }
}
