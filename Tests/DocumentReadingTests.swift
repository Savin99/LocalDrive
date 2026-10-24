import CoreGraphics
import XCTest
@testable import LocalDrive

// Второе чтение удостоверений моделью. Модель здесь — подделка: в симуляторе
// MLX не работает, а проверяется то, что вокруг неё, — слияние с правилами,
// очередь индекса и приватность. Значения полей синтетические
final class DocumentReadingMergeTests: XCTestCase {
    private let today = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 12).date!

    private func field(_ key: String, _ value: String, _ confidence: Double, _ source: FieldSource = .regex, verified: Bool = false) -> DocumentField {
        DocumentField(key: key, value: value, confidence: confidence, source: source, verified: verified)
    }

    private func merged(_ rules: [DocumentField], _ readout: DocumentReadout, text: String = "", type: DocumentType = .passportRU) -> [String: DocumentField] {
        let result = DocumentReadingMerge.merge(rules: rules, readout: readout, pageText: text, type: type, today: today)
        return Dictionary(result.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func testConfirmedRulesFieldsAreNeverTouched() {
        let rules = [
            field(FieldKey.fullName, "Савин Илья Андреевич", 0.99, .mrz),
            field(FieldKey.seriesNumber, "4601 123456", 0.99, .mrz),
        ]
        let readout = DocumentReadout(surname: "ИВАНОВ", givenName: "ПЁТР", number: "4602 654321")
        let result = merged(rules, readout, text: "ИВАНОВ ПЁТР 4602 654321")
        XCTAssertEqual(result[FieldKey.fullName]?.value, "Савин Илья Андреевич")
        XCTAssertEqual(result[FieldKey.seriesNumber]?.value, "4601 123456")
        XCTAssertEqual(result[FieldKey.fullName]?.source, .mrz)
    }

    func testManualAndVerifiedFieldsAreKept() {
        let rules = [
            field(FieldKey.issueDate, "01.02.2015", 1.0, .manual, verified: true),
            field(FieldKey.birthPlace, "ГОР. ТВЕРЬ", 0.6, verified: true),
        ]
        let readout = DocumentReadout(issueDate: "20.06.2010", birthPlace: "ГОР. МОСКВА")
        let result = merged(rules, readout, text: "20.06.2010 ГОР. МОСКВА")
        XCTAssertEqual(result[FieldKey.issueDate]?.value, "01.02.2015")
        XCTAssertEqual(result[FieldKey.birthPlace]?.value, "ГОР. ТВЕРЬ")
    }

    func testMissingFieldIsFlaggedUnlessPageTextBacksIt() {
        let readout = DocumentReadout(issueDate: "20.06.2010", birthPlace: "ГОР. МОСКВА")
        let result = merged([], readout, text: "Дата выдачи 20.06.2010")
        XCTAssertEqual(result[FieldKey.issueDate]?.confidence, DocumentAnalyzer.confirmedConfidence, "дата есть в тексте Vision")
        XCTAssertEqual(result[FieldKey.issueDate]?.source, .llm)
        XCTAssertEqual(result[FieldKey.birthPlace]?.confidence, DocumentAnalyzer.printedConfidence)
        XCTAssertTrue(result[FieldKey.birthPlace]?.needsReview == true, "только модель — «проверьте»")
    }

    func testModelRepeatingUnconfirmedRuleConfirmsIt() {
        let rules = [field(FieldKey.fullName, "Иванов Марк", 0.6, .mrz)]
        let result = merged(rules, DocumentReadout(surname: "ИВАНОВ", givenName: "МАРК"))
        XCTAssertEqual(result[FieldKey.fullName]?.confidence, DocumentAnalyzer.confirmedConfidence)
        XCTAssertEqual(result[FieldKey.fullName]?.source, .mrz, "значение — правил, модель его подтвердила")
    }

    func testUnconfirmedPrintedValueChangesOnlyWhenTextBacksModel() {
        let rules = [field(FieldKey.issueDate, "16.06.2023", 0.6)]
        let unbacked = merged(rules, DocumentReadout(issueDate: "16.06.2021"), text: "Дата выдачи 16.06.2023")
        XCTAssertEqual(unbacked[FieldKey.issueDate]?.value, "16.06.2023")
        let backed = merged(rules, DocumentReadout(issueDate: "15.06.2023"), text: "15.06.2023")
        XCTAssertEqual(backed[FieldKey.issueDate]?.value, "15.06.2023")
        XCTAssertEqual(backed[FieldKey.issueDate]?.confidence, DocumentAnalyzer.confirmedConfidence)
    }

    func testBrokenMRZValueIsReplacedButFlagged() {
        let rules = [field(FieldKey.birthDate, "01.01.1990", 0.4, .mrz)]
        let result = merged(rules, DocumentReadout(birthDate: "01.01.1991"))
        XCTAssertEqual(result[FieldKey.birthDate]?.value, "01.01.1991")
        XCTAssertEqual(result[FieldKey.birthDate]?.source, .llm)
        XCTAssertTrue(result[FieldKey.birthDate]?.needsReview == true)
    }

    func testMultilineFieldKeepsOCRValue() {
        let rules = [field(FieldKey.issuedBy, "ГУ МВД РОССИИ ПО Г. МОСКВЕ", 0.6)]
        let kept = merged(rules, DocumentReadout(issuedBy: "ГУ МВД РОССИИ"), text: "ГУ МВД РОССИИ")
        XCTAssertEqual(kept[FieldKey.issuedBy]?.value, "ГУ МВД РОССИИ ПО Г. МОСКВЕ", "модель обрывает многострочное")
        let filled = merged([], DocumentReadout(issuedBy: "ГУ МВД РОССИИ"), text: "ГУ МВД РОССИИ\nПО Г. МОСКВЕ")
        XCTAssertEqual(filled[FieldKey.issuedBy]?.value, "ГУ МВД РОССИИ")
        XCTAssertTrue(filled[FieldKey.issuedBy]?.needsReview == true, "обрывок есть в тексте, но это не подтверждение")
    }

    func testGivenNameRepeatingSurnameIsDropped() {
        let readout = DocumentReadout(surname: "РАХИМОВ", givenName: "РАХИМОВ", patronymic: "ФАРХОД ДАВЛАТОВИЧ")
        let values = Dictionary(DocumentReadingMerge.validated(readout, type: .passportIntl, rules: [], today: today), uniquingKeysWith: { a, _ in a })
        XCTAssertNil(values[FieldKey.fullName], "имя-повтор фамилии — ошибка модели")
    }

    func testMRZLineIsNotConfirmation() {
        // Первые десять цифр второй строки MRZ — не серия и номер
        let text = "456789\nPNRUSSEM2NOVA<<DAR98<F2DOROVNA<<<<<<<<<<<<<<\n0324567892RUS0108087F<<<<<<<1210819230007<08"
        let result = merged([], DocumentReadout(number: "0324567892"), text: text)
        XCTAssertEqual(result[FieldKey.seriesNumber]?.needsReview, true)
    }

    func testMultilineAgreementDoesNotConfirm() {
        // Подпись правил берёт одну строку, модель обрывает на первой: совпали, но обе неполные
        let rules = [field(FieldKey.birthPlace, "СТ. КАНЕВСКАЯ", 0.6)]
        let result = merged(rules, DocumentReadout(birthPlace: "СТ. КАНЕВСКАЯ"), text: "СТ. КАНЕВСКАЯ\nКРАСНОДАРСКОГО КРАЯ")
        XCTAssertEqual(result[FieldKey.birthPlace]?.confidence, 0.6)
    }

    func testDocumentKindResolution() {
        let printed = [field(FieldKey.fullName, "Ковальчук Никита", 0.6)]
        let saysInternal = DocumentReadout(type: "passport_ru")
        XCTAssertEqual(
            DocumentReadingMerge.resolvedType(rules: .passportRU, fields: printed, readout: saysInternal, pageText: "ПАСПОРТ / PASSPORT"),
            .passportIntl, "латинское PASSPORT бывает только у паспорта по ИКАО"
        )
        XCTAssertEqual(
            DocumentReadingMerge.resolvedType(rules: .other, fields: [], readout: DocumentReadout(type: "passport_foreign"), pageText: "PASPORT"),
            .passportIntl
        )
        let mrz = [field(FieldKey.seriesNumber, "4601 123456", 0.99, .mrz)]
        XCTAssertEqual(
            DocumentReadingMerge.resolvedType(rules: .passportRU, fields: mrz, readout: DocumentReadout(type: "driver_license"), pageText: "PASSPORT"),
            .passportRU, "MRZ главнее модели"
        )
        XCTAssertEqual(DocumentReadingMerge.resolvedType(rules: .other, fields: [], readout: DocumentReadout(type: "other"), pageText: ""), .other)
        XCTAssertTrue(DocumentReadingMerge.looksLikeIdentity("REPUBLIC OF UZBEKISTAN\nPASPORT"))
        XCTAssertTrue(DocumentReadingMerge.looksLikeIdentity("Фамилия ИВАНОВ\nОтчество ПЕТРОВИЧ"))
        XCTAssertFalse(DocumentReadingMerge.looksLikeIdentity("Договор аренды квартиры"))
    }

    func testValidationDropsImpossibleValues() {
        let readout = DocumentReadout(
            surname: "ПЕТРОВ", givenName: "ИВАН", patronymic: "ИВАН",
            birthDate: "12.05.1985", issueDate: "31.02.2010", expiryDate: "10.01.2030",
            number: "12345", departmentCode: "77-120", sex: "X"
        )
        let values = Dictionary(DocumentReadingMerge.validated(readout, type: .passportRU, rules: [], today: today), uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(values[FieldKey.fullName], "Петров Иван", "отчество-повтор имени отброшено")
        XCTAssertNil(values[FieldKey.issueDate], "31 февраля не бывает")
        XCTAssertNil(values[FieldKey.expiryDate], "у паспорта РФ нет срока действия")
        XCTAssertNil(values[FieldKey.seriesNumber])
        XCTAssertNil(values[FieldKey.departmentCode])
        XCTAssertNil(values[FieldKey.sex])
        XCTAssertEqual(values[FieldKey.birthDate], "12.05.1985")

        let order = DocumentReadout(birthDate: "12.05.1985", issueDate: "01.01.1980")
        XCTAssertNil(Dictionary(DocumentReadingMerge.validated(order, type: .passportRU, rules: [], today: today), uniquingKeysWith: { a, _ in a })[FieldKey.issueDate], "выдан раньше рождения")
        let future = DocumentReadout(issueDate: "01.01.2030")
        XCTAssertTrue(DocumentReadingMerge.validated(future, type: .passportRU, rules: [], today: today).isEmpty, "выдан в будущем")
    }

    func testMasksNormalizeNumbers() {
        let russian = DocumentReadout(number: "4601123456", departmentCode: "770 120", sex: "M")
        let values = Dictionary(DocumentReadingMerge.validated(russian, type: .passportRU, rules: [], today: today), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(values[FieldKey.seriesNumber], "4601 123456")
        XCTAssertEqual(values[FieldKey.departmentCode], "770-120")
        XCTAssertEqual(values[FieldKey.sex], "М")

        let travel = DocumentReadout(surname: "САВИН", givenName: "ИЛЬЯ", number: "72 1234567")
        let travelValues = Dictionary(DocumentReadingMerge.validated(travel, type: .passportIntl, rules: [], today: today), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(travelValues[FieldKey.seriesNumber], "72 1234567")
        XCTAssertNil(travelValues[FieldKey.fullName], "у загранпаспорта РФ ФИО латиницей, как в MRZ")
    }

    func testNeedsModelOnlyForUnconfirmedKeyFields() {
        let confirmed = [FieldKey.fullName, FieldKey.seriesNumber, FieldKey.issueDate, FieldKey.departmentCode, FieldKey.birthDate]
            .map { field($0, "x", 0.99, .mrz) }
        XCTAssertFalse(DocumentReadingMerge.needsModel(type: .passportRU, fields: confirmed))
        var weak = confirmed
        weak[0] = field(FieldKey.fullName, "x", 0.6, .mrz)
        XCTAssertTrue(DocumentReadingMerge.needsModel(type: .passportRU, fields: weak))
        weak[0] = field(FieldKey.fullName, "x", 1.0, .manual, verified: true)
        XCTAssertFalse(DocumentReadingMerge.needsModel(type: .passportRU, fields: weak))
        XCTAssertFalse(DocumentReadingMerge.needsModel(type: .diploma, fields: []))
    }

    func testReadoutDecodesGrammarOutput() throws {
        let json = #"{"type": "passport_ru", "surname": "КОВАЛЬЧУК", "given_name": "НИКИТА", "patronymic": "МАРКОВИЧ ", "birth_date": "14.07.1996", "issue_date": "", "expiry_date": "", "number": "4519 123456", "department_code": "770-001", "issued_by": "", "birth_place": "", "sex": "М", "country": "RUS"}"#
        let readout = try DocumentReaderPrompt.readout(fromJSON: json)
        XCTAssertEqual(readout.patronymic, "МАРКОВИЧ")
        XCTAssertNil(readout.issueDate)
        XCTAssertEqual(readout.number, "4519 123456")
    }
}

// MARK: - Выбор модели по памяти

final class DocumentModelChoiceTests: XCTestCase {
    private let standard = DocumentModelChoice.standard.requiredMemoryBytes
    private let light = DocumentModelChoice.light.requiredMemoryBytes

    func testLightFitsTheOwnersIPhone() {
        // iPhone 16 Pro Max без increased-memory-limit: «Доступно приложению: 3,24 ГБ»
        let owner: Int64 = 3_480_000_000
        XCTAssertLessThan(owner, standard)
        XCTAssertGreaterThanOrEqual(owner, light)
        XCTAssertEqual(DocumentModelChoice.recommended(available: owner), .light)
        XCTAssertEqual(DocumentModelChoice.recommended(available: standard), .standard)
    }

    func testBestInstalledModelThatFits() {
        XCTAssertEqual(DocumentModelChoice.best(installed: [.standard, .light], available: standard), .standard, "обе помещаются — 4B")
        XCTAssertEqual(DocumentModelChoice.best(installed: [.standard, .light], available: standard - 1), .light)
        XCTAssertEqual(DocumentModelChoice.best(installed: [.light], available: standard * 2), .light)
        XCTAssertEqual(DocumentModelChoice.best(installed: [.standard], available: light), .standard,
                       "не помещается ни одна — читатель есть, индекс скажет, что мало памяти")
        XCTAssertEqual(DocumentModelChoice.best(installed: [.standard, .light], available: light - 1), .light)
        XCTAssertNil(DocumentModelChoice.best(installed: [], available: standard))
    }

    func testRequirementIsMeasuredPeakPlusMargin() {
        XCTAssertEqual(DocumentModelChoice.light.requiredMemoryBytes, (2643 + 200) * 1_048_576)
        XCTAssertEqual(DocumentModelChoice.standard.revision, "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c")
        XCTAssertEqual(DocumentModelChoice.light.revision, "674aaa7240b91e8012fcad5d791b7dfe5ba90207")
    }

    func testIncompleteGrammarOutputHasNoValues() {
        // Обрыв на лимите токенов: JSON не закрыт — значений нет, ни одного
        let cut = #"{"type": "passport_ru", "surname": "КОВАЛЬЧУК", "given_name": "НИК"#
        XCTAssertThrowsError(try DocumentReaderPrompt.readout(fromJSON: cut))
    }
}

// MARK: - Очередь индекса

/// Подделка модели: отвечает заданным прочтением и считает вызовы
private actor FakeReader: DocumentReading {
    nonisolated let revision: String
    private let readout: DocumentReadout
    private let failure: (any Error & Sendable)?
    private(set) var calls = 0

    init(revision: String = "fake-1", readout: DocumentReadout, failure: (any Error & Sendable)? = nil) {
        self.revision = revision
        self.readout = readout
        self.failure = failure
    }

    func read(_ image: PageImage, kind: DocumentType) async throws -> DocumentReadout {
        calls += 1
        if let failure { throw failure }
        return readout
    }
}

@MainActor
final class DocumentModelPassTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!

    /// Синтетический разворот без MRZ: всё из подписей, всё на сверку
    private let page = """
    РОССИЙСКАЯ ФЕДЕРАЦИЯ
    Паспорт выдан ГУ МВД РОССИИ ПО Г. МОСКВЕ
    Дата выдачи 20.06.2010 Код подразделения 770-120
    46 01 123456
    Фамилия САВИН
    Имя ИЛЬЯ
    Отчество АНДРЕЕВИЧ
    """

    private let readout = DocumentReadout(
        type: "passport_ru", surname: "САВИН", givenName: "ИЛЬЯ", patronymic: "АНДРЕЕВИЧ",
        birthDate: "01.01.1990", issueDate: "20.06.2010", number: "4601 123456", departmentCode: "770-120"
    )

    /// Текстовый файл кадра не имеет — подставляем пустую картинку
    private static let blank: @Sendable (URL) -> PageImage? = { _ in
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage().map(PageImage.init)
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDriveModelPass-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        store = nil
        root = nil
    }

    private func folder(_ name: String, hidden: Bool = false, searchable: Bool = true) throws -> VaultFolder {
        store.createFolder(name: name, icon: "folder.fill", color: "indigo", isSuperHidden: hidden, searchable: searchable)
        return try XCTUnwrap(store.folders.last)
    }

    private func passport(in search: SearchService) async throws -> StoredDocument {
        // XCTUnwrap принимает автозамыкание без поддержки await
        let documents = await search.documents(ofTypes: [.passportRU])
        return try XCTUnwrap(documents.first)
    }

    func testModelConfirmsAndFillsFieldsOnce() async throws {
        let reader = FakeReader(readout: readout)
        let search = SearchService(store: store, databaseURL: nil, reader: reader, pageImage: Self.blank)
        store.importData(Data(page.utf8), preferredName: "паспорт.txt", to: try folder("Паспорта"))
        search.reconcile()
        await search.waitUntilIdle()

        let document = try await passport(in: search)
        let fields = await search.fields(for: [document.id])[document.id] ?? []
        let byKey = Dictionary(fields.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byKey[FieldKey.fullName]?.value, "Савин Илья Андреевич")
        XCTAssertEqual(byKey[FieldKey.fullName]?.needsReview, false, "подпись и модель совпали")
        XCTAssertEqual(byKey[FieldKey.seriesNumber]?.needsReview, false)
        XCTAssertEqual(byKey[FieldKey.birthDate]?.source, .llm)
        XCTAssertEqual(byKey[FieldKey.birthDate]?.needsReview, true, "даты рождения на странице нет — на сверку")
        let readerCalls = await reader.calls
        XCTAssertEqual(readerCalls, 1)
        let revision = await search.modelRevision(documentID: document.id)
        XCTAssertEqual(revision, "fake-1")

        // Повторная сверка не зовёт модель снова
        search.reconcile()
        await search.waitUntilIdle()
        let callsAfter = await reader.calls
        XCTAssertEqual(callsAfter, 1)
    }

    func testModelRecognizesPassportRulesMissed() async throws {
        // Тяжёлое фото: MRZ не прочиталась, подписей паспорта РФ нет — правила
        // дали «другое», но текст похож на паспорт
        let heavy = "REPUBLIC OF UZBEKISTAN\nPASPORT / PASSPORT\nTOSHMATOV\nDILSHOD"
        let reader = FakeReader(readout: DocumentReadout(
            type: "passport_foreign", surname: "TOSHMATOV", givenName: "DILSHOD",
            birthDate: "05.04.1991", number: "FA1234567", country: "UZB"
        ))
        let search = SearchService(store: store, databaseURL: nil, reader: reader, pageImage: Self.blank)
        store.importData(Data(heavy.utf8), preferredName: "паспорт.txt", to: try folder("Паспорта"))
        search.reconcile()
        await search.waitUntilIdle()

        let documents = await search.documents(ofTypes: [.passportIntl])
        let document = try XCTUnwrap(documents.first, "модель узнала паспорт по ИКАО")
        let fields = await search.fields(for: [document.id])[document.id] ?? []
        let byKey = Dictionary(fields.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byKey[FieldKey.fullName]?.value, "TOSHMATOV DILSHOD")
        XCTAssertEqual(byKey[FieldKey.fullName]?.needsReview, false, "слова ФИО напечатаны на странице")
        XCTAssertEqual(byKey[FieldKey.country]?.value, "UZB")
        XCTAssertEqual(byKey[FieldKey.birthDate]?.needsReview, true)
    }

    func testProgressCountsAndFileState() async throws {
        let reader = FakeReader(readout: readout)
        let search = SearchService(store: store, databaseURL: nil, reader: reader, pageImage: Self.blank)
        let passports = try folder("Паспорта")
        store.importData(Data(page.utf8), preferredName: "паспорт.txt", to: passports)
        store.importData(Data("договор аренды".utf8), preferredName: "договор.txt", to: passports)
        search.reconcile()
        await search.waitUntilIdle()

        XCTAssertTrue(search.progress.hasDocumentModel)
        XCTAssertEqual(search.progress.identityDocuments, 1)
        XCTAssertEqual(search.progress.modelRead, 1)
        XCTAssertEqual(search.progress.modelPending, 0)
        XCTAssertFalse(search.progress.modelReading)
        let files = store.files(in: passports)
        let passportFile = try XCTUnwrap(files.first { $0.name == "паспорт.txt" })
        let contract = try XCTUnwrap(files.first { $0.name == "договор.txt" })
        let read = await search.modelState(for: passportFile, in: passports)
        XCTAssertEqual(read, .read)
        let none = await search.modelState(for: contract, in: passports)
        XCTAssertNil(none, "не удостоверение — строки в «Сведениях» нет")
    }

    func testIncompleteOutputLeavesFieldsAndIsNotRetried() async throws {
        let reader = FakeReader(readout: readout, failure: DocumentReaderIncomplete())
        let search = SearchService(store: store, databaseURL: nil, reader: reader, pageImage: Self.blank)
        let passports = try folder("Паспорта")
        store.importData(Data(page.utf8), preferredName: "паспорт.txt", to: passports)
        search.reconcile()
        await search.waitUntilIdle()

        let document = try await passport(in: search)
        let fields = await search.fields(for: [document.id])[document.id] ?? []
        XCTAssertFalse(fields.contains { $0.source == .llm }, "неполный ответ — ни одного значения модели")
        let file = try XCTUnwrap(store.files(in: passports).first)
        let state = await search.modelState(for: file, in: passports)
        XCTAssertEqual(state, .failed)
        search.reconcile()
        await search.waitUntilIdle()
        let calls = await reader.calls
        XCTAssertEqual(calls, 1, "та же модель документ второй раз не читает")
    }

    func testHiddenAndNonSearchableFoldersNeverReachModel() async throws {
        let reader = FakeReader(readout: readout)
        let search = SearchService(store: store, databaseURL: nil, reader: reader, pageImage: Self.blank)
        store.importData(Data(page.utf8), preferredName: "скрытый.txt", to: try folder("Тайное", hidden: true))
        store.importData(Data(page.utf8), preferredName: "вне поиска.txt", to: try folder("Архив", searchable: false))
        search.reconcile()
        await search.waitUntilIdle()
        let readerCalls = await reader.calls
        XCTAssertEqual(readerCalls, 0)
        let indexed = await search.indexedFiles()
        XCTAssertTrue(indexed.isEmpty)
    }

    func testManualFieldSurvivesModel() async throws {
        let search = SearchService(store: store, databaseURL: nil, pageImage: Self.blank)
        store.importData(Data(page.utf8), preferredName: "паспорт.txt", to: try folder("Паспорта"))
        search.reconcile()
        await search.waitUntilIdle()
        let document = try await passport(in: search)
        await search.setManualField(documentID: document.id, key: FieldKey.issueDate, value: "21.06.2010")

        // Модель скачали позже: индекс начинает второе чтение
        let reader = FakeReader(readout: readout)
        search.useDocumentReader(reader)
        await search.waitUntilIdle()

        let fields = await search.fields(for: [document.id])[document.id] ?? []
        let issue = try XCTUnwrap(fields.first { $0.key == FieldKey.issueDate })
        XCTAssertEqual(issue.value, "21.06.2010")
        XCTAssertEqual(issue.source, .manual)
        let readerCalls = await reader.calls
        XCTAssertEqual(readerCalls, 1)
    }

    func testUnavailableModelWaitsForResume() async throws {
        let reader = FakeReader(readout: readout, failure: DocumentReaderUnavailable(reason: "Не хватает памяти"))
        let search = SearchService(store: store, databaseURL: nil, reader: reader, pageImage: Self.blank)
        store.importData(Data(page.utf8), preferredName: "паспорт.txt", to: try folder("Паспорта"))
        search.reconcile()
        await search.waitUntilIdle()
        let first = await reader.calls
        XCTAssertEqual(first, 1, "без памяти модель не зовут по кругу")
        XCTAssertEqual(search.progress.modelUnavailable, "Не хватает памяти")

        search.resume()
        await search.waitUntilIdle()
        let second = await reader.calls
        XCTAssertEqual(second, 2, "вернулись на экран — пробуем снова")
    }
}

// MARK: - Одна модель в памяти

final class ModelResidencyTests: XCTestCase {
    private final class Owner: Sendable {}

    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    func testLoadingOneModelUnloadsTheOther() async {
        let residency = ModelResidency()
        let chat = Owner()
        let documents = Owner()
        let unloads = Counter()
        await residency.acquire(ObjectIdentifier(chat)) { await unloads.increment() }
        await residency.acquire(ObjectIdentifier(chat)) { await unloads.increment() }
        let none = await unloads.value
        XCTAssertEqual(none, 0, "та же модель себя не выгружает")
        await residency.acquire(ObjectIdentifier(documents)) {}
        let once = await unloads.value
        XCTAssertEqual(once, 1)
        let current = await residency.current
        XCTAssertEqual(current, ObjectIdentifier(documents))
        await residency.release(ObjectIdentifier(documents))
        let released = await residency.current
        XCTAssertNil(released)
    }
}
