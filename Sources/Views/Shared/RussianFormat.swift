import Foundation

// Числа и даты на экранах — по-русски, как весь интерфейс. Язык разработки
// приложения английский, поэтому без явной локали системный формат дал бы
// «396 bytes» и «Oct 12, 2026»
enum RussianFormat {
    static let locale = Locale(identifier: "ru_RU")

    /// «1,2 МБ»; для точности — с байтами в скобках: «1,2 МБ (1 234 567 байт)»
    static func size(_ bytes: Int64, exact: Bool = false) -> String {
        let style = ByteCountFormatStyle(
            style: .file,
            allowedUnits: .all,
            spellsOutZero: true,
            includesActualByteCount: exact && bytes >= 1024,
            locale: locale
        )
        return bytes.formatted(style)
    }

    /// «12 октября 2026 г. в 14:41»
    static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(locale))
    }
}
