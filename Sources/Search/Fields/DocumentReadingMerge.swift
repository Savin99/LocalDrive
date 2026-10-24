import Foundation

// Слияние полей правил и прочитанного моделью. На стенде (docs/doc-reader.md)
// модель одна ошибалась в 4–9 раз чаще правил и ни разу не была права против
// контрольных цифр MRZ, а вместе с правилами давала лучший результат. Поэтому:
// - подтверждённое правилами (≥ 0,9), исправленное и подтверждённое человеком
//   не трогается, MRZ всегда главнее;
// - значение модели сначала проверяется: маски номера и кода, настоящие даты
//   по порядку, у паспорта РФ нет срока действия;
// - своё значение модель получает с уверенностью 0,6 («проверьте»), 0,9 — если
//   оно же есть в тексте Vision той же страницы;
// - если модель повторила неподтверждённое значение правил, оно становится 0,9;
// - «Кем выдан» и «Место рождения» многострочные, модель обрывала их на первой
//   строке: значение OCR остаётся, модель только заполняет пустое
enum DocumentReadingMerge {
    /// Без этих полей документ в чате неполный — ради них зовётся модель
    static func keyFields(for type: DocumentType) -> [String] {
        switch type {
        case .passportRU:
            [FieldKey.fullName, FieldKey.seriesNumber, FieldKey.issueDate, FieldKey.departmentCode, FieldKey.birthDate]
        case .passportIntl, .driverLicense:
            [FieldKey.fullName, FieldKey.seriesNumber, FieldKey.birthDate, FieldKey.issueDate, FieldKey.expiryDate]
        default:
            []
        }
    }

    /// Ключевое поле не найдено или не подтверждено
    static func needsModel(type: DocumentType, fields: [DocumentField]) -> Bool {
        let byKey = Dictionary(fields.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return keyFields(for: type).contains { key in
            guard let field = byKey[key] else { return true }
            return field.needsReview && field.source != .manual
        }
    }

    static let multiline: Set<String> = [FieldKey.issuedBy, FieldKey.birthPlace, FieldKey.registrationAddress, FieldKey.registrationIssuer]

    /// Правила не узнали документ, но текст страницы похож на удостоверение:
    /// на стенде так терялись тяжёлые и повёрнутые кадры, где MRZ не прочиталась
    static func looksLikeIdentity(_ pageText: String) -> Bool {
        let lower = SearchText.normalize(pageText)
        let strong = ["passport", "pasport", "паспорт", "шиноснома", "водительское удостоверение", "driving licence", "driver license"]
        if strong.contains(where: lower.contains) { return true }
        return lower.contains("фамилия") && (lower.contains("отчество") || lower.contains("дата рождения"))
    }

    /// Вид документа после чтения. MRZ главнее всего. Без неё — вид, который
    /// назвала модель, но загранпаспорт РФ она на стенде называла внутренним.
    /// Латинское «PASSPORT» печатают только паспорта по ИКАО, у паспорта РФ его нет
    static func resolvedType(rules type: DocumentType, fields: [DocumentField], readout: DocumentReadout, pageText: String) -> DocumentType {
        if fields.contains(where: { $0.source == .mrz }) { return type }
        let lower = SearchText.normalize(pageText)
        let icao = lower.contains("passport") || lower.contains("pasport")
        switch readout.type {
        case "passport_ru", "passport_intl", "passport_foreign": return icao ? .passportIntl : .passportRU
        case "driver_license": return .driverLicense
        default: return type
        }
    }

    static func merge(
        rules: [DocumentField],
        readout: DocumentReadout,
        pageText: String,
        type: DocumentType,
        today: Date = Date()
    ) -> [DocumentField] {
        let values = validated(readout, type: type, rules: rules, today: today)
        let page = PageTextIndex(pageText)
        var result = rules
        for (key, value) in values {
            // Обрывок многострочного поля тоже есть в тексте страницы — для
            // него совпадение с текстом не подтверждение (на стенде так прошли
            // бы 7 неверных «Кем выдан» и «Место рождения» без пометки)
            let inText = !multiline.contains(key) && page.contains(value, key: key)
            let confidence = inText ? DocumentAnalyzer.confirmedConfidence : DocumentAnalyzer.printedConfidence
            let modelField = DocumentField(key: key, value: value, confidence: confidence, source: .llm, verified: false)
            guard let index = result.firstIndex(where: { $0.key == key }) else {
                result.append(modelField)
                continue
            }
            let field = result[index]
            guard field.source != .manual, !field.verified, field.confidence < DocumentAnalyzer.confirmedConfidence else {
                continue
            }
            if same(field.value, value) {
                // Два независимых прочтения совпали. Кроме многострочных: подпись
                // правил берёт одну строку, модель тоже обрывает на первой —
                // совпадают и неполные (на стенде так «подтвердилось» усечённое
                // «Место рождения»)
                if !multiline.contains(key) {
                    result[index].confidence = DocumentAnalyzer.confirmedConfidence
                }
                continue
            }
            if multiline.contains(key) { continue }
            // Неподтверждённое значение правил — тоже со страницы. Меняем его,
            // только если своё значение модель подтверждает тем же текстом, или
            // если у правил MRZ не сошлась по контрольной цифре
            if inText || field.confidence < DocumentAnalyzer.printedConfidence {
                result[index] = modelField
            }
        }
        return result
    }

    // MARK: - Проверки

    /// Значения модели, прошедшие проверки, по ключам каталога и в порядке карточки.
    /// Тип документа — у правил: он из MRZ, а модель на стенде называла
    /// загранпаспорт внутренним
    static func validated(
        _ readout: DocumentReadout,
        type: DocumentType,
        rules: [DocumentField],
        today: Date = Date()
    ) -> [(String, String)] {
        let rule = Dictionary(rules.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let country = rule[FieldKey.country]?.value ?? countryCode(readout.country)
        var values: [String: String] = [:]

        if let name = fullName(readout, type: type, country: country, rulesName: rule[FieldKey.fullName]?.value) {
            values[FieldKey.fullName] = name
        }
        if let number = seriesNumber(readout.number, type: type, country: country) {
            values[FieldKey.seriesNumber] = number
        }
        if type == .passportRU, let code = departmentCode(readout.departmentCode) {
            values[FieldKey.departmentCode] = code
        }

        // Даты: настоящие, не из будущего и по порядку
        let birth = date(readout.birthDate).flatMap { $0 <= today && year(of: $0) >= 1900 ? $0 : nil }
        var issue = date(readout.issueDate).flatMap { $0 <= today ? $0 : nil }
        var expiry = type == .passportRU ? nil : date(readout.expiryDate)
        let ruleBirth = rule[FieldKey.birthDate].flatMap { date($0.value) }
        let ruleIssue = rule[FieldKey.issueDate].flatMap { date($0.value) }
        if let issued = issue, let born = birth ?? ruleBirth, born >= issued { issue = nil }
        if let ends = expiry, let issued = issue ?? ruleIssue, ends <= issued { expiry = nil }
        if let birth { values[FieldKey.birthDate] = DocumentAnalyzer.format(components(birth)) }
        if let issue { values[FieldKey.issueDate] = DocumentAnalyzer.format(components(issue)) }
        if let expiry { values[FieldKey.expiryDate] = DocumentAnalyzer.format(components(expiry)) }

        for (key, text) in [(FieldKey.issuedBy, readout.issuedBy), (FieldKey.birthPlace, readout.birthPlace)] {
            if let text = flatten(text), text.filter(\.isLetter).count >= 3 { values[key] = text }
        }
        if let sex = sex(readout.sex) { values[FieldKey.sex] = sex }

        // Регистрация — только у паспорта РФ. Дата не сверяется с датой выдачи:
        // в новый паспорт штамп переносят с прежней датой регистрации
        if type == .passportRU {
            if let address = flatten(readout.registrationAddress), address.filter(\.isLetter).count >= 5 {
                values[FieldKey.registrationAddress] = address
            }
            if let registered = date(readout.registrationDate), registered <= today,
               (birth ?? ruleBirth).map({ registered > $0 }) ?? true {
                values[FieldKey.registrationDate] = DocumentAnalyzer.format(components(registered))
            }
            if let issuer = flatten(readout.registrationIssuer), issuer.filter(\.isLetter).count >= 3 {
                values[FieldKey.registrationIssuer] = issuer
            }
        }
        if type == .passportIntl, rule[FieldKey.country] == nil, let country { values[FieldKey.country] = country }

        let order = FieldKey.order + [FieldKey.country]
        return order.compactMap { key in values[key].map { (key, $0) } }
    }

    /// «Фамилия Имя Отчество». У загранпаспорта РФ ФИО латиницей, как у
    /// правил: оно нужно для билетов. У других паспортов — в той же записи,
    /// что у правил, а без них — как напечатано
    private static func fullName(_ readout: DocumentReadout, type: DocumentType, country: String?, rulesName: String?) -> String? {
        guard let surname = word(readout.surname) else { return nil }
        let given = word(readout.givenName)
        // Имя, повторившее фамилию, — ошибка модели («Рахимов Рахимов» на стенде)
        if let first = given, SearchText.normalize(first) == SearchText.normalize(surname) { return nil }
        var patronymic = word(readout.patronymic)
        // Отчество — одно слово и не повтор имени (проверка стенда)
        if let middle = patronymic, let first = given, first.uppercased().contains(middle.uppercased()) { patronymic = nil }
        let parts = [surname] + [given, patronymic].compactMap { $0 }
        let latin = parts.allSatisfy { $0.unicodeScalars.allSatisfy { $0.isASCII } }
        let cyrillic = parts.allSatisfy { !$0.unicodeScalars.contains { $0.isASCII && CharacterSet.letters.contains($0) } }
        guard latin || cyrillic else { return nil }
        if type == .passportIntl {
            if country == nil || country == "RUS" {
                guard latin else { return nil }
            } else if let rulesName {
                let rulesLatin = rulesName.unicodeScalars.allSatisfy { $0.isASCII }
                guard rulesLatin == latin else { return nil }
            }
        }
        // Латиница — заглавными, как в MRZ; кириллица — с заглавной буквы
        return parts.map { latin ? $0.uppercased() : $0.capitalized }.joined(separator: " ")
    }

    private static func word(_ text: String?) -> String? {
        guard let text = flatten(text), !text.contains(" "),
              text.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }), text.contains(where: \.isLetter) else { return nil }
        return text
    }

    /// Маски номера: паспорт РФ — «#### ######», загранпаспорт РФ — «## #######»,
    /// права РФ — «## ## ######», иностранные документы — 6–10 букв и цифр
    private static func seriesNumber(_ text: String?, type: DocumentType, country: String?) -> String? {
        guard let text else { return nil }
        let compact = text.uppercased().filter { $0.isLetter || $0.isNumber }
        let digits = compact.allSatisfy(\.isNumber)
        switch type {
        case .passportRU:
            guard digits, compact.count == 10 else { return nil }
            return "\(compact.prefix(4)) \(compact.dropFirst(4))"
        case .passportIntl where country == nil || country == "RUS":
            guard digits, compact.count == 9 else { return nil }
            return "\(compact.prefix(2)) \(compact.dropFirst(2))"
        case .driverLicense where digits && compact.count == 10:
            return "\(compact.prefix(2)) \(compact.dropFirst(2).prefix(2)) \(compact.dropFirst(4))"
        case .snils:
            // «123-456-789 01»
            guard digits, compact.count == 11 else { return nil }
            let chars = Array(compact)
            return "\(String(chars[0..<3]))-\(String(chars[3..<6]))-\(String(chars[6..<9])) \(String(chars[9..<11]))"
        case .inn:
            guard digits, compact.count == 10 || compact.count == 12 else { return nil }
            return compact
        case .diploma, .certificate, .other:
            // Номер диплома или справки — как напечатан
            guard (4...20).contains(compact.count) else { return nil }
            return flatten(text)
        default:
            guard (6...10).contains(compact.count), compact.allSatisfy({ $0.isASCII }) else { return nil }
            return compact
        }
    }

    private static func departmentCode(_ text: String?) -> String? {
        guard let digits = text?.filter(\.isNumber), digits.count == 6 else { return nil }
        return "\(digits.prefix(3))-\(digits.suffix(3))"
    }

    private static func sex(_ text: String?) -> String? {
        switch text?.uppercased() {
        case "М", "M", "МУЖ", "MALE": "М"
        case "Ж", "F", "ЖЕН", "FEMALE": "Ж"
        default: nil
        }
    }

    private static func countryCode(_ text: String?) -> String? {
        guard let code = text?.uppercased(), code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return code
    }

    private static func flatten(_ text: String?) -> String? {
        guard let text else { return nil }
        let flat = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.isEmpty ? nil : String(flat.prefix(200))
    }

    // MARK: - Даты

    private static let calendar = Calendar(identifier: .gregorian)

    /// «ДД.ММ.ГГГГ» — только настоящая дата: 31.02 не пройдёт
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let parts = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard parts.count == 3, (1900...2100).contains(parts[2]) else { return nil }
        let wanted = DateComponents(year: parts[2], month: parts[1], day: parts[0])
        guard let date = calendar.date(from: wanted) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == parts[2] && back.month == parts[1] && back.day == parts[0] ? date : nil
    }

    private static func components(_ date: Date) -> DateComponents {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return DateComponents(year: parts.year, month: parts.month, day: parts.day)
    }

    private static func year(of date: Date) -> Int {
        calendar.component(.year, from: date)
    }

    /// Одно и то же значение, записанное по-разному: регистр, «ё», пробелы
    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        func key(_ text: String) -> String {
            SearchText.normalize(text).filter { $0.isLetter || $0.isNumber }
        }
        return key(lhs) == key(rhs)
    }
}

/// Текст страницы от Vision, приготовленный для сверки со значениями модели
private struct PageTextIndex {
    let words: Set<String>
    let dates: [DateComponents]
    let compact: String
    let flat: String

    init(_ text: String) {
        words = MRZNameReader.printedWords(in: text, script: .russianInternal)
            .union(MRZNameReader.printedWords(in: text, script: .latin))
        dates = PassportPrint.dates(in: text)
        // Строки MRZ — не подтверждение: первые десять цифр второй строки
        // похожи на серию и номер, но это не они
        let printed = text.components(separatedBy: .newlines)
            .filter { !MRZNameReader.looksLikeMRZ($0) }
            .joined(separator: "\n")
        compact = printed.uppercased().filter { $0.isLetter || $0.isNumber }
        flat = printed.uppercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    func contains(_ value: String, key: String) -> Bool {
        switch key {
        case FieldKey.fullName:
            let parts = value.split(separator: " ").map(String.init)
            return !parts.isEmpty && parts.allSatisfy { part in
                words.contains(MRZNameReader.normalize(part, script: .russianInternal))
                    || words.contains(MRZNameReader.normalize(part, script: .latin))
            }
        case FieldKey.birthDate, FieldKey.issueDate, FieldKey.expiryDate:
            guard let date = DocumentReadingMerge.date(value) else { return false }
            let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
            return dates.contains(DateComponents(year: parts.year, month: parts.month, day: parts.day))
        case FieldKey.seriesNumber, FieldKey.departmentCode:
            let needle = value.uppercased().filter { $0.isLetter || $0.isNumber }
            return !needle.isEmpty && compact.contains(needle)
        case FieldKey.issuedBy, FieldKey.birthPlace:
            let needle = value.uppercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return flat.contains(needle)
        default:
            return false
        }
    }
}
