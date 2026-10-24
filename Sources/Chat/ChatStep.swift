import Foundation

/// Шаг ответа, который видно в чате, пока он работает: что понял, кого
/// перебирает, что ищет, какой документ открыл. Владелец 24.10.2026: «чтобы
/// было видно, что он ищет, смотрит, перебирает людей — по-настоящему, а не для
/// галочки». Поэтому шаг ставит только тот код, который это действие и делает:
/// роутер, модель на iPhone, инструменты облака
struct ChatStep: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        /// Разбор вопроса: вид документа, поля, имя
        case understand
        /// Перебор людей из документов
        case people
        /// Поиск по тексту документов
        case search
        /// Открыл документ: поля из базы
        case open
        /// Смотрит страницы документа картинками
        case look
        case folders
        case files
        /// Модель на iPhone или облако думает
        case think
        case expiry
        /// Готовит предложение разложить файлы
        case propose
    }

    let id = UUID()
    var kind: Kind
    var text: String
    var startedAt = Date()
    var finishedAt: Date?

    var symbol: String {
        switch kind {
        case .understand: "text.magnifyingglass"
        case .people: "person.2"
        case .search: "magnifyingglass"
        case .open: "doc.text"
        case .look: "eye"
        case .folders: "folder"
        case .files: "doc.on.doc"
        case .think: "sparkles"
        case .expiry: "calendar.badge.clock"
        case .propose: "tray.and.arrow.down"
        }
    }

    var isRunning: Bool { finishedAt == nil }
}

/// Куда роутер и инструменты сообщают о шагах. nil — никто не смотрит (тесты)
typealias ChatStepSink = @MainActor (ChatStep.Kind, String) -> Void

extension ChatIntent {
    /// «Ищу: дата рождения · Ольга» — что чат понял из вопроса, словами
    /// человека. Пусто — понять нечего, тогда это поиск по тексту
    var summary: String {
        var parts: [String] = []
        if !types.isEmpty {
            var seen = Set<String>()
            let titles = types
                .map { $0 == .passportIntl && countries.count == 1 ? $0.title(country: countries.first) : $0.title }
                .filter { seen.insert($0).inserted }
            parts.append(titles.joined(separator: " или "))
        }
        if wantsAllFields { parts.append("все данные") }
        if wantsFile { parts.append("файл") }
        parts += fieldKeys.map { FieldKey.title($0).lowercased() }
        if wantsExpiry { parts.append("срок действия") }
        if wantsAddress { parts.append("адрес регистрации") }
        let name = nameWords.map(\.capitalized).joined(separator: " ")
        if !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " · ")
    }
}
