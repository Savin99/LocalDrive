import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum VaultFolderKind: String, Codable, CaseIterable {
    case files
    case feed

    var title: String {
        switch self {
        case .files: "Файлы"
        case .feed: "Лента"
        }
    }

    var subtitle: String {
        switch self {
        case .files: "Обычная сетка документов"
        case .feed: "Текст и вложения блоками"
        }
    }

    var icon: String {
        switch self {
        case .files: "square.grid.2x2"
        case .feed: "rectangle.stack"
        }
    }
}

// Как упорядочены файлы в папке. Выбор запоминается для каждой папки отдельно
enum FileSortOrder: String, Codable, CaseIterable {
    case addedNewest
    case addedOldest
    case dateNewest
    case dateOldest
    case nameAsc
    case sizeDesc
    case manual

    var title: String {
        switch self {
        case .addedNewest: "Добавлены: сначала новые"
        case .addedOldest: "Добавлены: сначала старые"
        case .dateNewest: "Дата файла: сначала новые"
        case .dateOldest: "Дата файла: сначала старые"
        case .nameAsc: "По имени"
        case .sizeDesc: "По размеру"
        case .manual: "Вручную"
        }
    }

    var icon: String {
        switch self {
        case .addedNewest, .addedOldest: "clock"
        case .dateNewest, .dateOldest: "calendar"
        case .nameAsc: "textformat"
        case .sizeDesc: "arrow.up.arrow.down.circle"
        case .manual: "hand.draw"
        }
    }

    /// В этих режимах в карточке уместнее показать дату самого файла
    var showsContentDate: Bool {
        self == .dateNewest || self == .dateOldest
    }
}

// Метаданные папки хранилища
struct VaultFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var icon: String
    var color: String
    var createdAt: Date
    var kind: VaultFolderKind
    var isSuperHidden: Bool
    var sortOrder: FileSortOrder
    /// Выбор человека «Доступна для поиска». У суперскрытой папки он не
    /// действует: она не индексируется никогда, см. `isIndexable`
    var searchable: Bool
    /// Папка, внутри которой лежит эта; nil — верхний уровень. Дерево живёт
    /// только в метаданных: файлы любой папки лежат в своём `Vault/<UUID>/`
    var parentID: UUID?

    init(
        id: UUID,
        name: String,
        icon: String,
        color: String,
        createdAt: Date,
        kind: VaultFolderKind = .files,
        isSuperHidden: Bool = false,
        sortOrder: FileSortOrder = .addedNewest,
        searchable: Bool = true,
        parentID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.createdAt = createdAt
        self.kind = kind
        self.isSuperHidden = isSuperHidden
        self.sortOrder = sortOrder
        self.searchable = searchable
        self.parentID = parentID
    }

    /// Собственные признаки папки без учёта родителей. Решает, видна ли папка
    /// и попадает ли в индекс, `VaultStore.isIndexable(_:)`: вложенная
    /// наследует скрытость и «вне поиска» от всех папок выше
    var isIndexable: Bool { searchable && !isSuperHidden }

    /// Внутри ленты папок нет: её содержимое — блоки
    var canContainSubfolders: Bool { kind == .files }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, color, createdAt, kind, isSuperHidden, sortOrder, searchable, parentID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        color = try container.decode(String.self, forKey: .color)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        kind = try container.decodeIfPresent(VaultFolderKind.self, forKey: .kind) ?? .files
        isSuperHidden = try container.decodeIfPresent(Bool.self, forKey: .isSuperHidden) ?? false
        sortOrder = try container.decodeIfPresent(FileSortOrder.self, forKey: .sortOrder) ?? .addedNewest
        // Папки, созданные до поиска, обычными остаются доступными для него
        searchable = try container.decodeIfPresent(Bool.self, forKey: .searchable) ?? true
        // Папки до вложенности лежат на верхнем уровне
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
    }
}

/// Изменения, которые индекс поиска отрабатывает сразу, не дожидаясь сверки:
/// из скрытой папки текст должен исчезнуть в момент скрытия
enum VaultChange: Equatable, Sendable {
    /// Папку скрыли, убрали из поиска или удалили — сама или вместе с папкой
    /// выше. Для поддерева событие приходит на каждую папку
    case folderExcluded(UUID)
    case fileRemoved(folder: UUID, name: String)
    case fileRenamed(folder: UUID, from: String, to: String)
    /// Файл перенесли в другую папку. Текст тот же: индекс переносит документ
    /// без нового распознавания, а если папка вне поиска — стирает его
    case fileMoved(fromFolder: UUID, name: String, toFolder: UUID, newName: String)
}

enum FeedBlockKind: String, Codable {
    case text
    case media
    case file
}

struct FeedBlock: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: FeedBlockKind
    var text: String?
    var fileNames: [String]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: FeedBlockKind,
        text: String? = nil,
        fileNames: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.fileNames = fileNames
        self.createdAt = createdAt
    }
}

// Содержимое .feed.json: блоки плюс пропорции медиа.
// Пропорции лежат отдельно от блоков, чтобы переживать объединение,
// разделение и перенос фото между рядами.
struct FeedDocument: Codable {
    var blocks: [FeedBlock] = []
    var aspects: [String: Double] = [:]

    init(blocks: [FeedBlock] = [], aspects: [String: Double] = [:]) {
        self.blocks = blocks
        self.aspects = aspects
    }
}

/// Что внутри папки: файлы (у ленты — блоки), их размер и вложенные папки
struct FolderStats: Equatable {
    var count: Int
    var size: Int64
    var subfolders: Int = 0
}

// Файл внутри папки — читается напрямую с диска
struct VaultFile: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let size: Int64
    /// Когда файл попал в хранилище
    let addedAt: Date
    /// Дата самого файла: съёмка фото, запись видео. Для импорта документов
    /// её сохраняет копирование, для фото подставляет дозаполнение из EXIF
    var contentDate: Date

    var type: UTType {
        UTType(filenameExtension: url.pathExtension) ?? .data
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Имя без расширения — в карточках оно не влезает, а тип виден по превью
    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Расширение заглавными для бейджа: PDF, PNG, TXT
    var extensionBadge: String? {
        let ext = url.pathExtension
        return ext.isEmpty ? nil : ext.uppercased()
    }

    // Иконка-заглушка по типу файла — когда миниатюру построить нельзя
    var iconName: String {
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .archive) { return "archivebox" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

@Observable
final class VaultStore {
    private(set) var folders: [VaultFolder] = []
    // Счётчик изменений: файлы не хранятся в модели, поэтому вьюхи
    // читают revision, чтобы Observation перерисовывал их после операций
    private(set) var revision: Int = 0

    // Лента читается на каждую отрисовку блока, а при инлайн-редактировании —
    // ещё и на каждый коммит текста. Декодировать JSON каждый раз слишком дорого.
    private var feedCache: [UUID: FeedDocument] = [:]

    /// Подписчик на изменения, которые нельзя откладывать до сверки, — индекс поиска
    @ObservationIgnored var onChange: ((VaultChange) -> Void)?

    private let fm = FileManager.default
    private let root: URL
    private var metaURL: URL { root.appendingPathComponent("vault.json") }

    var rootURL: URL { root }

    init(rootURL: URL? = nil) {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = rootURL ?? support.appendingPathComponent("Vault", isDirectory: true)
        try? fm.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        load()
    }

    // MARK: - Метаданные

    private func load() {
        guard let data = try? Data(contentsOf: metaURL),
              let decoded = try? JSONDecoder().decode([VaultFolder].self, from: data) else { return }
        folders = Self.repairedTree(decoded)
    }

    /// Родитель, которого нет, лента в роли родителя или цикл — признак
    /// повреждённого vault.json. Такая папка встаёт на верхний уровень: иначе
    /// до неё было бы не добраться. Цикл рвётся в одном месте — у первой его
    /// папки по порядку, остальные остаются внутри. Файл не переписывается
    /// до первой правки
    static func repairedTree(_ folders: [VaultFolder]) -> [VaultFolder] {
        var repaired = folders
        var byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in repaired.indices {
            var seen: Set<UUID> = [repaired[index].id]
            var cursor = repaired[index].parentID
            while let id = cursor {
                guard let parent = byID[id], parent.canContainSubfolders, seen.insert(id).inserted else {
                    repaired[index].parentID = nil
                    byID[repaired[index].id] = repaired[index]
                    break
                }
                cursor = parent.parentID
            }
        }
        return repaired
    }

    func reload() {
        folders = []
        feedCache.removeAll()
        load()
        revision &+= 1
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: metaURL, options: [.atomic, .completeFileProtection])
    }

    // MARK: - Папки

    func folderURL(_ folder: VaultFolder) -> URL {
        root.appendingPathComponent(folder.id.uuidString, isDirectory: true)
    }

    func folder(by id: UUID) -> VaultFolder? {
        folders.first(where: { $0.id == id })
    }

    /// Новая папка; `parentID` — внутри какой. В ленте и в несуществующей
    /// папке вложенную не создать — тогда nil
    @discardableResult
    func createFolder(
        name: String,
        icon: String,
        color: String,
        kind: VaultFolderKind = .files,
        isSuperHidden: Bool = false,
        searchable: Bool = true,
        parentID: UUID? = nil
    ) -> VaultFolder? {
        if let parentID {
            guard let parent = folder(by: parentID), parent.canContainSubfolders else { return nil }
        }
        let folder = VaultFolder(
            id: UUID(),
            name: name,
            icon: icon,
            color: color,
            createdAt: Date(),
            kind: kind,
            isSuperHidden: isSuperHidden,
            searchable: searchable,
            parentID: parentID
        )
        try? fm.createDirectory(
            at: folderURL(folder),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        folders.append(folder)
        save()
        revision &+= 1
        return folder
    }

    /// `searchable == nil` — выбор «Доступна для поиска» не меняется
    func updateFolder(
        id: UUID,
        name: String,
        icon: String,
        color: String,
        isSuperHidden: Bool,
        searchable: Bool? = nil
    ) {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        excludingLostFromIndex {
            folders[idx].name = name
            folders[idx].icon = icon
            folders[idx].color = color
            folders[idx].isSuperHidden = isSuperHidden
            if let searchable {
                folders[idx].searchable = searchable
            }
            save()
        }
        revision &+= 1
    }

    func setSuperHidden(_ isSuperHidden: Bool, for id: UUID) {
        guard let idx = folders.firstIndex(where: { $0.id == id }),
              folders[idx].isSuperHidden != isSuperHidden else { return }
        excludingLostFromIndex {
            folders[idx].isSuperHidden = isSuperHidden
            save()
        }
        revision &+= 1
    }

    func setSearchable(_ searchable: Bool, for id: UUID) {
        guard let idx = folders.firstIndex(where: { $0.id == id }),
              folders[idx].searchable != searchable else { return }
        excludingLostFromIndex {
            folders[idx].searchable = searchable
            save()
        }
        revision &+= 1
    }

    /// Правка признаков или дерева. Всё, что после неё ушло из поиска, — сама
    /// папка и всё её поддерево — индекс стирает немедленно. Вернувшееся в
    /// поиск подхватит сверка по ревизии
    private func excludingLostFromIndex(_ change: () -> Void) {
        let before = Set(folders.filter(isIndexable).map(\.id))
        change()
        let after = Set(folders.filter(isIndexable).map(\.id))
        for folder in folders where before.contains(folder.id) && !after.contains(folder.id) {
            onChange?(.folderExcluded(folder.id))
        }
    }

    /// Папка вместе со всем поддеревом и файлами. Индекс узнаёт о каждой
    /// удалённой папке, как при удалении одной
    func deleteFolder(_ folder: VaultFolder) {
        let doomed = [folder.id] + descendants(of: folder.id).map(\.id)
        for id in doomed {
            try? fm.removeItem(at: root.appendingPathComponent(id.uuidString, isDirectory: true))
            feedCache[id] = nil
        }
        let removed = Set(doomed)
        folders.removeAll { removed.contains($0.id) }
        save()
        for id in doomed {
            onChange?(.folderExcluded(id))
        }
        revision &+= 1
    }

    // MARK: - Дерево папок

    /// Папки верхнего уровня — то, что видно на экране «Файлы»
    var rootFolders: [VaultFolder] {
        children(of: nil)
    }

    /// Вложенные папки в порядке создания; nil — верхний уровень
    func children(of parentID: UUID?) -> [VaultFolder] {
        folders.filter { $0.parentID == parentID }
    }

    /// Всё поддерево папки, в глубину: сначала дочерняя, затем её содержимое
    func descendants(of id: UUID) -> [VaultFolder] {
        var result: [VaultFolder] = []
        var seen: Set<UUID> = [id]
        func walk(_ parent: UUID) {
            for child in children(of: parent) where seen.insert(child.id).inserted {
                result.append(child)
                walk(child.id)
            }
        }
        walk(id)
        return result
    }

    /// Папки выше этой — от верхнего уровня до родителя. Цикл в метаданных
    /// обрывается, а не зацикливает
    func ancestors(of folder: VaultFolder) -> [VaultFolder] {
        var chain: [VaultFolder] = []
        var seen: Set<UUID> = [folder.id]
        var cursor = folder.parentID
        while let id = cursor, seen.insert(id).inserted, let parent = self.folder(by: id) {
            chain.append(parent)
            cursor = parent.parentID
        }
        return chain.reversed()
    }

    /// Путь от верхнего уровня до самой папки включительно
    func lineage(of folder: VaultFolder) -> [VaultFolder] {
        ancestors(of: folder) + [folder]
    }

    /// «Документы / Паспорта» — там, где папка названа одна, без экрана вокруг
    func path(of folder: VaultFolder, separator: String = " / ") -> String {
        lineage(of: folder).map(\.name).joined(separator: separator)
    }

    /// Лежит ли `id` где-то внутри `ancestorID`
    func isDescendant(_ id: UUID, of ancestorID: UUID) -> Bool {
        guard let folder = folder(by: id) else { return false }
        return ancestors(of: folder).contains { $0.id == ancestorID }
    }

    /// Скрыта ли папка на деле: суперскрытая сама или лежит в суперскрытой.
    /// Суперскрытая папка прячет всё своё поддерево
    func isHidden(_ folder: VaultFolder) -> Bool {
        lineage(of: folder).contains(where: \.isSuperHidden)
    }

    /// Попадает ли папка в индекс на деле: она и все папки выше доступны для
    /// поиска и ни одна не суперскрытая
    func isIndexable(_ folder: VaultFolder) -> Bool {
        lineage(of: folder).allSatisfy(\.isIndexable)
    }

    /// Дерево для листа выбора: папка и её глубина, в порядке обхода.
    /// `includingHidden == false` — суперскрытая папка не попадает вместе со
    /// всем, что внутри
    func tree(includingHidden: Bool = false) -> [(folder: VaultFolder, depth: Int)] {
        var result: [(folder: VaultFolder, depth: Int)] = []
        var seen: Set<UUID> = []
        func walk(_ parent: UUID?, depth: Int) {
            for child in children(of: parent) where seen.insert(child.id).inserted {
                if !includingHidden && child.isSuperHidden { continue }
                result.append((child, depth))
                walk(child.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 0)
        return result
    }

    /// Можно ли переложить папку: не в себя, не в своё поддерево, не в ленту
    /// и не туда, где она уже лежит
    func canMoveFolder(_ id: UUID, to parentID: UUID?) -> Bool {
        guard let folder = folder(by: id), folder.parentID != parentID else { return false }
        guard let parentID else { return true }
        guard parentID != id, let parent = self.folder(by: parentID), parent.canContainSubfolders else { return false }
        return !isDescendant(parentID, of: id)
    }

    /// Переложить папку со всем поддеревом в другую или на верхний уровень.
    /// Файлы остаются в своих каталогах: меняется только родитель. Если
    /// поддерево попало в скрытую папку или в папку вне поиска, индекс
    /// стирает его сразу
    @discardableResult
    func moveFolder(_ id: UUID, to parentID: UUID?) -> Bool {
        guard canMoveFolder(id, to: parentID),
              let idx = folders.firstIndex(where: { $0.id == id }) else { return false }
        excludingLostFromIndex {
            folders[idx].parentID = parentID
            save()
        }
        revision &+= 1
        return true
    }

    /// Сколько уйдёт вместе с папкой: файлы на диске (у ленты — тоже) и
    /// вложенные папки всего поддерева
    func subtreeContents(of folder: VaultFolder) -> (files: Int, folders: Int) {
        let inner = descendants(of: folder.id)
        let files = ([folder] + inner).reduce(0) { $0 + self.files(in: $1).count }
        return (files, inner.count)
    }

    // MARK: - Файлы

    func files(in folder: VaultFolder) -> [VaultFile] {
        _ = revision // подписка на изменения
        let dir = folderURL(folder)
        let keys: [URLResourceKey] = [
            .fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey,
        ]
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url -> VaultFile? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory != true else { return nil }
            let added = values.creationDate ?? .distantPast
            return VaultFile(
                url: url,
                name: url.lastPathComponent,
                size: Int64(values.fileSize ?? 0),
                addedAt: added,
                contentDate: values.contentModificationDate ?? added
            )
        }
        .sorted { $0.addedAt > $1.addedAt }
    }

    /// Файлы папки в выбранном пользователем порядке
    func files(in folder: VaultFolder, sortedBy order: FileSortOrder) -> [VaultFile] {
        let items = files(in: folder)
        switch order {
        case .addedNewest: return items // files(in:) уже отдаёт новые первыми
        case .addedOldest: return items.reversed()
        case .dateNewest, .dateOldest:
            let known = contentDates(in: folder)
            let dated = items.map { file -> VaultFile in
                guard let date = known[file.name] else { return file }
                var copy = file
                copy.contentDate = date
                return copy
            }
            return order == .dateNewest
                ? dated.sorted { $0.contentDate > $1.contentDate }
                : dated.sorted { $0.contentDate < $1.contentDate }
        case .nameAsc:
            return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .sizeDesc: return items.sorted { $0.size > $1.size }
        case .manual:
            let saved = fileOrder(in: folder)
            guard !saved.isEmpty else { return items }
            let positions = Dictionary(uniqueKeysWithValues: saved.enumerated().map { ($1, $0) })
            // Файлы, добавленные после последней перестановки, уходят в конец
            return items.sorted { lhs, rhs in
                switch (positions[lhs.name], positions[rhs.name]) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.addedAt > rhs.addedAt
                }
            }
        }
    }

    // MARK: - Дозаполнение дат съёмки

    private func contentDatesURL(for folder: VaultFolder) -> URL {
        folderURL(folder).appendingPathComponent(".dates.json")
    }

    func contentDates(in folder: VaultFolder) -> [String: Date] {
        _ = revision
        guard let data = try? Data(contentsOf: contentDatesURL(for: folder)),
              let map = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return map
    }

    func setContentDates(_ dates: [String: Date], in folder: VaultFolder) {
        guard !dates.isEmpty else { return }
        var map = contentDates(in: folder)
        for (name, date) in dates { map[name] = date }
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: contentDatesURL(for: folder), options: [.atomic, .completeFileProtection])
        revision &+= 1
    }

    /// Файлы, для которых дату съёмки ещё не искали. Запись остаётся даже
    /// когда метаданных нет, иначе поиск повторялся бы при каждом открытии
    func fileNamesMissingContentDate(in folder: VaultFolder) -> [String] {
        let known = contentDates(in: folder)
        return files(in: folder).map(\.name).filter { known[$0] == nil }
    }

    func setSortOrder(_ order: FileSortOrder, for folder: VaultFolder) {
        guard let idx = folders.firstIndex(where: { $0.id == folder.id }),
              folders[idx].sortOrder != order else { return }
        folders[idx].sortOrder = order
        save()
    }

    // MARK: - Ручной порядок

    private func orderURL(for folder: VaultFolder) -> URL {
        folderURL(folder).appendingPathComponent(".order.json")
    }

    /// Порядок лежит рядом с файлами, поэтому переживает перезапуск
    /// приложения и попадает в резервную копию вместе с папкой
    func fileOrder(in folder: VaultFolder) -> [String] {
        _ = revision
        guard let data = try? Data(contentsOf: orderURL(for: folder)),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return names
    }

    func setFileOrder(_ names: [String], in folder: VaultFolder) {
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? data.write(to: orderURL(for: folder), options: [.atomic, .completeFileProtection])
        revision &+= 1
    }

    /// Что внутри папки для карточки и строки: файлы (у ленты — блоки), их
    /// размер и вложенные папки. Суперскрытые вложенные считаются, только
    /// когда их показывают: число не должно выдавать, что они есть
    func stats(for folder: VaultFolder, includingHidden: Bool = false) -> FolderStats {
        let items = files(in: folder)
        let count = folder.kind == .feed ? feedBlocks(in: folder).count : items.count
        let subfolders = children(of: folder.id).filter { includingHidden || !$0.isSuperHidden }.count
        return FolderStats(count: count, size: items.reduce(0) { $0 + $1.size }, subfolders: subfolders)
    }

    /// Последние файлы папки — для коллажа на её карточке
    func previewFiles(in folder: VaultFolder, limit: Int = 4) -> [VaultFile] {
        Array(files(in: folder).prefix(limit))
    }

    /// Недавно добавленное по всем папкам
    /// Папка внутри суперскрытой скрыта вместе с ней
    func recentFiles(limit: Int = 10, includingSuperHidden: Bool = false) -> [(file: VaultFile, folder: VaultFolder)] {
        folders
            .filter { includingSuperHidden || !isHidden($0) }
            .flatMap { folder in files(in: folder).map { (file: $0, folder: folder) } }
            .sorted { $0.file.addedAt > $1.file.addedAt }
            .prefix(limit)
            .map { $0 }
    }

    /// Что добавилось при импорте и что нет
    struct ImportResult {
        var imported: [String] = []
        var failed: [String] = []
    }

    /// Импорт из «Файлов». Копирование идёт под NSFileCoordinator: документ из
    /// iCloud Drive, который ещё не скачан на iPhone, без координатора не
    /// копируется — на диске лежит только заглушка, и раньше такой импорт
    /// молча ничего не добавлял. Координированное чтение сначала скачивает файл.
    /// Работа с диском идёт вне главного потока, ревизия меняется на нём
    @MainActor
    func importFiles(_ urls: [URL], to folder: VaultFolder) async -> ImportResult {
        var result = ImportResult()
        let directory = folderURL(folder)
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let copied = try await Task.detached(priority: .userInitiated) {
                    try Self.coordinatedCopy(from: url, into: directory)
                }.value
                result.imported.append(copied.lastPathComponent)
            } catch {
                result.failed.append(url.lastPathComponent)
            }
        }
        if !result.imported.isEmpty { revision &+= 1 }
        return result
    }

    /// Уникальное имя выбирается уже внутри координатора: пока файл
    /// скачивался, в папку мог попасть другой с тем же именем
    nonisolated static func coordinatedCopy(from source: URL, into directory: URL) throws -> URL {
        var coordinationError: NSError?
        var outcome: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: source,
            options: [.withoutChanges],
            error: &coordinationError
        ) { readable in
            outcome = Result {
                let destination = uniqueDestination(for: source.lastPathComponent, in: directory)
                try FileManager.default.copyItem(at: readable, to: destination)
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete, .creationDate: Date()],
                    ofItemAtPath: destination.path
                )
                return destination
            }
        }
        if let coordinationError { throw coordinationError }
        return try outcome.get()
    }

    // Импорт из «Файлов» (security-scoped доступ обеспечивает вызывающий код)
    @discardableResult
    func importFile(from source: URL, to folder: VaultFolder) -> String? {
        let dst = uniqueURL(for: source.lastPathComponent, in: folderURL(folder))
        do {
            try fm.copyItem(at: source, to: dst)
            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.complete, .creationDate: Date()],
                ofItemAtPath: dst.path
            )
            revision &+= 1
            return dst.lastPathComponent
        } catch {
            // Ошибку копирования просто пропускаем, файл-источник не трогаем
            return nil
        }
    }

    // Импорт бинарных данных (фото/видео из галереи)
    @discardableResult
    func importData(_ data: Data, preferredName: String, to folder: VaultFolder) -> String? {
        let dst = uniqueURL(for: preferredName, in: folderURL(folder))
        do {
            try data.write(to: dst, options: [.atomic, .completeFileProtection])
            revision &+= 1
            return dst.lastPathComponent
        } catch {
            return nil
        }
    }

    func deleteFile(_ file: VaultFile) {
        try? fm.removeItem(at: file.url)
        if let folder = folderID(containing: file.url) {
            onChange?(.fileRemoved(folder: folder, name: file.name))
        }
        revision &+= 1
    }

    func renameFile(_ file: VaultFile, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ext = file.url.pathExtension
        let fullName = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
        let dst = uniqueURL(for: fullName, in: file.url.deletingLastPathComponent())
        do {
            try fm.moveItem(at: file.url, to: dst)
            if let folder = folderID(containing: file.url) {
                onChange?(.fileRenamed(folder: folder, from: file.name, to: dst.lastPathComponent))
            }
        } catch {
            // Имя не поменялось — индексу сообщать нечего
        }
        revision &+= 1
    }

    /// Папка хранилища, в которой лежит файл: каталог назван её UUID
    private func folderID(containing url: URL) -> UUID? {
        UUID(uuidString: url.deletingLastPathComponent().lastPathComponent)
    }

    // MARK: - Перенос, копии и вставка

    /// Файл, попавший в папку назначения: откуда он и как называется теперь
    private struct Placed {
        let source: URL
        let name: String

        var oldName: String { source.lastPathComponent }
    }

    /// Перенос в другую папку. Дата съёмки и место в ручном порядке едут
    /// вместе с файлом, а индекс переносит документ без нового распознавания.
    /// Из ленты файлы не переносятся: там они — часть блоков
    @MainActor
    @discardableResult
    func moveFiles(_ files: [VaultFile], from source: VaultFolder, to destination: VaultFolder) async -> ImportResult {
        guard source.id != destination.id, source.kind != .feed else {
            return ImportResult(failed: files.map(\.name))
        }
        let sources = files.map { folderURL(source).appendingPathComponent($0.name) }
        let directory = folderURL(destination)
        let outcomes = await Task.detached(priority: .userInitiated) {
            sources.map { url in Result { try Self.relocate(url, into: directory) } }
        }.value
        let (placed, result) = Self.tally(outcomes, sources: sources)
        guard !placed.isEmpty else { return result }

        carryMetadata(placed, from: source, to: destination, removingFromSource: true)
        // События — до смены ревизии: сверка, которую она запустит, должна
        // застать документ уже в новой папке
        for item in placed {
            onChange?(.fileMoved(fromFolder: source.id, name: item.oldName, toFolder: destination.id, newName: item.name))
        }
        revision &+= 1
        await appendToFeed(result.imported, in: destination)
        return result
    }

    /// Копия в другую папку. Оригиналы остаются на месте, а копия
    /// распознаётся при сверке заново, как любой новый файл
    @MainActor
    @discardableResult
    func copyFiles(_ files: [VaultFile], to destination: VaultFolder) async -> ImportResult {
        let sources = files.map(\.url)
        let directory = folderURL(destination)
        let outcomes = await Task.detached(priority: .userInitiated) {
            sources.map { url in Result { try Self.coordinatedCopy(from: url, into: directory) } }
        }.value
        let (placed, result) = Self.tally(outcomes, sources: sources)
        guard !placed.isEmpty else { return result }

        // Дата съёмки берётся из той папки, где лежит оригинал
        let origins = Dictionary(grouping: placed) { folderID(containing: $0.source) }
        for (id, items) in origins {
            guard let id, let origin = folder(by: id) else { continue }
            carryMetadata(items, from: origin, to: destination, removingFromSource: false)
        }
        revision &+= 1
        await appendToFeed(result.imported, in: destination)
        return result
    }

    /// Копия рядом с оригиналом: «Паспорт копия.pdf», затем «Паспорт копия 2.pdf».
    /// В ручном порядке копия встаёт сразу за оригиналом
    @MainActor
    @discardableResult
    func duplicate(_ file: VaultFile) async -> String? {
        guard let id = folderID(containing: file.url),
              let folder = self.folder(by: id),
              folder.kind == .files else { return nil }
        let source = file.url
        let copy = try? await Task.detached(priority: .userInitiated) {
            try Self.locked {
                let directory = source.deletingLastPathComponent()
                let destination = directory.appendingPathComponent(
                    Self.duplicateName(for: source.lastPathComponent, in: directory)
                )
                try Self.storeCopy(of: source, to: destination)
                return destination.lastPathComponent
            }
        }.value
        guard let copy else { return nil }

        var dates = contentDates(in: folder)
        if let date = dates[file.name] {
            dates[copy] = date
            writeContentDates(dates, in: folder)
        }
        var order = fileOrder(in: folder).filter { $0 != copy }
        if let index = order.firstIndex(of: file.name) {
            order.insert(copy, at: index + 1)
            setFileOrder(order, in: folder)
        }
        revision &+= 1
        return copy
    }

    /// Вставка из буфера и перетаскивание из других приложений. Загрузка
    /// начинается прямо в этом вызове: содержимое доступно только внутри
    /// обработчика PasteButton или onDrop, и отложенный Task опоздал бы
    /// (ответ инженера Apple: developer.apple.com/forums/thread/743984).
    /// Ожидание и запись на диск идут вне главного потока
    @MainActor
    func importItems(_ providers: [NSItemProvider], to folder: VaultFolder) -> Task<ImportResult, Never> {
        let directory = folderURL(folder)
        // Ссылка или чужой внутренний тип файлом не станут — их не считаем
        // ни добавленными, ни сломанными
        let accepted = providers.filter { Self.isExternal($0) && Self.importType(for: $0) != nil }
        let stamp = Date()
        let (stream, continuation) = AsyncStream.makeStream(of: ItemOutcome.self)
        for (index, provider) in accepted.enumerated() {
            Self.loadItem(provider, into: directory, stamp: stamp) { stored, label in
                continuation.yield(ItemOutcome(index: index, stored: stored, label: label))
            }
        }
        let expected = accepted.count
        return Task {
            var outcomes: [ItemOutcome] = []
            if expected > 0 {
                for await outcome in stream {
                    outcomes.append(outcome)
                    if outcomes.count == expected { break }
                }
            }
            continuation.finish()
            var result = ImportResult()
            for outcome in outcomes.sorted(by: { $0.index < $1.index }) {
                if let stored = outcome.stored {
                    result.imported.append(stored)
                } else {
                    result.failed.append(outcome.label)
                }
            }
            if !result.imported.isEmpty { revision &+= 1 }
            return result
        }
    }

    private struct ItemOutcome: Sendable {
        let index: Int
        /// Имя в папке; nil — не получилось
        let stored: String?
        /// Как назвать объект в сообщении об ошибке
        let label: String
    }

    /// Свои перетаскивания — порядок файлов и блоки ленты — файлами не становятся
    nonisolated static func isExternal(_ provider: NSItemProvider) -> Bool {
        !provider.registeredContentTypes.contains { $0.conforms(to: .localDriveFileName) || $0.conforms(to: .feedBlock) }
    }

    /// Какое представление взять. Имя файла подсказывает его собственный тип;
    /// без имени картинка берётся картинкой, документ — документом, текст —
    /// простым текстом. Ссылки не берутся: на iPhone к чужому файлу по ссылке
    /// доступа нет, а адрес сайта файлом не является
    nonisolated static func importType(for provider: NSItemProvider) -> UTType? {
        let types = provider.registeredContentTypes.filter { !$0.conforms(to: .url) }
        if let suggested = provider.suggestedName {
            let ext = (suggested as NSString).pathExtension
            if !ext.isEmpty, let named = UTType(filenameExtension: ext), !named.isDynamic,
               let match = types.first(where: { $0.conforms(to: named) }) {
                return match
            }
            return types.first
        }
        if let image = types.first(where: { $0.conforms(to: .image) }) { return image }
        if let document = types.first(where: {
            !$0.conforms(to: .text) && !$0.isDynamic && $0.preferredFilenameExtension != nil
        }) { return document }
        // Скопированная ссылка приходит ещё и текстом — файл из адреса не нужен
        let isLink = provider.registeredContentTypes.contains { $0.conforms(to: .url) }
        guard !isLink else { return nil }
        if let text = types.first(where: { $0.conforms(to: .plainText) }) { return text }
        return types.first
    }

    /// Имя вставленного файла: подсказанное источником или по дате, как у фото
    /// из галереи. Расширение дописывается или заменяется по типу данных
    nonisolated static func pastedName(suggested: String?, type: UTType, date: Date) -> String {
        let ext = type.preferredFilenameExtension ?? (type.conforms(to: .plainText) ? "txt" : nil)
        guard let suggested = cleanedName(suggested) else {
            let prefix = if type.conforms(to: .image) {
                "Фото"
            } else if type.conforms(to: .audiovisualContent) {
                "Видео"
            } else if type.conforms(to: .text) {
                "Текст"
            } else {
                "Файл"
            }
            let stem = "\(prefix) \(stampFormatter.string(from: date))"
            return ext.map { "\(stem).\($0)" } ?? stem
        }
        let current = (suggested as NSString).pathExtension
        if !current.isEmpty, let named = UTType(filenameExtension: current), !named.isDynamic {
            // «Скан.HEIC» с данными HEIC остаётся как есть, а «Скан.heic» с
            // данными JPEG получает верное расширение
            if named.conforms(to: type) || type.conforms(to: named) { return suggested }
            let base = (suggested as NSString).deletingPathExtension
            return ext.map { "\(base).\($0)" } ?? suggested
        }
        // «Отчёт v1.2» — точка в имени, а не расширение
        return ext.map { "\(suggested).\($0)" } ?? suggested
    }

    /// Имя от чужого приложения: без разделителей пути и без точки в начале —
    /// скрытый файл не появился бы в папке
    nonisolated static func cleanedName(_ name: String?) -> String? {
        guard var name = name?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(150)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// «Паспорт.pdf» → «Паспорт копия.pdf» → «Паспорт копия 2.pdf». У копии
    /// копии растёт номер, а не «копия копия» — как в Finder
    nonisolated static func duplicateName(for name: String, in directory: URL) -> String {
        let ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        if let suffix = base.range(of: #" копия( \d+)?$"#, options: .regularExpression) {
            base.removeSubrange(suffix)
        }
        var number = 1
        while true {
            let stem = number == 1 ? "\(base) копия" : "\(base) копия \(number)"
            let candidate = ext.isEmpty ? stem : "\(stem).\(ext)"
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
            number += 1
        }
    }

    /// Одно содержимое буфера или перетаскивания — в файл папки
    nonisolated private static func loadItem(
        _ provider: NSItemProvider,
        into directory: URL,
        stamp: Date,
        completion: @escaping @Sendable (_ stored: String?, _ label: String) -> Void
    ) {
        guard let type = importType(for: provider) else {
            completion(nil, cleanedName(provider.suggestedName) ?? "содержимое буфера")
            return
        }
        let name = pastedName(suggested: provider.suggestedName, type: type, date: stamp)
        if type.conforms(to: .image) {
            // Картинку из «Фото» или браузера отдают данными — их и пишем
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                completion(data.flatMap { try? write($0, named: name, into: directory) }, name)
            }
        } else {
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                // Временный файл живёт только до выхода из обработчика:
                // копируем его, не откладывая
                completion(url.flatMap { try? adopt($0, named: name, into: directory) }, name)
            }
        }
    }

    /// Выбор свободного имени и запись — под одним замком: обработчики буфера
    /// приходят параллельно и иначе выбрали бы одно имя на двоих
    private static let placementLock = NSLock()

    nonisolated private static func locked<T>(_ body: () throws -> T) rethrows -> T {
        placementLock.lock()
        defer { placementLock.unlock() }
        return try body()
    }

    nonisolated private static func write(_ data: Data, named name: String, into directory: URL) throws -> String {
        try locked {
            let destination = uniqueDestination(for: name, in: directory)
            try data.write(to: destination, options: [.withoutOverwriting, .completeFileProtection])
            return destination.lastPathComponent
        }
    }

    nonisolated private static func adopt(_ temporary: URL, named name: String, into directory: URL) throws -> String {
        try locked {
            let destination = uniqueDestination(for: name, in: directory)
            try storeCopy(of: temporary, to: destination)
            return destination.lastPathComponent
        }
    }

    /// Свободное имя выбирается в момент переноса: в папке назначения уже
    /// может лежать файл с тем же именем
    nonisolated private static func relocate(_ source: URL, into directory: URL) throws -> URL {
        try locked {
            let destination = uniqueDestination(for: source.lastPathComponent, in: directory)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
    }

    /// Копия под выбранным именем с тем же классом защиты, что у всего
    /// хранилища. Дата добавления — сейчас: копия появилась только что
    nonisolated private static func storeCopy(of source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete, .creationDate: Date()],
            ofItemAtPath: destination.path
        )
    }

    private static func tally(_ outcomes: [Result<URL, Error>], sources: [URL]) -> ([Placed], ImportResult) {
        var placed: [Placed] = []
        var result = ImportResult()
        for (source, outcome) in zip(sources, outcomes) {
            switch outcome {
            case .success(let url):
                placed.append(Placed(source: source, name: url.lastPathComponent))
                result.imported.append(url.lastPathComponent)
            case .failure:
                result.failed.append(source.lastPathComponent)
            }
        }
        return (placed, result)
    }

    /// Дата съёмки и место в ручном порядке переезжают под новым именем.
    /// При переносе запись в исходной папке убирается: иначе она досталась
    /// бы следующему файлу с тем же именем
    private func carryMetadata(
        _ placed: [Placed],
        from source: VaultFolder,
        to destination: VaultFolder,
        removingFromSource: Bool
    ) {
        var sourceDates = contentDates(in: source)
        var destinationDates = contentDates(in: destination)
        var carried = false
        var removed = false
        for item in placed {
            if let date = sourceDates[item.oldName] {
                destinationDates[item.name] = date
                carried = true
                if removingFromSource {
                    sourceDates[item.oldName] = nil
                    removed = true
                }
            }
        }
        if removed { writeContentDates(sourceDates, in: source) }
        if carried { writeContentDates(destinationDates, in: destination) }

        if removingFromSource {
            let gone = Set(placed.map(\.oldName))
            let order = fileOrder(in: source)
            if order.contains(where: gone.contains) {
                setFileOrder(order.filter { !gone.contains($0) }, in: source)
            }
        }
        let arrived = placed.map(\.name)
        let destinationOrder = fileOrder(in: destination)
        if !destinationOrder.isEmpty {
            // Повтор имени в порядке уронил бы сортировку: словарь позиций
            // строится по уникальным ключам
            let fresh = Set(arrived)
            setFileOrder(destinationOrder.filter { !fresh.contains($0) } + arrived, in: destination)
        }
    }

    private func writeContentDates(_ map: [String: Date], in folder: VaultFolder) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: contentDatesURL(for: folder), options: [.atomic, .completeFileProtection])
    }

    /// В ленте файл виден только внутри блока: медиа встают рядами в конец,
    /// остальное — отдельными блоками-файлами, как при импорте в ленту
    @MainActor
    private func appendToFeed(_ names: [String], in folder: VaultFolder) async {
        guard folder.kind == .feed, !names.isEmpty else { return }
        let directory = folderURL(folder)
        var media: [String] = []
        var documents: [String] = []
        var aspects: [String: Double] = [:]
        for name in names {
            let url = directory.appendingPathComponent(name)
            if MediaAspect.isMedia(url) {
                media.append(name)
                aspects[name] = await MediaAspect.probe(url) ?? MediaAspect.fallback
            } else {
                documents.append(name)
            }
        }
        addMediaBlocks(media, to: folder, aspects: aspects)
        addFileBlocks(documents, to: folder)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    // MARK: - Блочная лента

    private func feedMetaURL(for folder: VaultFolder) -> URL {
        folderURL(folder).appendingPathComponent(".feed.json")
    }

    func feedDocument(in folder: VaultFolder) -> FeedDocument {
        _ = revision // подписка на изменения
        if let cached = feedCache[folder.id] { return cached }
        var document = FeedDocument()
        if let data = try? Data(contentsOf: feedMetaURL(for: folder)) {
            let decoder = JSONDecoder()
            if let decoded = try? decoder.decode(FeedDocument.self, from: data) {
                document = decoded
            } else if let legacy = try? decoder.decode([FeedBlock].self, from: data) {
                // Формат до появления пропорций — просто массив блоков
                document = FeedDocument(blocks: legacy)
            }
        }
        feedCache[folder.id] = document
        return document
    }

    func feedBlocks(in folder: VaultFolder) -> [FeedBlock] {
        feedDocument(in: folder).blocks
    }

    func feedAspects(in folder: VaultFolder) -> [String: Double] {
        feedDocument(in: folder).aspects
    }

    /// Пропорции всех медиа документа: имена без записи считаются портретом,
    /// пока фоновый backfill не подставит настоящие значения
    func aspect(of fileName: String, in folder: VaultFolder) -> Double {
        feedDocument(in: folder).aspects[fileName] ?? MediaAspect.fallback
    }

    func setAspects(_ aspects: [String: Double], in folder: VaultFolder) {
        guard !aspects.isEmpty else { return }
        var document = feedDocument(in: folder)
        var changed = false
        for (name, value) in aspects where document.aspects[name] != value {
            document.aspects[name] = value
            changed = true
        }
        guard changed else { return }
        saveFeedDocument(document, in: folder)
    }

    /// Имена медиафайлов ленты, для которых пропорции ещё не посчитаны
    func fileNamesMissingAspect(in folder: VaultFolder) -> [String] {
        let document = feedDocument(in: folder)
        let dir = folderURL(folder)
        return document.blocks
            .filter { $0.kind == .media }
            .flatMap(\.fileNames)
            .filter { document.aspects[$0] == nil && MediaAspect.isMedia(dir.appendingPathComponent($0)) }
    }

    func file(named name: String, in folder: VaultFolder) -> VaultFile? {
        let url = folderURL(folder).appendingPathComponent(name)
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isDirectory != true else { return nil }
        let added = values.creationDate ?? .distantPast
        return VaultFile(
            url: url,
            name: name,
            size: Int64(values.fileSize ?? 0),
            addedAt: added,
            contentDate: values.contentModificationDate ?? added
        )
    }

    /// Все медиафайлы документа подряд — порядок совпадает с полноэкранным пейджером
    func feedMediaFiles(in folder: VaultFolder) -> [VaultFile] {
        feedBlocks(in: folder)
            .filter { $0.kind == .media }
            .flatMap(\.fileNames)
            .compactMap { file(named: $0, in: folder) }
    }

    // MARK: Добавление блоков

    @discardableResult
    func addTextBlock(_ text: String, to folder: VaultFolder, at index: Int? = nil) -> FeedBlock {
        var document = feedDocument(in: folder)
        let block = FeedBlock(kind: .text, text: text)
        let position = index.map { max(0, min($0, document.blocks.count)) } ?? document.blocks.count
        document.blocks.insert(block, at: position)
        saveFeedDocument(document, in: folder)
        return block
    }

    func updateTextBlock(id: UUID, text: String, in folder: VaultFolder) {
        var document = feedDocument(in: folder)
        guard let index = document.blocks.firstIndex(where: { $0.id == id }),
              document.blocks[index].text != text else { return }
        document.blocks[index].text = text
        saveFeedDocument(document, in: folder)
    }

    func addFileBlocks(_ fileNames: [String], to folder: VaultFolder, at index: Int? = nil) {
        guard !fileNames.isEmpty else { return }
        var document = feedDocument(in: folder)
        let position = index.map { max(0, min($0, document.blocks.count)) } ?? document.blocks.count
        let blocks = fileNames.map { FeedBlock(kind: .file, fileNames: [$0]) }
        document.blocks.insert(contentsOf: blocks, at: position)
        saveFeedDocument(document, in: folder)
    }

    /// Первичная вставка режет выборку на ряды по три — так же ведёт себя референс.
    /// Дальше ряд можно объединить или разделить вручную, и его длина ничем не ограничена.
    func addMediaBlocks(
        _ fileNames: [String],
        to folder: VaultFolder,
        at index: Int? = nil,
        aspects: [String: Double] = [:]
    ) {
        guard !fileNames.isEmpty else { return }
        var document = feedDocument(in: folder)
        var rows: [FeedBlock] = []
        for start in stride(from: 0, to: fileNames.count, by: 3) {
            let end = min(start + 3, fileNames.count)
            rows.append(FeedBlock(kind: .media, fileNames: Array(fileNames[start..<end])))
        }
        let position = index.map { max(0, min($0, document.blocks.count)) } ?? document.blocks.count
        document.blocks.insert(contentsOf: rows, at: position)
        document.aspects.merge(aspects) { _, new in new }
        saveFeedDocument(document, in: folder)
    }

    // MARK: Удаление

    func deleteFeedBlock(_ block: FeedBlock, in folder: VaultFolder) {
        deleteFeedBlocks(ids: [block.id], in: folder)
    }

    func deleteFeedBlocks(ids: Set<UUID>, in folder: VaultFolder) {
        guard !ids.isEmpty else { return }
        var document = feedDocument(in: folder)
        let doomed = document.blocks.filter { ids.contains($0.id) }
        guard !doomed.isEmpty else { return }
        document.blocks.removeAll { ids.contains($0.id) }
        for name in doomed.flatMap(\.fileNames) {
            try? fm.removeItem(at: folderURL(folder).appendingPathComponent(name))
            document.aspects[name] = nil
            onChange?(.fileRemoved(folder: folder.id, name: name))
        }
        saveFeedDocument(document, in: folder)
    }

    // MARK: Перестановка

    /// Вставка по явному индексу в исходном массиве: цель считается ДО удаления
    /// источника, поэтому индекс корректируется при движении вниз
    func moveFeedBlock(id: UUID, toIndex index: Int, in folder: VaultFolder) {
        moveFeedBlocks(ids: [id], toIndex: index, in: folder)
    }

    /// Групповой вариант для режима выделения — относительный порядок блоков сохраняется
    func moveFeedBlocks(ids: Set<UUID>, toIndex index: Int, in folder: VaultFolder) {
        guard !ids.isEmpty else { return }
        var document = feedDocument(in: folder)
        let original = document.blocks
        let target = max(0, min(index, original.count))
        let moving = original.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }

        // Сколько выделенных блоков лежит выше точки вставки — на столько она сдвинется
        let removedAbove = original.prefix(target).filter { ids.contains($0.id) }.count
        var rest = original.filter { !ids.contains($0.id) }
        let destination = max(0, min(target - removedAbove, rest.count))
        rest.insert(contentsOf: moving, at: destination)
        guard rest.map(\.id) != original.map(\.id) else { return }
        document.blocks = rest
        saveFeedDocument(document, in: folder)
    }

    func moveFeedBlock(id: UUID, offset: Int, in folder: VaultFolder) {
        let blocks = feedBlocks(in: folder)
        guard let source = blocks.firstIndex(where: { $0.id == id }) else { return }
        let destination = max(0, min(source + offset, blocks.count - 1))
        guard source != destination else { return }
        // toIndex работает в координатах исходного массива: вниз целимся за соседа
        moveFeedBlock(id: id, toIndex: offset > 0 ? destination + 1 : destination, in: folder)
    }

    func canMoveFeedBlock(id: UUID, offset: Int, in folder: VaultFolder) -> Bool {
        let blocks = feedBlocks(in: folder)
        guard let source = blocks.firstIndex(where: { $0.id == id }) else { return false }
        return blocks.indices.contains(source + offset)
    }

    /// Перенос одного фото: между позициями внутри ряда или в соседний ряд.
    /// Опустевший ряд-источник исчезает.
    func moveFeedMedia(
        fileName: String,
        from sourceBlockID: UUID,
        to targetBlockID: UUID,
        atIndex index: Int,
        in folder: VaultFolder
    ) {
        var document = feedDocument(in: folder)
        guard let sourceIndex = document.blocks.firstIndex(where: { $0.id == sourceBlockID }),
              let offset = document.blocks[sourceIndex].fileNames.firstIndex(of: fileName) else { return }

        var destination = max(0, index)
        if sourceBlockID == targetBlockID {
            guard destination != offset, destination != offset + 1 else { return }
            if destination > offset { destination -= 1 }
            document.blocks[sourceIndex].fileNames.remove(at: offset)
            destination = min(destination, document.blocks[sourceIndex].fileNames.count)
            document.blocks[sourceIndex].fileNames.insert(fileName, at: destination)
        } else {
            document.blocks[sourceIndex].fileNames.remove(at: offset)
            guard let targetIndex = document.blocks.firstIndex(where: { $0.id == targetBlockID }),
                  document.blocks[targetIndex].kind == .media else { return }
            destination = min(destination, document.blocks[targetIndex].fileNames.count)
            document.blocks[targetIndex].fileNames.insert(fileName, at: destination)
            if document.blocks[sourceIndex].fileNames.isEmpty {
                document.blocks.remove(at: sourceIndex)
            }
        }
        saveFeedDocument(document, in: folder)
    }

    /// Вынести фото в собственный ряд на указанную позицию списка блоков
    func extractFeedMedia(
        fileName: String,
        from sourceBlockID: UUID,
        toBlockIndex index: Int,
        in folder: VaultFolder
    ) {
        var document = feedDocument(in: folder)
        guard let sourceIndex = document.blocks.firstIndex(where: { $0.id == sourceBlockID }),
              let offset = document.blocks[sourceIndex].fileNames.firstIndex(of: fileName) else { return }
        // Единственное фото ряда уже стоит там, куда его тянут
        if document.blocks[sourceIndex].fileNames.count == 1,
           index == sourceIndex || index == sourceIndex + 1 { return }

        document.blocks[sourceIndex].fileNames.remove(at: offset)
        var target = max(0, min(index, document.blocks.count))
        if document.blocks[sourceIndex].fileNames.isEmpty {
            document.blocks.remove(at: sourceIndex)
            if target > sourceIndex { target -= 1 }
        }
        target = max(0, min(target, document.blocks.count))
        document.blocks.insert(FeedBlock(kind: .media, fileNames: [fileName]), at: target)
        saveFeedDocument(document, in: folder)
    }

    // MARK: Ряды

    func canMergeMediaBlockWithPrevious(_ block: FeedBlock, in folder: VaultFolder) -> Bool {
        guard block.kind == .media else { return false }
        let blocks = feedBlocks(in: folder)
        guard let index = blocks.firstIndex(where: { $0.id == block.id }), index > 0 else { return false }
        return blocks[index - 1].kind == .media
    }

    func mergeMediaBlockWithPrevious(_ block: FeedBlock, in folder: VaultFolder) {
        var document = feedDocument(in: folder)
        guard let index = document.blocks.firstIndex(where: { $0.id == block.id }), index > 0,
              document.blocks[index - 1].kind == .media,
              document.blocks[index].kind == .media else { return }
        document.blocks[index - 1].fileNames.append(contentsOf: document.blocks[index].fileNames)
        document.blocks.remove(at: index)
        saveFeedDocument(document, in: folder)
    }

    /// Все выделенные соседние медиа-ряды в один
    func canMergeMediaBlocks(ids: Set<UUID>, in folder: VaultFolder) -> Bool {
        let blocks = feedBlocks(in: folder)
        let indices = blocks.indices.filter { ids.contains(blocks[$0].id) }
        guard indices.count > 1, indices.allSatisfy({ blocks[$0].kind == .media }) else { return false }
        return indices.last! - indices.first! == indices.count - 1
    }

    func mergeMediaBlocks(ids: Set<UUID>, in folder: VaultFolder) {
        guard canMergeMediaBlocks(ids: ids, in: folder) else { return }
        var document = feedDocument(in: folder)
        let indices = document.blocks.indices.filter { ids.contains(document.blocks[$0].id) }
        guard let first = indices.first, let last = indices.last else { return }
        let names = indices.flatMap { document.blocks[$0].fileNames }
        let merged = FeedBlock(kind: .media, fileNames: names, createdAt: document.blocks[first].createdAt)
        document.blocks.replaceSubrange(first...last, with: [merged])
        saveFeedDocument(document, in: folder)
    }

    func splitMediaBlock(_ block: FeedBlock, in folder: VaultFolder) {
        guard block.kind == .media, block.fileNames.count > 1 else { return }
        var document = feedDocument(in: folder)
        guard let index = document.blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let replacements = document.blocks[index].fileNames.map {
            FeedBlock(kind: .media, fileNames: [$0], createdAt: block.createdAt)
        }
        document.blocks.replaceSubrange(index...index, with: replacements)
        saveFeedDocument(document, in: folder)
    }

    func splitMediaBlocks(ids: Set<UUID>, in folder: VaultFolder) {
        var document = feedDocument(in: folder)
        var changed = false
        for id in ids {
            guard let index = document.blocks.firstIndex(where: { $0.id == id }),
                  document.blocks[index].kind == .media,
                  document.blocks[index].fileNames.count > 1 else { continue }
            let block = document.blocks[index]
            let replacements = block.fileNames.map {
                FeedBlock(kind: .media, fileNames: [$0], createdAt: block.createdAt)
            }
            document.blocks.replaceSubrange(index...index, with: replacements)
            changed = true
        }
        guard changed else { return }
        saveFeedDocument(document, in: folder)
    }

    private func saveFeedDocument(_ document: FeedDocument, in folder: VaultFolder) {
        feedCache[folder.id] = document
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: feedMetaURL(for: folder), options: [.atomic, .completeFileProtection])
        revision &+= 1
    }

    // Уникальное имя в каталоге: "name.ext", "name (1).ext", ...
    private func uniqueURL(for name: String, in dir: URL) -> URL {
        Self.uniqueDestination(for: name, in: dir)
    }

    nonisolated static func uniqueDestination(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var i = 1
        repeat {
            let newName = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            i += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}

// MARK: - Вложения чата

extension VaultStore {
    /// Файл из вложений чата — в папку под выбранным именем. Свободное имя
    /// выбирается в момент записи, в ленте файл встаёт блоком, как при импорте.
    /// Индекс находит новый файл сверкой по ревизии
    @MainActor
    @discardableResult
    func saveFile(at source: URL, named name: String, to folder: VaultFolder) async -> String? {
        let directory = folderURL(folder)
        let clean = Self.cleanedName(name) ?? source.lastPathComponent
        let stored = try? await Task.detached(priority: .userInitiated) {
            try Self.adopt(source, named: clean, into: directory)
        }.value
        guard let stored else { return nil }
        revision &+= 1
        await appendToFeed([stored], in: folder)
        return stored
    }

    /// Новая обычная папка, доступная для поиска, — и сама она в ответ.
    /// `parentID` — внутри какой; в ленте или пропавшей папке — nil
    @discardableResult
    func addFolder(
        named name: String,
        icon: String = "folder.fill",
        color: String = "indigo",
        parentID: UUID? = nil
    ) -> VaultFolder? {
        createFolder(name: name, icon: icon, color: color, parentID: parentID)
    }
}
