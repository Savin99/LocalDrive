import Foundation

/// Имя из первой строки MRZ, по словам: заглавные буквы кириллицы (паспорт РФ)
/// или латиницы (паспорт по ИКАО)
struct MRZNames: Equatable {
    /// Части фамилии: двойная фамилия пишется через одиночный заполнитель
    var surname: [String]
    /// Имя, за ним отчество (паспорт РФ) или вторые имена
    var given: [String]
    /// Каждое слово нашлось среди напечатанных на странице
    var confirmed: Bool
}

// Имя в MRZ не защищено контрольной цифрой, а Vision читает заполнитель «<»
// как «K»: «SAVIN<<IL98» приходит как «SAVINKKIL98», и без проверки получалось
// «Савинккилья» (снимок с iPhone владельца, 12.10.2026). Поэтому каждая «K»
// на стыке слов — либо буква, либо заполнитель. Из вариантов выбирается тот,
// что подтверждают напечатанные на странице слова, а без них — самый
// правдоподобный по строению: фамилия, имя, отчество, без слов из одних «К»
enum MRZNameReader {
    /// Кириллица по таблице приказа № 279 или латиница как есть
    enum Script: Sendable {
        case russianInternal
        case latin
    }

    /// Больше вариантов не перебираем: такое бывает только с мусорной строкой
    private static let maxVariants = 4096

    static func read(_ field: String, script: Script, printed: Set<String>) -> MRZNames {
        // Имя занимает поле до конца строки — последнее слово могли обрезать
        let truncated = field.last.map { $0 != "<" } ?? false
        let body = field.replacingOccurrences(of: "<+$", with: "", options: .regularExpression)
        let segments = Self.segments(Array(body))
        var best: (score: Double, changes: Int, names: MRZNames)?
        for variant in variants(of: segments) {
            let candidate = evaluate(variant.text, changes: variant.changes, script: script, printed: printed, truncated: truncated)
            if best == nil || candidate.score > best!.score
                || (candidate.score == best!.score && variant.changes < best!.changes) {
                best = (candidate.score, variant.changes, candidate.names)
            }
        }
        return best?.names ?? MRZNames(surname: [], given: [], confirmed: false)
    }

    /// Слова со страницы, которыми проверяется имя. Строки MRZ не в счёт:
    /// иначе ошибочное прочтение подтверждало бы само себя
    static func printedWords(in text: String, script: Script) -> Set<String> {
        var words = Set<String>()
        for line in text.components(separatedBy: .newlines) where !looksLikeMRZ(line) {
            for word in line.uppercased().split(whereSeparator: { !$0.isLetter }) {
                let normalized = normalize(String(word), script: script)
                if normalized.count >= 2 { words.insert(normalized) }
            }
        }
        return words
    }

    /// Строка из алфавита MRZ длиной с половину строки и больше
    static func looksLikeMRZ(_ line: String) -> Bool {
        let normalized = MRZ.normalize(line)
        return normalized.count >= 25 && normalized.allSatisfy { mrzAlphabet.contains($0) }
    }

    private static let mrzAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<")

    /// Vision пишет кириллицу латинскими двойниками и наоборот; Ё и Е не различаем
    static func normalize(_ word: String, script: Script) -> String {
        let table = script == .russianInternal ? toCyrillic : toLatin
        return String(word.uppercased().map { character in
            if character == "Ё" { return "Е" }
            return table[character] ?? character
        })
    }

    private static let toCyrillic: [Character: Character] = [
        "A": "А", "B": "В", "C": "С", "E": "Е", "H": "Н", "K": "К", "M": "М",
        "O": "О", "P": "Р", "T": "Т", "X": "Х", "Y": "У",
    ]

    private static let toLatin: [Character: Character] = [
        "А": "A", "В": "B", "С": "C", "Е": "E", "Н": "H", "К": "K", "М": "M",
        "О": "O", "Р": "P", "Т": "T", "Х": "X", "У": "Y",
    ]

    // MARK: - Варианты прочтения

    private enum Segment {
        /// Буквы без «K» и заполнителей — их не трогаем
        case fixed([Character])
        /// Подряд идущие «K» и «<»
        case ambiguous([Character])
    }

    private static func segments(_ body: [Character]) -> [Segment] {
        var result: [Segment] = []
        var current: [Character] = []
        var currentAmbiguous = false
        for character in body {
            let ambiguous = character == "K" || character == "<"
            if !current.isEmpty, ambiguous != currentAmbiguous {
                result.append(currentAmbiguous ? .ambiguous(current) : .fixed(current))
                current = []
            }
            current.append(character)
            currentAmbiguous = ambiguous
        }
        if !current.isEmpty { result.append(currentAmbiguous ? .ambiguous(current) : .fixed(current)) }
        return result
    }

    /// Варианты одной цепочки «K» и «<». Буквой «K» может быть только с краю
    /// цепочки, где она примыкает к слову: «KOVAL93UK<<KIRILL». «K» между
    /// заполнителями — однобуквенное слово, такого в именах нет
    private static func options(for run: [Character], hasPrevious: Bool, hasNext: Bool, reduced: Bool) -> [(text: [Character], changes: Int)] {
        guard run.contains("K") else { return [(run, 0)] }
        let lead = run.prefix { $0 == "K" }.count
        let trail = run.reversed().prefix { $0 == "K" }.count
        let maxLead = hasPrevious ? lead : 0
        let maxTrail = hasNext ? trail : 0
        var pairs: [(Int, Int)] = []
        if reduced {
            pairs = [(0, 0), (maxLead, min(maxTrail, run.count - maxLead))]
        } else {
            for p in 0...maxLead {
                for s in 0...maxTrail where p + s <= run.count { pairs.append((p, s)) }
            }
        }
        var seen = Set<String>()
        var result: [(text: [Character], changes: Int)] = []
        func add(_ text: [Character]) {
            guard seen.insert(String(text)).inserted else { return }
            result.append((text, zip(run, text).filter { $0 != $1 }.count))
        }
        for (p, s) in pairs {
            var text = run.map { $0 == "K" ? Character("<") : $0 }
            for index in 0..<p { text[index] = "K" }
            for index in 0..<s { text[run.count - 1 - index] = "K" }
            add(text)
        }
        // Исходное прочтение — тоже вариант: «K» внутри слова чаще всего буква
        add(run)
        return result
    }

    private static func variants(of segments: [Segment]) -> [(text: String, changes: Int)] {
        func choices(reduced: Bool) -> [[(text: [Character], changes: Int)]] {
            segments.enumerated().map { index, segment in
                switch segment {
                case .fixed(let characters):
                    return [(characters, 0)]
                case .ambiguous(let run):
                    let hasPrevious = index > 0
                    let hasNext = index < segments.count - 1
                    return options(for: run, hasPrevious: hasPrevious, hasNext: hasNext, reduced: reduced)
                }
            }
        }
        var perSegment = choices(reduced: false)
        let total = perSegment.reduce(1) { product, options in min(product * options.count, maxVariants + 1) }
        if total > maxVariants { perSegment = choices(reduced: true) }

        var result: [(text: [Character], changes: Int)] = [([], 0)]
        for options in perSegment {
            var next: [(text: [Character], changes: Int)] = []
            combine: for prefix in result {
                for option in options {
                    if next.count >= maxVariants { break combine }
                    next.append((prefix.text + option.text, prefix.changes + option.changes))
                }
            }
            result = next
        }
        return result.map { (String($0.text), $0.changes) }
    }

    // MARK: - Оценка варианта

    private static func evaluate(
        _ text: String,
        changes: Int,
        script: Script,
        printed: Set<String>,
        truncated: Bool
    ) -> (score: Double, names: MRZNames) {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "<"))
        var surnameRaw = trimmed
        var restRaw = ""
        if let separator = trimmed.range(of: "<<") {
            surnameRaw = String(trimmed[..<separator.lowerBound])
            restRaw = String(trimmed[separator.upperBound...])
        }
        // Лишние заполнители между словами: «<<<» после фамилии или второе «<<»
        let extraFillers = restRaw.prefix { $0 == "<" }.count + restRaw.components(separatedBy: "<<").count - 1
        var surname = surnameRaw.split(separator: "<").map { decode(String($0), script: script) }
        var given = restRaw.split(separator: "<").map { decode(String($0), script: script) }

        var score = 0.0
        var matched = 0
        let total = surname.count + given.count
        func check(_ word: inout String, isLast: Bool) {
            let key = normalize(word, script: script)
            if printed.contains(key) {
                score += 4
                matched += 1
            } else if isLast, truncated, key.count >= 3,
                      let full = printed.filter({ $0.hasPrefix(key) }).min(by: { $0.count < $1.count }) {
                // Обрезанное в MRZ слово берём целиком со страницы
                score += 3
                matched += 1
                word = full
            }
            if word.allSatisfy({ $0 == "К" || $0 == "K" }) {
                score -= 6
            } else if word.count == 1 {
                score -= 3
            }
            score -= 3 * Double(word.components(separatedBy: script == .russianInternal ? "КК" : "KK").count - 1)
        }
        for index in surname.indices {
            check(&surname[index], isLast: given.isEmpty && index == surname.count - 1)
        }
        for index in given.indices {
            check(&given[index], isLast: index == given.count - 1)
        }

        if given.isEmpty { score -= 5 }
        switch script {
        case .russianInternal:
            if given.count > 2 { score -= 3 * Double(given.count - 2) }
            if given.count == 2, isPatronymic(given[1]) { score += 1 }
        case .latin:
            if given.count > 3 { score -= 2 * Double(given.count - 3) }
        }
        score -= 2 * Double(extraFillers)
        score -= 0.3 * Double(changes)
        let names = MRZNames(surname: surname, given: given, confirmed: total > 0 && matched == total)
        return (score, names)
    }

    /// Окончания отчеств, в том числе тюркских: «Алиевич», «Алиев оглы»
    static func isPatronymic(_ word: String) -> Bool {
        let upper = word.uppercased()
        return ["ВИЧ", "ВНА", "ИЧ", "ЫЧ", "ИЧНА", "ЧНА", "ОГЛЫ", "КЫЗЫ", "УЛЫ", "УГЛИ", "КИЗИ"].contains { upper.hasSuffix($0) }
    }

    private static func decode(_ word: String, script: Script) -> String {
        switch script {
        case .russianInternal: String(word.map { cyrillic[$0] ?? $0 })
        case .latin: word
        }
    }

    /// Таблица приказа № 279: обратная транслитерация однозначна
    static let cyrillic: [Character: Character] = [
        "A": "А", "B": "Б", "V": "В", "G": "Г", "D": "Д", "E": "Е", "2": "Ё", "J": "Ж",
        "Z": "З", "I": "И", "Q": "Й", "K": "К", "L": "Л", "M": "М", "N": "Н", "O": "О",
        "P": "П", "R": "Р", "S": "С", "T": "Т", "U": "У", "F": "Ф", "H": "Х", "C": "Ц",
        "3": "Ч", "4": "Ш", "W": "Щ", "X": "Ъ", "Y": "Ы", "9": "Ь", "6": "Э", "7": "Ю",
        "8": "Я",
    ]
}
