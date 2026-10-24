import Foundation
import OSLog

// Хранилище секретов скрытых папок: знака и пароля. Основное место — Keychain
// с WhenUnlockedThisDeviceOnly; если приложение подписано без
// keychain-entitlement (самоподпись на устройстве), Keychain отвечает
// errSecMissingEntitlement — тогда пишем в файл контейнера под защитой ФС
// и исключаем его из резервных копий iPhone
struct SecretStore {
    let service: String
    let fileURL: URL

    private static let log = Logger(subsystem: "com.ilyaqa.LocalDrive", category: "secret-store")

    /// Знак, открывающий скрытые папки
    static let hiddenSymbol = SecretStore(service: "com.ilyaqa.localdrive.hidden-symbol", fileName: "hidden-symbol.dat")
    /// Пароль на случай, если знак не получается
    static let hiddenPassword = SecretStore(service: "com.ilyaqa.localdrive.hidden-password", fileName: "hidden-password.dat")
    /// Хеш кода входа из версий с экраном блокировки. Код больше не спрашивается
    static let legacyPin = SecretStore(service: "com.ilyaqa.localdrive.pin", fileName: "pin.dat")

    init(service: String, fileName: String, directory: URL? = nil) {
        self.service = service
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = base.appendingPathComponent(fileName)
    }

    func load() -> Data? {
        if let data = Keychain.get(service: service) { return data }
        return try? Data(contentsOf: fileURL)
    }

    @discardableResult
    func save(_ data: Data) -> Bool {
        let status = Keychain.set(data, service: service)
        if status == errSecSuccess {
            // Старая запасная копия в файле больше не нужна
            try? FileManager.default.removeItem(at: fileURL)
            return true
        }

        Self.log.error("Keychain недоступен (\(status, privacy: .public)), пишем секрет в защищённый файл")
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            // Атомарная запись создаёт новый файл: флаг ставится после каждой
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return true
        } catch {
            Self.log.error("не удалось сохранить секрет: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func delete() {
        Keychain.delete(service: service)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
