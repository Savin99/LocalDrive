import Foundation
import Observation
import OSLog
import UIKit

private let telemetryLog = Logger(subsystem: "com.ilyaqa.LocalDrive", category: "telemetry")

/// Постоянная дисковая очередь событий (кольцевой буфер до 400 записей).
///
/// Хранится в `Application Support/LocalDrive/telemetry-queue.json` с защитой
/// `completeUntilFirstUserAuthentication` и вне резервных копий iCloud.
actor TelemetryDiskQueue {
    private let fileURL: URL
    private let capacity: Int
    private var events: [TelemetryEvent] = []
    private var loaded = false

    init(fileURL: URL, capacity: Int = 400) {
        self.fileURL = fileURL
        self.capacity = capacity
    }

    func count() -> Int {
        ensureLoaded()
        return events.count
    }

    func append(_ event: TelemetryEvent) -> Int {
        ensureLoaded()
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        persist()
        return events.count
    }

    func snapshot(limit: Int = 250) -> [TelemetryEvent] {
        ensureLoaded()
        guard !events.isEmpty else { return [] }
        return Array(events.prefix(limit))
    }

    func dropFirst(_ count: Int) -> Int {
        ensureLoaded()
        let toRemove = min(count, events.count)
        if toRemove > 0 {
            events.removeFirst(toRemove)
            persist()
        }
        return events.count
    }

    func clear() {
        loaded = true
        events = []
        persist()
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TelemetryEvent].self, from: data) else {
            events = []
            return
        }
        events = Array(decoded.suffix(capacity))
    }

    private func persist() {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var excluded = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
    }
}

/// Единый клиент телеметрии LocalDrive (`app-logs` v1).
///
/// Собирает обезличенные технические события: шаги/инструменты/тайминги облачного чата,
/// ошибки сети и индекса, краши/зависания MetricKit и ручные отметки «Заметил баг».
/// Никогда не записывает тексты переписки, значения полей, номера документов или API-ключи.
@Observable
@MainActor
final class AppTelemetry {
    /// Плановый интервал авто-отправки: 5 часов.
    static let periodicInterval: TimeInterval = 5 * 60 * 60
    /// Минимальная пауза между срочными отправками на ошибках.
    static let errorFlushCooldown: TimeInterval = 10 * 60

    private static let enabledKey = "telemetry.enabled.v1"
    private static let installIdKey = "telemetry.installId.v1"
    private static let lastSentAtKey = "telemetry.lastSentAt.v1"
    private static let lastErrorFlushAtKey = "telemetry.lastErrorFlushAt.v1"

    /// Мост для движка чата, индекса и MetricKit. В тестах и превью остаётся `nil`.
    static weak var live: AppTelemetry?

    let isConfigured: Bool
    private(set) var pendingCount: Int = 0
    private(set) var lastSentAt: Date?
    private(set) var lastFailure: String?
    private(set) var isSending: Bool = false
    private(set) var currentScreen: String = "Launch"

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    @ObservationIgnored private let config: AppLogsConfig?
    @ObservationIgnored private let queue: TelemetryDiskQueue
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let appBundleId: String
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let buildNumber: String
    @ObservationIgnored private let osVersion: String
    @ObservationIgnored private let deviceModel: String
    @ObservationIgnored private let installId: String
    @ObservationIgnored private let sessionId: String
    @ObservationIgnored private var contextProvider: (@MainActor () -> [String: String])?
    @ObservationIgnored private var activeUploadTask: Task<Int, Error>?
    @ObservationIgnored private var backoffUntil: Date?
    @ObservationIgnored private var consecutiveFailures: Int = 0
    @ObservationIgnored private var urgentFlushTask: Task<Void, Never>?

    init(
        config: AppLogsConfig? = AppLogsConfig.fromBundle(),
        queueURL: URL = AppTelemetry.defaultQueueURL(),
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        bundle: Bundle = .main,
        registerAsLive: Bool = true
    ) {
        self.config = config
        self.isConfigured = config != nil
        self.queue = TelemetryDiskQueue(fileURL: queueURL)
        self.defaults = defaults
        self.session = session
        self.now = now
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if let ts = defaults.object(forKey: Self.lastSentAtKey) as? Double {
            self.lastSentAt = Date(timeIntervalSince1970: ts)
        }
        let info = bundle.infoDictionary
        self.appBundleId = bundle.bundleIdentifier ?? "com.ilyaqa.LocalDrive"
        self.appVersion = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        self.buildNumber = (info?["CFBundleVersion"] as? String) ?? "0"
        let ver = ProcessInfo.processInfo.operatingSystemVersion
        self.osVersion = "iOS \(ver.majorVersion).\(ver.minorVersion).\(ver.patchVersion)"
        self.deviceModel = Self.hardwareIdentifier()
        if let stored = defaults.string(forKey: Self.installIdKey), !stored.isEmpty {
            self.installId = stored
        } else {
            let fresh = UUID().uuidString.lowercased()
            defaults.set(fresh, forKey: Self.installIdKey)
            self.installId = fresh
        }
        self.sessionId = UUID().uuidString.lowercased()
        if registerAsLive, config != nil {
            Self.live = self
        }
        Task { [weak self] in
            guard let self else { return }
            self.pendingCount = await self.queue.count()
        }
    }

    static func disabled(defaults: UserDefaults = UserDefaults(suiteName: "localdrive.telemetry.disabled") ?? .standard) -> AppTelemetry {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("localdrive-telemetry-disabled-\(UUID().uuidString).json")
        return AppTelemetry(config: nil, queueURL: tmp, defaults: defaults, registerAsLive: false)
    }

    func setContextProvider(_ provider: @escaping @MainActor () -> [String: String]) {
        contextProvider = provider
    }

    // MARK: - Запись событий

    func recordScreen(_ name: String) {
        currentScreen = name
        record(kind: .screen, level: .info, category: "navigation", message: "Экран \(name)", screen: name)
    }

    func recordAction(_ category: String, code: String? = nil, message: String, meta: [String: String]? = nil) {
        record(kind: .action, level: .info, category: category, code: code, message: message, meta: meta)
    }

    func recordTiming(_ category: String, code: String, message: String, meta: [String: String]? = nil) {
        record(kind: .timing, level: .info, category: category, code: code, message: message, meta: meta)
    }

    func recordError(
        category: String,
        code: String,
        message: String,
        signature: String? = nil,
        level: TelemetryLevel = .error,
        meta: [String: String]? = nil,
        scheduleUrgentFlush: Bool = true
    ) {
        record(
            kind: .error,
            level: level,
            category: category,
            code: code,
            message: message,
            signature: signature ?? "\(category):\(code)",
            meta: meta
        )
        if scheduleUrgentFlush {
            scheduleUrgentErrorFlush()
        }
    }

    func record(
        kind: TelemetryKind,
        level: TelemetryLevel,
        category: String,
        code: String? = nil,
        message: String,
        screen: String? = nil,
        signature: String? = nil,
        meta: [String: String]? = nil
    ) {
        let event = TelemetryEvent(
            at: Self.isoString(from: now()),
            kind: kind,
            level: level,
            category: AppLogRedactor.redact(category, maxLength: 64),
            code: code.map { AppLogRedactor.redact($0, maxLength: 128) },
            message: AppLogRedactor.redact(message),
            screen: (screen ?? currentScreen).isEmpty ? nil : AppLogRedactor.redact(screen ?? currentScreen, maxLength: 128),
            signature: signature.map { AppLogRedactor.redact($0, maxLength: 200) },
            meta: AppLogRedactor.redactMeta(meta)
        )
        Task { [weak self] in
            guard let self else { return }
            self.pendingCount = await self.queue.append(event)
        }
    }

    /// Пользовательская отметка «Заметил баг» с немедленной отправкой буфера.
    @discardableResult
    func reportUserIssue(note: String) async throws -> Int {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty ? "Пользователь отметил проблему на экране \(currentScreen)" : trimmed
        let event = TelemetryEvent(
            at: Self.isoString(from: now()),
            kind: .userFlag,
            level: .warn,
            category: "user",
            code: "user_flag",
            message: AppLogRedactor.redact(message),
            screen: AppLogRedactor.redact(currentScreen, maxLength: 128),
            signature: "user_flag:\(AppLogRedactor.redact(currentScreen, maxLength: 80))",
            meta: trimmed.isEmpty ? nil : ["note": AppLogRedactor.redact(trimmed, maxLength: 480)]
        )
        pendingCount = await queue.append(event)
        return try await flushNow(trigger: .userFlag, bypassEnableCheck: true)
    }

    // MARK: - Отправка

    func flushIfDue(trigger: TelemetryTrigger) async {
        guard isConfigured, isEnabled else { return }
        let current = now()
        if let backoffUntil, current < backoffUntil { return }
        if let lastSentAt, current.timeIntervalSince(lastSentAt) < Self.periodicInterval {
            return
        }
        let queued = await queue.count()
        if queued == 0 {
            await appendStorageHeartbeat()
        }
        _ = try? await flushNow(trigger: trigger)
    }

    @discardableResult
    func flushNow(trigger: TelemetryTrigger, bypassEnableCheck: Bool = false) async throws -> Int {
        guard let config else { throw TelemetryUploadError.notConfigured }
        guard isEnabled || bypassEnableCheck else { throw TelemetryUploadError.disabled }

        if let existing = activeUploadTask {
            return try await existing.value
        }

        let events = await queue.snapshot(limit: 250)
        guard !events.isEmpty else {
            if trigger == .manual {
                await appendStorageHeartbeat()
                let fresh = await queue.snapshot(limit: 250)
                if fresh.isEmpty { throw TelemetryUploadError.emptyQueue }
                return try await performUpload(events: fresh, trigger: trigger, config: config)
            }
            return 0
        }
        return try await performUpload(events: events, trigger: trigger, config: config)
    }

    func flushInBackgroundIfNeeded() {
        guard isConfigured, isEnabled else { return }
        let current = now()
        if let lastSentAt, current.timeIntervalSince(lastSentAt) < Self.periodicInterval {
            return
        }
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "LocalDrive.TelemetryFlush") {
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
        Task { @MainActor [weak self] in
            await self?.flushIfDue(trigger: .background)
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
    }

    private func scheduleUrgentErrorFlush() {
        guard isConfigured, isEnabled else { return }
        let current = now()
        if let backoffUntil, current < backoffUntil { return }
        if let last = defaults.object(forKey: Self.lastErrorFlushAtKey) as? Double,
           current.timeIntervalSince(Date(timeIntervalSince1970: last)) < Self.errorFlushCooldown {
            return
        }
        urgentFlushTask?.cancel()
        urgentFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.defaults.set(self.now().timeIntervalSince1970, forKey: Self.lastErrorFlushAtKey)
            _ = try? await self.flushNow(trigger: .error)
        }
    }

    private func appendStorageHeartbeat() async {
        let ctx = contextProvider?() ?? [:]
        let event = TelemetryEvent(
            at: Self.isoString(from: now()),
            kind: .storage,
            level: .info,
            category: "storage",
            code: "heartbeat_ok",
            message: "Плановый снимок состояния хранилища",
            screen: currentScreen,
            signature: nil,
            meta: AppLogRedactor.redactMeta(ctx)
        )
        pendingCount = await queue.append(event)
    }

    private func performUpload(
        events: [TelemetryEvent],
        trigger: TelemetryTrigger,
        config: AppLogsConfig
    ) async throws -> Int {
        let context = AppLogRedactor.redactMeta(contextProvider?())
        let payload = TelemetryBatchPayload(
            schemaVersion: 1,
            app: appBundleId,
            appVersion: appVersion,
            build: buildNumber,
            osVersion: osVersion,
            deviceModel: deviceModel,
            installId: installId,
            sessionId: sessionId,
            trigger: trigger,
            sentAt: Self.isoString(from: now()),
            context: context,
            events: events
        )
        let body = try JSONEncoder().encode(payload)
        var request = URLRequest(url: config.ingestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        isSending = true
        let uploadTask = Task<Int, Error> { [session] in
            do {
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw TelemetryUploadError.transport("Некорректный HTTP-ответ")
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw TelemetryUploadError.httpStatus(http.statusCode)
                }
                return events.count
            } catch let error as TelemetryUploadError {
                throw error
            } catch {
                throw TelemetryUploadError.transport(error.localizedDescription)
            }
        }
        activeUploadTask = uploadTask
        defer {
            activeUploadTask = nil
            isSending = false
        }

        do {
            let sentCount = try await uploadTask.value
            pendingCount = await queue.dropFirst(sentCount)
            let stamp = now()
            lastSentAt = stamp
            defaults.set(stamp.timeIntervalSince1970, forKey: Self.lastSentAtKey)
            lastFailure = nil
            consecutiveFailures = 0
            backoffUntil = nil
            telemetryLog.info("Отправлено событий телеметрии: \(sentCount, privacy: .public) (\(trigger.rawValue, privacy: .public))")
            return sentCount
        } catch {
            consecutiveFailures += 1
            let delay = min(pow(2.0, Double(consecutiveFailures)) * 30.0, 3600.0)
            backoffUntil = now().addingTimeInterval(delay)
            lastFailure = error.localizedDescription
            telemetryLog.warning("Ошибка отправки телеметрии: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    nonisolated static func defaultQueueURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("LocalDrive", isDirectory: true)
            .appendingPathComponent("telemetry-queue.json")
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            acc.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "iPhone" : identifier
    }
}
