import Foundation

/// Кто владелец хранилища: «мой паспорт» — его документы. Чат не угадывает
/// владельца по документам: человек говорит сам («я Илья», выбор чипа после
/// «мой паспорт») или выбирает в настройках. Хранится файлом с защитой
/// `complete`, вне резервных копий — не в UserDefaults. Наружу уходит только
/// строка «Владелец хранилища: Савин И. А.» в инструкции облачного чата
@MainActor
@Observable
final class OwnerIdentity {
    struct Owner: Codable, Equatable, Sendable {
        /// Ключ человека латиницей по ИКАО: «savin ilia» — один у паспорта РФ и загранпаспорта
        let key: String
        /// «Савин И. А.»
        let name: String
    }

    private(set) var owner: Owner?
    @ObservationIgnored private let fileURL: URL?

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Owner", isDirectory: true)
            .appendingPathComponent("owner.json")
    }

    /// `fileURL == nil` — только в памяти, для тестов
    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            owner = try? JSONDecoder().decode(Owner.self, from: data)
        }
    }

    /// Владелец — человек с этим полным именем, как в документе
    func set(fullName: String) {
        let key = ChatRouter.personKey(fullName)
        guard !key.isEmpty else { return }
        owner = Owner(key: key, name: ChatRouter.shortName(fullName))
        save()
    }

    func clear() {
        owner = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Документ этого человека — тот же ключ имени
    func owns(fullName: String) -> Bool {
        guard let owner, !fullName.isEmpty else { return false }
        return ChatRouter.personKey(fullName) == owner.key
    }

    private func save() {
        guard let fileURL, let owner, let data = try? JSONEncoder().encode(owner) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }
}

/// Предложение запомнить владельца: чип «Запомнить: это я — Савин И. А.»
struct OwnerSuggestion: Equatable, Sendable {
    let fullName: String
    /// «Савин И. А.»
    let name: String
}
