import Foundation

/// Ключи полей. Хранятся в базе и передаются в карточках — значения
/// рендерер всегда берёт из базы
enum FieldKey {
    static let fullName = "full_name"
    static let seriesNumber = "series_number"
    static let issuedBy = "issued_by"
    static let issueDate = "issue_date"
    static let departmentCode = "department_code"
    static let birthDate = "birth_date"
    static let birthPlace = "birth_place"
    static let sex = "sex"
    static let expiryDate = "expiry_date"
    /// Код страны ИКАО у паспорта по ИКАО: «TJK». Строкой в карточке не
    /// показывается — страна видна в названии: «Паспорт Таджикистана»
    static let country = "country"
    /// Действующая регистрация по месту жительства — последний штамп
    /// «Зарегистрирован» на страницах «Место жительства» паспорта РФ
    static let registrationAddress = "registration_address"
    static let registrationDate = "registration_date"
    static let registrationIssuer = "registration_issuer"

    /// Порядок полей в карточке — как в паспорте: разворот, затем регистрация
    static let order = [
        fullName, seriesNumber, issuedBy, issueDate, departmentCode,
        expiryDate, birthDate, sex, birthPlace,
        registrationAddress, registrationDate, registrationIssuer,
    ]

    static let registration = [registrationAddress, registrationDate, registrationIssuer]

    static func title(_ key: String) -> String {
        switch key {
        case fullName: "ФИО"
        case seriesNumber: "Серия и номер"
        case issuedBy: "Кем выдан"
        case issueDate: "Дата выдачи"
        case departmentCode: "Код подразделения"
        case birthDate: "Дата рождения"
        case birthPlace: "Место рождения"
        case sex: "Пол"
        case expiryDate: "Действует до"
        case country: "Страна"
        case registrationAddress: "Адрес регистрации"
        case registrationDate: "Дата регистрации"
        case registrationIssuer: "Орган регистрации"
        default: key
        }
    }

    /// Номер документа в карточке закрыт маской, пока его не откроют касанием
    static func isSensitive(_ key: String) -> Bool {
        key == seriesNumber
    }
}

/// Что удалось понять о документе по его тексту
struct DocumentAnalysis: Sendable {
    var type: DocumentType
    var fields: [DocumentField]

    static let unknown = DocumentAnalysis(type: .other, fields: [])
}

// Поля типовых документов. Порядок надёжности из спецификации: сначала MRZ
// с проверкой контрольных цифр, затем подписи на самой странице. Всё, что
// не подтверждено проверкой или вторым прочтением, получает низкую уверенность
// и помечается в карточке для сверки с фото
enum DocumentAnalyzer {
    static let verifiedConfidence = 0.99
    /// MRZ не сошлась по контрольным цифрам, но совпала с подписью на странице
    static let confirmedConfidence = 0.9
    static let printedConfidence = 0.6
    static let brokenConfidence = 0.4

    static func analyze(_ extracted: ExtractedText, today: Date = Date()) -> DocumentAnalysis {
        let text = extracted.pages.map(\.text).joined(separator: "\n")
        guard !text.isEmpty else { return .unknown }
        let lower = SearchText.normalize(text)

        let registration = PrintedRegistration(text).fields
        if let mrz = MRZ.find(in: text.components(separatedBy: .newlines)) {
            let printedCyrillic = MRZNameReader.printedWords(in: text, script: .russianInternal)
            if let passport = RussianPassportMRZ(mrz, printed: printedCyrillic, today: today) {
                return DocumentAnalysis(type: .passportRU, fields: russianPassport(passport, text: text) + registration)
            }
            let printedLatin = MRZNameReader.printedWords(in: text, script: .latin)
            if let passport = TravelPassportMRZ(mrz, printed: printedLatin, today: today) {
                return DocumentAnalysis(type: .passportIntl, fields: travelPassport(passport, text: text))
            }
        }
        if looksLikeRussianPassport(lower) {
            return DocumentAnalysis(type: .passportRU, fields: russianPassport(nil, text: text) + registration)
        }
        // Страница «Место жительства» без имени и номера — разворот паспорта РФ:
        // чат приложит её к паспорту, как разворот «кем выдан»
        if !registration.isEmpty, lower.contains("место жительства") {
            return DocumentAnalysis(type: .passportRU, fields: registration)
        }
        return DocumentAnalysis(type: classify(lower), fields: [])
    }

    // MARK: - Паспорт РФ

    private static func russianPassport(_ mrz: RussianPassportMRZ?, text: String) -> [DocumentField] {
        let printed = PrintedPassport(text)
        var fields: [DocumentField] = []

        /// `valid` — сошлась контрольная цифра самого поля: ошибка в другом поле
        /// не должна ронять доверие к этому
        func add(_ key: String, mrz mrzValue: String?, valid: Bool, printed printedValue: String?) {
            let agrees = mrzValue != nil && printedValue != nil
                && SearchText.normalize(mrzValue!) == SearchText.normalize(printedValue!)
            if let mrzValue, mrz != nil {
                let confidence = valid ? verifiedConfidence : (agrees ? confirmedConfidence : brokenConfidence)
                fields.append(DocumentField(key: key, value: mrzValue, confidence: confidence, source: .mrz, verified: false))
            } else if let printedValue {
                fields.append(DocumentField(key: key, value: printedValue, confidence: printedConfidence, source: .regex, verified: false))
            }
        }

        if let mrz {
            fields.append(fullName(mrz, printed: printed.fullName))
        } else if let name = printed.fullName {
            fields.append(DocumentField(key: FieldKey.fullName, value: name, confidence: printedConfidence, source: .regex, verified: false))
        }
        add(FieldKey.seriesNumber, mrz: mrz?.seriesNumber, valid: mrz?.seriesNumberValid == true, printed: printed.seriesNumber)
        add(FieldKey.issuedBy, mrz: nil, valid: false, printed: printed.issuedBy)
        add(FieldKey.issueDate, mrz: mrz.map { format($0.issueDate) }, valid: mrz?.issueValid == true, printed: printed.issueDate)
        add(FieldKey.departmentCode, mrz: mrz?.departmentCode, valid: mrz?.issueValid == true, printed: printed.departmentCode)
        add(FieldKey.birthDate, mrz: mrz.map { format($0.birthDate) }, valid: mrz?.birthDateValid == true, printed: printed.birthDate)
        add(FieldKey.sex, mrz: mrz?.sex, valid: mrz?.isValid == true, printed: printed.sex)
        add(FieldKey.birthPlace, mrz: nil, valid: false, printed: printed.birthPlace)
        return fields
    }

    /// ФИО из MRZ. Контрольной цифры у имени нет: верим ему, только если его
    /// слова подтверждает напечатанное на странице. Иначе — на сверку с фото:
    /// раньше сошедшиеся цифры номера выдавали за проверенное и мусорное
    /// «Савинккилья», прочитанное из заполнителей
    private static func fullName(_ mrz: RussianPassportMRZ, printed printedName: String?) -> DocumentField {
        let agrees = printedName.map { SearchText.normalize($0) == SearchText.normalize(mrz.fullName) } ?? false
        let confidence = mrz.nameConfirmed ? verifiedConfidence : (agrees ? confirmedConfidence : printedConfidence)
        let value = mrz.fullName.isEmpty ? (printedName ?? "") : mrz.fullName
        return DocumentField(key: FieldKey.fullName, value: value, confidence: confidence, source: .mrz, verified: false)
    }

    private static func looksLikeRussianPassport(_ lower: String) -> Bool {
        // Свидетельства ЗАГСа тоже пишут «Российская Федерация», «Фамилия»,
        // «выдано», а паспорт родителей упоминают словом «паспорт». На iPhone
        // владельца так свидетельство о рождении стало «Паспортом РФ»
        guard !civilRegistryTitles.contains(where: lower.contains) else { return false }
        return lower.contains("паспорт")
            && (lower.contains("российская федерация") || lower.contains("код подразделения"))
            && (lower.contains("выдан") || lower.contains("фамилия"))
    }

    private static let civilRegistryTitles = [
        "свидетельство о рождении", "свидетельство о браке", "свидетельство о расторжении брака",
        "свидетельство о смерти", "свидетельство об установлении отцовства", "свидетельство о перемене имени",
    ]

    // MARK: - Загранпаспорт

    /// Загранпаспорт РФ и паспорта других стран. Поля из MRZ сверены своими
    /// контрольными цифрами; дата выдачи и орган — со страницы
    private static func travelPassport(_ mrz: TravelPassportMRZ, text: String) -> [DocumentField] {
        func field(_ key: String, _ value: String, _ confidence: Double, _ source: FieldSource = .mrz) -> DocumentField {
            DocumentField(key: key, value: value, confidence: confidence, source: source, verified: false)
        }
        func checked(_ valid: Bool) -> Double { valid ? verifiedConfidence : brokenConfidence }

        var fields: [DocumentField] = []
        // У паспортов стран СНГ ФИО напечатано и кириллицей — по ней ищут в
        // чате. Загранпаспорт РФ — латиницей: она нужна для билетов
        if mrz.country != "RUS",
           let cyrillic = ForeignPassportName.cyrillic(surname: mrz.surnameWords, given: mrz.givenWords, in: text) {
            fields.append(field(FieldKey.fullName, cyrillic, confirmedConfidence, .regex))
        } else {
            fields.append(field(FieldKey.fullName, mrz.latinName, mrz.nameConfirmed ? verifiedConfidence : printedConfidence))
        }
        fields.append(field(FieldKey.seriesNumber, mrz.number, checked(mrz.numberValid)))
        fields.append(field(FieldKey.expiryDate, format(mrz.expiryDate), checked(mrz.expiryValid)))
        fields.append(field(FieldKey.birthDate, format(mrz.birthDate), checked(mrz.birthDateValid)))
        fields.append(field(FieldKey.sex, mrz.sex, checked(mrz.isValid)))
        // Код страны контрольной цифрой не защищён: сверяем со второй строкой
        fields.append(field(FieldKey.country, mrz.country, mrz.country == mrz.nationality ? verifiedConfidence : printedConfidence))
        if let issue = PassportPrint.issueDate(in: text, birth: mrz.birthDate, expiry: mrz.expiryDate) {
            fields.append(field(FieldKey.issueDate, format(issue.date), issue.confidence, .regex))
        }
        if let authority = PassportPrint.authority(in: text) {
            fields.append(field(FieldKey.issuedBy, authority, printedConfidence, .regex))
        }
        return fields
    }

    // MARK: - Остальные типы

    /// Тип по ключевым словам. Полей у этих документов пока нет: после
    /// паспорта очередь за ними решает владелец (открытый вопрос спецификации)
    static func classify(_ lower: String) -> DocumentType {
        let head = String(lower.prefix(400))
        if lower.contains("диплом"),
           ["бакалавр", "магистр", "специалист", "высшем образовании", "приложение к диплому", "профессиональном образовании"]
               .contains(where: lower.contains) {
            return .diploma
        }
        if lower.contains("страховое свидетельство") || lower.contains("снилс") || lower.contains("страховой номер индивидуального") {
            return .snils
        }
        if lower.contains("идентификационный номер налогоплательщика") || lower.contains("постановке на учет") {
            return .inn
        }
        if lower.contains("водительское удостоверение") || lower.contains("driving licence") {
            return .driverLicense
        }
        if head.contains("справка") {
            return .certificate
        }
        return .other
    }

    static func format(_ date: DateComponents) -> String {
        String(format: "%02d.%02d.%04d", date.day ?? 0, date.month ?? 0, date.year ?? 0)
    }
}

/// Штамп регистрации со страницы «Место жительства»: адрес, дата и орган
/// после «Зарегистрирован». Штампы разные и OCR их читает плохо — всё с
/// уверенностью подписи, на сверку. Берётся последний штамп на странице;
/// «Зарегистрирован брак» со страницы семейного положения — не регистрация
struct PrintedRegistration {
    var address: String?
    var date: String?
    var issuer: String?

    init(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !MRZNameReader.looksLikeMRZ($0) }
        let starts = lines.indices.filter { index in
            let lower = SearchText.normalize(lines[index])
            return lower.contains("зарегистрирован") && !lower.contains("брак")
        }
        guard let start = starts.last else { return }
        var block: [String] = []
        // Хвост первой строки: «Зарегистрирован г. Москва…» — тоже адрес
        if let range = lines[start].range(of: "зарегистрирован", options: [.caseInsensitive, .diacriticInsensitive]) {
            var rest = lines[start][range.upperBound...]
            // «Зарегистрирована» — то же слово
            if rest.first.map({ $0 == "а" || $0 == "А" }) == true { rest = rest.dropFirst() }
            let tail = rest.trimmingCharacters(in: CharacterSet(charactersIn: " :,."))
            if !tail.isEmpty { block.append(tail) }
        }
        for line in lines.dropFirst(start + 1).prefix(8) {
            if SearchText.normalize(line).contains("снят с регистрац") { break }
            block.append(line)
        }
        date = block.lazy.compactMap(Self.date).first
        issuer = block.first { line in
            Self.issuerMarkers.contains { SearchText.normalize(line).contains($0) }
        }.map(Self.flatten)
        let addressLines = block.filter { line in
            line != issuer && Self.date(line) == nil
                && line.range(of: Self.addressPattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if !addressLines.isEmpty {
            let joined = Self.flatten(addressLines.joined(separator: " "))
            if joined.filter(\.isLetter).count >= 5 { address = String(joined.prefix(200)) }
        }
    }

    var fields: [DocumentField] {
        [(FieldKey.registrationAddress, address), (FieldKey.registrationDate, date), (FieldKey.registrationIssuer, issuer)]
            .compactMap { key, value in
                value.map { DocumentField(key: key, value: $0, confidence: DocumentAnalyzer.printedConfidence, source: .regex, verified: false) }
            }
    }

    private static let addressPattern = #"(^|[\s,])(г\.|гор\.|город|ул\.|улица|д\.|дом|кв\.|корп|стр\.|обл|край|р-н|район|пос\.|п\.|с\.|дер\.|пр-т|просп|пер\.|наб\.|ш\.|мкр)"#
    private static let issuerMarkers = ["овм", "уфмс", "мвд", "гувм", "овд", "отдел", "отделение", "миграц"]
    private static let months = ["января": 1, "февраля": 2, "марта": 3, "апреля": 4, "мая": 5, "июня": 6,
                                 "июля": 7, "августа": 8, "сентября": 9, "октября": 10, "ноября": 11, "декабря": 12]

    /// «15.07.2023» или «"15" июля 2023 г.»
    private static func date(_ line: String) -> String? {
        let lower = SearchText.normalize(line)
        let range = NSRange(lower.startIndex..., in: lower)
        if let numeric = try? NSRegularExpression(pattern: #"(\d{2})[.\-/](\d{2})[.\-/](\d{4})"#),
           let match = numeric.firstMatch(in: lower, range: range) {
            let parts = (1...3).compactMap { Range(match.range(at: $0), in: lower).flatMap { Int(lower[$0]) } }
            if parts.count == 3, let text = valid(parts[0], parts[1], parts[2]) { return text }
        }
        if let named = try? NSRegularExpression(pattern: #"(\d{1,2})\D{0,3}\s*(января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря)\s+(\d{4})"#),
           let match = named.firstMatch(in: lower, range: range),
           let dayRange = Range(match.range(at: 1), in: lower), let monthRange = Range(match.range(at: 2), in: lower),
           let yearRange = Range(match.range(at: 3), in: lower),
           let day = Int(lower[dayRange]), let month = months[String(lower[monthRange])], let year = Int(lower[yearRange]) {
            return valid(day, month, year)
        }
        return nil
    }

    private static func valid(_ day: Int, _ month: Int, _ year: Int) -> String? {
        let text = String(format: "%02d.%02d.%04d", day, month, year)
        return DocumentReadingMerge.date(text) != nil ? text : nil
    }

    private static func flatten(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
    }
}

/// Поля, напечатанные на развороте паспорта, — по подписям рядом с ними.
/// Vision ставит подпись и значение в одну строку, если они на одной высоте
struct PrintedPassport {
    var fullName: String?
    var seriesNumber: String?
    var issuedBy: String?
    var issueDate: String?
    var departmentCode: String?
    var birthDate: String?
    var birthPlace: String?
    var sex: String?

    init(_ fullText: String) {
        // Строки MRZ разбираются отдельно и с контрольными цифрами. Здесь они
        // только мешают: первые десять цифр второй строки похожи на «серию и номер»
        let text = fullText.components(separatedBy: .newlines)
            .filter { !MRZ.normalize($0).contains("<<") }
            .joined(separator: "\n")
        issuedBy = Self.capture(#"паспорт\s+выдан\s*[:\-]?\s*(.+?)\s*(?=дата\s+выдачи|код\s+подразделения|личная\s+подпись|$)"#, in: text, multiline: true)
            .map(Self.flatten)
            .flatMap { $0.count >= 4 && $0.contains(where: \.isLetter) ? String($0.prefix(200)) : nil }
        issueDate = Self.date(after: "дата\\s+выдачи", in: text)
        birthDate = Self.date(after: "дата\\s+рождения", in: text)
        if let code = Self.captures(#"код\s+подразделения\s*[:\-]?\s*(\d{3})\s*[-–—]?\s*(\d{3})"#, in: text) {
            departmentCode = "\(code[0])-\(code[1])"
        }
        birthPlace = Self.capture(#"место\s+рождения\s*[:\-]?\s*([^\n]+)"#, in: text, multiline: false).map(Self.flatten)
        if let sexWord = Self.capture(#"пол\s*[:\-]?\s*(муж|жен)"#, in: text, multiline: false) {
            sex = SearchText.normalize(sexWord).hasPrefix("ж") ? "Ж" : "М"
        }

        // Значения ФИО напечатаны заглавными: так подпись «Имя» не спутать
        // со значением в соседней колонке
        let parts = ["[Фф]амилия", "[Ии]мя", "[Оо]тчество"].compactMap { label -> String? in
            Self.captureCaseSensitive("\(label)\\s*[:\\-]?\\s*([А-ЯЁ][А-ЯЁ\\-]+)", in: text)
        }
        if parts.count >= 2 {
            fullName = parts.map { $0.capitalized }.joined(separator: " ")
        }

        // Серия и номер напечатаны по краю страницы: «45 09 123456». Номер
        // повторяется на обоих разворотах — берём самый частый вариант
        let numbers = Self.allCaptures(#"(?<!\d)(\d{2})\s?(\d{2})\s?(\d{6})(?!\d)"#, in: text).map { "\($0[0])\($0[1]) \($0[2])" }
        seriesNumber = Dictionary(grouping: numbers, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    private static func date(after label: String, in text: String) -> String? {
        guard let parts = captures(label + #"\s*[:\-]?\s*(\d{2})\s*[.,]\s*(\d{2})\s*[.,]\s*(\d{4})"#, in: text) else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    private static func flatten(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    // MARK: - Регулярные выражения

    private static func regex(_ pattern: String, ignoreCase: Bool, multiline: Bool) -> NSRegularExpression? {
        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }
        if multiline { options.insert(.dotMatchesLineSeparators) }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }

    private static func capture(_ pattern: String, in text: String, multiline: Bool) -> String? {
        captures(pattern, in: text, ignoreCase: true, multiline: multiline)?.first
    }

    private static func captureCaseSensitive(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text, ignoreCase: false, multiline: false)?.first
    }

    private static func captures(
        _ pattern: String,
        in text: String,
        ignoreCase: Bool = true,
        multiline: Bool = false
    ) -> [String]? {
        guard let regex = regex(pattern, ignoreCase: ignoreCase, multiline: multiline),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return groups(of: match, in: text)
    }

    private static func allCaptures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = regex(pattern, ignoreCase: true, multiline: false) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { groups(of: $0, in: text) }
    }

    private static func groups(of match: NSTextCheckingResult, in text: String) -> [String]? {
        var values: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            values.append(String(text[range]))
        }
        return values
    }
}
