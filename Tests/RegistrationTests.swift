import XCTest
@testable import LocalDrive

// Регистрация по месту жительства из паспорта РФ. Жалоба владельца
// 13.10.2026: «Регистрацию тоже» → «Не нашёл сведений о регистрации» — штампы
// со страниц «Место жительства» не распознавались полями. Адреса синтетические
final class RegistrationTests: XCTestCase {
    private let today = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 13).date!

    private func page(_ text: String) -> ExtractedText {
        ExtractedText(pages: [ExtractedPage(number: 1, text: text, lines: [])], pageCount: 1)
    }

    private func value(_ key: String, in fields: [DocumentField]) -> String? {
        fields.first { $0.key == key }?.value
    }

    func testFieldsAreInCardOrderAfterBirthPlace() {
        let order = FieldKey.order
        let birthPlace = try! XCTUnwrap(order.firstIndex(of: FieldKey.birthPlace))
        XCTAssertEqual(Array(order[(birthPlace + 1)...]), FieldKey.registration)
        XCTAssertEqual(FieldKey.title(FieldKey.registrationAddress), "Адрес регистрации")
        XCTAssertEqual(FieldKey.title(FieldKey.registrationDate), "Дата регистрации")
    }

    // MARK: - Правила без облака

    func testRulesReadRegistrationPage() {
        let text = """
        МЕСТО ЖИТЕЛЬСТВА
        ЗАРЕГИСТРИРОВАН
        "03" апреля 2019 г.
        г. Москва, ул. Лесная, д. 5, кв. 12
        ОВМ ОМВД России по району Тверской г. Москвы
        """
        let analysis = DocumentAnalyzer.analyze(page(text), today: today)
        XCTAssertEqual(analysis.type, .passportRU, "страница прописки — разворот паспорта РФ")
        XCTAssertEqual(value(FieldKey.registrationAddress, in: analysis.fields), "г. Москва, ул. Лесная, д. 5, кв. 12")
        XCTAssertEqual(value(FieldKey.registrationDate, in: analysis.fields), "03.04.2019")
        XCTAssertEqual(value(FieldKey.registrationIssuer, in: analysis.fields), "ОВМ ОМВД России по району Тверской г. Москвы")
        XCTAssertTrue(analysis.fields.allSatisfy(\.needsReview), "штамп по OCR — на сверку")
    }

    func testLatestStampOnPageWinsAndFeminineFormKeepsAddress() {
        let text = """
        МЕСТО ЖИТЕЛЬСТВА
        Зарегистрирована г. Тверь, ул. Новая, д. 1
        12.05.2010
        Снят с регистрационного учёта 01.02.2015
        Зарегистрирована г. Москва
        ул. Садовая, д. 7, кв. 3
        02.02.2015
        """
        let fields = DocumentAnalyzer.analyze(page(text), today: today).fields
        XCTAssertEqual(value(FieldKey.registrationAddress, in: fields), "г. Москва ул. Садовая, д. 7, кв. 3")
        XCTAssertEqual(value(FieldKey.registrationDate, in: fields), "02.02.2015")
    }

    func testMarriageStampIsNotRegistration() {
        let text = """
        СЕМЕЙНОЕ ПОЛОЖЕНИЕ
        Зарегистрирован брак с гр. ПЕТРОВОЙ А. И.
        г. Москва, ул. Лесная, д. 5
        10.06.2018
        """
        let fields = DocumentAnalyzer.analyze(page(text), today: today).fields
        XCTAssertNil(value(FieldKey.registrationAddress, in: fields))
    }

    func testPassportFileWithRegistrationPageKeepsBoth() {
        let text = """
        PNRUSSAVIN<<IL98<ANDREEVI3<<<<<<<<<<<<<<<<<<
        4601234561RUS9001011M<<<<<<<1100620770120<34
        МЕСТО ЖИТЕЛЬСТВА
        ЗАРЕГИСТРИРОВАН
        г. Москва, ул. Лесная, д. 5, кв. 12
        03.04.2019
        """
        let analysis = DocumentAnalyzer.analyze(page(text), today: today)
        XCTAssertEqual(analysis.type, .passportRU)
        XCTAssertEqual(value(FieldKey.seriesNumber, in: analysis.fields), "4601 123456")
        XCTAssertEqual(value(FieldKey.registrationDate, in: analysis.fields), "03.04.2019")
    }

    // MARK: - Облако

    func testCurrentRegistrationAcrossPages() throws {
        func readout(_ address: String?, _ date: String?, deregistered: String? = nil) -> CloudPageReadout {
            CloudPageReadout(readout: DocumentReadout(type: "passport_ru", registrationAddress: address, registrationDate: date,
                                                      deregistrationDate: deregistered), text: "")
        }
        let older = readout("г. Тверь, ул. Новая, д. 1", "12.05.2010")
        let newer = readout("г. Москва, ул. Садовая, д. 7", "02.02.2015")
        let both = CloudDocumentReadout(pages: [(1, older), (2, newer)]).readout
        XCTAssertEqual(both.registrationAddress, "г. Москва, ул. Садовая, д. 7")
        XCTAssertEqual(both.registrationDate, "02.02.2015")

        // Позже последней регистрации — снятие с учёта: действующей нет
        let cancelled = CloudDocumentReadout(pages: [(1, older), (2, newer), (3, readout(nil, nil, deregistered: "01.03.2020"))]).readout
        XCTAssertNil(cancelled.registrationAddress)

        // Снятие в тот же день, что и новая регистрация, — переезд
        let moved = CloudDocumentReadout(pages: [(1, readout("г. Москва, ул. Садовая, д. 7", "02.02.2015", deregistered: "02.02.2015"))]).readout
        XCTAssertEqual(moved.registrationDate, "02.02.2015")
    }

    func testCloudRegistrationIsValidatedAndManualWins() {
        let cloud = DocumentReadout(type: "passport_ru", birthDate: "01.01.1990", registrationAddress: "г. Москва, ул. Садовая, д. 7",
                                    registrationDate: "02.02.2015", registrationIssuer: "ОВМ ОМВД России по району Арбат")
        let fields = CloudMerge.merge(rules: [], cloud: cloud, type: .passportRU, today: today)
        XCTAssertEqual(value(FieldKey.registrationAddress, in: fields), "г. Москва, ул. Садовая, д. 7")
        XCTAssertEqual(fields.first { $0.key == FieldKey.registrationDate }?.confidence, DocumentAnalyzer.confirmedConfidence)

        // Дата из будущего и дата раньше рождения отбрасываются
        let future = DocumentReadout(type: "passport_ru", registrationAddress: "г. Москва, ул. Садовая, д. 7", registrationDate: "01.01.2030")
        XCTAssertNil(value(FieldKey.registrationDate, in: CloudMerge.merge(rules: [], cloud: future, type: .passportRU, today: today)))
        let early = DocumentReadout(type: "passport_ru", birthDate: "01.01.1990", registrationDate: "01.01.1980")
        XCTAssertNil(value(FieldKey.registrationDate, in: CloudMerge.merge(rules: [], cloud: early, type: .passportRU, today: today)))

        // У загранпаспорта регистрации нет
        XCTAssertNil(value(FieldKey.registrationAddress, in: CloudMerge.merge(rules: [], cloud: cloud, type: .passportIntl, today: today)))

        // Исправленное человеком главнее
        let manual = DocumentField(key: FieldKey.registrationAddress, value: "г. Москва, ул. Тверская, д. 1", confidence: 1, source: .manual, verified: true)
        XCTAssertEqual(value(FieldKey.registrationAddress, in: CloudMerge.merge(rules: [manual], cloud: cloud, type: .passportRU, today: today)),
                       "г. Москва, ул. Тверская, д. 1")
    }

    func testCloudReplyWithRegistrationDecodes() throws {
        let json = #"{"type": "passport_ru", "country": "", "text": "МЕСТО ЖИТЕЛЬСТВА", "surname": "", "given_name": "", "patronymic": "", "birth_date": "", "issue_date": "", "expiry_date": "", "number": "", "department_code": "", "issued_by": "", "birth_place": "", "registration_address": "г. Москва, ул. Садовая, д. 7", "registration_date": "02.02.2015", "registration_issuer": "ОВМ", "deregistration_date": "", "sex": ""}"#
        let page = try JSONDecoder().decode(CloudPageReadout.self, from: Data(json.utf8))
        XCTAssertEqual(page.readout.registrationAddress, "г. Москва, ул. Садовая, д. 7")
        XCTAssertEqual(page.readout.registrationDate, "02.02.2015")
        XCTAssertNil(page.readout.deregistrationDate)
    }

    func testCloudSchemaListsRegistrationAndStaysStrict() throws {
        let keys = CloudPrompt.keys
        for key in ["registration_address", "registration_date", "registration_issuer", "deregistration_date"] {
            XCTAssertTrue(keys.contains(key), key)
        }
        let schema = try JSONSerialization.jsonObject(with: OrderedJSON.data(CloudPrompt.schema))
        var problems: [String] = []
        func walk(_ node: Any, _ path: String) {
            if let object = node as? [String: Any] {
                if object["type"] as? String == "object" {
                    let properties = Set((object["properties"] as? [String: Any])?.keys.map { $0 } ?? [])
                    if Set(object["required"] as? [String] ?? []) != properties { problems.append("required \(path)") }
                    if object["additionalProperties"] as? Bool != false { problems.append("additionalProperties \(path)") }
                }
                if let types = object["type"] as? [String], types.contains("null"), types.contains("array") || types.contains("object") {
                    problems.append("nullable \(path)")
                }
                for (key, value) in object { walk(value, path + "/" + key) }
            } else if let array = node as? [Any] {
                for (index, value) in array.enumerated() { walk(value, path + "[\(index)]") }
            }
        }
        walk(schema, "#")
        XCTAssertEqual(problems, [])
    }
}
