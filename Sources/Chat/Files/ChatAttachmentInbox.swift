import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Файл, брошенный в чат: временная копия, пока человек не решил, куда его положить
struct ChatAttachment: Identifiable, Hashable, Sendable {
    /// «a1», «a2» — так на вложение ссылаются модель и карточки
    let id: String
    let name: String
    /// Временная копия с классом защиты .complete
    let url: URL
    let contentType: UTType?
    let byteCount: Int64

    /// Для превью — те же миниатюры, что у файлов хранилища
    var previewFile: VaultFile {
        VaultFile(url: url, name: name, size: byteCount, addedAt: Date(), contentDate: Date())
    }
}

// Вложения чата живут во временной папке: в хранилище их кладёт только
// «Выполнить» в карточке предложения. Копии стираются при удалении из ленты
// вложений, при «Новом чате» и при следующем запуске, если приложение
// закрылось раньше. Каждое вложение — в своём подкаталоге: имя файла остаётся
// исходным, а одинаковые имена не сталкиваются
@MainActor
@Observable
final class ChatAttachmentInbox {
    private(set) var items: [ChatAttachment] = []
    /// Ещё не отправленные — те, что видны над полем ввода. Отправленные
    /// остаются в ящике до решения, куда их положить, но с поля уходят
    private var draftIDs: [String] = []
    /// Имена и тех вложений, которых уже нет: карточка в переписке должна
    /// назвать файл и после того, как его сохранили
    @ObservationIgnored private(set) var names: [String: String] = [:]
    /// Куда сохранили вложение: карточка в переписке так и скажет
    private(set) var savedFolders: [String: String] = [:]
    @ObservationIgnored let directory: URL

    /// Номера на весь запуск приложения: «a1» не достанется другому файлу,
    /// даже если вложение удалили, а предложение с ним осталось в переписке
    private static var counter = 0
    private static var purged: Set<URL> = []

    /// Длинная сторона кадра для модели
    nonisolated static let maxModelSide: CGFloat = 2048

    /// Заглушка, если экран чата не передал свои вложения: сохранять из неё
    /// нечего, но переносы и переименования выполнятся
    static let unavailable = ChatAttachmentInbox(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("ChatAttachmentsUnavailable", isDirectory: true)
    )

    nonisolated static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ChatAttachments", isDirectory: true)
    }

    /// Остатки прошлого запуска стираются при первом создании за запуск
    init(directory: URL? = nil) {
        let directory = directory ?? Self.defaultDirectory
        self.directory = directory
        if Self.purged.insert(directory.standardizedFileURL).inserted {
            try? FileManager.default.removeItem(at: directory)
        }
        Self.prepare(directory)
    }

    func item(_ id: String) -> ChatAttachment? {
        items.first { $0.id == id }
    }

    /// Вложения в поле ввода, в порядке добавления
    var draft: [ChatAttachment] {
        draftIDs.compactMap { id in items.first { $0.id == id } }
    }

    /// Отправка: вложения уходят с поля ввода в переписку, файлы остаются
    func takeDraft() -> [ChatAttachment] {
        let taken = draft
        draftIDs.removeAll()
        return taken
    }

    // MARK: - Добавление

    /// Из окна выбора файлов: копия под NSFileCoordinator, как при импорте в
    /// папку, — недокачанный из iCloud файл сначала скачивается
    func add(urls: [URL]) async -> [ChatAttachment] {
        var added: [ChatAttachment] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let id = Self.nextID()
            let folder = directory.appendingPathComponent(id, isDirectory: true)
            do {
                let copied = try await Task.detached(priority: .userInitiated) {
                    try Self.prepareItemFolder(folder)
                    return try VaultStore.coordinatedCopy(from: url, into: folder)
                }.value
                added.append(attachment(id: id, at: copied))
            } catch {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        items += added
        draftIDs += added.map(\.id)
        return added
    }

    /// Готовые данные — фото из галереи
    func add(data: Data, named name: String) async -> ChatAttachment? {
        let id = Self.nextID()
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        let clean = VaultStore.cleanedName(name) ?? "Файл"
        let stored = try? await Task.detached(priority: .userInitiated) {
            try Self.prepareItemFolder(folder)
            let destination = folder.appendingPathComponent(clean)
            try data.write(to: destination, options: [.withoutOverwriting, .completeFileProtection])
            return destination
        }.value
        guard let stored else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        let item = attachment(id: id, at: stored)
        items.append(item)
        draftIDs.append(item.id)
        return item
    }

    /// Вставка и перетаскивание. Загрузка начинается прямо в этом вызове:
    /// содержимое буфера доступно только внутри обработчика PasteButton или
    /// onDrop (см. VaultStore.importItems), поэтому вызывать — синхронно из него
    func beginAdding(providers: [NSItemProvider]) -> Task<[ChatAttachment], Never> {
        let accepted = providers.filter { VaultStore.isExternal($0) && VaultStore.importType(for: $0) != nil }
        let stamp = Date()
        var slots: [(id: String, folder: URL)] = []
        let (stream, continuation) = AsyncStream.makeStream(of: Loaded.self)
        for (index, provider) in accepted.enumerated() {
            let id = Self.nextID()
            let folder = directory.appendingPathComponent(id, isDirectory: true)
            slots.append((id, folder))
            Self.load(provider, into: folder, stamp: stamp) { url in
                continuation.yield(Loaded(index: index, url: url))
            }
        }
        let expected = accepted.count
        return Task {
            var urls: [Int: URL] = [:]
            var received = 0
            if expected > 0 {
                for await loaded in stream {
                    received += 1
                    if let url = loaded.url { urls[loaded.index] = url }
                    if received == expected { break }
                }
            }
            continuation.finish()
            var added: [ChatAttachment] = []
            for (index, slot) in slots.enumerated() {
                if let url = urls[index] {
                    added.append(attachment(id: slot.id, at: url))
                } else {
                    try? FileManager.default.removeItem(at: slot.folder)
                }
            }
            items += added
            draftIDs += added.map(\.id)
            return added
        }
    }

    func add(providers: [NSItemProvider]) async -> [ChatAttachment] {
        await beginAdding(providers: providers).value
    }

    // MARK: - Удаление

    func remove(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        draftIDs.removeAll { $0 == id }
        try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
    }

    /// «Новый чат»: копии стираются вместе с перепиской
    func clear() {
        for item in items {
            try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
        }
        items.removeAll()
        draftIDs.removeAll()
        names.removeAll()
        savedFolders.removeAll()
    }

    /// Вложение сохранили в папку: временная копия больше не нужна
    func markSaved(_ id: String, in folderName: String) {
        savedFolders[id] = folderName
        remove(id)
    }

    // MARK: - Кадр для модели

    /// JPEG не больше 2048 px по длинной стороне: фото или первая страница PDF.
    /// Для остальных типов — nil
    func modelImage(_ id: String) async -> Data? {
        guard let item = item(id) else { return nil }
        let url = item.url
        let type = item.contentType
        return await Task.detached(priority: .userInitiated) {
            Self.jpeg(of: url, type: type)
        }.value
    }

    nonisolated static func jpeg(of url: URL, type: UTType?) -> Data? {
        guard let type else { return nil }
        let image: CGImage?
        if type.conforms(to: .pdf) {
            image = firstPage(of: url)
        } else if type.conforms(to: .image) {
            image = downsampled(url)
        } else {
            return nil
        }
        return image.flatMap { encodeJPEG($0, quality: 0.85) }
    }

    nonisolated private static func downsampled(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxModelSide,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    nonisolated private static func firstPage(of url: URL) -> CGImage? {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let rotated = page.rotation % 180 != 0
        let width = rotated ? bounds.height : bounds.width
        let height = rotated ? bounds.width : bounds.height
        let scale = maxModelSide / max(width, height)
        let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        return autoreleasepool { page.thumbnail(of: size, for: .mediaBox).cgImage }
    }

    nonisolated private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - Служебное

    private struct Loaded: Sendable {
        let index: Int
        let url: URL?
    }

    private static func nextID() -> String {
        counter += 1
        return "a\(counter)"
    }

    private func attachment(id: String, at url: URL) -> ChatAttachment {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let item = ChatAttachment(
            id: id,
            name: url.lastPathComponent,
            url: url,
            contentType: UTType(filenameExtension: url.pathExtension),
            byteCount: size
        )
        names[id] = item.name
        return item
    }

    /// Каталог вложений — с защитой .complete и вне резервной копии iPhone
    nonisolated private static func prepare(_ directory: URL) {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    nonisolated private static func prepareItemFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
    }

    /// Одно содержимое буфера или перетаскивания — во временный файл
    nonisolated private static func load(
        _ provider: NSItemProvider,
        into folder: URL,
        stamp: Date,
        completion: @escaping @Sendable (URL?) -> Void
    ) {
        guard let type = VaultStore.importType(for: provider),
              (try? prepareItemFolder(folder)) != nil else {
            completion(nil)
            return
        }
        let destination = folder.appendingPathComponent(
            VaultStore.pastedName(suggested: provider.suggestedName, type: type, date: stamp)
        )
        if type.conforms(to: .image) {
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                let written = data.flatMap { try? $0.write(to: destination, options: [.withoutOverwriting, .completeFileProtection]) }
                completion(written == nil ? nil : destination)
            }
        } else {
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                // Временный файл живёт только до выхода из обработчика
                guard let url, (try? FileManager.default.copyItem(at: url, to: destination)) != nil else {
                    completion(nil)
                    return
                }
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
                completion(destination)
            }
        }
    }
}
