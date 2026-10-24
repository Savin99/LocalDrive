import Foundation
import HuggingFace
import OSLog

// Скачанная модель для чата: выбор, загрузка, удаление и планировщик.
// Скачивание — единственный раз, когда приложение выходит в сеть, и только
// по кнопке на экране настроек. Дальше модель читается из папки на iPhone
@MainActor
@Observable
final class ChatModelStore {
    enum State: Equatable {
        case notInstalled
        case downloading(ChatModelChoice, fraction: Double)
        case installed(ChatModelChoice)
        case failed(String)
    }

    private(set) var state: State = .notInstalled

    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var planner: LocalModelPlanner?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log = Logger(subsystem: "com.ilyaqa.LocalDrive", category: "chat-model")

    private enum Key {
        static let choice = "chatModelChoice"
        /// Путь снимка относительно Application Support: абсолютный путь
        /// контейнера меняется при переустановке приложения
        static let snapshot = "chatModelSnapshot"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let choice = installedChoice, snapshotURL != nil {
            state = .installed(choice)
        }
    }

    /// В симуляторе MLX не работает: экран настроек объясняет это, а чат
    /// отвечает правилами
    static var runsOnThisDevice: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    var installedChoice: ChatModelChoice? {
        defaults.string(forKey: Key.choice).flatMap(ChatModelChoice.init(rawValue:))
    }

    /// Хватит ли памяти для модели прямо сейчас. nil — узнать нельзя (симулятор)
    func hasMemory(for choice: ChatModelChoice) -> Bool? {
        let available = DeviceMemory.available
        guard available > 0 else { return nil }
        return available >= choice.requiredMemoryBytes
    }

    // MARK: - Планировщик для чата

    /// Планировщик установленной модели, если она есть и может работать здесь
    var currentPlanner: (any ChatPlanning)? {
        guard Self.runsOnThisDevice, case .installed(let choice) = state, let snapshot = snapshotURL else {
            return nil
        }
        if let planner, planner.choice == choice { return planner }
        let created = LocalModelPlanner(choice: choice, snapshot: snapshot)
        planner = created
        return created
    }

    /// Приложение уходит в фон: генерация останавливается, модель выгружается
    func suspend() {
        guard let planner else { return }
        Task { await planner.suspend() }
    }

    // MARK: - Скачивание

    func download(_ choice: ChatModelChoice) {
        guard downloadTask == nil else { return }
        state = .downloading(choice, fraction: 0)
        downloadTask = Task { [weak self] in
            do {
                let root = try Self.storageRoot()
                let client = HubClient(cache: HubCache(cacheDirectory: root.appendingPathComponent("hub", isDirectory: true)))
                let snapshot = try await client.downloadSnapshot(
                    of: Repo.ID(rawValue: choice.repository) ?? "invalid/repository",
                    revision: choice.revision,
                    matching: ChatModelChoice.filePatterns,
                    progressHandler: { progress in
                        self?.state = .downloading(choice, fraction: progress.fractionCompleted)
                    }
                )
                try Task.checkCancellation()
                self?.finishDownload(choice, snapshot: snapshot)
            } catch is CancellationError {
                self?.state = self?.installedChoice.map(State.installed) ?? .notInstalled
            } catch {
                self?.log.error("модель не скачалась: \(error.localizedDescription, privacy: .public)")
                self?.state = .failed("Не удалось скачать модель: \(error.localizedDescription)")
            }
            self?.downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func finishDownload(_ choice: ChatModelChoice, snapshot: URL) {
        // Прежняя модель другого размера больше не нужна
        if let previous = installedChoice, previous != choice {
            removeFiles(of: previous)
        }
        defaults.set(choice.rawValue, forKey: Key.choice)
        defaults.set(Self.relativePath(of: snapshot), forKey: Key.snapshot)
        planner = nil
        state = .installed(choice)
    }

    func delete() {
        if let planner { Task { await planner.suspend() } }
        planner = nil
        if let choice = installedChoice { removeFiles(of: choice) }
        defaults.removeObject(forKey: Key.choice)
        defaults.removeObject(forKey: Key.snapshot)
        state = .notInstalled
    }

    // MARK: - Файлы

    /// Application Support/LLM, исключён из резервных копий: веса публичные
    /// и тяжёлые, их проще скачать заново. Не Library/Caches — её система
    /// периодически чистит
    static func storageRoot() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        var root = support.appendingPathComponent("LLM", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return root
    }

    private var snapshotURL: URL? {
        guard let relative = defaults.string(forKey: Key.snapshot),
              let support = try? FileManager.default.url(
                  for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
              ) else { return nil }
        let url = support.appendingPathComponent(relative, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) ? url : nil
    }

    static func relativePath(of url: URL) -> String {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ))?.standardizedFileURL.path ?? ""
        let path = url.standardizedFileURL.path
        guard !support.isEmpty, path.hasPrefix(support) else { return path }
        return String(path.dropFirst(support.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func removeFiles(of choice: ChatModelChoice) {
        guard let root = try? Self.storageRoot(),
              let repo = Repo.ID(rawValue: choice.repository) else { return }
        let cache = HubCache(cacheDirectory: root.appendingPathComponent("hub", isDirectory: true))
        try? FileManager.default.removeItem(at: cache.repoDirectory(repo: repo, kind: .model))
    }
}
