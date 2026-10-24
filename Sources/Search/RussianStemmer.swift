import Foundation

// Стеммер Snowball для русского языка: https://snowballstem.org/algorithms/russian/stemmer.html
//
// Лемматизатор NLTagger на macOS понимает русский, но в симуляторе iOS
// отдаёт слово без изменений: языковые ассеты ставятся системой отдельно.
// Индекс и запросы должны разбираться одинаково на любом iPhone, поэтому
// вместо него — детерминированный алгоритм без моделей и сети.
//
// Тонкость реализации: среди окончаний группы выбирается самое длинное,
// умещающееся в RV. Если у него не выполнено условие (например, «после а/я»),
// группа считается не совпавшей — более короткие окончания не пробуются.
// Так работает `among` в эталонной реализации на Snowball.
enum RussianStemmer {
    static func stem(_ word: String) -> String {
        var letters = Array(word.lowercased().replacingOccurrences(of: "ё", with: "е"))
        let regions = Regions(letters)
        guard regions.rv < letters.count else { return String(letters) }
        var stemmer = Work(letters: letters, limit: regions.rv)

        // Шаг 1
        if !stemmer.remove(longestOf: perfectiveGerund) {
            _ = stemmer.remove(longestOf: reflexive)
            if stemmer.remove(longestOf: adjective) {
                _ = stemmer.remove(longestOf: participle)
            } else if !stemmer.remove(longestOf: verb) {
                _ = stemmer.remove(longestOf: noun)
            }
        }

        // Шаг 2
        _ = stemmer.remove(longestOf: [Ending("и")])

        // Шаг 3: словообразовательный суффикс целиком в R2
        if let ending = stemmer.longestMatch(of: derivational),
           stemmer.letters.count - ending.text.count >= regions.r2 {
            stemmer.drop(ending.text.count)
        }

        // Шаг 4
        if let ending = stemmer.longestMatch(of: superlative) {
            stemmer.drop(ending.text.count)
            stemmer.undoubleN()
        } else if stemmer.endsWith("нн") {
            stemmer.undoubleN()
        } else if stemmer.endsWith("ь") {
            stemmer.drop(1)
        }

        letters = stemmer.letters
        return String(letters)
    }

    // MARK: - Окончания

    private struct Ending {
        let text: [Character]
        /// Окончание отрезается, только если перед ним «а» или «я»
        let afterAOrYa: Bool

        init(_ text: String, afterAOrYa: Bool = false) {
            self.text = Array(text)
            self.afterAOrYa = afterAOrYa
        }
    }

    private static func group(_ endings: [String], afterAOrYa: Bool = false) -> [Ending] {
        endings.map { Ending($0, afterAOrYa: afterAOrYa) }
    }

    private static let perfectiveGerund =
        group(["в", "вши", "вшись"], afterAOrYa: true)
        + group(["ив", "ивши", "ившись", "ыв", "ывши", "ывшись"])

    private static let adjective = group([
        "ее", "ие", "ые", "ое", "ими", "ыми", "ей", "ий", "ый", "ой", "ем", "им", "ым",
        "ом", "его", "ого", "ему", "ому", "их", "ых", "ую", "юю", "ая", "яя", "ою", "ею",
    ])

    private static let participle =
        group(["ем", "нн", "вш", "ющ", "щ"], afterAOrYa: true)
        + group(["ивш", "ывш", "ующ"])

    private static let reflexive = group(["ся", "сь"])

    private static let verb =
        group([
            "ла", "на", "ете", "йте", "ли", "й", "л", "ем", "н", "ло", "но", "ет", "ют",
            "ны", "ть", "ешь", "нно",
        ], afterAOrYa: true)
        + group([
            "ила", "ыла", "ена", "ейте", "уйте", "ите", "или", "ыли", "ей", "уй", "ил", "ыл",
            "им", "ым", "ен", "ило", "ыло", "ено", "ят", "ует", "уют", "ит", "ыт", "ены",
            "ить", "ыть", "ишь", "ую", "ю",
        ])

    private static let noun = group([
        "а", "ев", "ов", "ие", "ье", "е", "иями", "ями", "ами", "еи", "ии", "и", "ией",
        "ей", "ой", "ий", "й", "иям", "ям", "ием", "ем", "ам", "ом", "о", "у", "ах",
        "иях", "ях", "ы", "ь", "ию", "ью", "ю", "ия", "ья", "я",
    ])

    private static let superlative = group(["ейш", "ейше"])
    private static let derivational = group(["ост", "ость"])

    // MARK: - Области слова

    private static let vowels: Set<Character> = ["а", "е", "и", "о", "у", "ы", "э", "ю", "я"]

    /// RV — всё после первой гласной. R2 — после согласной, следующей за
    /// гласной, внутри R1, а R1 — после первой согласной, следующей за гласной
    private struct Regions {
        var rv: Int
        var r2: Int

        init(_ letters: [Character]) {
            rv = letters.count
            r2 = letters.count
            guard let firstVowel = letters.firstIndex(where: vowels.contains) else { return }
            rv = firstVowel + 1
            guard let r1Consonant = letters[rv...].firstIndex(where: { !vowels.contains($0) }) else { return }
            let r1 = r1Consonant + 1
            guard let vowel = letters[r1...].firstIndex(where: vowels.contains),
                  let consonant = letters[(vowel + 1)...].firstIndex(where: { !vowels.contains($0) })
            else { return }
            r2 = consonant + 1
        }
    }

    private struct Work {
        var letters: [Character]
        /// Начало RV: отрезать можно только то, что целиком лежит правее
        let limit: Int

        func endsWith(_ suffix: String) -> Bool {
            let suffix = Array(suffix)
            return letters.count - suffix.count >= limit && letters.suffix(suffix.count).elementsEqual(suffix)
        }

        func longestMatch(of endings: [Ending]) -> Ending? {
            endings
                .filter { ending in
                    letters.count - ending.text.count >= limit
                        && letters.suffix(ending.text.count).elementsEqual(ending.text)
                }
                .max { $0.text.count < $1.text.count }
        }

        /// Самое длинное подходящее окончание группы. Не выполнено условие —
        /// группа не совпала, как в эталонной реализации
        mutating func remove(longestOf endings: [Ending]) -> Bool {
            guard let ending = longestMatch(of: endings) else { return false }
            if ending.afterAOrYa {
                let before = letters.count - ending.text.count - 1
                guard before >= limit, letters[before] == "а" || letters[before] == "я" else { return false }
            }
            drop(ending.text.count)
            return true
        }

        mutating func drop(_ count: Int) {
            letters.removeLast(count)
        }

        mutating func undoubleN() {
            if endsWith("нн") { letters.removeLast() }
        }
    }
}
