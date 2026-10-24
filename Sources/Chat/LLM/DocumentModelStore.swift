import Foundation
import HuggingFace
import OSLog

// Скачанные модели для документов: загрузка, удаление и читатель для индекса.
// Моделей две — 4B и облегчённая 2B, читает та, что помещается в память.
// Как и модель чата, скачиваются один раз и только по кнопке в настройках
@MainActor
@Observable
final class DocumentModelStore {
    enum State: Equatable {
        case notInstalled
        case downloading(fraction: Double)
        case installed
        case failed(String)
    }

    private(set) var states: [DocumentModelChoice: State] = [:]

    /// Читатель появился, пропал или сменилась модель: индекс начинает,
    /// прекращает или продолжает второе чтение другой моделью
    @ObservationIgnored var onReaderChange: ((any DocumentReading)?) -> Void = { _ in }

    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var reader: LocalDocumentReader?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log = Logger(subsystem: "com.ilyaqa.LocalDrive", category: "document-model")

    private enum Key {
        static func revision(_ choice: DocumentModelChoice) -> String { "documentModelRevision.\(choice.rawValue)" }
        /// Путь снимка относительно Application Support: абсолютный путь
        /// контейнера меняется при переустановке приложения
        static func snapshot(_ choice: DocumentModelChoice) -> String { "documentModelSnapshot.\(choice.rawValue)" }
        /// Сборка 7 знала одну модель — 4B — и хранила её без суффикса
        static let legacyRevision = "documentModelRevision"
        static let legacySnapshot = "documentModelSnapshot"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let snapshot = defaults.string(forKey: Key.legacySnapshot),
           defaults.string(forKey: Key.legacyRevision) == DocumentModelChoice.standard.revision {
            defaults.set(DocumentModelChoice.standard.revision, forKey: Key.revision(.standard))
            defaults.set(snapshot, forKey: Key.snapshot(.standard))
        }
        defaults.removeObject(forKey: Key.legacyRevision)
        defaults.removeObject(forKey: Key.legacySnapshot)
        for choice in DocumentModelChoice.allCases {
            states[choice] = snapshotURL(choice) == nil ? .notInstalled : .installed
        }
    }

    func state(_ choice: DocumentModelChoice) -> State {
        states[choice] ?? .notInstalled
    }

    var installed: Set<DocumentModelChoice> {
        Set(DocumentModelChoice.allCases.filter { state($0) == .installed })
    }

    /// Модель, которой индекс читает документы сейчас
    var activeChoice: DocumentModelChoice? {
        DocumentModelChoice.best(installed: installed, available: DeviceMemory.available)
    }

    var isDownloading: Bool { downloadTask != nil }

    /// Читатель модели, которая помещается в память, — 4B, если помещается.
    /// Не помещается ни одна — читатель самой лёгкой: индекс покажет, что не
    /// хватает памяти
    var currentReader: (any DocumentReading)? {
        guard DocumentReaderFeature.isEnabled, ChatModelStore.runsOnThisDevice,
              let choice = activeChoice, let snapshot = snapshotURL(choice) else { return nil }
        if let reader, reader.choice == choice { return reader }
        if let reader { Task { await reader.suspend() } }
        let created = LocalDocumentReader(choice: choice, snapshot: snapshot)
        reader = created
        return created
    }

    /// Хватит ли памяти этой модели прямо сейчас. nil — узнать нельзя (симулятор)
    func fits(_ choice: DocumentModelChoice) -> Bool? {
        let available = DeviceMemory.available
        guard available > 0 else { return nil }
        return available >= choice.requiredMemoryBytes
    }

    /// Приложение уходит в фон: чтение останавливается, модель выгружается
    func suspend() {
        guard let reader else { return }
        Task { await reader.suspend() }
    }

    // MARK: - Скачивание

    func download(_ choice: DocumentModelChoice) {
        guard downloadTask == nil else { return }
        states[choice] = .downloading(fraction: 0)
        downloadTask = Task { [weak self] in
            do {
                let root = try ChatModelStore.storageRoot()
                let client = HubClient(cache: HubCache(cacheDirectory: root.appendingPathComponent("hub", isDirectory: true)))
                let snapshot = try await client.downloadSnapshot(
                    of: Repo.ID(rawValue: choice.repository) ?? "invalid/repository",
                    revision: choice.revision,
                    matching: ChatModelChoice.filePatterns,
                    progressHandler: { progress in
                        self?.states[choice] = .downloading(fraction: progress.fractionCompleted)
                    }
                )
                try Task.checkCancellation()
                self?.finishDownload(choice, snapshot: snapshot)
            } catch is CancellationError {
                self?.states[choice] = self?.snapshotURL(choice) == nil ? .notInstalled : .installed
            } catch {
                self?.log.error("модель для документов не скачалась: \(error.localizedDescription, privacy: .public)")
                self?.states[choice] = .failed("Не удалось скачать модель: \(error.localizedDescription)")
            }
            self?.downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func finishDownload(_ choice: DocumentModelChoice, snapshot: URL) {
        defaults.set(choice.revision, forKey: Key.revision(choice))
        defaults.set(ChatModelStore.relativePath(of: snapshot), forKey: Key.snapshot(choice))
        states[choice] = .installed
        onReaderChange(currentReader)
    }

    func delete(_ choice: DocumentModelChoice) {
        if let reader, reader.choice == choice {
            Task { await reader.suspend() }
            self.reader = nil
        }
        removeFiles(choice)
        defaults.removeObject(forKey: Key.revision(choice))
        defaults.removeObject(forKey: Key.snapshot(choice))
        states[choice] = .notInstalled
        onReaderChange(currentReader)
    }

    // MARK: - Файлы

    private func snapshotURL(_ choice: DocumentModelChoice) -> URL? {
        guard defaults.string(forKey: Key.revision(choice)) == choice.revision,
              let relative = defaults.string(forKey: Key.snapshot(choice)),
              let support = try? FileManager.default.url(
                  for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
              ) else { return nil }
        let url = support.appendingPathComponent(relative, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) ? url : nil
    }

    private func removeFiles(_ choice: DocumentModelChoice) {
        guard let root = try? ChatModelStore.storageRoot(),
              let repo = Repo.ID(rawValue: choice.repository) else { return }
        let cache = HubCache(cacheDirectory: root.appendingPathComponent("hub", isDirectory: true))
        try? FileManager.default.removeItem(at: cache.repoDirectory(repo: repo, kind: .model))
    }
}
