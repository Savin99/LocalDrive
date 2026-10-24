import Foundation

// Машиночитаемая запись паспорта: две строки по 44 символа (формат TD3).
//
// Паспорт гражданина РФ — по приказу ФМС России от 30.06.2011 № 279:
//   строка 1: PN RUS ФАМИЛИЯ<<ИМЯ<ОТЧЕСТВО, кириллица по своей таблице
//             (Ё→2, Й→Q, Ч→3, Ш→4, Щ→W, Ъ→X, Ы→Y, Ь→9, Э→6, Ю→7, Я→8);
//   строка 2: 1–9 три цифры серии и шесть цифр номера, 10 — контроль,
//             11–13 RUS, 14–19 дата рождения ГГММДД, 20 — контроль, 21 пол,
//             22–27 и 28 — заполнители (срока действия нет), 29 — последняя
//             цифра серии, 30–35 дата выдачи, 36–41 код подразделения,
//             42 — заполнитель, 43 — контроль 29–42, 44 — итоговый контроль.
// Остальные паспорта — обычный TD3 по ИКАО 9303 с номером и сроком действия:
// загранпаспорт РФ и паспорта других стран.
//
// Имя контрольными цифрами не защищено, а Vision читает заполнитель «<» как
// «K». Как имя читается несмотря на это — в MRZNames.swift
struct MRZ: Equatable {
    enum Kind: Equatable {
        /// Паспорт гражданина РФ: PN RUS
        case russianInternal
        /// Паспорт по ИКАО 9303: «P», вторая буква и код страны
        case travelPassport
    }

    let kind: Kind
    let line1: String
    let line2: String

    // MARK: - Поиск в тексте OCR

    /// Ищет в строках распознанного текста пару строк MRZ. Vision иногда
    /// режет строку MRZ на две рамки или читает латиницу кириллицей —
    /// поэтому строки нормализуются до проверки
    static func find(in lines: [String]) -> MRZ? {
        let candidates = lines.map(normalize)
        for (index, first) in candidates.enumerated() where index + 1 < candidates.count {
            guard let top = fittedFirstLine(first) else { continue }
            // Вторая строка — следующая непустая или две следующие рамки подряд
            let following = Array(candidates[(index + 1)...].prefix(2))
            var options = following.filter { $0.count >= 40 }
            if following.count == 2 { options.append(following[0] + following[1]) }
            for next in options {
                if let bottom = fittedSecondLine(next) {
                    return MRZ(kind: kind(of: top, bottom: bottom), line1: top, line2: bottom)
                }
            }
        }
        return nil
    }

    /// «PNRUS» — паспорт РФ. Если Vision ошибся во второй букве, паспорт РФ
    /// узнаётся по пустому сроку действия: у него эти позиции — заполнители.
    /// Остальное — паспорт по ИКАО: вторая буква там на усмотрение страны,
    /// а «P<» Vision читает и как «PK»
    private static func kind(of top: String, bottom: String) -> Kind {
        if top.hasPrefix("PNRUS") { return .russianInternal }
        let chars = Array(bottom)
        if top.dropFirst(2).hasPrefix("RUS"), chars[21..<28].allSatisfy({ $0 == "<" || $0 == "K" }) {
            return .russianInternal
        }
        return .travelPassport
    }

    /// Верхний регистр, без пробелов; кириллические двойники латиницы, скобки
    /// и «ёлочки» вместо заполнителей приводятся к алфавиту MRZ
    static func normalize(_ line: String) -> String {
        var result = ""
        for character in line.uppercased() {
            switch character {
            case " ", "\t": continue
            case "«": result += "<<"
            case "‹", "≤", "<", "(", "[", "{", "∠", "＜", "﹤", "〈", "⟨": result += "<"
            default:
                result.append(lookalikes[character] ?? character)
            }
        }
        return result
    }

    private static let lookalikes: [Character: Character] = [
        "А": "A", "В": "B", "С": "C", "Е": "E", "Н": "H", "К": "K", "М": "M",
        "О": "O", "Р": "P", "Т": "T", "Х": "X", "У": "Y", "З": "3",
    ]

    private static let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<")

    /// Строка имени: хвост из заполнителей Vision часто укорачивает или
    /// удлиняет — длина выравнивается по ним. Заполнители бывают прочитаны
    /// все до одного как «K». Ошибиться строкой здесь трудно: вторая строка
    /// всё равно проверяется длиной и контрольными цифрами
    private static func fittedFirstLine(_ line: String) -> String? {
        guard line.count >= 10, line.contains("<") || line.contains("KKK"),
              line.allSatisfy(alphabet.contains), line.first == "P"
        else { return nil }
        if line.count == 44 { return line }
        let core = line.replacingOccurrences(of: "<+$", with: "", options: .regularExpression)
        guard core.count <= 44 else { return nil }
        return core.padding(toLength: 44, withPad: "<", startingAt: 0)
    }

    private static func fittedSecondLine(_ line: String) -> String? {
        guard line.count == 44, line.allSatisfy(alphabet.contains) else { return nil }
        return line
    }

    // MARK: - Контрольные цифры

    /// Контрольная цифра ИКАО: веса 7, 3, 1 по кругу, буквы A–Z — 10…35,
    /// заполнитель — ноль, остаток от деления на 10
    static func checkDigit<S: Sequence>(_ characters: S) -> Int where S.Element == Character {
        let weights = [7, 3, 1]
        var sum = 0
        for (index, character) in characters.enumerated() {
            sum += value(of: character) * weights[index % 3]
        }
        return sum % 10
    }

    private static func value(of character: Character) -> Int {
        if let digit = character.wholeNumberValue { return digit }
        if let ascii = character.asciiValue, character.isLetter { return Int(ascii) - 55 }
        return 0
    }

    /// Совпадает ли символ контроля с посчитанной цифрой. Для пустого поля
    /// приказ № 279 ставит заполнитель, встречается и ноль
    static func verifies(_ field: Substring, check: Character) -> Bool {
        let digit = checkDigit(field)
        if check == "<" { return digit == 0 && field.allSatisfy { $0 == "<" } }
        return check.wholeNumberValue == digit
    }
}

// MARK: - Разбор паспорта РФ

/// Данные из MRZ паспорта гражданина РФ
struct RussianPassportMRZ: Equatable {
    let surname: String
    let givenName: String
    let patronymic: String
    /// Каждое слово ФИО нашлось среди напечатанных на странице. Контрольной
    /// цифры у имени нет — без такого подтверждения ФИО идёт на сверку
    let nameConfirmed: Bool
    /// Четыре цифры серии и шесть цифр номера: «4601 123456»
    let seriesNumber: String
    let birthDate: DateComponents
    /// «М» или «Ж»
    let sex: String
    let issueDate: DateComponents
    /// «770-120»
    let departmentCode: String
    /// Номер сверен своей контрольной цифрой и блоком с последней цифрой серии
    let seriesNumberValid: Bool
    let birthDateValid: Bool
    /// Блок «последняя цифра серии, дата выдачи, код подразделения»
    let issueValid: Bool
    /// Все контрольные цифры сошлись
    let isValid: Bool

    var fullName: String {
        [surname, givenName, patronymic].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Разбор с исправлением типичных ошибок OCR в цифровых позициях.
    /// `printed` — слова со страницы, которыми сверяется имя.
    /// Возвращает nil, если строка совсем не похожа на паспорт РФ
    init?(_ mrz: MRZ, printed: Set<String> = [], today: Date = Date()) {
        guard mrz.kind == .russianInternal else { return nil }
        let line2 = Self.repairDigits(Self.repairFillers(mrz.line2))
        let chars = Array(line2)
        guard chars.count == 44 else { return nil }
        func field(_ from: Int, _ to: Int) -> Substring { line2.dropFirst(from).prefix(to - from) }

        let seriesHead = field(0, 3)
        let number = field(3, 9)
        let seriesTail = field(28, 29)
        let issue = field(29, 35)
        let department = field(35, 41)
        let birth = field(13, 19)
        guard (seriesHead + number + seriesTail + issue + department + birth).allSatisfy(\.isNumber),
              let birthDate = Self.date(birth, today: today, isBirth: true),
              let issueDate = Self.date(issue, today: today, isBirth: false) else { return nil }

        let numberCheck = MRZ.verifies(field(0, 9), check: chars[9])
        let birthCheck = MRZ.verifies(birth, check: chars[19])
        let expiryCheck = MRZ.verifies(field(21, 27), check: chars[27])
        let issueCheck = MRZ.verifies(field(28, 42), check: chars[42])
        let compositeCheck = MRZ.verifies(Substring(String(field(0, 10)) + field(13, 20) + field(21, 43)), check: chars[43])

        let names = MRZNameReader.read(String(mrz.line1.dropFirst(5)), script: .russianInternal, printed: printed)
        surname = names.surname.map(\.capitalized).joined(separator: "-")
        givenName = names.given.first?.capitalized ?? ""
        patronymic = names.given.dropFirst().map(\.capitalized).joined(separator: " ")
        nameConfirmed = names.confirmed
        seriesNumber = "\(seriesHead)\(seriesTail) \(number)"
        self.birthDate = birthDate
        sex = chars[20] == "F" ? "Ж" : "М"
        self.issueDate = issueDate
        departmentCode = "\(department.prefix(3))-\(department.suffix(3))"
        seriesNumberValid = numberCheck && issueCheck
        birthDateValid = birthCheck
        issueValid = issueCheck
        isValid = numberCheck && birthCheck && expiryCheck && issueCheck && compositeCheck
            && "MF".contains(chars[20]) && field(10, 13) == "RUS"
    }

    /// Цифровые позиции второй строки паспорта РФ: номер, даты, код подразделения, контроль
    static let digitPositions = Set(Array(0..<10) + Array(13..<20) + Array(28..<41) + [42, 43])

    /// Позиции, где у паспорта РФ всегда заполнитель: пустой срок действия и 42-я
    static let fillerPositions = Set(Array(21..<28) + [41])

    /// В цифровых позициях второй строки буква — почти всегда ошибка OCR
    static func repairDigits(_ line: String, at digitPositions: Set<Int> = digitPositions) -> String {
        let fixes: [Character: Character] = [
            "O": "0", "Q": "0", "D": "0", "I": "1", "L": "1",
            "Z": "2", "S": "5", "B": "8", "G": "6",
        ]
        return String(line.enumerated().map { index, character in
            digitPositions.contains(index) ? (fixes[character] ?? character) : character
        })
    }

    /// «K» на месте заполнителя — тот же «<», прочитанный Vision
    static func repairFillers(_ line: String) -> String {
        String(line.enumerated().map { index, character in
            fillerPositions.contains(index) && character == "K" ? "<" : character
        })
    }

    /// Век по смыслу: дата рождения не в будущем, дата выдачи — не раньше 1997 года
    static func date(_ text: Substring, today: Date, isBirth: Bool) -> DateComponents? {
        let digits = text.compactMap(\.wholeNumberValue)
        guard digits.count == 6 else { return nil }
        let yy = digits[0] * 10 + digits[1]
        let month = digits[2] * 10 + digits[3]
        let day = digits[4] * 10 + digits[5]
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: today)
        var year = 2000 + yy
        if year > currentYear { year -= 100 }
        if !isBirth, year < 1997 { return nil }
        return DateComponents(year: year, month: month, day: day)
    }
}

// MARK: - Паспорт по ИКАО

/// Данные из MRZ паспорта по ИКАО 9303: загранпаспорт РФ или паспорт другой страны
struct TravelPassportMRZ: Equatable {
    /// Код страны, выдавшей паспорт: «RUS», «TJK», у Германии — «D»
    let country: String
    /// Гражданство из второй строки — обычно совпадает со страной
    let nationality: String
    let surnameWords: [String]
    let givenWords: [String]
    /// Латиница, как в MRZ: «SAVIN ILIA»
    let latinName: String
    /// Каждое слово имени нашлось среди напечатанных на странице
    let nameConfirmed: Bool
    let number: String
    let birthDate: DateComponents
    let sex: String
    let expiryDate: DateComponents
    let numberValid: Bool
    let birthDateValid: Bool
    let expiryValid: Bool
    let isValid: Bool

    init?(_ mrz: MRZ, printed: Set<String> = [], today: Date = Date()) {
        guard mrz.kind == .travelPassport else { return nil }
        let country = String(mrz.line1.dropFirst(2).prefix(3)).replacingOccurrences(of: "<", with: "")
        // Номер обычного паспорта ИКАО бывает с буквами (L898902C3) — его не
        // трогаем. У российского загранпаспорта номер из одних цифр
        var digits = Set(Array(13..<20) + Array(21..<28) + [43])
        if country == "RUS" { digits.formUnion(0..<10) }
        let line2 = RussianPassportMRZ.repairDigits(Self.repairOptionalFillers(mrz.line2), at: digits)
        let chars = Array(line2)
        guard chars.count == 44 else { return nil }
        func field(_ from: Int, _ to: Int) -> Substring { line2.dropFirst(from).prefix(to - from) }

        guard let birthDate = RussianPassportMRZ.date(field(13, 19), today: today, isBirth: true),
              let expiry = Self.expiry(field(21, 27), today: today) else { return nil }

        numberValid = MRZ.verifies(field(0, 9), check: chars[9])
        birthDateValid = MRZ.verifies(field(13, 19), check: chars[19])
        expiryValid = MRZ.verifies(field(21, 27), check: chars[27])
        let compositeCheck = MRZ.verifies(Substring(String(field(0, 10)) + field(13, 20) + field(21, 43)), check: chars[43])
        isValid = numberValid && birthDateValid && expiryValid && compositeCheck

        self.country = country
        nationality = String(field(10, 13)).replacingOccurrences(of: "<", with: "")
        let names = MRZNameReader.read(String(mrz.line1.dropFirst(5)), script: .latin, printed: printed)
        surnameWords = names.surname
        givenWords = names.given
        latinName = (names.surname + names.given).joined(separator: " ")
        nameConfirmed = names.confirmed
        let rawNumber = field(0, 9).replacingOccurrences(of: "<", with: "")
        // Номер российского загранпаспорта: две цифры серии и семь цифр номера
        number = country == "RUS" && rawNumber.count == 9
            ? "\(rawNumber.prefix(2)) \(rawNumber.dropFirst(2))"
            : rawNumber
        self.birthDate = birthDate
        sex = chars[20] == "F" ? "Ж" : "М"
        expiryDate = expiry
    }

    /// Личный номер в позициях 29–42 у многих паспортов пустой. Если поле почти
    /// всё из заполнителей, «K» в нём — тоже заполнитель, прочитанный Vision
    static func repairOptionalFillers(_ line: String) -> String {
        var chars = Array(line)
        guard chars.count == 44 else { return line }
        let optional = 28..<42
        let fillers = chars[optional].filter { $0 == "<" || $0 == "K" }.count
        guard fillers >= 10, chars[optional].contains("<") else { return line }
        for index in optional where chars[index] == "K" { chars[index] = "<" }
        if chars[42] == "K" { chars[42] = "<" }
        return String(chars)
    }

    /// Срок действия — в будущем или недавнем прошлом, век выбирается так
    private static func expiry(_ text: Substring, today: Date) -> DateComponents? {
        let digits = text.compactMap(\.wholeNumberValue)
        guard digits.count == 6 else { return nil }
        let yy = digits[0] * 10 + digits[1]
        let month = digits[2] * 10 + digits[3]
        let day = digits[4] * 10 + digits[5]
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: today)
        var year = 2000 + yy
        if year > currentYear + 30 { year -= 100 }
        return DateComponents(year: year, month: month, day: day)
    }
}
