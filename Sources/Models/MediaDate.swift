import AVFoundation
import Foundation
import ImageIO

// Дата самого файла — когда снято фото или записано видео.
// Отличается от даты добавления в хранилище: импорт ставит файлу
// свежую дату создания, а исходную мы вытаскиваем из метаданных
enum MediaDate {
    /// Читает дату съёмки из EXIF или из метаданных видео. Работает с диском,
    /// поэтому вызывать только вне главного потока
    static func originalDate(of url: URL) -> Date? {
        if let date = exifDate(of: url) { return date }
        return assetDate(of: url)
    }

    private static func exifDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized] {
                if let text = exif[key] as? String, let date = exifFormatter.date(from: text) {
                    return date
                }
            }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let text = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = exifFormatter.date(from: text) {
            return date
        }
        return nil
    }

    private static func assetDate(of url: URL) -> Date? {
        let asset = AVURLAsset(url: url)
        for item in asset.commonMetadata where item.commonKey == .commonKeyCreationDate {
            if let date = item.dateValue { return date }
            if let text = item.stringValue, let date = isoFormatter.date(from: text) { return date }
        }
        return nil
    }

    // EXIF пишет дату без часового пояса, в локальном времени съёмки
    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let isoFormatter = ISO8601DateFormatter()
}
