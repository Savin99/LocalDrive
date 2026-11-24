import Foundation

/// Жёсткая зачистка секретов, API-ключей и номеров документов до записи в буфер телеметрии.
enum AppLogRedactor {
    private static let maxMessageLength = 1800
    private static let maxMetaKeys = 32
    private static let maxMetaKeyLength = 64
    private static let maxMetaValueLength = 480

    private static let sensitiveKeys: Set<String> = [
        "token", "access_token", "refresh_token", "api_key", "apikey",
        "authorization", "password", "passwd", "secret", "cookie", "session_key",
        "recovery_key", "series_number", "passport", "mrz", "question", "answer",
    ]

    private static let patterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            (#"(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1[REDACTED]"),
            (#"\bsk-(?:proj-|live-|test-)?[A-Za-z0-9_-]{16,}\b"#, "[REDACTED_KEY]"),
            (#"\bAIza[0-9A-Za-z_-]{20,}\b"#, "[REDACTED_KEY]"),
            (
                #"(?i)((?:token|api[_-]?key|access[_-]?token|refresh[_-]?token|password|passwd|secret|authorization|session[_-]?key|cookie)\s*[=:]\s*)([^\s&;,'\"}\]]+)"#,
                "$1[REDACTED]"
            ),
            // Номера документов и длинные числовые идентификаторы (6+ цифр подряд)
            (#"(?<!\d)\d{6,}(?!\d)"#, "[NUM]"),
        ]
        return specs.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, replacement)
        }
    }()

    static func redact(_ text: String, maxLength: Int = maxMessageLength) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (regex, replacement) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
        }
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
        }
        return result
    }

    static func sanitizedURL(_ url: URL?) -> String {
        guard let url else { return "-" }
        let host = url.host ?? ""
        let path = url.path
        if host.isEmpty { return redact(path, maxLength: 200) }
        return "\(host)\(path)"
    }

    static func redactMeta(_ meta: [String: String]?) -> [String: String]? {
        guard let meta, !meta.isEmpty else { return nil }
        var cleaned: [String: String] = [:]
        cleaned.reserveCapacity(min(meta.count, maxMetaKeys))
        for (rawKey, rawValue) in meta.sorted(by: { $0.key < $1.key }).prefix(maxMetaKeys) {
            let key = String(rawKey.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxMetaKeyLength))
            guard !key.isEmpty else { continue }
            let lower = key.lowercased()
            if sensitiveKeys.contains(where: { lower.contains($0) }) {
                cleaned[key] = "[REDACTED]"
            } else {
                cleaned[key] = redact(rawValue, maxLength: maxMetaValueLength)
            }
        }
        return cleaned.isEmpty ? nil : cleaned
    }
}
