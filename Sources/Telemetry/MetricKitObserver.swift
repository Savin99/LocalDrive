import Foundation
import MetricKit
import OSLog

private let metricLog = Logger(subsystem: "com.ilyaqa.LocalDrive", category: "metrickit")

/// Подписчик `MetricKit`: собирает краши и длительные зависания UI и отправляет их в `app-logs`.
final class MetricKitObserver: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitObserver()

    private let lock = NSLock()
    private var registered = false

    func start() {
        let shouldAdd = lock.withLock { () -> Bool in
            guard !registered else { return false }
            registered = true
            return true
        }
        guard shouldAdd else { return }
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        var captured: [(TelemetryKind, TelemetryLevel, String, String, String, [String: String])] = []

        for payload in payloads {
            if let crashes = payload.crashDiagnostics {
                for crash in crashes {
                    let signal = crash.signal.map(String.init) ?? "-"
                    let excType = crash.exceptionType.map(String.init) ?? "-"
                    let excCode = crash.exceptionCode.map(String.init) ?? "-"
                    let reason = crash.terminationReason ?? "Crash"
                    let stack = Self.compactJSON(crash.callStackTree.jsonRepresentation())
                    captured.append((
                        .crash,
                        .fatal,
                        "crash_\(excType)_\(signal)",
                        "Crash: \(reason) (exc=\(excType), code=\(excCode), sig=\(signal))",
                        "metrickit:crash:\(excType):\(signal)",
                        ["callStack": stack, "appVersion": crash.applicationVersion]
                    ))
                }
            }
            if let hangs = payload.hangDiagnostics {
                for hang in hangs {
                    let sec = hang.hangDuration.converted(to: .seconds).value
                    let stack = Self.compactJSON(hang.callStackTree.jsonRepresentation())
                    captured.append((
                        .hang,
                        .error,
                        "ui_hang",
                        String(format: "Зависание интерфейса %.2f с", sec),
                        "metrickit:hang",
                        ["durationSec": String(format: "%.2f", sec), "callStack": stack]
                    ))
                }
            }
        }

        guard !captured.isEmpty else { return }
        metricLog.notice("MetricKit доставил диагностик: \(captured.count, privacy: .public)")
        Task { @MainActor in
            guard let telemetry = AppTelemetry.live else { return }
            for item in captured {
                telemetry.record(
                    kind: item.0,
                    level: item.1,
                    category: "metrickit",
                    code: item.2,
                    message: item.3,
                    signature: item.4,
                    meta: item.5
                )
            }
            _ = try? await telemetry.flushNow(trigger: .metrickit)
        }
    }

    private static func compactJSON(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        return AppLogRedactor.redact(singleLine, maxLength: 450)
    }
}
