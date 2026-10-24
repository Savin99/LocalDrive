import Foundation
import SwiftUI

@MainActor
@Observable
final class BackupManager {
    private enum DefaultsKey {
        static let enabled = "encryptedBackupEnabled"
    }

    private enum AccessMode: Sendable {
        case reading
        case writing
    }

    private let vaultURL: URL
    private let explicitBackupRootURL: URL?
    private let engine = EncryptedBackupEngine()
    private var automaticTask: Task<Void, Never>?
    private var needsBackupAfterCurrentOperation = false

    private(set) var isWorking = false
    private(set) var lastBackupDate: Date?
    private(set) var lastBackupSize: Int64 = 0
    private(set) var versionCount = 0
    private(set) var summaries: [BackupSummary] = []
    private(set) var errorMessage: String?
    private(set) var storageAvailable = true

    // Состояние хранится, а не вычисляется на лету: Observation не отслеживает
    // чтения UserDefaults и Keychain, поэтому SwiftUI не узнавал об изменениях
    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: DefaultsKey.enabled)
            if !isEnabled { automaticTask?.cancel() }
        }
    }

    private(set) var hasRecoveryKey: Bool
    private(set) var hasBackupLocation: Bool
    private(set) var backupLocationName: String

    var recoveryCode: String? { RecoveryKeyStore.code() }

    init(vaultURL: URL, backupRootURL: URL? = nil) {
        self.vaultURL = vaultURL
        explicitBackupRootURL = backupRootURL
        isEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.enabled)
        hasRecoveryKey = RecoveryKeyStore.hasKey
        if backupRootURL == nil { Self.ensureDropFolderIsVisible() }
        let location = Self.locationState(explicit: backupRootURL)
        hasBackupLocation = location.available
        backupLocationName = location.name
    }

    // Папку могли положить в «Файлы» уже после запуска
    private func updateLocationState() {
        let location = Self.locationState(explicit: explicitBackupRootURL)
        hasBackupLocation = location.available
        backupLocationName = location.name
    }

    func createRecoveryCode() throws -> String {
        let code = try RecoveryKeyStore.code() ?? RecoveryKeyStore.create()
        hasRecoveryKey = true
        return code
    }

    func discardRecoveryCode() {
        RecoveryKeyStore.delete()
        hasRecoveryKey = false
    }

    func selectBackupFolder(_ url: URL) throws {
        try BackupFolderStore.save(url)
        hasBackupLocation = true
        backupLocationName = BackupFolderStore.displayName ?? url.lastPathComponent
        errorMessage = nil
        storageAvailable = true
        apply([])
    }

    func enableAndCreateFirstBackup() async {
        isEnabled = true
        await createBackup()
        if errorMessage != nil { isEnabled = false }
    }

    func refresh() async {
        updateLocationState()
        do {
            let summaries = try await withBackupRoot(mode: .reading) { [engine] root in
                try engine.listBackups(at: root)
            }
            apply(summaries)
            storageAvailable = true
            if !isWorking { errorMessage = nil }
        } catch {
            storageAvailable = false
            if isEnabled { errorMessage = error.localizedDescription }
        }
    }

    func createBackup() async {
        guard !isWorking else {
            needsBackupAfterCurrentOperation = true
            return
        }
        guard let keyData = RecoveryKeyStore.keyData() else {
            errorMessage = "Сначала сохраните код восстановления."
            return
        }
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            if needsBackupAfterCurrentOperation {
                needsBackupAfterCurrentOperation = false
                scheduleAutomaticBackup()
            }
        }

        do {
            _ = try await withBackupRoot(mode: .writing) { [engine, vaultURL] root in
                try engine.createBackup(vaultURL: vaultURL, backupRootURL: root, keyData: keyData)
            }
            let summaries = try await withBackupRoot(mode: .reading) { [engine] root in
                try engine.listBackups(at: root)
            }
            apply(summaries)
            storageAvailable = true
        } catch {
            errorMessage = error.localizedDescription
            storageAvailable = false
        }
    }

    func scheduleAutomaticBackup() {
        guard isEnabled, hasRecoveryKey else { return }
        if isWorking {
            needsBackupAfterCurrentOperation = true
            return
        }
        automaticTask?.cancel()
        automaticTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.createBackup()
        }
    }

    func restoreLatest(using recoveryCode: String) async throws -> BackupSummary {
        // Список версий мог устареть: копию могли донести в папку уже после
        // того, как экран открылся, и тогда «последней» оказывалась старая
        await refresh()
        guard let summary = summaries.first else { throw BackupEngineError.noBackups }
        return try await restore(summary, using: recoveryCode)
    }

    func restore(_ summary: BackupSummary, using recoveryCode: String) async throws -> BackupSummary {
        guard !isWorking else { throw BackupEngineError.damagedBackup }
        let keyData = try RecoveryKeyStore.keyData(from: recoveryCode)
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let restoredSummary = try await withBackupRoot(mode: .reading) { [engine, vaultURL] root in
                try engine.restore(summary, backupRootURL: root, vaultURL: vaultURL, keyData: keyData)
            }
            try RecoveryKeyStore.saveRestoredKey(keyData)
            hasRecoveryKey = true
            // Автокопии включаем только если есть куда писать: восстановление
            // из папки приложения такой папкой не является
            isEnabled = explicitBackupRootURL != nil || BackupFolderStore.hasSelection
            await refresh()
            return restoredSummary
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func deleteBackups() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await withBackupRoot(mode: .writing) { [engine] root in
                try engine.deleteAllBackups(at: root)
            }
            apply([])
            isEnabled = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Пользователь может выбрать как папку-контейнер, так и саму «LocalDrive Backups» —
    // в «Файлах» легко зайти на уровень глубже, чем ожидает приложение
    // Копию можно просто положить в «Файлы» → «На iPhone» → LocalDrive.
    // Это собственный контейнер приложения: доступ к нему не требует
    // разрешения от «Файлов» и не зависит от того, как приложение подписано
    static let localFolderName = "LocalDrive в «Файлах»"
    private static let dropHintFileName = "Куда положить копию.txt"

    private nonisolated static var documentsURL: URL? {
        try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private nonisolated static func localDropRoot() -> URL? {
        let fm = FileManager.default
        guard let documents = documentsURL,
              let items = try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)
        else { return nil }

        let backupsFolder = documents.appendingPathComponent(
            EncryptedBackupEngine.folderName,
            isDirectory: true
        )
        if fm.fileExists(atPath: backupsFolder.path) { return backupsFolder }

        // копии положили прямо в корень папки приложения
        if items.contains(where: { $0.pathExtension == EncryptedBackupEngine.packageExtension }) {
            return documents
        }

        // положили папку-контейнер, внутри которой «LocalDrive Backups»
        for item in items {
            let nested = item.appendingPathComponent(
                EncryptedBackupEngine.folderName,
                isDirectory: true
            )
            if fm.fileExists(atPath: nested.path) { return nested }
        }
        return nil
    }

    // Пустая папка Documents в «Файлах» не показывается, поэтому оставляем в ней записку
    private nonisolated static func ensureDropFolderIsVisible() {
        guard let documents = documentsURL else { return }
        let hint = documents.appendingPathComponent(dropHintFileName)
        guard !FileManager.default.fileExists(atPath: hint.path) else { return }
        let text = """
        Чтобы восстановить файлы без выбора папки, скопируйте сюда папку
        «\(EncryptedBackupEngine.folderName)» из iCloud Drive — целиком или
        только нужную версию backup-….\(EncryptedBackupEngine.packageExtension).

        Дальше откройте LocalDrive: копия найдётся сама, останется ввести
        код восстановления.
        """
        try? text.write(to: hint, atomically: true, encoding: .utf8)
    }

    private nonisolated static func locationState(explicit: URL?) -> (available: Bool, name: String) {
        if let explicit { return (true, explicit.lastPathComponent) }
        if BackupFolderStore.hasSelection {
            return (true, BackupFolderStore.displayName ?? "Выбрать папку")
        }
        if localDropRoot() != nil { return (true, localFolderName) }
        return (false, "Выбрать папку")
    }

    private nonisolated static func backupRoot(in folder: URL) throws -> URL {
        if folder.pathExtension == EncryptedBackupEngine.packageExtension {
            throw BackupFolderError.singleVersionSelected
        }
        if folder.lastPathComponent == EncryptedBackupEngine.folderName {
            return folder
        }
        return folder.appendingPathComponent(EncryptedBackupEngine.folderName, isDirectory: true)
    }

    private func apply(_ summaries: [BackupSummary]) {
        self.summaries = summaries
        lastBackupDate = summaries.first?.createdAt
        lastBackupSize = summaries.first?.encryptedBytes ?? 0
        versionCount = summaries.count
    }

    private func withBackupRoot<T: Sendable>(
        mode: AccessMode,
        operation: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        if let explicitBackupRootURL {
            return try await Task.detached {
                try operation(explicitBackupRootURL)
            }.value
        }

        guard let bookmark = BackupFolderStore.bookmarkData() else {
            // Своя папка приложения — источник ТОЛЬКО для восстановления.
            // Писать в неё нельзя: там лежит то, что положил пользователь,
            // а ротация версий (хранятся три последние) удалила бы его копии.
            // localDropRoot уже возвращает уровень, на котором лежат копии
            guard case .reading = mode, let root = Self.localDropRoot() else {
                throw BackupFolderError.notSelected
            }
            return try await Task.detached { try operation(root) }.value
        }

        return try await Task.detached {
            let selectedFolder = try BackupFolderStore.resolve(bookmark)
            guard selectedFolder.startAccessingSecurityScopedResource() else {
                throw BackupFolderError.accessDenied
            }
            defer { selectedFolder.stopAccessingSecurityScopedResource() }

            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinatorError: NSError?
            var result: Result<T, Error>?

            let coordinatedOperation: (URL) -> Void = { folder in
                result = Result {
                    let root = try BackupManager.backupRoot(in: folder)
                    if case .writing = mode {
                        try FileManager.default.createDirectory(
                            at: root,
                            withIntermediateDirectories: true
                        )
                    }
                    return try operation(root)
                }
            }

            switch mode {
            case .reading:
                coordinator.coordinate(
                    readingItemAt: selectedFolder,
                    options: [],
                    error: &coordinatorError,
                    byAccessor: coordinatedOperation
                )
            case .writing:
                coordinator.coordinate(
                    writingItemAt: selectedFolder,
                    options: .forMerging,
                    error: &coordinatorError,
                    byAccessor: coordinatedOperation
                )
            }

            if let coordinatorError { throw coordinatorError }
            guard let result else { throw BackupFolderError.accessDenied }
            return try result.get()
        }.value
    }
}
