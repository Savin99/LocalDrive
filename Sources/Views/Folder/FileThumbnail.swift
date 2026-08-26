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
        .frame(width: size.width, height: size.height)
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
            image = cached
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
            image = thumb.uiImage
        } catch {
            // Тип без превью (архив, неизвестный формат) — показываем иконку
            failed = true
        }
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
