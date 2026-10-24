import Foundation

enum BackupFolderError: LocalizedError {
    case notSelected
    case accessDenied
    case invalidBookmark
    case singleVersionSelected

    var errorDescription: String? {
        switch self {
        case .notSelected:
            "Выберите папку для резервных копий в приложении «Файлы»."
        case .accessDenied:
            "LocalDrive больше не имеет доступа к выбранной папке. Выберите её заново."
        case .invalidBookmark:
            "Сохранённая папка резервных копий недоступна. Выберите её заново."
        case .singleVersionSelected:
            "Выбрана одна резервная копия. Выберите папку «\(EncryptedBackupEngine.folderName)» или ту, в которой она лежит."
        }
    }
}

enum BackupFolderStore {
    private enum DefaultsKey {
        static let bookmark = "encryptedBackupFolderBookmark"
        static let displayName = "encryptedBackupFolderDisplayName"
    }

    static var hasSelection: Bool {
        UserDefaults.standard.data(forKey: DefaultsKey.bookmark) != nil
    }

    static var displayName: String? {
        UserDefaults.standard.string(forKey: DefaultsKey.displayName)
    }

    static func save(_ url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let bookmark = try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: DefaultsKey.bookmark)
        UserDefaults.standard.set(url.lastPathComponent, forKey: DefaultsKey.displayName)
    }

    static func bookmarkData() -> Data? {
        UserDefaults.standard.data(forKey: DefaultsKey.bookmark)
    }

    static func resolve(_ bookmark: Data) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else { throw BackupFolderError.invalidBookmark }
        return url
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.bookmark)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.displayName)
    }
}
