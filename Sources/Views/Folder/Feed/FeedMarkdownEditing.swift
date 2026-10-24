import Foundation

/// Что ставит панель форматирования в начало строки
enum FeedLinePrefix: Equatable {
    case heading(Int)
    case bullet
    case numbered

    var marker: String {
        switch self {
        case .heading(let level): String(repeating: "#", count: max(1, min(3, level))) + " "
        case .bullet: "- "
        case .numbered: "1. "
        }
    }
}

// Кнопки панели правят исходник, а не оформление: жирный — это пара звёздочек
// вокруг выделения, заголовок — решётки в начале строки. Функции чистые,
// чтобы поведение проверялось тестами без UITextView.
enum FeedMarkdownEditing {
    struct Edit: Equatable {
        var text: String
        var selection: NSRange
    }

    /// Обернуть выделение маркером или снять его, если он уже стоит.
    /// Пустое выделение раскрывается до слова под кареткой.
    static func toggleEmphasis(_ marker: String, in text: String, selection: NSRange) -> Edit {
        let source = text as NSString
        let markerLength = (marker as NSString).length
        let range = normalize(selection, in: source)
        let target = range.length == 0 ? word(around: range.location, in: source) : range

        // Пустая строка или пробелы вокруг каретки — ставим пару маркеров
        // и оставляем каретку между ними
        if target.length == 0 {
            let updated = source.replacingCharacters(
                in: target,
                with: marker + marker
            )
            return Edit(
                text: updated,
                selection: NSRange(location: target.location + markerLength, length: 0)
            )
        }

        if isWrapped(target, in: source, marker: marker) {
            let outer = NSRange(
                location: target.location - markerLength,
                length: target.length + markerLength * 2
            )
            let inner = source.substring(with: target)
            return Edit(
                text: source.replacingCharacters(in: outer, with: inner),
                selection: NSRange(location: outer.location, length: target.length)
            )
        }

        if containsWrapping(target, in: source, marker: marker) {
            let inner = source.substring(
                with: NSRange(
                    location: target.location + markerLength,
                    length: target.length - markerLength * 2
                )
            )
            return Edit(
                text: source.replacingCharacters(in: target, with: inner),
                selection: NSRange(location: target.location, length: (inner as NSString).length)
            )
        }

        let wrapped = marker + source.substring(with: target) + marker
        return Edit(
            text: source.replacingCharacters(in: target, with: wrapped),
            selection: NSRange(location: target.location + markerLength, length: target.length)
        )
    }

    /// Поставить префикс всем затронутым строкам, а если он уже стоит у всех —
    /// снять. Префикс из того же семейства заменяется: ## поверх # даёт ##.
    static func toggleLinePrefix(_ prefix: FeedLinePrefix, in text: String, selection: NSRange) -> Edit {
        let source = text as NSString
        let range = normalize(selection, in: source)
        let lines = lineRanges(intersecting: range, in: source)
        let marker = prefix.marker

        let existing = lines.map { existingPrefix(in: $0, of: source) }
        let removes = existing.allSatisfy { $0.map { source.substring(with: $0) } == marker }

        var updated = source as String
        var deltas: [Int] = []

        // Правим с конца, чтобы уже посчитанные диапазоны не съезжали
        for (line, current) in zip(lines, existing).reversed() {
            let replaced = current ?? NSRange(location: line.location, length: 0)
            let replacement = removes ? "" : marker
            deltas.insert((replacement as NSString).length - replaced.length, at: 0)
            updated = (updated as NSString).replacingCharacters(in: replaced, with: replacement)
        }

        guard let firstLine = lines.first, let firstDelta = deltas.first else {
            return Edit(text: text, selection: range)
        }

        let prefixEnd = firstLine.location + (existing.first.flatMap { $0 }?.length ?? 0)
        let location = range.location < prefixEnd
            ? firstLine.location + (removes ? 0 : (marker as NSString).length)
            : range.location + firstDelta
        let length = range.length + deltas.dropFirst().reduce(0, +)

        return Edit(
            text: updated,
            selection: NSRange(location: max(0, location), length: max(0, length))
        )
    }

    // MARK: - Разбор

    private static func normalize(_ selection: NSRange, in source: NSString) -> NSRange {
        let location = min(max(0, selection.location), source.length)
        let length = min(max(0, selection.length), source.length - location)
        return NSRange(location: location, length: length)
    }

    private static func word(around offset: Int, in source: NSString) -> NSRange {
        var start = offset
        var end = offset

        while start > 0, isWordCharacter(source.character(at: start - 1)) { start -= 1 }
        while end < source.length, isWordCharacter(source.character(at: end)) { end += 1 }

        return NSRange(location: start, length: end - start)
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// Маркеры стоят снаружи выделения
    private static func isWrapped(_ range: NSRange, in source: NSString, marker: String) -> Bool {
        let length = (marker as NSString).length
        guard range.location >= length, range.location + range.length + length <= source.length else {
            return false
        }
        guard source.substring(with: NSRange(location: range.location - length, length: length)) == marker,
              source.substring(with: NSRange(location: range.location + range.length, length: length)) == marker
        else { return false }

        // Одиночная звёздочка не должна отщипывать половину от жирного
        if length == 1 {
            let symbol = marker
            if range.location - 2 >= 0,
               source.substring(with: NSRange(location: range.location - 2, length: 1)) == symbol {
                return false
            }
            let after = range.location + range.length + 1
            if after < source.length,
               source.substring(with: NSRange(location: after, length: 1)) == symbol {
                return false
            }
        }

        return true
    }

    /// Маркеры попали внутрь выделения
    private static func containsWrapping(_ range: NSRange, in source: NSString, marker: String) -> Bool {
        let length = (marker as NSString).length
        guard range.length >= length * 2 else { return false }
        return source.substring(with: NSRange(location: range.location, length: length)) == marker
            && source.substring(
                with: NSRange(location: range.location + range.length - length, length: length)
            ) == marker
    }

    private static func lineRanges(intersecting range: NSRange, in source: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var start = lineStart(at: range.location, in: source)
        let last = range.location + range.length

        while true {
            let end = lineEnd(at: start, in: source)
            result.append(NSRange(location: start, length: end - start))

            guard end < source.length, end < last else { return result }
            start = end + 1
        }
    }

    private static func lineStart(at offset: Int, in source: NSString) -> Int {
        var index = min(offset, source.length)
        while index > 0, source.character(at: index - 1) != asciiCode("\n") { index -= 1 }
        return index
    }

    private static func lineEnd(at offset: Int, in source: NSString) -> Int {
        var index = offset
        while index < source.length, source.character(at: index) != asciiCode("\n") { index += 1 }
        return index
    }

    /// Диапазон уже стоящего в строке префикса — заголовка или пункта списка
    private static func existingPrefix(in line: NSRange, of source: NSString) -> NSRange? {
        let end = line.location + line.length

        func character(_ at: Int) -> unichar? {
            at < end ? source.character(at: at) : nil
        }

        var hashes = 0
        while let c = character(line.location + hashes), c == asciiCode("#"), hashes < 3 { hashes += 1 }
        if hashes > 0, character(line.location + hashes) == asciiCode(" ") {
            return NSRange(location: line.location, length: hashes + 1)
        }

        if let c = character(line.location), c == asciiCode("-") || c == asciiCode("*"),
           character(line.location + 1) == asciiCode(" ") {
            return NSRange(location: line.location, length: 2)
        }

        var digits = 0
        while let c = character(line.location + digits), c >= asciiCode("0"), c <= asciiCode("9"), digits < 3 {
            digits += 1
        }
        if digits > 0,
           let separator = character(line.location + digits),
           separator == asciiCode(".") || separator == asciiCode(")"),
           character(line.location + digits + 1) == asciiCode(" ") {
            return NSRange(location: line.location, length: digits + 2)
        }

        return nil
    }
}
