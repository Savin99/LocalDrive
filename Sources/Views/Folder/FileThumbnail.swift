import SwiftUI
import QuickLookThumbnailing

// Кэш миниатюр: ключ — путь файла + размер в точках
private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 300
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    /// Пропорции листа (ширина к высоте) — по пути файла, без размера: лист
    /// сразу рисуется своей формы, а не прыгает, когда догрузится превью
    private let aspects = NSCache<NSString, NSNumber>()

    func aspect(for path: String) -> CGFloat? {
        aspects.object(forKey: path as NSString).map { CGFloat($0.doubleValue) }
    }

    func storeAspect(of image: UIImage, for path: String) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        aspects.setObject(NSNumber(value: Double(image.size.width / image.size.height)), forKey: path as NSString)
    }
}

// Миниатюра файла: реальное содержимое (фото, первая страница документа),
// с запасным вариантом — иконка по типу файла
struct FileThumbnail: View {
    let file: VaultFile
    let accent: Color
    let size: CGSize
    var cornerRadius: CGFloat = 14
    /// В коллаже обводка не нужна — ячейки и без неё разделены зазором
    var showsBorder: Bool = true
    /// Занять предложенное место вместо фиксированного `size`: в ряду ленты
    /// размеры ячеек считает раскладка, а `size` нужен только для запроса превью
    var fills: Bool = false
    /// Какой край превью виден, когда оно обрезается: у листа, выглядывающего
    /// из папки, — верх документа
    var alignment: Alignment = .center
    /// Пропорции превью (ширина к высоте), когда оно загрузилось
    var onAspect: ((CGFloat) -> Void)?

    /// Пропорции файла, если его превью уже грузили
    static func cachedAspect(of file: VaultFile) -> CGFloat? {
        ThumbnailCache.shared.aspect(for: file.url.path)
    }

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var textSnippet: String?
    @State private var failed = false

    // Превью текста системными средствами выходит нечитаемым — рисуем сами,
    // но только если карточка достаточно крупная
    private var showsTextSnippet: Bool {
        file.type.conforms(to: .text) && size.width >= 100
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let textSnippet {
                Theme.card
                Text(textSnippet)
                    .font(.system(size: max(6, size.width * 0.05), design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.75))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(size.width * 0.08)
            } else {
                accent.opacity(0.13)
                if failed {
                    Image(systemName: file.iconName)
                        .font(.system(size: min(size.width, size.height) * 0.32, weight: .medium))
                        .foregroundStyle(accent)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .frame(
            maxWidth: fills ? .infinity : size.width,
            maxHeight: fills ? .infinity : size.height,
            alignment: alignment
        )
        .frame(width: fills ? nil : size.width, height: fills ? nil : size.height, alignment: alignment)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            // Тонкая обводка: без неё светлые превью (страница текста) сливаются с фоном
            if showsBorder {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.7)
            }
        }
        .task(id: file.id) { await load() }
    }

    private var cacheKey: String {
        "\(file.url.path)|\(Int(size.width))x\(Int(size.height))"
    }

    private func load() async {
        if showsTextSnippet {
            textSnippet = await Self.snippet(of: file.url)
            if textSnippet == nil { failed = true }
            return
        }

        if file.type.conforms(to: .text) {
            // Мелкая миниатюра текста бесполезна — сразу иконка
            failed = true
            return
        }

        if let cached = ThumbnailCache.shared.image(for: cacheKey) {
            show(cached)
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: file.url,
            size: size,
            scale: displayScale,
            representationTypes: .thumbnail
        )

        do {
            let thumb = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            ThumbnailCache.shared.store(thumb.uiImage, for: cacheKey)
            show(thumb.uiImage)
        } catch {
            // Тип без превью (архив, неизвестный формат) — показываем иконку
            failed = true
        }
    }

    private func show(_ loaded: UIImage) {
        ThumbnailCache.shared.storeAspect(of: loaded, for: file.url.path)
        image = loaded
        if loaded.size.height > 0 { onAspect?(loaded.size.width / loaded.size.height) }
    }

    // Первые строки текстового файла для превью
    private static func snippet(of url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else { return nil }
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(400))
        }.value
    }
}
