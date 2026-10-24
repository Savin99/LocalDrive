import Foundation

// Поля из облака. Модель там сильная, поэтому прошедшее проверки значение
// получает 0,9 — без «проверьте». Но MRZ с контрольной цифрой и исправленное
// или подтверждённое человеком главнее всегда. Проверки те же, что у
// локальной модели: маски номера и кода, настоящие даты по порядку, у
// паспорта РФ нет срока действия; непрошедшее отбрасывается
enum CloudMerge {
    /// Вид документа: при MRZ — у правил, иначе — что назвало облако
    static func resolvedType(rules type: DocumentType, fields: [DocumentField], cloud: DocumentReadout) -> DocumentType {
        if fields.contains(where: { $0.source == .mrz }) { return type }
        return cloud.type.flatMap(DocumentType.init(rawValue:)) ?? type
    }

    static func merge(rules: [DocumentField], cloud: DocumentReadout, type: DocumentType, today: Date = Date()) -> [DocumentField] {
        var result = rules
        for (key, value) in DocumentReadingMerge.validated(cloud, type: type, rules: rules, today: today) {
            let field = DocumentField(key: key, value: value, confidence: DocumentAnalyzer.confirmedConfidence, source: .cloud, verified: false)
            guard let index = result.firstIndex(where: { $0.key == key }) else {
                result.append(field)
                continue
            }
            let existing = result[index]
            if existing.source == .manual || existing.verified { continue }
            if existing.source == .mrz, existing.confidence >= DocumentAnalyzer.verifiedConfidence { continue }
            result[index] = field
        }
        return result
    }
}
