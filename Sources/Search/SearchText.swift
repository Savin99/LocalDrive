import Foundation

/// Слово текста: как написано и его основа
struct SearchToken: Equatable {
    let range: Range<String.Index>
    /// Нижний регистр, «ё» заменена на «е»
    let word: String
    /// Основа по Snowball для кириллицы; у чисел и латиницы совпадает со словом
    let stem: String
}

// Морфология для полнотекстового поиска. Токенизатор unicode61 в FTS5
// складывает регистр кириллицы, но не знает русских окончаний и не
// отождествляет «ё» с «е» (проверено замером, см. docs/search.md).
// Поэтому в индекс уходят две колонки: слова и их основы.
enum SearchText {
    static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    /// Слова режутся так же, как их режет unicode61: буквы и цифры подряд,
    /// всё остальное — разделитель. Иначе слово запроса и слово индекса
    /// могли бы не совпасть на «НПМбд-01-21» или «Антиплагиат.ВУЗ»
    static func tokens(in text: String) -> [SearchToken] {
        var tokens: [SearchToken] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let isWordCharacter = character.isLetter || character.isNumber
            if isWordCharacter, start == nil {
                start = index
            } else if !isWordCharacter, let begin = start {
                tokens.append(token(text, begin..<index))
                start = nil
            }
            index = text.index(after: index)
        }
        if let begin = start {
            tokens.append(token(text, begin..<text.endIndex))
        }
        return tokens
    }

    private static func token(_ text: String, _ range: Range<String.Index>) -> SearchToken {
        let word = normalize(String(text[range]))
        return SearchToken(range: range, word: word, stem: stem(word))
    }

    static func stem(_ word: String) -> String {
        let isCyrillic = word.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
        return isCyrillic ? RussianStemmer.stem(word) : word
    }

    /// Колонка основ: основы слов через пробел
    static func stems(of text: String) -> String {
        tokens(in: text).map(\.stem).joined(separator: " ")
    }

    /// Имя файла как текст: подчёркивания и точки в именах вроде
    /// «Справка_антиплагиат_2025» разделяют слова
    static func title(fromFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
    }
}

/// Запрос пользователя, разобранный на значимые слова
struct SearchQuery: Equatable, Sendable {
    struct Term: Equatable, Sendable {
        let word: String
        let stem: String
    }

    let terms: [Term]

    init(_ text: String) {
        let tokens = SearchText.tokens(in: text)
        let meaningful = tokens.filter { !Self.stopWords.contains($0.word) }
        // Запрос из одних служебных слов («мой») всё равно что-то ищет
        let chosen = meaningful.isEmpty ? tokens : meaningful
        var seen = Set<String>()
        terms = chosen.compactMap { token in
            guard seen.insert(token.word).inserted else { return nil }
            return Term(word: token.word, stem: token.stem)
        }
    }

    var isEmpty: Bool { terms.isEmpty }

    /// Выражение для `MATCH`. Слово подходит, если с него начинается слово
    /// текста или совпадает основа: «справку» найдёт и «справка», и «справки».
    /// Основа сравнивается целиком: префикс «стат» от «статьи» нашёл бы «статус».
    /// `matchAll == false` — запасной вариант, когда ни один документ не
    /// содержит всех слов сразу
    func ftsExpression(matchAll: Bool) -> String? {
        guard !terms.isEmpty else { return nil }
        let groups = terms.map { term -> String in
            // Префикс из одной-двух букв совпадает почти с чем угодно
            let prefix = term.word.count > 2 ? " *" : ""
            return "(words : \(Self.quoted(term.word))\(prefix) OR stems : \(Self.quoted(term.stem)))"
        }
        return groups.joined(separator: matchAll ? " AND " : " OR ")
    }

    /// Подходит ли слово текста к одному из слов запроса — для подсветки
    func matches(_ token: SearchToken) -> Bool {
        !termIndices(matching: token).isEmpty
    }

    /// Номера слов запроса, которым соответствует слово текста
    func termIndices(matching token: SearchToken) -> [Int] {
        terms.indices.filter { index in
            let term = terms[index]
            return token.stem == term.stem
                || token.word == term.word
                || (term.word.count > 2 && token.word.hasPrefix(term.word))
        }
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // Служебные слова и вопросы вроде «мой паспорт» или «когда истекает»:
    // в документах их нет, а с «и» запрос перестал бы что-либо находить
    static let stopWords: Set<String> = [
        "а", "без", "в", "во", "где", "да", "для", "до", "его", "ее", "же", "за",
        "и", "из", "или", "как", "какая", "какие", "какой", "когда", "ко", "ли",
        "мне", "мой", "моя", "мое", "мои", "мою", "моего", "моей", "моих", "на",
        "над", "не", "ни", "но", "о", "об", "обо", "от", "по", "под", "при",
        "про", "с", "со", "свой", "то", "у", "что", "это", "я",
        "a", "an", "and", "for", "in", "my", "of", "on", "or", "the", "to",
    ]
}

extension SearchQuery {
    /// Фрагмент текста длиной около `length` символов там, где сошлось больше
    /// всего разных слов запроса; совпавшие слова выделены `stronglyEmphasized`,
    /// цвет подсветки выбирает вью
    func snippet(in text: String, radius: Int = 60, length: Int = 150) -> AttributedString? {
        let tokens = SearchText.tokens(in: text)
        let matched = tokens.indices.filter { matches(tokens[$0]) }
        guard let firstMatch = matched.first else { return nil }

        // На «справка антиплагиат» первое совпадение — «справка», а
        // «антиплагиат» может стоять строкой ниже. Окно, где видны оба,
        // объясняет выдачу лучше, чем окно вокруг первого
        var span = (first: firstMatch, last: firstMatch, coverage: 0)
        for (offset, first) in matched.enumerated() {
            let limit = text.index(tokens[first].range.lowerBound, offsetBy: length, limitedBy: text.endIndex)
                ?? text.endIndex
            var covered = Set<Int>()
            var last = first
            for index in matched[offset...] where tokens[index].range.upperBound <= limit {
                covered.formUnion(termIndices(matching: tokens[index]))
                last = index
            }
            if covered.count > span.coverage {
                span = (first, last, covered.count)
            }
        }

        // Свободное место окна уходит на слова перед совпадением, окно режется по словам
        let spanStart = tokens[span.first].range.lowerBound
        let spanLength = text.distance(from: spanStart, to: tokens[span.last].range.upperBound)
        let context = min(radius, max(0, length - spanLength))
        var start = text.index(spanStart, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        if start != text.startIndex, let word = tokens.first(where: { $0.range.lowerBound >= start }) {
            start = word.range.lowerBound
        }
        var end = text.index(start, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
        if end != text.endIndex, let word = tokens.last(where: { $0.range.upperBound <= end }) {
            end = word.range.upperBound
        }

        var result = AttributedString()
        if start != text.startIndex { result += AttributedString("…") }
        var cursor = start
        for token in tokens where token.range.lowerBound >= start && token.range.upperBound <= end {
            guard matches(token) else { continue }
            result += AttributedString(Self.flattened(text[cursor..<token.range.lowerBound]))
            var highlighted = AttributedString(String(text[token.range]))
            highlighted.inlinePresentationIntent = .stronglyEmphasized
            result += highlighted
            cursor = token.range.upperBound
        }
        result += AttributedString(Self.flattened(text[cursor..<end]))
        if end != text.endIndex { result += AttributedString("…") }
        return result
    }

    /// Переносы строк из OCR внутри однострочного фрагмента не нужны
    private static func flattened(_ text: Substring) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }
}
