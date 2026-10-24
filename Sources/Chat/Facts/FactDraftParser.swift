import Foundation

/// «Запомни: у Камилы домофон 45К, этаж 3, адрес Тверская 5» → черновик
/// карточки «Дом Камилы» с полями «Домофон», «Этаж», «Адрес». Разбор без
/// облака и без модели: подписи узнаются по основам слов, ссылки, телефоны и
/// почта — по виду значения. Облако разбирает свободнее и умеет скриншоты
/// (инструмент `propose_fact_card`), а это — путь на iPhone. Владелец
/// 24.10.2026: «что я прошу запомнить и чего нет в документах»
enum FactDraftParser {
    /// Подпись поля: основы Snowball и целые короткие слова, каноническое
    /// название, вид значения
    struct Label {
        var stems: [String] = []
        var words: [String] = []
        let title: String
        let kind: FactItem.Kind
        /// Поле жилья: с ним карточка «у Камилы» — это «Дом Камилы»
        var isHome = false
    }

    static let labels: [Label] = [
        Label(stems: ["адрес", "улиц"], words: ["ул"], title: "Адрес", kind: .address, isHome: true),
        Label(stems: ["домофон"], title: "Домофон", kind: .code, isHome: true),
        Label(stems: ["подъезд"], title: "Подъезд", kind: .text, isHome: true),
        Label(stems: ["этаж"], title: "Этаж", kind: .text, isHome: true),
        Label(stems: ["квартир"], words: ["кв"], title: "Квартира", kind: .text, isHome: true),
        Label(stems: ["калитк", "ворот", "шлагбаум"], title: "Калитка", kind: .code, isHome: true),
        Label(stems: ["парковк", "машиномест"], title: "Парковка", kind: .text, isHome: true),
        Label(stems: ["сет"], words: ["wifi", "вайфай", "вифи"], title: "Wi-Fi", kind: .wifi),
        Label(stems: ["парол"], title: "Пароль", kind: .code),
        Label(words: ["пин", "pin", "пинкод"], title: "PIN", kind: .code),
        Label(stems: ["код"], title: "Код", kind: .code),
        Label(stems: ["телефон"], words: ["тел"], title: "Телефон", kind: .phone),
        Label(stems: ["почт"], words: ["email", "mail", "имейл", "емейл"], title: "Почта", kind: .email),
        Label(stems: ["ссылк", "сайт"], words: ["url"], title: "Ссылка", kind: .link),
        Label(stems: ["дат"], words: ["др"], title: "Дата", kind: .date),
    ]

    /// Глаголы просьбы запомнить. Только повелительное: «я запомнил» — рассказ
    static let verbs = ["запомни", "запиши", "сохрани заметку", "сохрани карточку", "создай карточку", "добавь карточку", "заметка", "запомнить"]

    /// Это просьба запомнить? Тогда — остаток после глагола
    static func request(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for verb in verbs where lower.hasPrefix(verb) {
            let rest = trimmed.dropFirst(verb.count).trimmingCharacters(in: CharacterSet(charactersIn: " :,—-–").union(.whitespacesAndNewlines))
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    /// Черновик карточки или nil — разобрать нечего
    static func draft(from text: String) -> FactCard? {
        guard let body = request(in: text) else { return nil }
        var title = ""
        var rest = body
        // «Дом Камилы: домофон 45…», «Дом Камилы — домофон 45…»
        if let separator = body.range(of: #"\s*[:—–]\s*|\s+-\s+"#, options: .regularExpression),
           !body[..<separator.lowerBound].contains(",") {
            title = String(body[..<separator.lowerBound])
            rest = String(body[separator.upperBound...])
        }
        var items: [FactItem] = []
        var segments = split(rest)
        // «у Камилы домофон 45, этаж 3» — название до первой подписи
        if title.isEmpty, let first = segments.first {
            let (head, item) = leadingTitle(first)
            title = head
            segments.removeFirst()
            if let item { items.append(item) }
        }
        items += segments.compactMap(item(from:))
        guard !items.isEmpty else { return nil }

        let home = items.contains { item in labels.contains { $0.title == item.label && $0.isHome } }
        title = cleanTitle(title, home: home)
        guard !title.isEmpty else { return nil }
        return FactCard(title: title, symbol: home ? "house.fill" : symbol(for: items), items: items)
    }

    // MARK: - Разбор

    /// Части через запятую, точку с запятой и перевод строки. Запятая внутри
    /// адреса («Тверская 5, кв. 12») разрежет его — «кв.» станет своим полем,
    /// так даже удобнее
    static func split(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))) }
            .filter { !$0.isEmpty }
    }

    /// «у Камилы домофон 45» → («у Камилы», поле «Домофон: 45»)
    static func leadingTitle(_ segment: String) -> (String, FactItem?) {
        let words = segment.split(separator: " ").map(String.init)
        for index in words.indices where labelFor(word: words[index]) != nil {
            let head = words[..<index].joined(separator: " ")
            let tail = words[index...].joined(separator: " ")
            return (head, item(from: tail))
        }
        return (segment, nil)
    }

    static func item(from segment: String) -> FactItem? {
        let cleaned = segment.trimmingCharacters(in: CharacterSet(charactersIn: " :—–-"))
        guard !cleaned.isEmpty else { return nil }
        // Значение само говорит, что это: ссылка, почта, телефон
        if let url = cleaned.range(of: #"https?://\S+|www\.\S+"#, options: .regularExpression) {
            let label = labelPrefix(cleaned, before: url.lowerBound) ?? "Ссылка"
            return FactItem(kind: .link, label: label, value: String(cleaned[url]))
        }
        if let mail = cleaned.range(of: #"[\w.+-]+@[\w-]+\.[\w.]+"#, options: .regularExpression) {
            return FactItem(kind: .email, label: labelPrefix(cleaned, before: mail.lowerBound) ?? "Почта", value: String(cleaned[mail]))
        }
        let words = cleaned.split(separator: " ").map(String.init)
        // «Домофон 45К», «код домофона: 1234», «2 подъезд»
        if let index = words.firstIndex(where: { labelFor(word: $0) != nil }), let label = labelFor(word: words[index]) {
            var valueWords = words
            valueWords.remove(at: index)
            // «код домофона» — подпись из двух слов: берём более точную
            var title = label.title
            var kind = label.kind
            if label.title == "Код", let next = valueWords.first, let better = labelFor(word: next), better.title != "Код" {
                valueWords.removeFirst()
                title = better.title
                kind = better.kind == .text ? .code : better.kind
            }
            var value = valueWords.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " :—–-"))
            guard !value.isEmpty else { return nil }
            // «телефон председателя +7 916 …» — номер в значение, остальное в подпись
            if kind == .phone, let number = value.range(of: #"\+?\d[\d\s()-]{5,}\d"#, options: .regularExpression) {
                let extra = value.replacingCharacters(in: number, with: "").trimmingCharacters(in: .whitespaces)
                if !extra.isEmpty { title += " \(extra)" }
                value = String(value[number])
            } else if kind == .phone {
                kind = .text
            }
            return FactItem(kind: kind, label: title, value: value)
        }
        if cleaned.range(of: #"^\+?[\d\s()-]{7,}$"#, options: .regularExpression) != nil {
            return FactItem(kind: .phone, label: "Телефон", value: cleaned)
        }
        // «Пароль: qwerty» с незнакомой подписью — подпись до двоеточия
        if let colon = segment.firstIndex(of: ":") {
            let label = segment[..<colon].trimmingCharacters(in: .whitespaces)
            let value = segment[segment.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !label.isEmpty, !value.isEmpty, label.count <= 30 {
                return FactItem(kind: .text, label: label.prefix(1).uppercased() + label.dropFirst(), value: value)
            }
        }
        return FactItem(kind: .note, label: "Заметка", value: cleaned)
    }

    /// Подпись перед значением: «сайт https://…» → «Сайт»
    private static func labelPrefix(_ text: String, before index: String.Index) -> String? {
        let head = text[..<index].trimmingCharacters(in: CharacterSet(charactersIn: " :—–-"))
        guard !head.isEmpty, head.count <= 30 else { return nil }
        return head.prefix(1).uppercased() + head.dropFirst()
    }

    static func labelFor(word: String) -> Label? {
        guard let token = SearchText.tokens(in: word).first else { return nil }
        return labels.first { label in
            label.words.contains(token.word) || label.stems.contains(token.stem)
                // «Домофона», «квартиры»: основа длинной подписи — началом слова
                || label.stems.contains { $0.count >= 4 && token.word.hasPrefix($0) }
        }
    }

    /// «у Камилы» → «Дом Камилы» для жилья, иначе «Камила»
    static func cleanTitle(_ raw: String, home: Bool) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lower = title.lowercased()
        for prefix in ["у ", "для ", "про ", "о ", "об "] where lower.hasPrefix(prefix) {
            let name = String(title.dropFirst(prefix.count))
            title = home ? "Дом \(name)" : nominative(name)
            break
        }
        guard let first = title.first else { return "" }
        return first.uppercased() + title.dropFirst()
    }

    /// «Камилы» → «Камила», «Ольги» → «Ольга», «Марии» → «Мария». Только
    /// женские имена на -а/-я: у мужских родительный совпадает с другими формами
    static func nominative(_ name: String) -> String {
        name.split(separator: " ").map { word -> String in
            let text = String(word)
            if text.hasSuffix("ии") { return String(text.dropLast()) + "я" }
            if text.hasSuffix("ьи") { return String(text.dropLast()) + "я" }
            if text.hasSuffix("ы") { return String(text.dropLast()) + "а" }
            if let before = text.dropLast().last, text.hasSuffix("и"), "гкхжшчщ".contains(before) { return String(text.dropLast()) + "а" }
            return text
        }.joined(separator: " ")
    }

    /// Значок карточки по её полям
    static func symbol(for items: [FactItem]) -> String {
        if items.contains(where: { $0.kind == .wifi }) { return "wifi" }
        if items.contains(where: { $0.kind == .phone || $0.kind == .email }) { return "person.crop.circle.fill" }
        if items.contains(where: { $0.kind == .link }) { return "link" }
        if items.contains(where: { $0.kind == .code }) { return "key.fill" }
        return "square.text.square.fill"
    }
}
