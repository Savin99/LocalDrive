import Foundation

// Поиск по карточкам: «дом Камилы», «домофон Камилы», «где живёт Камила».
// Карточек десятки, поэтому без индекса — перебором в памяти. Слова режутся
// и приводятся к основе так же, как в поиске по документам (`SearchText`,
// Snowball), служебные слова отбрасываются тем же списком.
//
// Слова запроса двух сортов. «Общие» называют поле — домофон, этаж, адрес,
// живёт: они уточняют, какое поле показать, но карточку не выбирают.
// «Особые» — всё остальное, обычно имя: «Камила». Карточка подходит, если в
// ней есть все особые слова; «дом Петра» не найдёт «Дом Камилы» по слову «дом»
enum FactSearch {
    struct Match: Equatable, Sendable {
        let card: FactCard
        /// Поля, о которых спросили: «домофон Камилы» → поле «Домофон».
        /// Пусто — спросили о карточке целиком
        let itemIDs: Set<UUID>
        let score: Int
        /// Особое слово запроса — в названии карточки: «этаж у Камиллы»
        var namedByTitle = false
        /// Сколько общих слов запроса нашлось: «пароль от вайфая» — два у
        /// дачи, одно у домофона Камилы
        var fieldHits = 0
    }

    static func matches(_ query: String, in cards: [FactCard]) -> [Match] {
        let terms = Self.terms(in: query)
        guard !terms.isEmpty else { return [] }

        let strict = cards.compactMap { evaluate($0, terms: terms, mode: .strict) }
        // Лишнее особое слово («скажи домофон Камилы», если «скажи» не
        // в списке) не должно обнулять выдачу: хватает одного особого слова.
        // Одно-единственное особое слово обязательно — иначе «дом Петра»
        // показал бы чужой дом
        let specificCount = terms.filter { !$0.isGeneric }.count
        var found = strict.isEmpty && specificCount >= 2
            ? cards.compactMap { evaluate($0, terms: terms, mode: .relaxed) }
            : strict
        // Одни слова-поля — карточки, которые объясняют больше слов запроса
        if specificCount == 0, let best = found.map(\.fieldHits).max() {
            found = found.filter { $0.fieldHits == best }
        }

        return found.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.card.updatedAt > rhs.card.updatedAt
        }
    }

    // MARK: - Слова запроса

    struct Term: Equatable, Sendable {
        let word: String
        let stem: String
        /// Слово называет поле, а не карточку: «домофон», «этаж», «живёт»
        let isGeneric: Bool
    }

    static func terms(in query: String) -> [Term] {
        let tokens = SearchText.tokens(in: query)
        let meaningful = tokens.filter {
            !SearchQuery.stopWords.contains($0.word) && !fillerWords.contains($0.word)
        }
        // Запрос из одних служебных слов всё равно что-то ищет, как в документах
        let chosen = meaningful.isEmpty ? tokens : meaningful
        var seen = Set<String>()
        return chosen.compactMap { token in
            guard seen.insert(token.stem).inserted else { return nil }
            // «Вайфая», «этажа» — то же слово с другим окончанием. Только по
            // общему началу от четырёх букв: по началу слова «Домников» стал
            // бы «домом», а «Кодин» — «кодом»
            let generic = genericWords.contains(token.word) || genericStems.contains(token.stem)
                || genericWords.contains { word in
                    let common = zip(token.word, word).prefix { $0 == $1 }.count
                    return common >= 4 && common >= max(token.word.count, word.count) - 2
                }
            return Term(word: token.word, stem: token.stem, isGeneric: generic)
        }
    }

    /// Просьбы вокруг вопроса: «скажи», «напомни», «покажи карточку»
    static let fillerWords: Set<String> = [
        "скажи", "скажите", "напомни", "напомните", "покажи", "покажите", "найди",
        "найдите", "дай", "дайте", "подскажи", "подскажите", "открой", "пожалуйста",
        "карточка", "карточку", "карточки", "запомни", "там", "который", "которая",
        "какое", "сколько", "мы", "нам", "она", "он", "они", "ее", "его", "их",
    ]

    /// Слова, которые называют поле. Сравниваются и целиком, и основой
    static let genericWords: Set<String> = [
        "адрес", "дом", "домофон", "код", "подъезд", "квартира", "кв", "этаж", "ключ",
        "ключи", "пароль", "wifi", "wi", "fi", "вайфай", "сеть", "интернет", "телефон",
        "тел", "номер", "почта", "email", "mail", "ссылка", "сайт", "дата", "заметка",
        "живет", "живут", "живешь", "живу", "проживает", "находится", "добраться",
        "доехать", "ехать", "калитка", "ворота", "парковка", "метро", "позвонить",
        "написать", "контакт", "пин", "pin", "улица",
    ]

    private static let genericStems: Set<String> = Set(genericWords.map(SearchText.stem))

    // MARK: - Карточка

    private enum Mode {
        /// Все особые слова, а без них — хотя бы одно общее
        case strict
        /// Хотя бы одно особое слово
        case relaxed
    }

    /// Где нашлось слово запроса. Вес: название — главное
    private enum Place: Int {
        case title = 8
        case label = 4
        case kind = 3
        case value = 2
    }

    private static func evaluate(_ card: FactCard, terms: [Term], mode: Mode) -> Match? {
        let title = SearchText.tokens(in: card.title)
        let items = card.items.map { item in
            (
                id: item.id,
                label: SearchText.tokens(in: item.label),
                kind: kindTokens[item.kind] ?? [],
                value: SearchText.tokens(in: item.value)
            )
        }

        var score = 0
        var matchedSpecific = 0
        var matchedGeneric = 0
        var specificInTitle = false
        var highlighted = Set<UUID>()

        for term in terms {
            // Слово из названия выбирает карточку, а не поле: «дом Камилы»
            // показывает карточку целиком. Иначе подсвечиваются поля самого
            // сильного места: подпись, затем вид, затем значение
            let place: Place
            if title.contains(where: { matches($0, term) }) {
                place = .title
            } else {
                // Вид поля — только для общих слов: «где живёт» → адрес. Особое
                // слово видом не находится: «какого числа у Ольги день
                // рождения» находило «число» и «день» в каждой карточке с
                // этажом или длительностью (владелец 26.10.2026)
                let tiers: [(Place, [UUID])] = [
                    (.label, items.filter { $0.label.contains { matches($0, term) } }.map(\.id)),
                    (.kind, term.isGeneric ? items.filter { $0.kind.contains { matches($0, term) } }.map(\.id) : []),
                    (.value, items.filter { $0.value.contains { matches($0, term) } }.map(\.id)),
                ]
                guard let hit = tiers.first(where: { !$0.1.isEmpty }) else { continue }
                place = hit.0
                highlighted.formUnion(hit.1)
            }
            score += place.rawValue
            if term.isGeneric {
                matchedGeneric += 1
            } else {
                matchedSpecific += 1
                if place == .title { specificInTitle = true }
            }
        }

        let specific = terms.filter { !$0.isGeneric }.count
        let generic = terms.count - specific
        // Спросили о поле («домофон Камилы») — карточка должна это поле
        // объяснить. Дача, где Камила только в значении «ключи у Камилы», а
        // домофона нет, — не ответ. Карточка самой Камилы — ответ и без домофона
        let explainsField = generic == 0 || matchedGeneric > 0 || specificInTitle
        let accepted = switch mode {
        case .strict: specific > 0 ? matchedSpecific == specific && explainsField : matchedGeneric > 0
        case .relaxed: matchedSpecific > 0 && explainsField
        }
        guard accepted else { return nil }
        return Match(card: card, itemIDs: highlighted, score: score, namedByTitle: specificInTitle, fieldHits: matchedGeneric)
    }

    /// Слово текста подходит к слову запроса: та же основа, то же слово или
    /// слово запроса — начало слова текста («дом» → «домофон»). Имена Snowball
    /// режет неровно: «Камила» для него глагол на «-ила» с основой «кам», а
    /// «Камилы» — «камил». Поэтому слова с общим началом от четырёх букв, у
    /// которых различаются только последние две, тоже совпадают: «Камила»,
    /// «Камилы», «Камилой», «Камилин». «Петра» и «Петя» — нет: общее начало короче
    static func matches(_ token: SearchToken, _ term: Term) -> Bool {
        if token.stem == term.stem || token.word == term.word { return true }
        if term.word.count > 2, token.word.hasPrefix(term.word) { return true }
        let common = zip(token.word, term.word).prefix { $0 == $1 }.count
        return common >= 4 && common >= min(token.word.count, term.word.count) - 2
    }

    /// Поле находится и по виду: адрес — на «где живёт», Wi-Fi — на «пароль
    /// от интернета», даже если подпись у поля другая
    private static let kindTokens: [FactItem.Kind: [SearchToken]] = {
        let words: [FactItem.Kind: String] = [
            .address: "адрес живет проживает находится добраться доехать улица",
            .wifi: "wifi wi fi вайфай сеть интернет пароль",
            .phone: "телефон тел номер позвонить звонить",
            .email: "почта email mail написать имейл",
            .link: "ссылка сайт url",
            .code: "код пароль пин",
            .date: "дата когда день",
            .number: "номер число",
            .note: "заметка",
        ]
        return words.mapValues { SearchText.tokens(in: $0) }
    }()
}
