import Foundation

/// «Исправь дату рождения на 12.05.1985», «в фамилии ошибка, правильно
/// Трошкина», «фамилия не Трошина, а Трошкина», «номер должен быть 4601
/// 123457» — просьба поправить поле, которое распознавание прочитало неверно.
/// Владелец 24.10.2026: «в фамилии ошибка — говорю в чате, он не исправляет».
/// Чат только предлагает: поле меняется по кнопке «Исправить» и становится
/// ручным — повторное распознавание его не перезапишет
struct ChatFieldFix: Equatable {
    /// Ключ поля (FieldKey); nil — поле не названо
    var key: String?
    /// Часть ФИО: фамилия, имя или отчество — меняется только она
    var namePart: NamePart?
    /// Новое значение; nil — не сказано, тогда чат спросит
    var value: String?
    /// «Не Трошина, а Трошкина»: что заменить на что
    var replacing: String?

    enum NamePart: Int, Equatable {
        case surname = 0
        case given = 1
        case patronymic = 2

        var title: String {
            switch self {
            case .surname: "Фамилия"
            case .given: "Имя"
            case .patronymic: "Отчество"
            }
        }
    }

    /// Слова, по которым понятно, что речь об ошибке, а не о вопросе
    static let markers = [
        "исправь", "исправить", "исправьте", "поправь", "поправить", "поправьте", "измени", "изменить",
        "поменяй", "поменять", "замени", "заменить", "ошибка", "ошибку", "ошибкой", "ошибся", "ошиблась",
        "опечатка", "опечатку", "неправильно", "неправильная", "неправильный", "неправильное", "неверно",
        "неверная", "неверный", "неверное", "должно быть", "должна быть", "должен быть", "правильно",
        "на самом деле",
    ]

    init?(_ text: String) {
        let lower = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let words = Set(SearchText.tokens(in: lower).map(\.word))
        let marked = Self.markers.contains { marker in
            marker.contains(" ") ? lower.contains(marker) : words.contains(marker)
        }
        // «Не Трошина, а Трошкина» — само по себе поправка
        let notBut = Self.capture(#"(?i)(?:^|\s)не\s+([^,]+?),?\s+а\s+(.+?)\s*$"#, in: text)
        guard marked || notBut != nil else { return nil }

        // Поле: части ФИО отдельно, остальное — тем же разбором, что вопросы
        if words.contains(where: { $0.hasPrefix("фамили") }) {
            key = FieldKey.fullName
            namePart = .surname
        } else if words.contains(where: { $0.hasPrefix("отчеств") }) {
            key = FieldKey.fullName
            namePart = .patronymic
        } else if words.contains("имя") || words.contains("имени") {
            key = FieldKey.fullName
            namePart = .given
        } else {
            let intent = ChatIntent(text)
            if intent.wantsAddress {
                key = FieldKey.registrationAddress
            } else {
                key = intent.fieldKeys.first
            }
        }

        // Значение: «не X, а Y», «правильно Y», «должно быть Y», «на Y», «…: Y»
        if let notBut, notBut.count == 2 {
            replacing = Self.clean(notBut[0])
            value = Self.clean(notBut[1])
        }
        if value == nil {
            let patterns = [#"(?i)\bправильно\s*[:—-]?\s+(.+)$"#, #"(?i)должн[оаы]\s+быть\s+(.+)$"#,
                            #"(?i)(?:^|\s)на\s+(.+)$"#, #"[:—]\s*(.+)$"#]
            for pattern in patterns {
                guard let found = Self.capture(pattern, in: text)?.first else { continue }
                let candidate = Self.clean(found)
                if !candidate.isEmpty, !Self.markers.contains(candidate.lowercased()) {
                    value = candidate
                    break
                }
            }
        }
        // Дата — в формате базы «ДД.ММ.ГГГГ»
        if let value, key.map(Self.isDate) == true {
            self.value = Self.normalizedDate(value) ?? value
        }
    }

    /// Ответ на «Как правильно?» — само значение
    init(key: String, namePart: NamePart?, answer: String) {
        self.key = key
        self.namePart = namePart
        let cleaned = Self.clean(answer)
        value = Self.isDate(key) ? (Self.normalizedDate(cleaned) ?? cleaned) : cleaned
    }

    /// Новое значение поля целиком: для части ФИО — ФИО с заменённым словом
    func resolvedValue(current: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if let replacing, let current, current.localizedCaseInsensitiveContains(replacing) {
            return current.replacingOccurrences(of: replacing, with: value, options: [.caseInsensitive])
        }
        guard key == FieldKey.fullName, let namePart, let current else { return value }
        var parts = current.split(separator: " ").map(String.init)
        // Назвали ФИО целиком — оно и есть новое значение
        if value.split(separator: " ").count >= 2 { return value }
        while parts.count <= namePart.rawValue { parts.append("") }
        parts[namePart.rawValue] = value.prefix(1).uppercased() + value.dropFirst()
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// «Трошкина О. П.» при ФИО «Трошина Ольга Петровна» → «Трошкина Ольга
    /// Петровна»: инициалы, взятые моделью из описи, заменяются словами
    /// текущего ФИО с той же буквы. Живая проверка OpenAI 24.10.2026: 2 из 3
    /// предложений пришли с инициалами
    static func expandingInitials(_ value: String, current: String) -> String {
        let words = value.split(separator: " ").map(String.init)
        let known = current.split(separator: " ").map(String.init)
        guard words.count <= known.count else { return value }
        var expanded = words
        for (index, word) in words.enumerated() {
            let letters = word.filter { $0 != "." }
            guard letters.count == 1, word.count <= 2, let letter = letters.first else { continue }
            // Инициал не той буквы — значит, имя и правда другое: не раскрываем
            // ничего, чтобы не вышло «Трошина А. Петровна»
            guard known[index].lowercased().first == Character(letter.lowercased()) else { return value }
            expanded[index] = known[index]
        }
        return expanded.joined(separator: " ")
    }

    /// ФИО от модели → новое значение поля. «Трошкина О. П.» — инициалы
    /// раскрываются; «Ольга Трошкина» при «Трошина Ольга Петровна» — одно новое
    /// слово заменяет самое похожее слово текущего ФИО, порядок и отчество
    /// остаются (живая проверка OpenAI 24.10.2026). Новое слово ни на что не
    /// похоже или новых слов несколько — значение как есть: человек видит
    /// «станет» до кнопки
    static func correctedName(_ value: String, current: String) -> String {
        let value = expandingInitials(value, current: current)
        let words = value.split(separator: " ").map(String.init)
        var known = current.split(separator: " ").map(String.init)
        let fresh = words.filter { word in !known.contains { $0.caseInsensitiveCompare(word) == .orderedSame } }
        guard words.count < known.count || words.map({ $0.lowercased() }) != known.map({ $0.lowercased() }),
              fresh.count == 1, let word = fresh.first else { return value }
        let rest = known.indices.filter { index in !words.contains { $0.caseInsensitiveCompare(known[index]) == .orderedSame } }
        let distances = rest.map { ($0, ChatRouter.editDistance(word.lowercased(), known[$0].lowercased())) }
        guard let (index, distance) = distances.min(by: { $0.1 < $1.1 }),
              distance <= max(2, known[index].count / 3) else { return value }
        known[index] = word
        return known.joined(separator: " ")
    }

    static func isDate(_ key: String) -> Bool {
        [FieldKey.birthDate, FieldKey.issueDate, FieldKey.expiryDate, FieldKey.registrationDate].contains(key)
    }

    /// «12.5.85», «12/05/1985», «12-05-1985» → «12.05.1985»
    static func normalizedDate(_ text: String) -> String? {
        guard let range = text.range(of: #"\d{1,2}[./-]\d{1,2}[./-]\d{2,4}"#, options: .regularExpression) else { return nil }
        let parts = text[range].split(whereSeparator: { "./-".contains($0) }).compactMap { Int($0) }
        guard parts.count == 3, (1...31).contains(parts[0]), (1...12).contains(parts[1]) else { return nil }
        var year = parts[2]
        if year < 100 { year += year > (Calendar.current.component(.year, from: Date()) % 100) ? 1900 : 2000 }
        return String(format: "%02d.%02d.%04d", parts[0], parts[1], year)
    }

    /// Группы первого совпадения
    private static func capture(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;«»\"'“”").union(.whitespacesAndNewlines))
    }
}
