import Foundation

/// Конфигурация подключения к единому приёмнику логов `app-logs` (`v1`).
///
/// Хост и токен задаются в `Config/Secrets.xcconfig` (`APP_LOGS_HOST` без `https://`,
/// `APP_LOGS_TOKEN`) и попадают в `Info.plist`. Без валидного HTTPS-хоста и токена,
/// а также в тестах и превью телеметрия тихо отключена.
struct AppLogsConfig: Equatable, Sendable {
    let ingestURL: URL
    let token: String

    init?(host: String?, token: String?) {
        guard let rawHost = Self.cleaned(host),
              let rawToken = Self.cleaned(token),
              rawToken.count >= 20 else {
            return nil
        }
        guard !rawHost.contains("://"), !rawHost.contains("/"), !rawHost.contains(" ") else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = rawHost
        components.path = "/v1/ingest"
        guard let url = components.url, url.scheme == "https", url.host == rawHost else {
            return nil
        }
        self.ingestURL = url
        self.token = rawToken
    }

    static func fromBundle(_ bundle: Bundle = .main) -> AppLogsConfig? {
        let env = ProcessInfo.processInfo.environment
        let args = ProcessInfo.processInfo.arguments
        if env["XCTestConfigurationFilePath"] != nil
            || env["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            || args.contains("-DemoVault")
            || args.contains("-UITesting") {
            return nil
        }
        let info = bundle.infoDictionary
        return AppLogsConfig(
            host: info?["AppLogsHost"] as? String,
            token: info?["AppLogsToken"] as? String
        )
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("$(") else {
            return nil
        }
        return trimmed
    }
}
