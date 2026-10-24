import XCTest
@testable import LocalDrive

// Чтение имени и дат из MRZ, когда OCR ошибается так, как на iPhone владельца
// 12.10.2026: Vision прочитал заполнитель «<» как «K», и ФИО превратилось в
// «Савинккилья-… Кк Кк К Кк» с пометкой «проверено». Здесь только
// синтетические паспорта. Вторые строки MRZ — векторы из PassportFieldsTests
// и вектор паспорта Таджикистана, посчитанный отдельным скриптом на Python
// по ИКАО 9303; ошибки OCR внесены в первую строку, у имени контроля нет
final class PassportReadingTests: XCTestCase {
    /// Савин Илья Андреевич, 4601 123456, выдан 20.06.2010, код 770-120, родился 01.01.1990
    private let russianLine2 = "4601234561RUS9001011M<<<<<<<1100620770120<34"
    /// «SAVIN<<IL98<ANDREEVI3» с «<<» и частью хвоста, прочитанными как «K»
    private let garbledLine1 = "PNRUSSAVINKKIL98<ANDREEVI3<<KK<KK<K<KK<<<<<<"
    /// Рахимов Дилшод, Таджикистан, 401234567, родился 15.03.1985, действует до 10.01.2028
    private let tajikLine1 = "P<TJKRAHIMOV<<DILSHOD<<<<<<<<<<<<<<<<<<<<<<<"
    private let tajikLine2 = "4012345676TJK8503150M2801108<<<<<<<<<<<<<<06"
    private let today = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 12).date!

    private func page(_ text: String) -> ExtractedText {
        ExtractedText(pages: [ExtractedPage(number: 1, text: text, lines: [])], pageCount: 1)
    }

    private func field(_ key: String, in analysis: DocumentAnalysis) throws -> DocumentField {
        try XCTUnwrap(analysis.fields.first { $0.key == key }, "нет поля \(key)")
    }

    private func russian(_ line1: String, printed: String = "") throws -> RussianPassportMRZ {
        let mrz = try XCTUnwrap(MRZ.find(in: [line1, russianLine2]))
        let words = MRZNameReader.printedWords(in: printed, script: .russianInternal)
        return try XCTUnwrap(RussianPassportMRZ(mrz, printed: words, today: today))
    }

    // MARK: - Заполнитель, прочитанный как «K»

    func testFillerReadAsKIsNotPartOfName() throws {
        let passport = try russian(garbledLine1)
        XCTAssertEqual(passport.fullName, "Савин Илья Андреевич")
        XCTAssertFalse(passport.nameConfirmed, "без слов со страницы подтвердить имя нечем")

        let analysis = DocumentAnalyzer.analyze(page("\(garbledLine1)\n\(russianLine2)"), today: today)
        let name = try field(FieldKey.fullName, in: analysis)
        XCTAssertEqual(name.value, "Савин Илья Андреевич")
        XCTAssertTrue(name.needsReview, "контрольной цифры у имени нет — без подтверждения оно на сверку")
        XCTAssertFalse(try field(FieldKey.seriesNumber, in: analysis).needsReview, "номер сверен своими цифрами")
    }

    func testPrintedWordsConfirmName() throws {
        let text = """
        Фамилия САВИН
        Имя ИЛЬЯ
        Отчество АНДРЕЕВИЧ
        \(garbledLine1)
        \(russianLine2)
        """
        let analysis = DocumentAnalyzer.analyze(page(text), today: today)
        let name = try field(FieldKey.fullName, in: analysis)
        XCTAssertEqual(name.value, "Савин Илья Андреевич")
        XCTAssertFalse(name.needsReview)
        XCTAssertEqual(name.confidence, DocumentAnalyzer.verifiedConfidence)
    }

    /// Напечатанное латинскими двойниками («CABИH») — те же слова
    func testPrintedLookalikesStillConfirm() throws {
        let passport = try russian(garbledLine1, printed: "CABИH\nИЛЬЯ\nAHДPEEBИЧ")
        XCTAssertTrue(passport.nameConfirmed)
    }

    // MARK: - Настоящая «К» в имени

    func testRealKLettersOnBothSidesOfSeparator() throws {
        // КОВАЛЬЧУК<<КИРИЛЛ<ПЕТРОВИЧ, «<<» прочитано как «KK»
        let passport = try russian("PNRUSKOVAL93UKKKKIRILL<PETROVI3", printed: "КОВАЛЬЧУК\nКИРИЛЛ\nПЕТРОВИЧ")
        XCTAssertEqual(passport.fullName, "Ковальчук Кирилл Петрович")
        XCTAssertTrue(passport.nameConfirmed)
    }

    func testKInsideWordsAndAtWordStart() throws {
        // НИКИТИН<<НИКИТА<КИРИЛЛОВИЧ: «<<» и «<» прочитаны как «K»
        let passport = try russian("PNRUSNIKITINKKNIKITAKKIRILLOVI3<<<<<<<<<<<<<", printed: "НИКИТИН\nНИКИТА\nКИРИЛЛОВИЧ")
        XCTAssertEqual(passport.fullName, "Никитин Никита Кириллович")
    }

    func testEveryFillerReadAsK() throws {
        let passport = try russian("PNRUSSAVINKKIL98KANDREEVI3KKKKKKKKKKKKKKKKKK", printed: "САВИН\nИЛЬЯ\nАНДРЕЕВИЧ")
        XCTAssertEqual(passport.fullName, "Савин Илья Андреевич")
        XCTAssertTrue(passport.nameConfirmed)
    }

    func testNameEndingInKKeepsItWithoutPrintedText() throws {
        // ИВАНОВ<<МАРК, хвост из заполнителей прочитан как «KKKK»
        let passport = try russian("PNRUSIVANOV<<MARKKKKK")
        XCTAssertEqual(passport.fullName, "Иванов Марк")
    }

    func testICAONameWithKInsideIsUntouched() throws {
        let mrz = try XCTUnwrap(MRZ.find(in: [
            "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<",
            "L898902C36UTO7408122F1204159ZE184226B<<<<<10",
        ]))
        XCTAssertEqual(try XCTUnwrap(TravelPassportMRZ(mrz, today: today)).latinName, "ERIKSSON ANNA MARIA")
    }

    // MARK: - Контрольные цифры по полям

    func testEachFieldIsTrustedByItsOwnCheckDigit() throws {
        // Контроль даты рождения 1 → 2: дата на сверку, номер и выдача — нет
        let line2 = "4601234561RUS9001012M<<<<<<<1100620770120<34"
        let analysis = DocumentAnalyzer.analyze(page("PNRUSSAVIN<<IL98<ANDREEVI3\n\(line2)"), today: today)
        XCTAssertTrue(try field(FieldKey.birthDate, in: analysis).needsReview)
        XCTAssertFalse(try field(FieldKey.seriesNumber, in: analysis).needsReview)
        XCTAssertFalse(try field(FieldKey.issueDate, in: analysis).needsReview)
        XCTAssertFalse(try field(FieldKey.departmentCode, in: analysis).needsReview)
    }

    func testRussianFillersReadAsKInSecondLine() throws {
        let line2 = "4601234561RUS9001011MKKKKKKK1100620770120K34"
        let mrz = try XCTUnwrap(MRZ.find(in: ["PNRUSSAVIN<<IL98<ANDREEVI3", line2]))
        XCTAssertTrue(try XCTUnwrap(RussianPassportMRZ(mrz, today: today)).isValid)
    }

    func testSecondLineSplitIntoTwoBoxes() throws {
        let mrz = try XCTUnwrap(MRZ.find(in: [tajikLine1, "4012345676TJK8503150M", "2801108<<<<<<<<<<<<<<06"]))
        XCTAssertEqual(mrz.line2, tajikLine2)
    }

    /// Свидетельство ЗАГСа с «Российская Федерация», «Фамилия», «выдано» и
    /// паспортом матери в тексте — не паспорт (снимок владельца 12.10.2026)
    func testBirthCertificateIsNotAPassport() {
        let text = """
        РОССИЙСКАЯ ФЕДЕРАЦИЯ
        СВИДЕТЕЛЬСТВО О РОЖДЕНИИ
        Фамилия ПЕТРОВА
        Имя АННА
        Отчество ИВАНОВНА
        Мать ПЕТРОВА МАРИЯ СЕРГЕЕВНА, паспорт 4510 654321
        Свидетельство выдано отделом ЗАГС
        """
        XCTAssertNotEqual(DocumentAnalyzer.analyze(page(text), today: today).type, .passportRU)
    }

    // MARK: - Паспорт другой страны

    private var tajikPage: String {
        """
        Ҷумҳурии Тоҷикистон / Republic of Tajikistan
        Насаб / Surname
        РАХИМОВ
        RAHIMOV
        Ном ва номи падар / Name
        ДИЛШОД ДЖУРАЕВИЧ
        DILSHOD
        Санаи таваллуд / Date of birth
        15.03.1985
        Санаи додан / Date of issue    Мӯҳлати эътибор / Date of expiry
        11.01.2018 10.01.2028
        Мақомоти шиносномадиҳанда / Authority
        ШВКД дар ш. Душанбе
        \(tajikLine1)
        \(tajikLine2)
        """
    }

    func testForeignPassportReadsCyrillicNameAndIssue() throws {
        let analysis = DocumentAnalyzer.analyze(page(tajikPage), today: today)
        XCTAssertEqual(analysis.type, .passportIntl)
        XCTAssertEqual(try field(FieldKey.country, in: analysis).value, "TJK")
        let name = try field(FieldKey.fullName, in: analysis)
        XCTAssertEqual(name.value, "Рахимов Дилшод Джураевич", "кириллица со страницы, отчество — из той же строки")
        XCTAssertFalse(name.needsReview)
        XCTAssertEqual(try field(FieldKey.seriesNumber, in: analysis).value, "401234567")
        XCTAssertFalse(try field(FieldKey.seriesNumber, in: analysis).needsReview)
        XCTAssertEqual(try field(FieldKey.birthDate, in: analysis).value, "15.03.1985")
        XCTAssertEqual(try field(FieldKey.expiryDate, in: analysis).value, "10.01.2028")

        // Подпись даты выдачи стоит над значением в другой колонке: дату
        // находит срок действия — десять лет без дня
        let issue = try field(FieldKey.issueDate, in: analysis)
        XCTAssertEqual(issue.value, "11.01.2018")
        XCTAssertFalse(issue.needsReview)
        let authority = try field(FieldKey.issuedBy, in: analysis)
        XCTAssertEqual(authority.value, "ШВКД дар ш. Душанбе")
        XCTAssertTrue(authority.needsReview, "орган сверить не с чем")
    }

    func testForeignPassportWithoutCyrillicKeepsConfirmedLatin() throws {
        let text = "Republic of Tajikistan\nSurname RAHIMOV\nName DILSHOD\n\(tajikLine1)\n\(tajikLine2)"
        let name = try field(FieldKey.fullName, in: DocumentAnalyzer.analyze(page(text), today: today))
        XCTAssertEqual(name.value, "RAHIMOV DILSHOD")
        XCTAssertFalse(name.needsReview, "латиница MRZ подтверждена напечатанной латиницей")
    }

    func testTypeLetterReadAsKIsStillPassport() throws {
        let mrz = try XCTUnwrap(MRZ.find(in: ["PKTJKRAHIMOV<<DILSHOD<<<<<<<<<<<<<<<<<<<<<<<", tajikLine2]))
        XCTAssertEqual(mrz.kind, .travelPassport)
        XCTAssertEqual(try XCTUnwrap(TravelPassportMRZ(mrz, today: today)).country, "TJK")
    }

    func testFillerTailReadAsKInLatinName() throws {
        let mrz = try XCTUnwrap(MRZ.find(in: ["P<TJKRAHIMOVKKDILSHODKKKK<<<<", tajikLine2]))
        let words = MRZNameReader.printedWords(in: "RAHIMOV\nDILSHOD", script: .latin)
        let passport = try XCTUnwrap(TravelPassportMRZ(mrz, printed: words, today: today))
        XCTAssertEqual(passport.latinName, "RAHIMOV DILSHOD")
        XCTAssertTrue(passport.nameConfirmed)
    }

    /// «паспорт петрова»: Snowball отрезает у «Петров» окончание «ов», основы
    /// «петр» и «петров» не совпадают — имя сверяется и по началу слова
    @MainActor
    func testMaleSurnameInGenitiveMatchesOwner() {
        XCTAssertTrue(ChatRouter.nameMatches(["петрова"], owner: "Петров Иван Сергеевич"))
        XCTAssertTrue(ChatRouter.nameMatches(["петровым"], owner: "Петров Иван Сергеевич"))
        XCTAssertFalse(ChatRouter.nameMatches(["петровский"], owner: "Петров Иван Сергеевич"))
        XCTAssertFalse(ChatRouter.nameMatches(["савина"], owner: "Петров Иван Сергеевич"))
    }

    func testRomanizationTables() {
        XCTAssertTrue(ForeignPassportName.romanizes("ЁДГОР", as: "YODGOR"), "таджикская таблица: Ё → YO")
        XCTAssertTrue(ForeignPassportName.romanizes("РАХИМОВ", as: "RAKHIMOV"), "ИКАО: Х → KH")
        XCTAssertTrue(ForeignPassportName.romanizes("РАХИМОВ", as: "RAHIMOV"))
        XCTAssertTrue(ForeignPassportName.romanizes("ИЛЬЯ", as: "ILIA"))
        XCTAssertFalse(ForeignPassportName.romanizes("ИВАНОВ", as: "PETROV"))
    }

    func testIssueDateFallsBackToLabelWithLowConfidence() throws {
        let birth = DateComponents(year: 1985, month: 3, day: 15)
        let expiry = DateComponents(year: 2028, month: 1, day: 10)
        // Срок не сходится ни с 10, ни с 5 годами — остаётся подпись
        let issue = try XCTUnwrap(PassportPrint.issueDate(in: "Date of issue 03.02.2019", birth: birth, expiry: expiry))
        XCTAssertEqual(issue.date, DateComponents(year: 2019, month: 2, day: 3))
        XCTAssertEqual(issue.confidence, DocumentAnalyzer.printedConfidence)
        XCTAssertEqual(PassportPrint.dates(in: "11 JAN/ЯНВ 2018"), [DateComponents(year: 2018, month: 1, day: 11)])
    }
}

// Иностранные паспорта в чате: по имени без слова «иностранный», в списке
// «Какой нужен?», по стране. И разворот «кем выдан» не прикладывается к чужому
@MainActor
final class ForeignPassportChatTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDriveForeignTests-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
        search = SearchService(store: store, databaseURL: nil)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        search = nil
        store = nil
        root = nil
    }

    private enum Fixture {
        static let savin = """
        ПАСПОРТ
        PNRUSSAVIN<<IL98<ANDREEVI3<<<<<<<<<<<<<<<<<<
        4601234561RUS9001011M<<<<<<<1100620770120<34
        """
        static let ivanova = """
        ПАСПОРТ
        PNRUSIVANOVA<<ANNA<SERGEEVNA<<<<<<<<<<<<<<<<
        4516543213RUS8505121F<<<<<<<0120315690001<44
        """
        static let rahimov = """
        Republic of Tajikistan
        РАХИМОВ
        RAHIMOV
        ДИЛШОД ДЖУРАЕВИЧ
        DILSHOD
        P<TJKRAHIMOV<<DILSHOD<<<<<<<<<<<<<<<<<<<<<<<
        4012345676TJK8503150M2801108<<<<<<<<<<<<<<06
        """
        /// Разворот «Паспорт выдан» без имени и номера
        static let issued = """
        РОССИЙСКАЯ ФЕДЕРАЦИЯ
        Паспорт выдан ГУ МВД РОССИИ ПО Г. МОСКВЕ
        Дата выдачи 20.06.2010 Код подразделения 770-120
        Личная подпись
        """
    }

    private func folder(_ name: String) throws -> VaultFolder {
        store.createFolder(name: name, icon: "folder.fill", color: "indigo")
        return try XCTUnwrap(store.folders.last)
    }

    private func add(_ text: String, named name: String, to folder: VaultFolder) {
        store.importData(Data(text.utf8), preferredName: name, to: folder)
    }

    private func indexAll() async {
        search.reconcile()
        await search.waitUntilIdle()
    }

    private func document(named fileName: String) async throws -> StoredDocument {
        let documents = await search.documents(ofTypes: DocumentType.allCases)
        return try XCTUnwrap(documents.first { $0.fileName == fileName }, "в индексе нет «\(fileName)»")
    }

    private func reply(_ text: String) async -> ChatReply {
        await ChatRouter(search: search).reply(to: text).0
    }

    private func seed() async throws -> (savin: StoredDocument, ivanova: StoredDocument, rahimov: StoredDocument) {
        let passports = try folder("Паспорта")
        add(Fixture.savin, named: "savin.txt", to: passports)
        add(Fixture.ivanova, named: "ivanova.txt", to: passports)
        add(Fixture.rahimov, named: "rahimov.txt", to: passports)
        await indexAll()
        return (try await document(named: "savin.txt"), try await document(named: "ivanova.txt"), try await document(named: "rahimov.txt"))
    }

    func testForeignPassportIsFoundByName() async throws {
        let docs = try await seed()
        let answer = await reply("паспорт рахимова")
        XCTAssertEqual(answer.cards.first?.documentIDs, [docs.rahimov.id])
        XCTAssertTrue(answer.text.contains("паспорт Таджикистана"), answer.text)
    }

    func testMyPassportListsForeignPassportToo() async throws {
        let docs = try await seed()
        let answer = await reply("мой паспорт")
        guard case .clarify(_, let options) = answer.cards.first else {
            return XCTFail("ждали «Какой нужен?», пришло \(answer.cards)")
        }
        XCTAssertEqual(Set(options.compactMap(\.documentID)), [docs.savin.id, docs.ivanova.id, docs.rahimov.id])
        let foreign = try XCTUnwrap(options.first { $0.documentID == docs.rahimov.id })
        XCTAssertEqual(foreign.title, "Паспорт Таджикистана · Рахимов Д. Д.")

        // Запрос чипа однозначно выбирает этот паспорт
        let followUp = await reply(foreign.query)
        XCTAssertEqual(followUp.cards.first?.documentIDs, [docs.rahimov.id], foreign.query)
    }

    func testUnknownNameListsAllPassports() async throws {
        let docs = try await seed()
        let answer = await reply("паспорт зематова")
        guard case .clarify(_, let options) = answer.cards.first else {
            return XCTFail("ждали список паспортов, пришло \(answer.cards)")
        }
        XCTAssertTrue(options.contains { $0.documentID == docs.rahimov.id })
    }

    func testCountryWordPicksForeignPassport() async throws {
        let docs = try await seed()
        XCTAssertEqual(ChatIntent("паспорт таджикистана").countries, ["TJK"])
        XCTAssertEqual(ChatIntent("паспорт таджикистана").nameWords, [])
        let answer = await reply("паспорт таджикистана")
        XCTAssertEqual(answer.cards.first?.documentIDs, [docs.rahimov.id])
        let none = await reply("паспорт узбекистана")
        XCTAssertEqual(none.cards, [])
        XCTAssertEqual(none.text, "Не нашёл паспорта Узбекистана.")
    }

    func testForeignWordExcludesRussianTravelPassport() async throws {
        let docs = try await seed()
        let travel = """
        P<RUSSAVIN<<ILIA<<<<<<<<<<<<<<<<<<<<<<<<<<<<
        7212345673RUS9001011M3103153<<<<<<<<<<<<<<02
        """
        add(travel, named: "загран.txt", to: try XCTUnwrap(store.folders.first))
        await indexAll()
        let answer = await reply("иностранный паспорт")
        XCTAssertEqual(answer.cards.first?.documentIDs, [docs.rahimov.id])
    }

    func testIssuedPageIsNotAttachedWhenFolderHasTwoPeople() async throws {
        let docs = try await seed()
        add(Fixture.issued, named: "выдан.txt", to: try XCTUnwrap(store.folders.first))
        await indexAll()
        let page = try await document(named: "выдан.txt")

        let byName = await reply("паспорт савина")
        XCTAssertFalse(byName.cards.flatMap(\.documentIDs).contains(page.id), "«кем выдан» мог быть чужим")
        XCTAssertTrue(byName.cards.flatMap(\.documentIDs).contains(docs.savin.id))

        let (chosen, _) = await ChatRouter(search: search).reply(to: "паспорт РФ", preferring: docs.savin.id)
        XCTAssertFalse(chosen.cards.flatMap(\.documentIDs).contains(page.id))
    }
}
