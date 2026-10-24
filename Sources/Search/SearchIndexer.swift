import Foundation
import OSLog
import SQLite3

/// Папка, которую разрешено индексировать: снимок из VaultStore
struct IndexableFolder: Hashable, Sendable {
    let id: UUID
    let url: URL
}

/// Файл на диске и его отпечаток: по нему видно, что файл заменили
struct DiskFile: Hashable, Sendable {
    let folderID: UUID
    let name: String
    let size: Int64
    let modified: Double

    var key: FileKey { FileKey(folderID: folderID, name: name) }
}

struct FileKey: Hashable, Sendable {
    let folderID: UUID
    let name: String
}

// Индексирует папки хранилища в фоне: по одному файлу, с низким приоритетом.
// Все обращения к базе идут через этот актор, поэтому соединение SQLite
// никогда не используется из двух потоков сразу
actor SearchIndexer {
    /// Версия разбора текста и полей. Когда она растёт, документы
    /// перечитываются в фоне, а ручные правки полей сохраняются.
    /// 2 — поля паспортов и тип документа;
    /// 3 — имя из MRZ сверяется со страницей, паспорта других стран.
    /// Осторожно: рост версии сбрасывает и облачные отметки — включённое облако
    /// заново отправит все фото (деньги и повторная отправка паспортов). Сначала
    /// нужен кэш облачного ответа по неизменённому файлу
    static let indexVersion = 3
    /// Длина фрагмента: по нему считается bm25 и строится подсветка
    static let chunkLength = 1500

    private let databaseURL: URL?
    private var store: SearchIndexStore?
    /// Папки, которые сейчас разрешено индексировать
    private var folders: [UUID: IndexableFolder] = [:]
    private var queue: [DiskFile] = []
    private var current: DiskFile?
    private var worker: Task<Void, Never>?
    private var isSuspended = false
    /// Файлы, из которых текст не достался, пробуем снова один раз за запуск
    private var retriedFailures = false

    /// Второе чтение удостоверений моделью «текст + картинка». nil — модель
    /// не скачана или не работает на этом устройстве
    private var reader: (any DocumentReading)?
    /// Кадр страницы для модели: фото или первая страница PDF
    private let pageImage: @Sendable (URL) -> PageImage?
    private var modelWorker: Task<Void, Never>?
    private var modelQueue: [ModelReadCandidate] = []
    private var modelCurrent: ModelReadCandidate?
    /// Модель отказалась работать — до возвращения приложения на экран не зовём
    private var modelUnavailable: String?

    /// Виды документов, на которых промпт и грамматика модели проверены
    /// стендом (docs/doc-reader.md). СНИЛС и ИНН там не было
    static let modelReadableTypes: [DocumentType] = [.passportRU, .passportIntl, .driverLicense]
    /// Кандидаты: удостоверения и «другое», если текст похож на удостоверение
    private static let modelCandidateTypes = modelReadableTypes + [.other]

    /// Облачное распознавание всех документов. Пока оно включено, локальная
    /// модель не читает: облако сильнее
    private var cloudReader: (any CloudReading)?
    private let cloudPages: @Sendable (URL) -> [CloudPage]?
    private var cloudWorker: Task<Void, Never>?
    private var cloudQueue: [ModelReadCandidate] = []
    private var cloudCurrent: ModelReadCandidate?
    /// Облако остановилось: нет VPN, ключ не подходит, перегружено
    private var cloudPaused: CloudFailure?

    /// Ход индексации для экрана. Хранится только последнее значение
    nonisolated let progressUpdates: AsyncStream<SearchIndexProgress>
    /// Последний отправленный ход работы — чтобы дождаться его на экране
    private(set) var lastProgress = SearchIndexProgress()
    private let progressContinuation: AsyncStream<SearchIndexProgress>.Continuation

    private let log = Logger(subsystem: "com.ilyaqa.LocalDrive", category: "search-index")

    /// `databaseURL == nil` — база в памяти, для тестов
    init(
        databaseURL: URL?,
        pageImage: @escaping @Sendable (URL) -> PageImage? = DocumentPageImage.load,
        cloudPages: @escaping @Sendable (URL) -> [CloudPage]? = CloudPageImages.pages
    ) {
        self.databaseURL = databaseURL
        self.pageImage = pageImage
        self.cloudPages = cloudPages
        (progressUpdates, progressContinuation) = AsyncStream.makeStream(
            of: SearchIndexProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    func apply(_ change: VaultChange) {
        switch change {
        case .folderExcluded(let id):
            exclude(folder: id)
        case .fileRemoved(let folder, let name):
            remove(folder: folder, fileName: name)
        case .fileRenamed(let folder, let oldName, let newName):
            rename(folder: folder, from: oldName, to: newName)
        case .fileMoved(let source, let name, let destination, let newName):
            move(from: source, name: name, to: destination, newName: newName)
        }
    }

    // MARK: - Сверка

    /// Индекс приводится к тому, что лежит на диске: лишнее удаляется,
    /// новое и изменённое встаёт в очередь
    func update(folders snapshot: [IndexableFolder]) {
        folders = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        queue.removeAll { folders[$0.folderID] == nil }
        guard let store = openStore() else { return }

        do {
            try store.deleteFolders(except: Set(folders.keys))
            let disk = scan(snapshot)
            var indexed = Set<FileKey>()
            for state in try store.fileStates() {
                let key = FileKey(folderID: state.folderID, name: state.fileName)
                // Папку не удалось прочитать — ничего не удаляем, сверим позже
                guard let listing = disk[state.folderID] else { continue }
                guard let file = listing[state.fileName] else {
                    try store.deleteDocument(folderID: state.folderID, fileName: state.fileName)
                    continue
                }
                indexed.insert(key)
                let changed = file.size != state.fileSize || abs(file.modified - state.fileModified) > 0.001
                let outdated = state.indexVersion < Self.indexVersion
                let retry = state.failed && !retriedFailures
                if changed || outdated || retry { enqueue(file) }
            }
            for file in disk.values.flatMap(\.values) where !indexed.contains(file.key) {
                enqueue(file)
            }
            retriedFailures = true
        } catch {
            handle(error)
        }
        report()
        startWorker()
        startCloudWorker()
        startModelWorker()
    }

    /// Папку скрыли, убрали из поиска или удалили: всё извлечённое из неё
    /// стирается сразу, а не при следующей сверке
    func exclude(folder id: UUID) {
        folders[id] = nil
        queue.removeAll { $0.folderID == id }
        modelQueue.removeAll { $0.folderID == id }
        cloudQueue.removeAll { $0.folderID == id }
        do {
            try openStore()?.deleteFolder(id)
        } catch {
            handle(error)
        }
        report()
    }

    func remove(folder id: UUID, fileName: String) {
        queue.removeAll { $0.key == FileKey(folderID: id, name: fileName) }
        modelQueue.removeAll { $0.folderID == id && $0.fileName == fileName }
        cloudQueue.removeAll { $0.folderID == id && $0.fileName == fileName }
        do {
            try openStore()?.deleteDocument(folderID: id, fileName: fileName)
        } catch {
            handle(error)
        }
        report()
    }

    /// Текст файла не изменился — достаточно поправить имя, без нового OCR
    func rename(folder id: UUID, from oldName: String, to newName: String) {
        guard folders[id] != nil else { return }
        // В очереди модели осталось старое имя — документ вернётся при следующем наборе
        modelQueue.removeAll { $0.folderID == id && $0.fileName == oldName }
        cloudQueue.removeAll { $0.folderID == id && $0.fileName == oldName }
        let title = Self.chunk(page: 0, text: SearchText.title(fromFileName: newName))
        do {
            try openStore()?.renameDocument(folderID: id, from: oldName, to: newName, title: title)
        } catch {
            handle(error)
        }
        if let index = queue.firstIndex(where: { $0.key == FileKey(folderID: id, name: oldName) }) {
            let old = queue[index]
            queue[index] = DiskFile(folderID: id, name: newName, size: old.size, modified: old.modified)
        }
    }

    /// Файл перенесли в другую папку. Текст и поля те же, поэтому документ
    /// переезжает целиком — с ручными исправлениями и без нового распознавания.
    /// Папка назначения вне поиска — всё извлечённое из файла стирается сразу,
    /// как при скрытии папки. Если о папке назначения актор ещё не знает (её
    /// только что создали), документ тоже стирается: сверка распознает файл заново
    func move(from source: UUID, name: String, to destination: UUID, newName: String) {
        let oldKey = FileKey(folderID: source, name: name)
        let waiting = queue.first { $0.key == oldKey }
        queue.removeAll { $0.key == oldKey }
        modelQueue.removeAll { $0.folderID == source && $0.fileName == name }
        cloudQueue.removeAll { $0.folderID == source && $0.fileName == name }

        guard folders[destination] != nil else {
            do {
                if try openStore()?.deleteDocument(folderID: source, fileName: name) == true {
                    // Удалённые слова остаются в сегментах FTS до слияния
                    try openStore()?.compact()
                }
            } catch {
                handle(error)
            }
            report()
            return
        }

        let title = Self.chunk(page: 0, text: SearchText.title(fromFileName: newName))
        do {
            try openStore()?.moveDocument(
                folderID: source,
                fileName: name,
                toFolder: destination,
                newName: newName,
                title: title
            )
        } catch {
            handle(error)
        }
        // Файл ещё ждал распознавания — теперь ждёт его в новой папке
        if let waiting {
            enqueue(DiskFile(folderID: destination, name: newName, size: waiting.size, modified: waiting.modified))
            startWorker()
        }
        report()
    }

    // MARK: - Фон

    /// Приложение уходит в фон: на заблокированном iPhone база недоступна
    func suspend() {
        isSuspended = true
        // База в памяти живёт, пока открыта, поэтому закрываем только файл
        if databaseURL != nil, current == nil, modelCurrent == nil, cloudCurrent == nil {
            store?.close()
            store = nil
        }
    }

    func resume() {
        isSuspended = false
        // Памяти могло стать больше: модель попробует снова
        modelUnavailable = nil
        // Сеть могла смениться: VPN включили, облако разгрузилось. Неверный
        // ключ и имя модели ждут смены настроек
        if let paused = cloudPaused, paused != .keyRejected, paused != .modelNotFound { cloudPaused = nil }
        startWorker()
        startCloudWorker()
        startModelWorker()
    }

    /// Дождаться, пока обе очереди опустеют. Для тестов
    func waitUntilIdle() async {
        while worker != nil || modelWorker != nil || cloudWorker != nil {
            if let worker { await worker.value }
            if let cloudWorker { await cloudWorker.value }
            if let modelWorker { await modelWorker.value }
        }
    }

    private func enqueue(_ file: DiskFile) {
        if let index = queue.firstIndex(where: { $0.key == file.key }) {
            queue[index] = file
        } else {
            queue.append(file)
        }
    }

    private func startWorker() {
        guard worker == nil, !isSuspended, !queue.isEmpty else { return }
        worker = Task(priority: .utility) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !isSuspended, !queue.isEmpty {
            let file = queue.removeFirst()
            current = file
            await index(file)
            current = nil
            report()
        }
        worker = nil
        if isSuspended, databaseURL != nil, modelCurrent == nil, cloudCurrent == nil {
            store?.close()
            store = nil
        }
        // Распознавание закончилось — очередь облака или модели
        startCloudWorker()
        startModelWorker()
    }

    // MARK: - Второе чтение моделью

    // Удостоверение, у которого правила не подтвердили ключевые поля, модель
    // читает по фото. Сначала распознаётся всё новое: модель медленная (секунды
    // на кадр) и ждёт, пока очередь Vision опустеет. Только пока приложение на
    // экране — в фоне iOS не даёт GPU. Суперскрытые и убранные из поиска папки
    // сюда не попадают: кандидаты берутся только из разрешённых папок

    func useReader(_ reader: (any DocumentReading)?) {
        self.reader = reader
        modelUnavailable = nil
        if reader == nil {
            modelQueue = []
            modelWorker?.cancel()
        }
        report()
        startModelWorker()
    }

    private func startModelWorker() {
        guard modelWorker == nil, worker == nil, queue.isEmpty, !isSuspended, cloudReader == nil,
              reader != nil, modelUnavailable == nil else { return }
        modelWorker = Task(priority: .background) { [weak self] in
            await self?.drainModel()
        }
    }

    private func drainModel() async {
        refillModelQueue()
        while !isSuspended, modelUnavailable == nil, queue.isEmpty, worker == nil,
              let reader, !Task.isCancelled, !modelQueue.isEmpty {
            let candidate = modelQueue.removeFirst()
            modelCurrent = candidate
            report()
            await read(candidate, with: reader)
            modelCurrent = nil
            report()
        }
        modelWorker = nil
        if isSuspended, databaseURL != nil, current == nil, cloudCurrent == nil {
            store?.close()
            store = nil
        }
    }

    // MARK: - Облако

    // Каждый документ разрешённых папок после Vision уходит в облако — если его
    // включили и сохранили ключ. Суперскрытые и убранные из поиска папки сюда
    // не попадают: кандидаты берутся только из `folders`. Текст облака заменяет
    // фрагменты поиска отправленных страниц, поля сливаются с правилами

    func useCloudReader(_ reader: (any CloudReading)?) {
        cloudReader = reader
        cloudPaused = nil
        cloudQueue = []
        if reader == nil {
            cloudWorker?.cancel()
        } else {
            // Пока облако включено, локальная модель не читает
            modelWorker?.cancel()
        }
        report()
        startCloudWorker()
        startModelWorker()
    }

    /// Перечитать всё выбранной моделью: отметки стираются, очередь
    /// набирается заново. Идущее чтение доработает, следующий набор возьмёт всё
    func rereadAll(cloud: Bool) {
        guard let store = openStore() else { return }
        do {
            if cloud {
                try store.resetCloudMarks(folders: Set(folders.keys))
                cloudPaused = nil
                cloudQueue = []
            } else {
                try store.resetModelMarks(folders: Set(folders.keys))
                modelQueue = []
            }
        } catch {
            handle(error)
        }
        report()
        if cloud { startCloudWorker() } else { startModelWorker() }
    }

    private func startCloudWorker() {
        guard cloudWorker == nil, worker == nil, queue.isEmpty, !isSuspended,
              cloudReader != nil, cloudPaused == nil else { return }
        cloudWorker = Task(priority: .background) { [weak self] in
            await self?.drainCloud()
        }
    }

    private func drainCloud() async {
        if let reader = cloudReader, let store = openStore() {
            do {
                cloudQueue = try store.cloudCandidates(mark: reader.mark, folders: Set(folders.keys))
            } catch {
                handle(error)
            }
            report()
        }
        while !isSuspended, cloudPaused == nil, queue.isEmpty, worker == nil,
              let reader = cloudReader, !Task.isCancelled, !cloudQueue.isEmpty {
            let candidate = cloudQueue.removeFirst()
            cloudCurrent = candidate
            report()
            await readCloud(candidate, with: reader)
            cloudCurrent = nil
            report()
        }
        cloudWorker = nil
        if isSuspended, databaseURL != nil, current == nil, modelCurrent == nil {
            store?.close()
            store = nil
        }
    }

    private func readCloud(_ candidate: ModelReadCandidate, with reader: any CloudReading) async {
        guard let folder = folders[candidate.folderID] else { return }
        let url = folder.url.appendingPathComponent(candidate.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let load = cloudPages
        let pages = await Task.detached(priority: .utility) { load(url) }.value
        // Не фото и не скан: текст файла и так точный — облаку уходит он,
        // чтобы заполнить поля и метаданные. Нет и текста — отправлять нечего
        var text = ""
        if pages?.isEmpty ?? true {
            text = (try? openStore()?.documentText(documentID: candidate.documentID)) ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                try? openStore()?.markCloud(documentID: candidate.documentID, mark: SearchIndexStore.CloudMark.skipped(reader.mark))
                return
            }
        }

        let readout: CloudDocumentReadout
        do {
            if let pages, !pages.isEmpty {
                readout = try await reader.read(pages: pages)
            } else {
                readout = try await reader.read(text: text)
            }
        } catch let failure as CloudFailure {
            if failure.pausesQueue {
                cloudPaused = failure
                cloudQueue.insert(candidate, at: 0)
            } else {
                try? openStore()?.markCloud(documentID: candidate.documentID, mark: SearchIndexStore.CloudMark.failed(reader.mark))
            }
            return
        } catch is CancellationError {
            cloudQueue.insert(candidate, at: 0)
            return
        } catch {
            log.error("облако не прочитало документ: \(String(describing: type(of: error)), privacy: .public)")
            try? openStore()?.markCloud(documentID: candidate.documentID, mark: SearchIndexStore.CloudMark.failed(reader.mark))
            return
        }

        // Пока шёл запрос, папку могли скрыть, а файл — заменить. Тогда
        // прочитанное выбрасывается
        guard !isSuspended, folders[candidate.folderID] != nil,
              let disk = Self.diskFile(at: url, folderID: candidate.folderID),
              disk.size == candidate.fileSize, abs(disk.modified - candidate.fileModified) <= 0.001,
              let store = openStore() else { return }
        do {
            guard try store.cloudCandidates(mark: reader.mark, folders: [candidate.folderID])
                .contains(where: { $0.documentID == candidate.documentID }) else { return }
            let current = try store.fields(documentID: candidate.documentID)
            let type = CloudMerge.resolvedType(rules: candidate.type, fields: current, cloud: readout.readout)
            let fields = CloudMerge.merge(rules: current, cloud: readout.readout, type: type)
            let pagesWithText = readout.pages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let chunks = pagesWithText.flatMap { page in
                Self.split(page.text, limit: Self.chunkLength).map { Self.chunk(page: page.number, text: $0) }
            }
            let metadata = readout.meta.map { meta in
                (json: meta.json, chunk: Self.chunk(page: SearchIndexStore.metadataPage, text: meta.searchText))
            }
            try store.applyCloud(
                documentID: candidate.documentID,
                fields: fields,
                pages: pagesWithText.map(\.number),
                chunks: chunks,
                type: type == candidate.type ? nil : type,
                mark: reader.mark,
                metadata: metadata
            )
        } catch {
            handle(error)
        }
    }

    /// Облачное распознавание файла для «Сведений». nil — облако выключено
    func cloudState(folderID: UUID, fileName: String) -> CloudReadState? {
        guard let cloudReader, folders[folderID] != nil else { return nil }
        if cloudCurrent?.folderID == folderID, cloudCurrent?.fileName == fileName { return .waiting }
        return (try? openStore()?.cloudState(folderID: folderID, fileName: fileName, mark: cloudReader.mark)) ?? nil
    }

    /// Кандидаты, у которых правила не подтвердили ключевые поля. Остальные
    /// сразу отмечаются прочитанными: модель им не нужна
    private func refillModelQueue() {
        guard let reader, let store = openStore() else { return }
        do {
            let candidates = try store.modelCandidates(
                types: Self.modelCandidateTypes,
                revision: reader.revision,
                folders: Set(folders.keys)
            )
            let fields = try store.fields(documentIDs: candidates.map(\.documentID))
            var waiting: [ModelReadCandidate] = []
            for candidate in candidates {
                let needed = candidate.type == .other
                    ? DocumentReadingMerge.looksLikeIdentity(try store.pageText(documentID: candidate.documentID))
                    : DocumentReadingMerge.needsModel(type: candidate.type, fields: fields[candidate.documentID] ?? [])
                if needed {
                    waiting.append(candidate)
                } else {
                    let mark = SearchIndexStore.ModelMark.notNeeded(reader.revision)
                    try store.markModelRead(documentID: candidate.documentID, revision: mark)
                }
            }
            modelQueue = waiting
        } catch {
            handle(error)
        }
        report()
    }

    private func read(_ candidate: ModelReadCandidate, with reader: any DocumentReading) async {
        guard let folder = folders[candidate.folderID] else { return }
        let url = folder.url.appendingPathComponent(candidate.fileName)
        // Файл переименовали или удалили, пока он ждал: вернётся при следующем наборе
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let load = pageImage
        let image = await Task.detached(priority: .utility) { load(url) }.value
        let failed = SearchIndexStore.ModelMark.failed(reader.revision)
        guard let image else {
            // Не фото и не PDF — смотреть модели не на что
            try? openStore()?.markModelRead(documentID: candidate.documentID, revision: failed)
            return
        }

        let readout: DocumentReadout
        do {
            readout = try await reader.read(image, kind: candidate.type)
        } catch let error as DocumentReaderUnavailable {
            modelUnavailable = error.reason
            modelQueue.insert(candidate, at: 0)
            return
        } catch is CancellationError {
            // Ушли в фон или модель выгрузили ради чата — прочитаем позже
            modelQueue.insert(candidate, at: 0)
            return
        } catch {
            // Неполный ответ или сбой: значений нет, второй раз эта модель
            // документ не читает. Значений полей в журнале нет — только вид ошибки
            log.error("модель не прочитала документ: \(String(describing: type(of: error)), privacy: .public)")
            try? openStore()?.markModelRead(documentID: candidate.documentID, revision: failed)
            return
        }

        // Пока модель читала, папку могли скрыть, а файл — заменить или
        // перечитать. Тогда прочитанное выбрасывается
        guard !isSuspended, folders[candidate.folderID] != nil,
              let disk = Self.diskFile(at: url, folderID: candidate.folderID),
              disk.size == candidate.fileSize, abs(disk.modified - candidate.fileModified) <= 0.001,
              let store = openStore() else { return }
        do {
            guard try store.modelCandidates(
                types: [candidate.type], revision: reader.revision, folders: [candidate.folderID]
            ).contains(where: { $0.documentID == candidate.documentID }) else { return }
            let current = try store.fields(documentID: candidate.documentID)
            let text = try store.pageText(documentID: candidate.documentID)
            let type = DocumentReadingMerge.resolvedType(rules: candidate.type, fields: current, readout: readout, pageText: text)
            guard Self.modelReadableTypes.contains(type) else {
                // Модель удостоверения не увидела
                try store.markModelRead(documentID: candidate.documentID, revision: failed)
                return
            }
            let merged = DocumentReadingMerge.merge(rules: current, readout: readout, pageText: text, type: type)
            try store.applyModelFields(
                documentID: candidate.documentID,
                fields: merged,
                revision: reader.revision,
                type: type == candidate.type ? nil : type
            )
        } catch {
            handle(error)
        }
    }

    /// Второе чтение файла для «Сведений». nil — модели нет или это не удостоверение
    func modelState(folderID: UUID, fileName: String) -> ModelReadState? {
        guard let reader, folders[folderID] != nil else { return nil }
        if modelCurrent?.folderID == folderID, modelCurrent?.fileName == fileName { return .waiting }
        return (try? openStore()?.modelState(
            folderID: folderID, fileName: fileName, types: Self.modelReadableTypes, revision: reader.revision
        )) ?? nil
    }

    /// Какая модель прочитала документ. Для проверок
    func modelRevision(documentID: Int64) -> String? {
        (try? openStore()?.modelRevision(documentID: documentID)) ?? nil
    }

    private func index(_ file: DiskFile) async {
        guard let folder = folders[file.folderID] else { return }
        let url = folder.url.appendingPathComponent(file.name)
        guard let before = Self.diskFile(at: url, folderID: file.folderID) else {
            // Файл удалили, пока он ждал в очереди
            _ = try? openStore()?.deleteDocument(folderID: file.folderID, fileName: file.name)
            return
        }

        let record = await Self.makeRecord(for: before, at: url)

        // Пока шло распознавание, папку могли скрыть, а файл — удалить или
        // заменить. Тогда результат выбрасывается: в индекс не должно попасть
        // ничего из папки, которую уже убрали из поиска
        guard folders[file.folderID] != nil else { return }
        guard let after = Self.diskFile(at: url, folderID: file.folderID) else { return }
        guard after == before else {
            enqueue(after)
            return
        }
        guard !isSuspended else {
            queue.insert(file, at: 0)
            return
        }
        do {
            try openStore()?.save(record, indexVersion: Self.indexVersion)
        } catch {
            handle(error)
        }
    }

    // MARK: - Поиск

    /// Совпадения в тексте и именах файлов. Папки пересекаются со своим
    /// списком разрешённых: если скрытие ещё не дошло до актора, запрос
    /// всё равно ограничен тем, что разрешило хранилище
    func search(_ query: SearchQuery, in allowed: Set<UUID>, limit: Int = 60) -> [SearchHit] {
        let scope = allowed.intersection(folders.keys)
        guard !scope.isEmpty, !query.isEmpty, let store = openStore() else { return [] }
        do {
            var matches: [ChunkMatch] = []
            for matchAll in [true, false] {
                guard let expression = query.ftsExpression(matchAll: matchAll) else { break }
                matches = try store.search(expression, folders: scope, limit: limit * 4)
                if !matches.isEmpty || query.terms.count == 1 { break }
            }

            // Совпадения идут от лучшего к худшему: первое появление документа —
            // его лучший результат. Для подсветки нужен лучший фрагмент текста,
            // а не заголовок
            var order: [Int64] = []
            var excerpts: [Int64: ChunkMatch] = [:]
            for match in matches {
                if !order.contains(match.documentID) { order.append(match.documentID) }
                if match.page > 0, excerpts[match.documentID] == nil { excerpts[match.documentID] = match }
            }
            order = Array(order.prefix(limit))
            let documents = try store.documents(ids: order)
            let texts = try store.chunkTexts(ids: order.compactMap { excerpts[$0]?.chunkID })

            return order.compactMap { id in
                guard let document = documents[id] else { return nil }
                let excerpt = excerpts[id]
                let snippet = excerpt.flatMap { texts[$0.chunkID] }.flatMap { query.snippet(in: $0) }
                return SearchHit(
                    documentID: id,
                    folderID: document.folderID,
                    fileName: document.fileName,
                    type: document.type,
                    page: snippet == nil ? nil : excerpt?.page,
                    pageCount: document.pageCount,
                    snippet: snippet
                )
            }
        } catch {
            handle(error)
            return []
        }
    }

    /// Всё, что лежит в индексе, без учёта разрешённых папок — для проверок
    func indexedFiles() -> [FileKey] {
        (try? openStore()?.indexedFiles()) ?? []
    }

    func rowCounts() -> SearchIndexStore.RowCounts? {
        try? openStore()?.rowCounts()
    }

    // MARK: - Документы и поля для чата

    // Каждый запрос пересекает папки со своим списком разрешённых, как и поиск:
    // карточка не должна показать документ папки, которую только что скрыли

    func documents(types: [DocumentType], in allowed: Set<UUID>) -> [StoredDocument] {
        let scope = allowed.intersection(folders.keys)
        return (try? openStore()?.documents(types: types, folders: scope)) ?? []
    }

    func documents(ids: [Int64], in allowed: Set<UUID>) -> [StoredDocument] {
        let scope = allowed.intersection(folders.keys)
        guard let found = try? openStore()?.documents(ids: ids) else { return [] }
        return ids.compactMap { found[$0] }.filter { scope.contains($0.folderID) }
    }

    func fields(documentIDs ids: [Int64], in allowed: Set<UUID>) -> [Int64: [DocumentField]] {
        let visible = documents(ids: ids, in: allowed).map(\.id)
        return (try? openStore()?.fields(documentIDs: visible)) ?? [:]
    }

    func metadata(folderID: UUID, fileName: String) -> DocumentMetadata? {
        guard folders[folderID] != nil,
              let id = (try? openStore()?.documentID(folderID: folderID, fileName: fileName)) ?? nil,
              let json = (try? openStore()?.metadata(documentIDs: [id]))?[id] else { return nil }
        return DocumentMetadata.parse(json)
    }

    func metadata(documentIDs ids: [Int64], in allowed: Set<UUID>) -> [Int64: DocumentMetadata] {
        let visible = documents(ids: ids, in: allowed).map(\.id)
        let rows = (try? openStore()?.metadata(documentIDs: visible)) ?? [:]
        return rows.compactMapValues(DocumentMetadata.parse)
    }

    func documentText(documentID: Int64, in allowed: Set<UUID>) -> String? {
        guard !documents(ids: [documentID], in: allowed).isEmpty else { return nil }
        let text = (try? openStore()?.pageText(documentID: documentID)) ?? nil
        return text?.isEmpty == false ? text : nil
    }

    func setManualField(documentID: Int64, key: String, value: String, in allowed: Set<UUID>) {
        guard !documents(ids: [documentID], in: allowed).isEmpty else { return }
        do {
            try openStore()?.setManualField(documentID: documentID, key: key, value: value)
        } catch {
            handle(error)
        }
    }

    func verifyField(documentID: Int64, key: String, in allowed: Set<UUID>) {
        guard !documents(ids: [documentID], in: allowed).isEmpty else { return }
        do {
            try openStore()?.verifyField(documentID: documentID, key: key)
        } catch {
            handle(error)
        }
    }

    // MARK: - Разбор файла

    /// Распознавание и леммы — тяжёлая работа, она идёт вне актора,
    /// чтобы поиск не ждал, пока распознаётся очередной скан
    private static func makeRecord(for file: DiskFile, at url: URL) async -> DocumentRecord {
        await Task.detached(priority: .utility) {
            let title = SearchText.title(fromFileName: file.name)
            var chunks = [chunk(page: 0, text: title)]
            var failed = false
            var extracted = ExtractedText.empty
            do {
                extracted = try await DocumentTextExtractor.extract(from: url)
            } catch {
                failed = true
            }
            for page in extracted.pages {
                for piece in split(page.text, limit: chunkLength) {
                    chunks.append(chunk(page: page.number, text: piece))
                }
            }
            let analysis = DocumentAnalyzer.analyze(extracted)
            return DocumentRecord(
                folderID: file.folderID,
                fileName: file.name,
                type: analysis.type,
                title: title,
                pageCount: extracted.pageCount,
                fileSize: file.size,
                fileModified: file.modified,
                failed: failed,
                chunks: chunks,
                fields: analysis.fields
            )
        }.value
    }

    static func chunk(page: Int, text: String) -> ChunkRecord {
        ChunkRecord(
            page: page,
            text: text,
            words: SearchText.normalize(text),
            stems: SearchText.stems(of: text)
        )
    }

    /// Режет текст страницы на куски не длиннее `limit` по границам строк,
    /// а слишком длинную строку — по пробелам
    static func split(_ text: String, limit: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            current = ""
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > limit { flush() }
            if line.count > limit {
                for word in line.split(separator: " ") {
                    if current.count + word.count + 1 > limit { flush() }
                    current += current.isEmpty ? String(word) : " " + word
                }
            } else {
                current += current.isEmpty ? String(line) : "\n" + line
            }
        }
        flush()
        return pieces
    }

    // MARK: - Диск

    /// Файлы разрешённых папок. Папка, которую не удалось прочитать, в
    /// результат не попадает: её документы нельзя считать удалёнными
    private func scan(_ snapshot: [IndexableFolder]) -> [UUID: [String: DiskFile]] {
        let fm = FileManager.default
        var result: [UUID: [String: DiskFile]] = [:]
        for folder in snapshot {
            guard fm.fileExists(atPath: folder.url.path) else {
                result[folder.id] = [:]
                continue
            }
            guard let urls = try? fm.contentsOfDirectory(
                at: folder.url,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            var files: [String: DiskFile] = [:]
            for url in urls {
                if let file = Self.diskFile(at: url, folderID: folder.id) {
                    files[file.name] = file
                }
            }
            result[folder.id] = files
        }
        return result
    }

    private static func diskFile(at url: URL, folderID: UUID) -> DiskFile? {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        ), values.isRegularFile == true else { return nil }
        return DiskFile(
            folderID: folderID,
            name: url.lastPathComponent,
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
    }

    // MARK: - База

    private func openStore() -> SearchIndexStore? {
        if let store { return store }
        do {
            store = try makeStore()
        } catch let error as SQLiteError where error.code == SQLITE_CORRUPT || error.code == SQLITE_NOTADB {
            // Индекс производный: испорченный файл проще построить заново
            log.error("индекс повреждён, создаётся заново")
            removeDatabaseFiles()
            store = try? makeStore()
        } catch {
            log.error("индекс не открылся: \(String(describing: error), privacy: .public)")
        }
        return store
    }

    private func makeStore() throws -> SearchIndexStore {
        guard let databaseURL else { return try SearchIndexStore(url: nil) }
        let directory = databaseURL.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            // Индекс восстанавливается из файлов, в копии iPhone ему делать нечего
            var location = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? location.setResourceValues(values)
        }
        return try SearchIndexStore(url: databaseURL)
    }

    private func removeDatabaseFiles() {
        guard let databaseURL else { return }
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
    }

    /// Ошибка ввода-вывода чаще всего значит, что iPhone заблокировали и
    /// файл базы стал недоступен. Соединение переоткроется при следующем обращении
    private func handle(_ error: Error) {
        log.error("ошибка индекса: \(String(describing: error), privacy: .public)")
        if databaseURL != nil {
            store?.close()
            store = nil
        }
    }

    private func report() {
        let indexed = (try? store?.documentCount(folders: Set(folders.keys))) ?? 0
        let pending = queue.count + (current == nil ? 0 : 1)
        var progress = SearchIndexProgress(indexed: indexed, pending: pending)
        if let reader {
            let counts = (try? store?.modelCounts(
                types: Self.modelReadableTypes, revision: reader.revision, folders: Set(folders.keys)
            )) ?? SearchIndexStore.ModelCounts()
            progress.hasDocumentModel = true
            progress.identityDocuments = counts.identity
            progress.modelRead = counts.read
            progress.modelPending = modelQueue.count + (modelCurrent == nil ? 0 : 1)
            progress.modelReading = modelCurrent != nil
            progress.modelUnavailable = modelUnavailable
        }
        if let cloudReader {
            let counts = (try? store?.cloudCounts(mark: cloudReader.mark, folders: Set(folders.keys)))
                ?? SearchIndexStore.ModelCounts()
            progress.hasCloud = true
            progress.cloudDocuments = counts.identity
            progress.cloudRead = counts.read
            progress.cloudPending = cloudQueue.count + (cloudCurrent == nil ? 0 : 1)
            progress.cloudReading = cloudCurrent != nil
            progress.cloudPaused = cloudPaused?.message
        }
        lastProgress = progress
        progressContinuation.yield(progress)
    }
}
