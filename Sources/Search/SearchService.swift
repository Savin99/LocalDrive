import Foundation
import SwiftUI

/// Документ в выдаче: живой файл хранилища и то, чем он совпал
struct SearchResult: Identifiable {
    let file: VaultFile
    let folder: VaultFolder
    /// nil — файл ещё не распознан, нашёлся по названию папки
    let documentID: Int64?
    let type: DocumentType
    /// Страница совпадения — только у многостраничных документов
    let page: Int?
    let snippet: AttributedString?
    /// Слова запроса нашлись в названии папки
    let matchedFolder: Bool

    var id: String { file.id }
}

// Связка хранилища, индекса и экрана поиска. Сам индекс живёт в акторе
// SearchIndexer, здесь — снимки папок, события и сборка выдачи
@MainActor
@Observable
final class SearchService {
    private(set) var progress = SearchIndexProgress()
    /// Модель для документов: второе чтение удостоверений по фото
    let documentModel: DocumentModelStore
    /// Облачное распознавание всех документов — по ключу владельца
    let cloud: CloudRecognitionStore
    /// Кто владелец хранилища: «мой паспорт» — его документы
    let owner: OwnerIdentity

    @ObservationIgnored private let store: VaultStore
    @ObservationIgnored private let indexer: SearchIndexer
    @ObservationIgnored private let commands: AsyncStream<Command>.Continuation
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?

    private enum Command: Sendable {
        case update([IndexableFolder])
        case change(VaultChange)
        case suspend
        case resume
        case reader((any DocumentReading)?)
        case cloudReader((any CloudReading)?)
        case barrier(CheckedContinuation<Void, Never>)
    }

    nonisolated static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SearchIndex", isDirectory: true)
            .appendingPathComponent("index.sqlite")
    }

    /// `databaseURL == nil` — индекс в памяти, для тестов. `reader` и
    /// `pageImage` подменяют модель и кадр страницы в тестах
    init(
        store: VaultStore,
        databaseURL: URL? = SearchService.defaultDatabaseURL,
        documentModel: DocumentModelStore? = nil,
        reader: (any DocumentReading)? = nil,
        pageImage: @escaping @Sendable (URL) -> PageImage? = DocumentPageImage.load,
        cloud: CloudRecognitionStore? = nil,
        cloudReader: (any CloudReading)? = nil,
        cloudPages: @escaping @Sendable (URL) -> [CloudPage]? = CloudPageImages.pages,
        owner: OwnerIdentity? = nil
    ) {
        self.store = store
        // Индекс в памяти — тесты: владелец тоже только в памяти
        self.owner = owner ?? OwnerIdentity(fileURL: databaseURL == nil ? nil : OwnerIdentity.defaultURL)
        let documentModel = documentModel ?? DocumentModelStore()
        self.documentModel = documentModel
        let cloud = cloud ?? CloudRecognitionStore()
        self.cloud = cloud
        let indexer = SearchIndexer(databaseURL: databaseURL, pageImage: pageImage, cloudPages: cloudPages)
        self.indexer = indexer

        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        commands = continuation
        // Команды доходят до индекса строго по порядку: иначе сверка, снятая
        // до скрытия папки, могла бы выполниться после него и вернуть папку в индекс
        Task.detached(priority: .utility) {
            for await command in stream {
                switch command {
                case .update(let folders): await indexer.update(folders: folders)
                case .change(let change): await indexer.apply(change)
                case .suspend: await indexer.suspend()
                case .resume: await indexer.resume()
                case .reader(let reader): await indexer.useReader(reader)
                case .cloudReader(let reader): await indexer.useCloudReader(reader)
                case .barrier(let waiter): waiter.resume()
                }
            }
        }
        Task { [weak self] in
            for await progress in indexer.progressUpdates {
                self?.progress = progress
            }
        }
        store.onChange = { [weak self] change in
            self?.commands.yield(.change(change))
        }
        // Модель скачали или удалили — индекс начинает или прекращает второе чтение
        // Облако: включено ли и есть ли ключ — решают настройки владельца
        if let cloudReader {
            useCloudReader(cloudReader)
        } else {
            useCloudReader(cloud.currentReader)
            cloud.onReaderChange = { [weak self] reader in
                self?.useCloudReader(reader)
            }
        }
        if let reader {
            useDocumentReader(reader)
        } else if DocumentReaderFeature.isEnabled {
            useDocumentReader(documentModel.currentReader)
            documentModel.onReaderChange = { [weak self] reader in
                self?.useDocumentReader(reader)
            }
        }
    }

    /// Подключить или отключить второе чтение. Тесты подключают подделку модели
    func useDocumentReader(_ reader: (any DocumentReading)?) {
        commands.yield(.reader(reader))
    }

    /// Подключить или отключить облачное распознавание
    func useCloudReader(_ reader: (any CloudReading)?) {
        commands.yield(.cloudReader(reader))
    }

    /// Папки, из которых разрешено искать: поиск включён и папка не суперскрытая
    var searchableFolders: [VaultFolder] {
        store.folders.filter(\.isIndexable)
    }

    // MARK: - Индексация

    /// Сверить индекс с хранилищем прямо сейчас
    func reconcile() {
        reconcileTask?.cancel()
        reconcileTask = nil
        let snapshot = searchableFolders.map { IndexableFolder(id: $0.id, url: store.folderURL($0)) }
        commands.yield(.update(snapshot))
    }

    /// После импорта, удаления или восстановления. Серия изменений подряд
    /// сводится к одной сверке, а снимок папок снимается в момент отправки
    func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    func suspend() {
        commands.yield(.suspend)
        // В фоне iOS отклоняет работу GPU: модель останавливается и выгружается
        documentModel.suspend()
    }

    func resume() {
        commands.yield(.resume)
    }

    /// Дождаться, пока индекс отработает все команды и очередь. Для тестов
    func waitUntilIdle() async {
        await withCheckedContinuation { waiter in
            commands.yield(.barrier(waiter))
        }
        await indexer.waitUntilIdle()
        // Ход работы приходит потоком: последний может быть ещё в пути
        let latest = await indexer.lastProgress
        for _ in 0..<200 where progress != latest {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Содержимое индекса без фильтра по папкам — для проверок приватности
    func indexedFiles() async -> [FileKey] {
        await indexer.indexedFiles()
    }

    func rowCounts() async -> SearchIndexStore.RowCounts? {
        await indexer.rowCounts()
    }

    /// Распознан ли файл в облаке — для «Сведений»
    func cloudState(for file: VaultFile, in folder: VaultFolder) async -> CloudReadState? {
        guard folder.isIndexable else { return nil }
        return await indexer.cloudState(folderID: folder.id, fileName: file.name)
    }

    /// Прочитала ли модель для документов этот файл — для «Сведений»
    func modelState(for file: VaultFile, in folder: VaultFolder) async -> ModelReadState? {
        guard folder.isIndexable else { return nil }
        return await indexer.modelState(folderID: folder.id, fileName: file.name)
    }

    /// Какая модель прочитала документ — для проверок
    func modelRevision(documentID: Int64) async -> String? {
        await indexer.modelRevision(documentID: documentID)
    }

    // MARK: - Поиск

    func search(_ text: String, limit: Int = 50) async -> [SearchResult] {
        let query = SearchQuery(text)
        guard !query.isEmpty else { return [] }
        let hits = await indexer.search(query, in: Set(searchableFolders.map(\.id)))

        // Папки перечитываются после ожидания: если какую-то скрыли, пока
        // шёл запрос, её документы в выдачу уже не попадут
        let folders = searchableFolders
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })

        // Два списка — совпадения в тексте и файлы папок с подходящим
        // названием — объединяются по рангу (Reciprocal Rank Fusion)
        var ranked: [FileKey: (score: Double, order: Int)] = [:]
        var hitsByKey: [FileKey: SearchHit] = [:]
        func add(_ key: FileKey, rank: Int) {
            let score = 1 / (Self.rrfK + Double(rank))
            if let existing = ranked[key] {
                ranked[key] = (existing.score + score, existing.order)
            } else {
                ranked[key] = (score, ranked.count)
            }
        }
        for (offset, hit) in hits.enumerated() where byID[hit.folderID] != nil {
            hitsByKey[hit.key] = hit
            add(hit.key, rank: offset + 1)
        }
        var folderRank = 0
        let matchedFolders = Set(folders.filter { folder in
            SearchText.tokens(in: folder.name).contains(where: query.matches)
        }.map(\.id))
        for folder in folders where matchedFolders.contains(folder.id) {
            for file in store.files(in: folder) {
                folderRank += 1
                add(FileKey(folderID: folder.id, name: file.name), rank: folderRank)
            }
        }

        let ordered = ranked.sorted { lhs, rhs in
            lhs.value.score != rhs.value.score ? lhs.value.score > rhs.value.score : lhs.value.order < rhs.value.order
        }
        return ordered.prefix(limit).compactMap { key, _ in
            guard let folder = byID[key.folderID],
                  let file = store.file(named: key.name, in: folder) else { return nil }
            let hit = hitsByKey[key]
            return SearchResult(
                file: file,
                folder: folder,
                documentID: hit?.documentID,
                type: hit?.type ?? .other,
                page: (hit?.pageCount ?? 0) > 1 ? hit?.page : nil,
                snippet: hit?.snippet,
                matchedFolder: matchedFolders.contains(folder.id)
            )
        }
    }

    /// Константа RRF из исходной статьи: сглаживает разницу между первыми местами
    private static let rrfK = 60.0

    // MARK: - Документы для чата

    private var allowedFolderIDs: Set<UUID> { Set(searchableFolders.map(\.id)) }

    func documents(ofTypes types: [DocumentType]) async -> [StoredDocument] {
        await indexer.documents(types: types, in: allowedFolderIDs)
    }

    func documents(ids: [Int64]) async -> [StoredDocument] {
        await indexer.documents(ids: ids, in: allowedFolderIDs)
    }

    func fields(for ids: [Int64]) async -> [Int64: [DocumentField]] {
        await indexer.fields(documentIDs: ids, in: allowedFolderIDs)
    }

    func setManualField(documentID: Int64, key: String, value: String) async {
        await indexer.setManualField(documentID: documentID, key: key, value: value, in: allowedFolderIDs)
    }

    func verifyField(documentID: Int64, key: String) async {
        await indexer.verifyField(documentID: documentID, key: key, in: allowedFolderIDs)
    }

    /// Файлы папки — только доступной для поиска: облачному чату другие не видны
    func files(in folder: VaultFolder) -> [VaultFile] {
        guard searchableFolders.contains(where: { $0.id == folder.id }) else { return [] }
        return store.files(in: folder)
    }

    /// Метаданные документов от облачного распознавания — только из папок,
    /// доступных для поиска
    func metadata(for ids: [Int64]) async -> [Int64: DocumentMetadata] {
        await indexer.metadata(documentIDs: ids, in: allowedFolderIDs)
    }

    /// Метаданные файла — для «Сведений»
    func metadata(for file: VaultFile, in folder: VaultFolder) async -> DocumentMetadata? {
        guard folder.isIndexable else { return nil }
        return await indexer.metadata(folderID: folder.id, fileName: file.name)
    }

    /// Опись документов для облачного чата — строка на документ: id, вид,
    /// название, владелец (фамилия и инициалы), папка. Номеров нет: цифры
    /// длиннее трёх закрываются. Только папки, доступные для поиска; не больше
    /// `limit` строк в порядке id — префикс запроса не меняется без причины,
    /// и кэш облака работает. С описью поиск своего документа — один раунд
    func chatDocumentIndex(limit: Int = 200) async -> String {
        let folders = Dictionary(uniqueKeysWithValues: searchableFolders.map { ($0.id, $0) })
        let documents = await documents(ofTypes: DocumentType.allCases).sorted { $0.id < $1.id }.prefix(limit)
        let ids = documents.map(\.id)
        let fields = await fields(for: ids)
        let metadata = await metadata(for: ids)
        return documents.compactMap { document -> String? in
            guard let folder = folders[document.folderID] else { return nil }
            let owner = fields[document.id]?.first { $0.key == FieldKey.fullName }?.value ?? ""
            let meta = metadata[document.id]
            let kind = [document.type.rawValue, meta?.kind.nilIfEmpty].compactMap { $0 }.joined(separator: "/")
            var line = [
                ChatCard.encodeID(document.id), kind, Self.withoutNumbers(meta?.title.nilIfEmpty ?? document.fileName),
                owner.isEmpty ? "—" : ChatRouter.shortName(owner), Self.withoutNumbers(folder.name),
            ].joined(separator: " · ")
            // Срок — только записанный в документе: «когда истекает» модель
            // отвечает текстом сразу. Срок паспорта РФ выводится из даты
            // рождения — его в описи нет
            let values = fields[document.id] ?? []
            if let until = values.first(where: { $0.key == FieldKey.expiryDate })?.value.nilIfEmpty ?? meta?.validUntil.nilIfEmpty,
               DocumentReadingMerge.date(until) != nil {
                line += " · до \(until)"
            }
            return line
        }.joined(separator: "\n")
    }

    private static func withoutNumbers(_ text: String) -> String {
        text.replacingOccurrences(of: #"\d{4,}"#, with: "…", options: .regularExpression)
    }

    /// Текст первой страницы документа из индекса — для облачного чата
    func documentText(id: Int64) async -> String? {
        await indexer.documentText(documentID: id, in: allowedFolderIDs)
    }

    /// Люди из личных документов: полные имена, по одному на человека —
    /// кириллицей, если есть паспорт РФ. Для «Это я» и «я Илья»
    func peopleNames() async -> [String] {
        let documents = await documents(ofTypes: DocumentType.allCases.filter(\.isPersonal))
        let fields = await fields(for: documents.map(\.id))
        var byKey: [String: String] = [:]
        for document in documents {
            guard let name = fields[document.id]?.first(where: { $0.key == FieldKey.fullName })?.value, !name.isEmpty else { continue }
            let key = ChatRouter.personKey(name)
            let cyrillic = name.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
            if byKey[key] == nil || cyrillic { byKey[key] = name }
        }
        return byKey.values.sorted()
    }

    /// Файл документа на диске — для страниц картинками (view_document)
    func fileURL(for document: StoredDocument) -> URL? {
        guard let live = file(for: document) else { return nil }
        return store.folderURL(live.folder).appendingPathComponent(live.file.name)
    }

    /// Живой файл хранилища для документа индекса
    func file(for document: StoredDocument) -> (file: VaultFile, folder: VaultFolder)? {
        guard let folder = store.folder(by: document.folderID), folder.isIndexable,
              let file = store.file(named: document.fileName, in: folder) else { return nil }
        return (file, folder)
    }
}
