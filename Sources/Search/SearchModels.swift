import Foundation

/// Тип документа. Пока распознаётся только паспорт РФ, остальные — задел
/// под следующие типы из спецификации
enum DocumentType: String, Codable, CaseIterable, Sendable {
    case passportRU = "passport_ru"
    case passportIntl = "passport_intl"
    case snils
    case inn
    case driverLicense = "driver_license"
    case diploma
    case certificate
    case other

    var title: String {
        switch self {
        case .passportRU: "Паспорт РФ"
        case .passportIntl: "Загранпаспорт"
        case .snils: "СНИЛС"
        case .inn: "ИНН"
        case .driverLicense: "Водительское удостоверение"
        case .diploma: "Диплом"
        case .certificate: "Справка"
        case .other: "Документ"
        }
    }
}

/// Откуда взято значение поля
enum FieldSource: String, Codable, Sendable {
    case mrz
    case regex
    case llm
    /// Облачное распознавание (OpenAI или Gemini)
    case cloud
    case manual
}

/// Поле документа: серия и номер, дата выдачи и так далее
struct DocumentField: Hashable, Sendable {
    let key: String
    var value: String
    /// 0…1. Ниже `DocumentField.trustedConfidence` поле помечается для сверки с фото
    var confidence: Double
    var source: FieldSource
    /// Человек проверил или исправил значение руками
    var verified: Bool

    static let trustedConfidence = 0.9

    var needsReview: Bool { !verified && confidence < Self.trustedConfidence }
}

/// Документ, найденный в индексе
struct SearchHit: Hashable, Sendable {
    let documentID: Int64
    let folderID: UUID
    let fileName: String
    let type: DocumentType
    /// Страница лучшего совпадения в тексте; nil — совпало только имя
    let page: Int?
    let pageCount: Int
    /// Фрагмент вокруг совпадения, совпавшие слова — `stronglyEmphasized`
    let snippet: AttributedString?

    var key: FileKey { FileKey(folderID: folderID, name: fileName) }
}

/// Сколько документов уже в индексе и сколько ждут распознавания
struct SearchIndexProgress: Equatable, Sendable {
    var indexed = 0
    var pending = 0
    /// Модель для документов подключена к индексу
    var hasDocumentModel = false
    /// Удостоверений в папках, доступных для поиска
    var identityDocuments = 0
    /// Сколько из них прочитала текущая модель
    var modelRead = 0
    /// Удостоверения, которые ждут второго чтения моделью
    var modelPending = 0
    /// Модель читает документ прямо сейчас
    var modelReading = false
    /// Почему модель сейчас не читает: не хватает памяти, симулятор
    var modelUnavailable: String?
    /// Облачное распознавание включено и с ключом
    var hasCloud = false
    /// Документов в папках, доступных для поиска
    var cloudDocuments = 0
    /// Сколько из них прочитало облако с текущими настройками
    var cloudRead = 0
    /// Ждут облака
    var cloudPending = 0
    var cloudReading = false
    /// Почему облако остановилось: нет VPN, ключ не подходит, перегружено
    var cloudPaused: String?

    var isIndexing: Bool { pending > 0 }
}
