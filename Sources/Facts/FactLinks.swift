import Foundation
import UIKit
import UniformTypeIdentifiers

/// Что делает касание поля карточки
enum FactItemAction: CaseIterable, Sendable {
    case openMaps
    case openLink
    case call
    case mail
    case copy

    /// Пункт меню «Открыть…»; у копирования своего пункта «Скопировать»
    var title: String {
        switch self {
        case .openMaps: "Открыть в Картах"
        case .openLink: "Открыть ссылку"
        case .call: "Позвонить"
        case .mail: "Написать письмо"
        case .copy: "Скопировать"
        }
    }

    /// Подсказка VoiceOver
    var hint: String {
        switch self {
        case .openMaps: "Нажмите, чтобы открыть в Картах"
        case .openLink: "Нажмите, чтобы открыть ссылку"
        case .call: "Нажмите, чтобы позвонить"
        case .mail: "Нажмите, чтобы написать письмо"
        case .copy: "Нажмите, чтобы скопировать"
        }
    }
}

// Адрес, ссылка, телефон и почта — не текст, а кнопка. Здесь только чистые
// функции: строка → URL, без UIApplication, чтобы их проверяли тесты.
// Карты — «единые ссылки» Apple (iOS 18.4+): /search?query= для адреса,
// /place?coordinate= для точки. Документация:
// developer.apple.com/documentation/mapkit/unified-map-urls
enum FactLinks {
    /// Действие касания. Если строку не удалось превратить в ссылку
    /// («позвоню позже» в поле телефона), касание её копирует
    static func primaryAction(for item: FactItem) -> FactItemAction {
        guard url(for: item) != nil else { return .copy }
        return switch item.kind {
        case .address: .openMaps
        case .link: .openLink
        case .phone: .call
        case .email: .mail
        default: .copy
        }
    }

    /// Ссылка, которую открывает касание; nil — поле копируется
    static func url(for item: FactItem) -> URL? {
        switch item.kind {
        case .address: mapsURL(for: item.value)
        case .link: webURL(for: item.value)
        case .phone: phoneURL(for: item.value)
        case .email: mailURL(for: item.value)
        case .code, .text, .date, .number, .wifi, .note: nil
        }
    }

    // MARK: - Карты

    static func mapsURL(for address: String) -> URL? {
        let text = collapsed(address)
        guard !text.isEmpty else { return nil }
        if let point = coordinate(in: text) {
            return URL(string: "https://maps.apple.com/place?coordinate=\(point.latitude),\(point.longitude)")
        }
        return URL(string: "https://maps.apple.com/search?query=" + percentEncoded(text))
    }

    /// Точка «55.7558, 37.6173» — как её копируют из Карт. Обе части с
    /// дробной частью: «Тверская 5, 12» точкой не считается
    static func coordinate(in text: String) -> (latitude: String, longitude: String)? {
        let pattern = #"^\s*(-?\d{1,2}\.\d+)\s*[,;]?\s*(-?\d{1,3}\.\d+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let latRange = Range(match.range(at: 1), in: text),
              let lonRange = Range(match.range(at: 2), in: text) else { return nil }
        let latitude = String(text[latRange])
        let longitude = String(text[lonRange])
        guard let lat = Double(latitude), let lon = Double(longitude),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return (latitude, longitude)
    }

    // MARK: - Ссылка

    /// Схемы, которые из карточки не открываются никогда
    private static let blockedSchemes: Set<String> = ["javascript", "file", "data", "vbscript"]

    /// «ya.ru/maps» → https://ya.ru/maps; своя схема («tg://…») сохраняется
    static func webURL(for link: String) -> URL? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let candidate: String
        if let separator = text.range(of: "://") {
            let scheme = text[..<separator.lowerBound].lowercased()
            let isScheme = scheme.first?.isLetter == true
                && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
            guard isScheme, !blockedSchemes.contains(scheme) else { return nil }
            candidate = text
        } else {
            candidate = "https://" + text
        }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "http" || scheme == "https" {
            // Без точки в имени сервера это не адрес сайта: «javascript:alert(1)»
            // превратился бы в https://javascript:alert(1)
            guard let host = url.host(percentEncoded: false), host.contains(".") else { return nil }
        }
        return url
    }

    /// Ссылка на экране — без https:// и www.: «ya.ru/maps»
    static func displayLink(_ link: String) -> String {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.lowercased().hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    // MARK: - Телефон и почта

    /// «+7 (916) 123-45-67 доб. 12» → tel:+79161234567. Номер начинается с
    /// первой цифры или «+» и кончается на первой букве
    static func phoneURL(for phone: String) -> URL? {
        guard let start = phone.firstIndex(where: { $0 == "+" || ($0.isASCII && $0.isNumber) }) else { return nil }
        var number = ""
        for character in phone[start...] {
            if character.isLetter { break }
            if character.isASCII && character.isNumber {
                number.append(character)
            } else if character == "+" && number.isEmpty {
                number.append(character)
            }
        }
        let digits = number.filter(\.isNumber).count
        guard (3...15).contains(digits) else { return nil }
        return URL(string: "tel:" + number)
    }

    static func mailURL(for email: String) -> URL? {
        var text = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("mailto:") { text.removeFirst("mailto:".count) }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !text.contains(where: \.isWhitespace) else { return nil }
        return URL(string: "mailto:" + percentEncoded(text, keeping: "@+"))
    }

    // MARK: - Кодирование

    /// Только незарезервированные символы RFC 3986: «&», «+» и «#» в адресе
    /// не должны разорвать параметр запроса
    private static func percentEncoded(_ text: String, keeping extra: String = "") -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~" + extra)
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// Переносы строк и повторные пробелы — одним пробелом
    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// Буфер только этого iPhone и на две минуты — как у полей документов в чате
enum FactClipboard {
    static let lifetime: TimeInterval = 120

    @MainActor
    static func copy(_ value: String) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: value]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(lifetime),
            ]
        )
    }
}
