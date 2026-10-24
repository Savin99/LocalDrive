import UIKit

/// Код ASCII-символа в UTF-16: NSString работает с unichar,
/// а UInt16(ascii:) в стандартной библиотеке нет
func asciiCode(_ scalar: Unicode.Scalar) -> unichar { unichar(scalar.value) }

// Текст блока хранится обычным Markdown-исходником: так он переживает
// экспорт, шаринг и склейку блоков без отдельной модели стилей.
//
// Вне фокуса блок показывает готовый вид, в фокусе — исходник со служебными
// символами. Поддержан узкий набор: заголовки #, ##, ###, **жирный**,
// *курсив*, маркированные и нумерованные списки.
//
// Разбор строчный и свой, а не через AttributedString(markdown:), по двум
// причинам: Foundation выбрасывает переводы строк между блоками, и он не
// отдаёт исходные диапазоны — без них тап по отрендеренному тексту не смог бы
// попасть в нужный символ исходника.
enum FeedMarkdown {
    struct Style {
        var body: UIFont
        var textColor: UIColor
        var syntaxColor: UIColor

        static func standard(body: UIFont = .preferredFont(forTextStyle: .body)) -> Style {
            Style(body: body, textColor: .label, syntaxColor: .tertiaryLabel)
        }

        func font(forHeading level: Int) -> UIFont {
            let textStyle: UIFont.TextStyle = switch level {
            case 1: .title1
            case 2: .title2
            default: .headline
            }
            return UIFont.preferredFont(forTextStyle: textStyle).withTraits(.traitBold)
        }
    }

    /// Готовый вид блока плюс карта смещений: sourceOffsets[i] — индекс в
    /// исходнике для i-го символа отрендеренного текста. Длина карты на один
    /// больше длины текста, последний элемент указывает за конец исходника.
    struct Rendered {
        var text: NSAttributedString
        var sourceOffsets: [Int]

        func sourceOffset(for renderedOffset: Int) -> Int {
            guard !sourceOffsets.isEmpty else { return 0 }
            let index = min(max(0, renderedOffset), sourceOffsets.count - 1)
            return sourceOffsets[index]
        }
    }

    /// Готовый вид: служебные символы убраны, маркеры списков нарисованы.
    static func rendered(_ source: String, style: Style) -> Rendered {
        var builder = Builder(style: style, keepsSyntax: false)
        builder.walk(source)
        return Rendered(text: builder.output, sourceOffsets: builder.offsets + [(source as NSString).length])
    }

    /// Исходник как есть: служебные символы видны, но приглушены,
    /// а оформление уже применено — заголовок при правке остаётся заголовком.
    static func styledSource(_ source: String, style: Style) -> NSAttributedString {
        var builder = Builder(style: style, keepsSyntax: true)
        builder.walk(source)
        return builder.output
    }

    // MARK: - Разбор

    private struct Builder {
        let style: Style
        let keepsSyntax: Bool

        var output = NSMutableAttributedString()
        var offsets: [Int] = []

        private var source: NSString = ""

        init(style: Style, keepsSyntax: Bool) {
            self.style = style
            self.keepsSyntax = keepsSyntax
        }

        mutating func walk(_ text: String) {
            source = text as NSString

            for line in Self.lines(in: source) {
                let prefix = parsePrefix(in: line.range)

                let font = prefix.headingLevel.map { style.font(forHeading: $0) } ?? style.body
                let paragraph = prefix.marker.map { Self.paragraphStyle(indentedBy: $0, font: font) }

                if keepsSyntax, prefix.syntax.length > 0 {
                    append(
                        source.substring(with: prefix.syntax),
                        sourceIndex: prefix.syntax.location,
                        attributes: attributes(font: font, color: style.syntaxColor, paragraph: paragraph)
                    )
                } else if let marker = prefix.marker {
                    // Маркера нет в исходнике — вся его ширина указывает
                    // на начало содержимого строки
                    append(
                        marker,
                        sourceIndex: prefix.contentStart,
                        attributes: attributes(font: font, color: style.textColor, paragraph: paragraph),
                        collapsingSourceIndex: true
                    )
                }

                appendInline(
                    from: prefix.contentStart,
                    to: line.range.location + line.range.length,
                    font: font,
                    traits: [],
                    paragraph: paragraph
                )

                if !line.isLast {
                    append(
                        "\n",
                        sourceIndex: line.range.location + line.range.length,
                        attributes: attributes(font: font, color: style.textColor, paragraph: paragraph)
                    )
                }
            }
        }

        // MARK: Строки и префиксы

        private struct Line {
            var range: NSRange
            var isLast: Bool
        }

        private static func lines(in source: NSString) -> [Line] {
            var result: [Line] = []
            var start = 0

            while true {
                let tail = NSRange(location: start, length: source.length - start)
                let newline = source.range(of: "\n", options: [], range: tail)

                if newline.location == NSNotFound {
                    result.append(Line(range: tail, isLast: true))
                    return result
                }

                result.append(
                    Line(range: NSRange(location: start, length: newline.location - start), isLast: false)
                )
                start = newline.location + 1
            }
        }

        private struct LinePrefix {
            var headingLevel: Int?
            /// Что рисуем вместо служебных символов списка
            var marker: String?
            var contentStart: Int
            var syntax: NSRange
        }

        private func parsePrefix(in line: NSRange) -> LinePrefix {
            let end = line.location + line.length
            var index = line.location

            func character(_ at: Int) -> unichar? {
                at < end ? source.character(at: at) : nil
            }

            // Заголовок: от одной до трёх решёток и пробел
            var hashes = 0
            while let c = character(index + hashes), c == asciiCode("#"), hashes < 3 {
                hashes += 1
            }
            if hashes > 0, character(index + hashes) == asciiCode(" ") {
                let length = hashes + 1
                return LinePrefix(
                    headingLevel: hashes,
                    marker: nil,
                    contentStart: index + length,
                    syntax: NSRange(location: index, length: length)
                )
            }

            // Маркированный список: дефис или звёздочка и пробел
            if let c = character(index), c == asciiCode("-") || c == asciiCode("*"),
               character(index + 1) == asciiCode(" ") {
                return LinePrefix(
                    headingLevel: nil,
                    marker: "•  ",
                    contentStart: index + 2,
                    syntax: NSRange(location: index, length: 2)
                )
            }

            // Нумерованный список: цифры, точка или скобка, пробел
            var digits = 0
            while let c = character(index + digits), c >= asciiCode("0"), c <= asciiCode("9"), digits < 3 {
                digits += 1
            }
            if digits > 0,
               let separator = character(index + digits),
               separator == asciiCode(".") || separator == asciiCode(")"),
               character(index + digits + 1) == asciiCode(" ") {
                let length = digits + 2
                let number = source.substring(with: NSRange(location: index, length: digits))
                return LinePrefix(
                    headingLevel: nil,
                    marker: "\(number).  ",
                    contentStart: index + length,
                    syntax: NSRange(location: index, length: length)
                )
            }

            index = line.location
            return LinePrefix(
                headingLevel: nil,
                marker: nil,
                contentStart: index,
                syntax: NSRange(location: index, length: 0)
            )
        }

        // MARK: Внутристрочное оформление

        private mutating func appendInline(
            from: Int,
            to: Int,
            font: UIFont,
            traits: UIFontDescriptor.SymbolicTraits,
            paragraph: NSParagraphStyle?
        ) {
            let styled = font.withTraits(traits)
            let plain = attributes(font: styled, color: style.textColor, paragraph: paragraph)
            let syntax = attributes(font: styled, color: style.syntaxColor, paragraph: paragraph)

            var index = from
            while index < to {
                let character = source.character(at: index)

                if character == asciiCode("*") || character == asciiCode("_") {
                    // Двойной маркер — жирный
                    if index + 1 < to, source.character(at: index + 1) == character,
                       let closing = closingDouble(character, from: index + 2, to: to) {
                        if keepsSyntax {
                            append(marker(character, count: 2), sourceIndex: index, attributes: syntax)
                        }
                        appendInline(
                            from: index + 2,
                            to: closing,
                            font: font,
                            traits: traits.union(.traitBold),
                            paragraph: paragraph
                        )
                        if keepsSyntax {
                            append(marker(character, count: 2), sourceIndex: closing, attributes: syntax)
                        }
                        index = closing + 2
                        continue
                    }

                    // Одиночный маркер — курсив
                    if let closing = closingSingle(character, from: index + 1, to: to),
                       isEmphasisBoundary(opening: index, closing: closing, character: character, to: to) {
                        if keepsSyntax {
                            append(marker(character, count: 1), sourceIndex: index, attributes: syntax)
                        }
                        appendInline(
                            from: index + 1,
                            to: closing,
                            font: font,
                            traits: traits.union(.traitItalic),
                            paragraph: paragraph
                        )
                        if keepsSyntax {
                            append(marker(character, count: 1), sourceIndex: closing, attributes: syntax)
                        }
                        index = closing + 1
                        continue
                    }
                }

                append(
                    source.substring(with: NSRange(location: index, length: 1)),
                    sourceIndex: index,
                    attributes: plain
                )
                index += 1
            }
        }

        private func marker(_ character: unichar, count: Int) -> String {
            String(repeating: String(UnicodeScalar(character) ?? "*"), count: count)
        }

        private func closingDouble(_ character: unichar, from: Int, to: Int) -> Int? {
            guard from < to else { return nil }
            var index = from
            while index + 1 < to {
                if source.character(at: index) == character, source.character(at: index + 1) == character {
                    return index > from ? index : nil
                }
                index += 1
            }
            return nil
        }

        private func closingSingle(_ character: unichar, from: Int, to: Int) -> Int? {
            var index = from
            while index < to {
                if source.character(at: index) == character {
                    return index > from ? index : nil
                }
                index += 1
            }
            return nil
        }

        /// Подчёркивание внутри слова (`snake_case`) курсивом не считается
        private func isEmphasisBoundary(opening: Int, closing: Int, character: unichar, to: Int) -> Bool {
            guard character == asciiCode("_") else { return true }

            let before = opening > 0 ? source.character(at: opening - 1) : nil
            let after = closing + 1 < to ? source.character(at: closing + 1) : nil
            return !Self.isWordCharacter(before) && !Self.isWordCharacter(after)
        }

        private static func isWordCharacter(_ character: unichar?) -> Bool {
            guard let character, let scalar = UnicodeScalar(character) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }

        // MARK: Сборка

        private mutating func append(
            _ text: String,
            sourceIndex: Int,
            attributes: [NSAttributedString.Key: Any],
            collapsingSourceIndex: Bool = false
        ) {
            guard !text.isEmpty else { return }

            output.append(NSAttributedString(string: text, attributes: attributes))

            let length = (text as NSString).length
            for step in 0..<length {
                offsets.append(collapsingSourceIndex ? sourceIndex : sourceIndex + step)
            }
        }

        private func attributes(
            font: UIFont,
            color: UIColor,
            paragraph: NSParagraphStyle?
        ) -> [NSAttributedString.Key: Any] {
            var result: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let paragraph {
                result[.paragraphStyle] = paragraph
            }
            return result
        }

        /// Перенос внутри пункта списка встаёт под текст, а не под маркер
        private static func paragraphStyle(indentedBy marker: String, font: UIFont) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.headIndent = (marker as NSString).size(withAttributes: [.font: font]).width
            return style
        }
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard !traits.isEmpty else { return self }
        let merged = fontDescriptor.symbolicTraits.union(traits)
        guard let descriptor = fontDescriptor.withSymbolicTraits(merged) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
