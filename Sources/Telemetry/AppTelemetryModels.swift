import Foundation

/// Повод отправки пакета в `app-logs` v1.
enum TelemetryTrigger: String, Codable, Sendable {
    case launch
    case background
    case error
    case userFlag = "user_flag"
    case metrickit
    case periodic
    case manual
}

/// Тип события в конверте `app-logs` v1.
enum TelemetryKind: String, Codable, Sendable {
    case action
    case screen
    case error
    case timing
    case crash
    case hang
    case userFlag = "user_flag"
    case storage
}

/// Уровень важности события `app-logs` v1.
enum TelemetryLevel: String, Codable, Sendable {
    case info
    case warn
    case error
    case fatal
}

/// Одно событие в кольцевом буфере и пакете `app-logs` v1.
struct TelemetryEvent: Codable, Sendable, Equatable {
    let at: String
    let kind: TelemetryKind
    let level: TelemetryLevel
    let category: String
    let code: String?
    let message: String
    let screen: String?
    let signature: String?
    let meta: [String: String]?
}

/// Пакет отправки `POST /v1/ingest` (`schemaVersion == 1`).
struct TelemetryBatchPayload: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let app: String
    let appVersion: String
    let build: String
    let osVersion: String
    let deviceModel: String
    let installId: String
    let sessionId: String
    let trigger: TelemetryTrigger
    let sentAt: String
    let context: [String: String]?
    let events: [TelemetryEvent]
}

/// Ошибки ручной/автоматической отправки логов.
enum TelemetryUploadError: LocalizedError, Equatable {
    case notConfigured
    case disabled
    case emptyQueue
    case httpStatus(Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Приёмник логов не настроен в этой сборке."
        case .disabled: "Отправка логов выключена в настройках."
        case .emptyQueue: "Новых событий для отправки нет."
        case .httpStatus(let code): "Сервер логов ответил кодом \(code)."
        case .transport(let detail): "Не удалось отправить логи: \(detail)"
        }
    }
}
