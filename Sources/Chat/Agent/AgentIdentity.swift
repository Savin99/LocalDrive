import Foundation

/// Чистое описание агента: кто он, где находится и как мыслит.
/// Источник правды — `Sources/Chat/Agent/AGENT.md`, подключённый ресурсом в бандл.
enum AgentIdentity {
    static let resourceName = "AGENT"
    static let resourceExtension = "md"

    /// Текст `AGENT.md` из бандла приложения (или тестового бандла).
    static let instructions: String = load()

    /// Путь к ресурсу в бандле — проверяется тестами, чтобы файл гарантированно попадал в сборку.
    static var resourceURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
            ?? Bundle(for: BundleAnchor.self).url(forResource: resourceName, withExtension: resourceExtension)
    }

    private static func load() -> String {
        if let url = resourceURL,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return fallback
    }

    private final class BundleAnchor {}

    private static let fallback = """
    # Агент LocalDrive

    Ты — живой, умный, внимательный собеседник внутри приложения LocalDrive на iPhone (личное локальное хранилище документов, файлов и «Карточек»).
    Думай сам и принимай решения по контексту разговора, без заученных шаблонов. Не выдумывай факты и числа; если нужного нет в описи — посмотри документ через view_document или вложение через view_attachment.
    Не навязывай сохранение в папку, когда просят помочь с содержимым файла. Изменения файлов, полей и «Карточек» — только через инструменты-предложения, с подтверждением кнопкой.
    Никогда не пиши в открытом тексте серии, номера документов и коды подразделений — показывай их карточкой документа (включая series_number и department_code). Краткие итоги рассуждений пиши по-русски.
    """
}
