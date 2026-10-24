import SwiftUI
import Observation

/// Данные приложения для блоков с `source`. Реализует приложение поверх
/// индекса: только папки, доступные для поиска, номера — маской
protocol GenUIDataProvider: Sendable {
    func rows(for source: GenUIDataSource) async throws -> GenUIRows
}

/// Действия, которые движок сам не выполняет: модель, файлы, напоминания.
/// Меняющие данные (`needsConfirmation`) приложение подтверждает у человека
@MainActor
protocol GenUIActionPerformer: AnyObject {
    func perform(_ action: GenUIAction, block: String, state: GenUIStateSnapshot) async -> GenUIActionOutcome
}

/// Чем кончилось действие. Текст показывается под кнопкой
enum GenUIActionOutcome: Hashable, Sendable {
    case done(String?)
    case failed(String)
}

/// Что движку нужно от приложения
struct GenUIEnvironment {
    var dataProvider: (any GenUIDataProvider)?
    var actionPerformer: (any GenUIActionPerformer)?
    /// Карточка из каталога чата (`app_card`): приложение берёт значения из базы
    var appCard: (@MainActor (ChatCard) -> AnyView)?

    init(
        dataProvider: (any GenUIDataProvider)? = nil,
        actionPerformer: (any GenUIActionPerformer)? = nil,
        appCard: (@MainActor (ChatCard) -> AnyView)? = nil
    ) {
        self.dataProvider = dataProvider
        self.actionPerformer = actionPerformer
        self.appCard = appCard
    }

    static let empty = GenUIEnvironment()
}

/// Выполнение действий сообщения: локальные — сразу, остальные — через
/// приложение. Пока действие идёт, его кнопка недоступна
@MainActor
@Observable
final class GenUIActionRunner {
    private(set) var running: Set<String> = []
    private(set) var outcomes: [String: GenUIActionOutcome] = [:]
    /// Последние вызовы — для отладки и тестов, без значений состояния
    private(set) var log: [String] = []

    init() {}

    func run(_ action: GenUIAction, block: String, state: GenUIState, performer: (any GenUIActionPerformer)?) async {
        switch action {
        case .set(let variable, let value):
            state.set(variable, state.evaluate(value) ?? .null)
            return
        case .reset(let variables):
            state.reset(variables)
            return
        default:
            break
        }
        guard !running.contains(block) else { return }
        log.append("\(block): \(action.kind.rawValue)")
        guard let performer else {
            outcomes[block] = .failed("Действие недоступно")
            return
        }
        running.insert(block)
        defer { running.remove(block) }
        let snapshot: GenUIStateSnapshot = if case .submit(let include, _) = action {
            state.snapshot(include: include)
        } else {
            state.snapshot()
        }
        outcomes[block] = await performer.perform(action, block: block, state: snapshot)
    }

    func clearOutcome(_ block: String) {
        outcomes[block] = nil
    }
}
