import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// Пропорции медиафайла (ширина / высота) — основа justified-раскладки ряда.
// Считаются один раз при импорте и хранятся в .feed.json, чтобы вёрстка
// не прыгала, пока грузятся миниатюры.
enum MediaAspect {
    /// Значение по умолчанию, пока настоящие пропорции неизвестны: портрет 3:4
    static let fallback: Double = 0.75

    /// Разумный диапазон — панорама или очень узкий кадр не должны ломать ряд
    static func clamp(_ value: Double) -> Double {
        min(max(value, 0.35), 3.0)
    }

    static func isMedia(_ url: URL) -> Bool {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video)
    }

    static func probe(_ url: URL) async -> Double? {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) {
            return await Task.detached(priority: .utility) { probeImage(url) }.value
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return await probeVideo(url)
        }
        return nil
    }

    // Метаданные заголовка — без декодирования пикселей
    private static func probeImage(_ url: URL) -> Double? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }

        // EXIF-ориентации 5–8 меняют стороны местами
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapped = orientation >= 5 && orientation <= 8
        return clamp(swapped ? height / width : width / height)
    }

    private static func probeVideo(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let oriented = size.applying(transform)
        let width = abs(oriented.width)
        let height = abs(oriented.height)
        guard width > 0, height > 0 else { return nil }
        return clamp(Double(width / height))
    }
}
