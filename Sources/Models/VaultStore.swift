import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Метаданные папки хранилища
struct VaultFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var icon: String
    var color: String
    var createdAt: Date
}

// Файл внутри папки — читается напрямую с диска
struct VaultFile: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let size: Int64
    let addedAt: Date

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

    private let fm = FileManager.default
    private let root: URL
    private var metaURL: URL { root.appendingPathComponent("vault.json") }

    init() {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Vault", isDirectory: true)
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
        folders = decoded
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

    func createFolder(name: String, icon: String, color: String) {
        let folder = VaultFolder(id: UUID(), name: name, icon: icon, color: color, createdAt: Date())
        try? fm.createDirectory(
            at: folderURL(folder),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        folders.append(folder)
        save()
        revision &+= 1
    }

    func updateFolder(id: UUID, name: String, icon: String, color: String) {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[idx].name = name
        folders[idx].icon = icon
        folders[idx].color = color
        save()
        revision &+= 1
    }

    func deleteFolder(_ folder: VaultFolder) {
        try? fm.removeItem(at: folderURL(folder))
        folders.removeAll { $0.id == folder.id }
        save()
        revision &+= 1
    }

    // MARK: - Файлы

    func files(in folder: VaultFolder) -> [VaultFile] {
        _ = revision // подписка на изменения
        let dir = folderURL(folder)
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url -> VaultFile? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .isDirectoryKey]),
                  values.isDirectory != true else { return nil }
            return VaultFile(
                url: url,
                name: url.lastPathComponent,
                size: Int64(values.fileSize ?? 0),
                addedAt: values.creationDate ?? .distantPast
            )
        }
        .sorted { $0.addedAt > $1.addedAt }
    }

    func stats(for folder: VaultFolder) -> (count: Int, size: Int64) {
        let items = files(in: folder)
        return (items.count, items.reduce(0) { $0 + $1.size })
    }

    /// Последние файлы папки — для коллажа на её карточке
    func previewFiles(in folder: VaultFolder, limit: Int = 4) -> [VaultFile] {
        Array(files(in: folder).prefix(limit))
    }

    /// Недавно добавленное по всем папкам
    func recentFiles(limit: Int = 10) -> [(file: VaultFile, folder: VaultFolder)] {
        folders
            .flatMap { folder in files(in: folder).map { (file: $0, folder: folder) } }
            .sorted { $0.file.addedAt > $1.file.addedAt }
            .prefix(limit)
            .map { $0 }
    }

    // Импорт из «Файлов» (security-scoped доступ обеспечивает вызывающий код)
    func importFile(from source: URL, to folder: VaultFolder) {
        let dst = uniqueURL(for: source.lastPathComponent, in: folderURL(folder))
        do {
            try fm.copyItem(at: source, to: dst)
            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.complete, .creationDate: Date()],
                ofItemAtPath: dst.path
            )
            revision &+= 1
        } catch {
            // Ошибку копирования просто пропускаем, файл-источник не трогаем
        }
    }

    // Импорт бинарных данных (фото/видео из галереи)
    func importData(_ data: Data, preferredName: String, to folder: VaultFolder) {
        let dst = uniqueURL(for: preferredName, in: folderURL(folder))
        try? data.write(to: dst, options: [.atomic, .completeFileProtection])
        revision &+= 1
    }

    func deleteFile(_ file: VaultFile) {
        try? fm.removeItem(at: file.url)
        revision &+= 1
    }

    func renameFile(_ file: VaultFile, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ext = file.url.pathExtension
        let fullName = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
        let dst = uniqueURL(for: fullName, in: file.url.deletingLastPathComponent())
        try? fm.moveItem(at: file.url, to: dst)
        revision &+= 1
    }

    // Уникальное имя в каталоге: "name.ext", "name (1).ext", ...
    private func uniqueURL(for name: String, in dir: URL) -> URL {
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
