import Foundation

/// Страна паспорта по коду ИКАО — для названия документа в чате: «Паспорт
/// Таджикистана». Слова — как страну называют в запросе
struct PassportCountry: Sendable {
    let code: String
    let name: String
    let genitive: String
    /// Целые слова запроса: «таджикистана», «таджика»
    let words: Set<String>
    /// Начала прилагательных: «таджикский». Только у стран СНГ — у остальных
    /// прилагательное слишком похоже на фамилию («Турецкий»)
    let prefixes: [String]

    init(_ code: String, _ name: String, _ genitive: String, _ words: Set<String>, _ prefixes: [String] = []) {
        self.code = code
        self.name = name
        self.genitive = genitive
        self.words = words
        self.prefixes = prefixes
    }

    static func named(_ code: String?) -> PassportCountry? {
        guard let code else { return nil }
        return all.first { $0.code == code }
    }

    /// Страна, о которой слово запроса, или nil
    static func code(forWord word: String) -> String? {
        let lower = word.lowercased()
        return all.first { $0.words.contains(lower) || $0.prefixes.contains(where: lower.hasPrefix) }?.code
    }

    static let all: [PassportCountry] = [
        .init("TJK", "Таджикистан", "Таджикистана", ["таджикистан", "таджикистана", "таджикистане", "таджик", "таджика", "таджички"], ["таджикск"]),
        .init("UZB", "Узбекистан", "Узбекистана", ["узбекистан", "узбекистана", "узбекистане", "узбек", "узбека", "узбечки"], ["узбекск"]),
        .init("KGZ", "Киргизия", "Киргизии", ["киргизия", "киргизии", "кыргызстан", "кыргызстана", "киргиз", "киргиза", "кыргыз", "кыргыза"], ["киргизск", "кыргызск"]),
        .init("KAZ", "Казахстан", "Казахстана", ["казахстан", "казахстана", "казахстане", "казах", "казаха"], ["казахск", "казахстанск"]),
        .init("ARM", "Армения", "Армении", ["армения", "армении", "армянин", "армянина"], ["армянск"]),
        .init("AZE", "Азербайджан", "Азербайджана", ["азербайджан", "азербайджана", "азербайджане"], ["азербайджанск"]),
        .init("BLR", "Беларусь", "Беларуси", ["беларусь", "беларуси", "белоруссия", "белоруссии"], ["белорусск"]),
        .init("MDA", "Молдова", "Молдовы", ["молдова", "молдовы", "молдавия", "молдавии"], ["молдавск", "молдовск"]),
        .init("UKR", "Украина", "Украины", ["украина", "украины", "украине"], ["украинск"]),
        .init("GEO", "Грузия", "Грузии", ["грузия", "грузии"], ["грузинск"]),
        .init("TKM", "Туркменистан", "Туркменистана", ["туркменистан", "туркменистана", "туркмения", "туркмении"], ["туркменск"]),
        .init("CHN", "Китай", "Китая", ["китай", "китая", "кнр"]),
        .init("VNM", "Вьетнам", "Вьетнама", ["вьетнам", "вьетнама"]),
        .init("TUR", "Турция", "Турции", ["турция", "турции"]),
        .init("IND", "Индия", "Индии", ["индия", "индии"]),
        .init("AFG", "Афганистан", "Афганистана", ["афганистан", "афганистана"]),
        .init("IRN", "Иран", "Ирана", ["иран", "ирана"]),
        .init("SRB", "Сербия", "Сербии", ["сербия", "сербии"]),
        .init("MNG", "Монголия", "Монголии", ["монголия", "монголии"]),
        .init("ISR", "Израиль", "Израиля", ["израиль", "израиля"]),
        .init("D", "Германия", "Германии", ["германия", "германии"]),
        .init("USA", "США", "США", ["сша"]),
        .init("GBR", "Великобритания", "Великобритании", ["великобритания", "великобритании"]),
        .init("FRA", "Франция", "Франции", ["франция", "франции"]),
        .init("ITA", "Италия", "Италии", ["италия", "италии"]),
        .init("ESP", "Испания", "Испании", ["испания", "испании"]),
        .init("POL", "Польша", "Польши", ["польша", "польши"]),
        .init("LVA", "Латвия", "Латвии", ["латвия", "латвии"]),
        .init("LTU", "Литва", "Литвы", ["литва", "литвы"]),
        .init("EST", "Эстония", "Эстонии", ["эстония", "эстонии"]),
        .init("FIN", "Финляндия", "Финляндии", ["финляндия", "финляндии"]),
        .init("THA", "Таиланд", "Таиланда", ["таиланд", "таиланда"]),
        .init("EGY", "Египет", "Египта", ["египет", "египта"]),
        .init("SYR", "Сирия", "Сирии", ["сирия", "сирии"]),
        .init("KOR", "Южная Корея", "Южной Кореи", ["корея", "кореи"]),
        .init("JPN", "Япония", "Японии", ["япония", "японии"]),
        .init("CUB", "Куба", "Кубы", ["куба", "кубы"]),
    ]
}

// ФИО кириллицей у паспортов стран СНГ напечатано рядом с латиницей, а в MRZ
// его нет. По нему владелец ищет в чате, поэтому кириллица берётся со
// страницы — но только если каждое слово латиницы из MRZ находит кириллическую
// пару по таблицам транслитерации. Таблицы у стран разные: «Ёдгор» в
// Таджикистане — YODGOR, по ИКАО было бы EDGOR
enum ForeignPassportName {
    static func cyrillic(surname: [String], given: [String], in text: String) -> String? {
        let latin = surname + given
        guard !surname.isEmpty, !given.isEmpty else { return nil }
        let lines: [[String]] = text.components(separatedBy: .newlines)
            .filter { !MRZNameReader.looksLikeMRZ($0) }
            .map { line in
                line.uppercased()
                    .split(whereSeparator: { !$0.isLetter })
                    .map(String.init)
                    .filter { $0.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } }
                    .map(cyrillicLookalikes)
            }

        var matched: [String] = []
        var lastPosition: (line: Int, word: Int)?
        for word in latin {
            var found: (line: Int, word: Int)?
            search: for (lineIndex, words) in lines.enumerated() {
                for (wordIndex, candidate) in words.enumerated() where romanizes(candidate, as: word) {
                    found = (lineIndex, wordIndex)
                    break search
                }
            }
            guard let found else { return nil }
            matched.append(lines[found.line][found.word])
            lastPosition = found
        }
        // Отчество стоит в той же строке сразу после имени
        if let lastPosition, lastPosition.word + 1 < lines[lastPosition.line].count {
            let next = lines[lastPosition.line][lastPosition.word + 1]
            if MRZNameReader.isPatronymic(next), !matched.contains(next) { matched.append(next) }
        }
        return matched.map(\.capitalized).joined(separator: " ")
    }

    /// Можно ли кириллическое слово записать этой латиницей по одной из таблиц
    static func romanizes(_ cyrillic: String, as latin: String) -> Bool {
        let target = Array(latin.uppercased())
        var reachable: Set<Int> = [0]
        for letter in cyrillic {
            guard let options = romanizations[letter] else { return false }
            var next = Set<Int>()
            for position in reachable {
                for option in options {
                    let end = position + option.count
                    if end <= target.count, String(target[position..<end]) == option { next.insert(end) }
                }
            }
            guard !next.isEmpty else { return false }
            reachable = next
        }
        return reachable.contains(target.count)
    }

    /// Латинские двойники в кириллическом слове — ошибка OCR
    private static func cyrillicLookalikes(_ word: String) -> String {
        let table: [Character: Character] = [
            "A": "А", "B": "В", "C": "С", "E": "Е", "H": "Н", "K": "К", "M": "М",
            "O": "О", "P": "Р", "T": "Т", "X": "Х", "Y": "У",
        ]
        return String(word.map { table[$0] ?? $0 })
    }

    /// ИКАО 9303, ГОСТ и национальные таблицы Таджикистана, Узбекистана,
    /// Казахстана и Киргизии
    private static let romanizations: [Character: [String]] = [
        "А": ["A"], "Б": ["B"], "В": ["V", "W"], "Г": ["G", "GH"], "Ғ": ["GH", "G"], "Д": ["D"],
        "Е": ["E", "YE", "IE"], "Ё": ["YO", "E", "IO", "JO", "YE"], "Ж": ["ZH", "J", "DJ", "Z"],
        "З": ["Z"], "И": ["I", "Y"], "Ӣ": ["I", "Y"], "Й": ["Y", "I", "J"], "К": ["K"], "Қ": ["Q", "K"],
        "Л": ["L"], "М": ["M"], "Н": ["N"], "Ң": ["NG", "N"], "О": ["O"], "Ө": ["O", "OE", "U"],
        "П": ["P"], "Р": ["R"], "С": ["S"], "Т": ["T"], "У": ["U", "OU"], "Ӯ": ["U", "O", "W"],
        "Ў": ["O", "U", "W"], "Ү": ["U", "Y", "UE"], "Ұ": ["U"], "Ф": ["F"], "Х": ["KH", "H", "X"],
        "Ҳ": ["H", "KH"], "Һ": ["H"], "Ц": ["TS", "C", "TC", "TZ"], "Ч": ["CH", "TCH", "C"],
        "Ҷ": ["J", "DJ", "CH", "DZH", "ZH"], "Ш": ["SH", "S"], "Щ": ["SHCH", "SCH", "SH"],
        "Ъ": ["", "IE", "Y"], "Ы": ["Y", "I"], "Ь": ["", "I", "Y"], "Э": ["E"], "Ә": ["A", "AE", "E"],
        "І": ["I"], "Ю": ["IU", "YU", "JU", "U"], "Я": ["IA", "YA", "JA", "A"],
    ]
}

/// Напечатанные поля паспорта по ИКАО: дата выдачи и орган, которых нет в MRZ
enum PassportPrint {
    /// Дата выдачи. Подпись у неё часто стоит над значением в другой колонке,
    /// поэтому сначала дата ищется по сроку действия: паспорт выдают на 10 или
    /// 5 лет, и срок кончается в тот же день или накануне. Так она сверена
    /// с MRZ; дата только по подписи — на сверку
    static func issueDate(in text: String, birth: DateComponents, expiry: DateComponents) -> (date: DateComponents, confidence: Double)? {
        let calendar = Calendar(identifier: .gregorian)
        guard let expiryDay = calendar.date(from: expiry) else { return nil }
        let candidates = dates(in: text).filter { $0 != birth && $0 != expiry }
        for years in [10, 5] {
            for candidate in candidates {
                guard let issued = calendar.date(from: candidate),
                      let end = calendar.date(byAdding: .year, value: years, to: issued),
                      let dayBefore = calendar.date(byAdding: .day, value: -1, to: end) else { continue }
                if calendar.isDate(end, inSameDayAs: expiryDay) || calendar.isDate(dayBefore, inSameDayAs: expiryDay) {
                    return (candidate, DocumentAnalyzer.confirmedConfidence)
                }
            }
        }
        if let labeled = labeledIssueDate(in: text), labeled != birth, labeled != expiry {
            return (labeled, DocumentAnalyzer.printedConfidence)
        }
        return nil
    }

    /// Орган, выдавший паспорт: после подписи «Authority», «Орган, выдавший
    /// документ», «Кем выдан» — в той же строке или на следующей
    static func authority(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let label = try? NSRegularExpression(
            pattern: #"authority|орган[^/\n]{0,25}выда\w*|кем\s+выдан"#,
            options: [.caseInsensitive]
        ) else { return nil }
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            // Подпись бывает на двух языках: значение — после последней
            guard let match = label.matches(in: line, range: range).last,
                  let end = Range(match.range, in: line)?.upperBound else { continue }
            let tail = String(line[end...]).trimmingCharacters(in: CharacterSet(charactersIn: " /:,."))
            if tail.filter(\.isLetter).count >= 3 { return clean(tail) }
            if let next = lines.dropFirst(index + 1).first(where: { !$0.isEmpty }),
               next.filter(\.isLetter).count >= 3,
               !MRZNameReader.looksLikeMRZ(next),
               !isLabel(next) {
                return clean(next)
            }
        }
        return nil
    }

    /// Все даты страницы: «11.01.2018», «11 01 2018», «11 JAN 2018», «11 ЯНВ/JAN 2018»
    static func dates(in text: String) -> [DateComponents] {
        let lines = text.components(separatedBy: .newlines).filter { !MRZNameReader.looksLikeMRZ($0) }
        let page = lines.joined(separator: "\n")
        var result: [DateComponents] = []
        let range = NSRange(page.startIndex..., in: page)
        if let numeric = try? NSRegularExpression(pattern: #"(?<!\d)(\d{2})[.\-/ ](\d{2})[.\-/ ](\d{4})(?!\d)"#) {
            for match in numeric.matches(in: page, range: range) {
                let parts = (1...3).compactMap { Range(match.range(at: $0), in: page).flatMap { Int(page[$0]) } }
                if parts.count == 3, let date = valid(day: parts[0], month: parts[1], year: parts[2]) { result.append(date) }
            }
        }
        if let named = try? NSRegularExpression(
            pattern: #"(?<!\d)(\d{1,2})\s+([A-Za-zА-Яа-яЁё]{3,4})\.?(?:\s*/\s*[A-Za-zА-Яа-яЁё]{3,4}\.?)?\s+(\d{4})(?!\d)"#
        ) {
            for match in named.matches(in: page, range: range) {
                guard let dayRange = Range(match.range(at: 1), in: page),
                      let monthRange = Range(match.range(at: 2), in: page),
                      let yearRange = Range(match.range(at: 3), in: page),
                      let day = Int(page[dayRange]), let year = Int(page[yearRange]),
                      let month = months[page[monthRange].uppercased()],
                      let date = valid(day: day, month: month, year: year) else { continue }
                result.append(date)
            }
        }
        return result
    }

    private static func labeledIssueDate(in text: String) -> DateComponents? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:дата\s+выдачи|date\s+of\s+issue)[^\d]{0,60}?(\d{2})[.\-/ ](\d{2})[.\-/ ](\d{4})"#,
            options: [.caseInsensitive]
        ), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let parts = (1...3).compactMap { Range(match.range(at: $0), in: text).flatMap { Int(text[$0]) } }
        guard parts.count == 3 else { return nil }
        return valid(day: parts[0], month: parts[1], year: parts[2])
    }

    private static func valid(day: Int, month: Int, year: Int) -> DateComponents? {
        guard (1...31).contains(day), (1...12).contains(month), (1900...2100).contains(year) else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    private static func isLabel(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["date", "дата", "подпись", "signature", "expiry"].contains { lower.contains($0) }
    }

    private static func clean(_ value: String) -> String {
        String(value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(120))
    }

    private static let months: [String: Int] = [
        "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
        "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12,
        "ЯНВ": 1, "ФЕВ": 2, "МАР": 3, "АПР": 4, "МАЙ": 5, "МАЯ": 5, "ИЮН": 6,
        "ИЮЛ": 7, "АВГ": 8, "СЕН": 9, "СЕНТ": 9, "ОКТ": 10, "НОЯ": 11, "ДЕК": 12,
    ]
}
