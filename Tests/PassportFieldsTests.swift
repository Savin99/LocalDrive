import XCTest
@testable import LocalDrive

// Векторы MRZ посчитаны независимо от кода приложения (скрипт на Python
// по правилам приказа ФМС № 279 и ИКАО 9303), иначе тест проверял бы сам себя
final class PassportFieldsTests: XCTestCase {
    /// Пример из приказа № 279: серия 4601 № 123456, выдан 20.06.2010, код 770-120
    private let russianLine1 = "PNRUSSAVIN<<IL98<ANDREEVI3<<<<<<<<<<<<<<<<<<"
    private let russianLine2 = "4601234561RUS9001011M<<<<<<<1100620770120<34"
    private let travelLine1 = "P<RUSSAVIN<<ILIA<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
    private let travelLine2 = "7212345673RUS9001011M3103153<<<<<<<<<<<<<<02"
    private let today = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 12).date!

    private func page(_ text: String) -> ExtractedText {
        ExtractedText(pages: [ExtractedPage(number: 1, text: text, lines: [])], pageCount: 1)
    }

    private func value(_ key: String, in analysis: DocumentAnalysis) -> String? {
        analysis.fields.first { $0.key == key }?.value
    }

    // MARK: - Контрольные цифры

    func testCheckDigitsOfICAOSpecimen() {
        let line = "L898902C36UTO7408122F1204159ZE184226B<<<<<10"
        XCTAssertEqual(MRZ.checkDigit(line.prefix(9)), 6)
        XCTAssertEqual(MRZ.checkDigit(line.dropFirst(13).prefix(6)), 2)
        XCTAssertEqual(MRZ.checkDigit(line.dropFirst(21).prefix(6)), 9)
        XCTAssertEqual(MRZ.checkDigit(line.dropFirst(28).prefix(14)), 1)
    }

    // MARK: - Паспорт РФ

    func testParsesRussianInternalPassport() throws {
        let mrz = try XCTUnwrap(MRZ.find(in: ["Личная подпись", russianLine1, russianLine2]))
        let passport = try XCTUnwrap(RussianPassportMRZ(mrz, today: today))
        XCTAssertTrue(passport.isValid)
        XCTAssertEqual(passport.fullName, "Савин Илья Андреевич")
        XCTAssertEqual(passport.seriesNumber, "4601 123456")
        XCTAssertEqual(passport.departmentCode, "770-120")
        XCTAssertEqual(DocumentAnalyzer.format(passport.issueDate), "20.06.2010")
        XCTAssertEqual(DocumentAnalyzer.format(passport.birthDate), "01.01.1990")
        XCTAssertEqual(passport.sex, "М")
    }

    /// Vision режет строку на две рамки, читает «<<» ёлочками и путает O с нулём
    func testSurvivesTypicalOCRNoise() throws {
        let noisy2 = "46O123456 1RUS9001011M«<<<<<1100620770120<34"
        let mrz = try XCTUnwrap(MRZ.find(in: ["PNRUSSAVIN«IL98<ANDREEVI3«<<<<", noisy2]))
        let passport = try XCTUnwrap(RussianPassportMRZ(mrz, today: today))
        XCTAssertTrue(passport.isValid, "после нормализации контрольные цифры должны сойтись")
        XCTAssertEqual(passport.seriesNumber, "4601 123456")
        XCTAssertEqual(passport.fullName, "Савин Илья Андреевич")
    }

    func testCyrillicLookalikesAreLatinInMRZ() throws {
        // «Р», «N» и «С» в первой строке пришли кириллицей
        let mrz = try XCTUnwrap(MRZ.find(in: ["РNRUSSAVIN<<IL98<ANDREEVI3", russianLine2]))
        XCTAssertEqual(mrz.kind, .russianInternal)
    }

    func testWrongDigitFailsCheckAndLowersConfidence() throws {
        // Номер 123458 вместо 123456: OCR ошибся, контрольная цифра не сходится
        let broken = "4601234581RUS9001011M<<<<<<<1100620770120<34"
        let mrz = try XCTUnwrap(MRZ.find(in: [russianLine1, broken]))
        let passport = try XCTUnwrap(RussianPassportMRZ(mrz, today: today))
        XCTAssertFalse(passport.isValid)

        let analysis = DocumentAnalyzer.analyze(page([russianLine1, broken].joined(separator: "\n")), today: today)
        let number = try XCTUnwrap(analysis.fields.first { $0.key == FieldKey.seriesNumber })
        XCTAssertTrue(number.needsReview, "ошибка OCR должна быть помечена, а не молча сохранена")
    }

    func testValidMRZFieldsAreTrusted() throws {
        let analysis = DocumentAnalyzer.analyze(page("ПАСПОРТ\n\(russianLine1)\n\(russianLine2)"), today: today)
        XCTAssertEqual(analysis.type, .passportRU)
        let number = try XCTUnwrap(analysis.fields.first { $0.key == FieldKey.seriesNumber })
        XCTAssertFalse(number.needsReview)
        XCTAssertEqual(number.source, .mrz)
    }

    func testPrintedFieldsComplementMRZ() throws {
        let text = """
        РОССИЙСКАЯ ФЕДЕРАЦИЯ
        Паспорт выдан ГУ МВД РОССИИ
        ПО Г. МОСКВЕ
        Дата выдачи 20.06.2010 Код подразделения 770-120
        Личная подпись
        Фамилия САВИН
        Имя ИЛЬЯ
        Отчество АНДРЕЕВИЧ
        Пол МУЖ. Дата рождения 01.01.1990
        Место рождения ГОР. МОСКВА
        \(russianLine1)
        \(russianLine2)
        """
        let analysis = DocumentAnalyzer.analyze(page(text), today: today)
        XCTAssertEqual(analysis.type, .passportRU)
        XCTAssertEqual(value(FieldKey.issuedBy, in: analysis), "ГУ МВД РОССИИ ПО Г. МОСКВЕ")
        XCTAssertEqual(value(FieldKey.birthPlace, in: analysis), "ГОР. МОСКВА")
        XCTAssertEqual(value(FieldKey.fullName, in: analysis), "Савин Илья Андреевич")
        XCTAssertEqual(value(FieldKey.departmentCode, in: analysis), "770-120")
        // Кем выдан нечем проверить — поле ждёт сверки с фото
        XCTAssertEqual(analysis.fields.first { $0.key == FieldKey.issuedBy }?.needsReview, true)
    }

    func testPassportWithoutMRZIsReadFromPrintedFields() throws {
        let text = """
        РОССИЙСКАЯ ФЕДЕРАЦИЯ
        Паспорт выдан ОТДЕЛОМ УФМС РОССИИ ПО ТВЕРСКОЙ ОБЛ.
        Дата выдачи 15.03.2012 Код подразделения 690-001
        45 09 123456
        Фамилия ИВАНОВА
        Имя АННА
        """
        let analysis = DocumentAnalyzer.analyze(page(text), today: today)
        XCTAssertEqual(analysis.type, .passportRU)
        XCTAssertEqual(value(FieldKey.seriesNumber, in: analysis), "4509 123456")
        XCTAssertEqual(value(FieldKey.issueDate, in: analysis), "15.03.2012")
        XCTAssertEqual(value(FieldKey.fullName, in: analysis), "Иванова Анна")
        XCTAssertTrue(analysis.fields.allSatisfy(\.needsReview), "без MRZ проверить нечем — всё на сверку")
    }

    // MARK: - Загранпаспорт

    func testParsesTravelPassport() throws {
        let analysis = DocumentAnalyzer.analyze(page("\(travelLine1)\n\(travelLine2)"), today: today)
        XCTAssertEqual(analysis.type, .passportIntl)
        XCTAssertEqual(value(FieldKey.seriesNumber, in: analysis), "72 1234567")
        XCTAssertEqual(value(FieldKey.expiryDate, in: analysis), "15.03.2031")
        XCTAssertEqual(value(FieldKey.fullName, in: analysis), "SAVIN ILIA")
        XCTAssertFalse(try XCTUnwrap(analysis.fields.first { $0.key == FieldKey.seriesNumber }).needsReview)
        // Имя контрольными цифрами не защищено, а слов со страницы здесь нет.
        // Раньше его считали проверенным — так на iPhone и прошло «Савинккилья»
        XCTAssertTrue(try XCTUnwrap(analysis.fields.first { $0.key == FieldKey.fullName }).needsReview)
    }

    func testICAOSpecimenKeepsLettersInDocumentNumber() throws {
        let mrz = try XCTUnwrap(MRZ.find(in: [
            "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<",
            "L898902C36UTO7408122F1204159ZE184226B<<<<<10",
        ]))
        let passport = try XCTUnwrap(TravelPassportMRZ(mrz, today: today))
        XCTAssertTrue(passport.isValid)
        XCTAssertEqual(passport.number, "L898902C3")
        XCTAssertEqual(passport.latinName, "ERIKSSON ANNA MARIA")
        XCTAssertEqual(DocumentAnalyzer.format(passport.birthDate), "12.08.1974")
    }

    // MARK: - Типы

    func testClassifiesOtherDocuments() {
        XCTAssertEqual(DocumentAnalyzer.classify("российский университет дружбы народов диплом бакалавра"), .diploma)
        XCTAssertEqual(DocumentAnalyzer.classify("справка о результатах проверки"), .certificate)
        XCTAssertEqual(DocumentAnalyzer.classify("страховое свидетельство обязательного пенсионного страхования"), .snils)
        XCTAssertEqual(DocumentAnalyzer.classify("договор аренды"), .other)
    }
}
