import Foundation
import OSLog

// Хранилище хеша кода. Основное место — Keychain; если приложение подписано
// без keychain-entitlement (самоподпись на устройстве), Keychain отвечает
// errSecMissingEntitlement — тогда пишем в файл контейнера под защитой ФС.
enum PinStore {
    private static let service = "com.ilyaqa.localdrive.pin"
    private static let log = Logger(subsystem: "com.ilyaqa.LocalDrive", category: "pin-store")

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("pin.dat")
    }

    static func load() -> Data? {
        if let data = Keychain.get(service: service) { return data }
        return try? Data(contentsOf: fileURL)
    }

    static func save(_ data: Data) -> Bool {
        let status = Keychain.set(data, service: service)
        if status == errSecSuccess { return true }

        log.error("Keychain недоступен (\(status, privacy: .public)), пишем код в защищённый файл")
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            log.error("не удалось сохранить код: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
