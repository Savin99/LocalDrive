import XCTest
@testable import LocalDrive

// Логика чата: разбор запроса, ответы роутера карточками, формат JSON
// каталога и сроки действия.
//
// Паспорта попадают в индекс текстовыми файлами с MRZ: извлечение текста
// читает .txt как есть, а анализатор находит в нём машиночитаемую запись.
// Векторы MRZ посчитаны независимо от кода приложения — скриптом на Python
// по правилам приказа ФМС № 279 и ИКАО 9303, иначе тест проверял бы сам себя
@MainActor
final class ChatRouterTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDriveChatTests-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
        search = SearchService(store: store, databaseURL: nil)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        search = nil
        store = nil
        root = nil
    }

    // MARK: - Данные

    private enum Fixture {
        /// Савин Илья Андреевич, 4601 123456, выдан 20.06.2010, код 770-120, родился 01.01.1990
        static let savinRussian = """
        ПАСПОРТ
        Паспорт выдан ГУ МВД РОССИИ ПО Г. МОСКВЕ
        Дата выдачи 20.06.2010 Код подразделения 770-120
        PNRUSSAVIN<<IL98<ANDREEVI3<<<<<<<<<<<<<<<<<<
        4601234561RUS9001011M<<<<<<<1100620770120<34
        """

        /// SAVIN ILIA, 72 1234567, родился 01.01.1990, действует до 15.03.2031
        static let savinTravel = """
        ЗАГРАНИЧНЫЙ ПАСПОРТ
        P<RUSSAVIN<<ILIA<<<<<<<<<<<<<<<<<<<<<<<<<<<<
        7212345673RUS9001011M3103153<<<<<<<<<<<<<<02
        """

        /// Иванова Анна Сергеевна, 4510 654321, выдан 15.03.2012, код 690-001, родилась 12.05.1985
        static let ivanovaRussian = """
        ПАСПОРТ
        PNRUSIVANOVA<<ANNA<SERGEEVNA<<<<<<<<<<<<<<<<
        4516543213RUS8505121F<<<<<<<0120315690001<44
        """
    }

    @discardableResult
    private func makeFolder(_ name: String, hidden: Bool = false) throws -> VaultFolder {
        store.createFolder(name: name, icon: "folder.fill", color: "indigo", isSuperHidden: hidden)
        return try XCTUnwrap(store.folders.last)
    }

    private func add(_ text: String, named name: String, to folder: VaultFolder) {
        store.importData(Data(text.utf8), preferredName: name, to: folder)
    }

    private func indexAll() async {
        search.reconcile()
        await search.waitUntilIdle()
    }

    private func document(_ type: DocumentType) async throws -> StoredDocument {
        let documents = await search.documents(ofTypes: [type])
        return try XCTUnwrap(documents.first, "в индексе нет документа типа \(type)")
    }

    /// Документ конкретного человека — по ФИО, распознанному из MRZ
    private func document(_ type: DocumentType, owner: String) async throws -> StoredDocument {
        let documents = await search.documents(ofTypes: [type])
        let fields = await search.fields(for: documents.map(\.id))
        let match = documents.first { document in
            fields[document.id]?.contains { $0.key == FieldKey.fullName && $0.value == owner } == true
        }
        return try XCTUnwrap(match, "в индексе нет документа «\(owner)»")
    }

    private func document(named fileName: String) async throws -> StoredDocument {
        let documents = await search.documents(ofTypes: DocumentType.allCases)
        return try XCTUnwrap(documents.first { $0.fileName == fileName }, "в индексе нет «\(fileName)»")
    }

    private func reply(_ text: String) async -> ChatReply {
        await ChatRouter(search: search).reply(to: text).0
    }

    private func waitForAnswer(_ session: ChatSession) async throws {
        var attempts = 0
        while session.isAnswering, attempts < 300 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        XCTAssertFalse(session.isAnswering, "ответ не пришёл за 3 секунды")
    }

    private func day(_ text: String) throws -> Date {
        try XCTUnwrap(DocumentValidity.parse(text))
    }

    // MARK: - Разбор запроса

    func testIntentMyPassportAsksForEitherPassport() {
        let intent = ChatIntent("мой паспорт")
        XCTAssertEqual(intent.types, [.passportRU, .passportIntl])
        XCTAssertEqual(intent.fieldKeys, [])
        XCTAssertFalse(intent.wantsExpiry)
        XCTAssertFalse(intent.wantsList)
        XCTAssertEqual(intent.nameWords, [], "«мой» — служебное слово, а не имя")
    }

    func testIntentPassportNumberAsksForSeriesNumber() {
        let intent = ChatIntent("номер паспорта")
        XCTAssertEqual(intent.types, [.passportRU, .passportIntl])
        XCTAssertEqual(intent.fieldKeys, [FieldKey.seriesNumber])
        XCTAssertEqual(intent.nameWords, [])
    }

    func testIntentKeepsOwnerName() {
        let intent = ChatIntent("паспорт савина илья")
        XCTAssertEqual(intent.types, [.passportRU, .passportIntl])
        XCTAssertEqual(intent.fieldKeys, [])
        XCTAssertEqual(intent.nameWords, ["савина", "илья"])
    }

    func testIntentExpiryOfTravelPassport() {
        let intent = ChatIntent("когда истекает загран")
        XCTAssertEqual(intent.types, [.passportIntl])
        XCTAssertTrue(intent.wantsExpiry)
        XCTAssertEqual(intent.fieldKeys, [], "«когда» без «выдан» — не дата выдачи")
        XCTAssertEqual(intent.nameWords, [])
    }

    func testIntentDiplomaDocumentsIsList() {
        let intent = ChatIntent("дипломные документы")
        XCTAssertEqual(intent.types, [.diploma])
        XCTAssertTrue(intent.wantsList)
        XCTAssertEqual(intent.nameWords, [])
    }

    func testIntentContentQueryHasNoDocumentType() {
        let intent = ChatIntent("справка о принятии статьи")
        XCTAssertEqual(intent.types, [], "справка ищется по тексту, а не по типу")
        XCTAssertEqual(intent.fieldKeys, [])
        XCTAssertFalse(intent.wantsExpiry)
        XCTAssertFalse(intent.wantsList)
    }

    func testIntentIssuedByField() {
        let intent = ChatIntent("кем выдан паспорт")
        XCTAssertEqual(intent.types, [.passportRU, .passportIntl])
        XCTAssertEqual(intent.fieldKeys, [FieldKey.issuedBy], "«выдан» после «кем» — орган, а не дата выдачи")
        XCTAssertEqual(intent.nameWords, [])
    }

    func testIntentExplicitPassportKind() {
        XCTAssertEqual(ChatIntent("паспорт РФ").types, [.passportRU])
        XCTAssertEqual(ChatIntent("загранпаспорт").types, [.passportIntl])
        XCTAssertEqual(ChatIntent("паспорт рф савин").nameWords, ["савин"])
    }

    // MARK: - Ответы роутера

    func testSingleRussianPassportAnswersWithFieldsAndFile() async throws {
        let folder = try makeFolder("Паспорта")
        add(Fixture.savinRussian, named: "паспорт.txt", to: folder)
        await indexAll()
        let passport = try await document(.passportRU)
        let fields = await search.fields(for: [passport.id])
        let available = Set(fields[passport.id]?.map(\.key) ?? [])
        XCTAssertTrue(available.contains(FieldKey.seriesNumber), "MRZ должна дать серию и номер")

        let answer = await reply("мой паспорт")
        XCTAssertEqual(answer.cards, [
            .fields(documentID: passport.id, keys: FieldKey.order.filter(available.contains)),
            .document(documentID: passport.id),
        ])
    }

    func testPassportNumberShowsOnlySeriesNumber() async throws {
        let folder = try makeFolder("Паспорта")
        add(Fixture.savinRussian, named: "паспорт.txt", to: folder)
        await indexAll()
        let passport = try await document(.passportRU)

        let answer = await reply("номер паспорта")
        XCTAssertEqual(answer.cards, [.fields(documentID: passport.id, keys: [FieldKey.seriesNumber])])
    }

    func testIssuedByShowsOnlyThatField() async throws {
        let folder = try makeFolder("Паспорта")
        add(Fixture.savinRussian, named: "паспорт.txt", to: folder)
        await indexAll()
        let passport = try await document(.passportRU)

        let answer = await reply("кем выдан паспорт")
        XCTAssertEqual(answer.cards, [.fields(documentID: passport.id, keys: [FieldKey.issuedBy])])
    }

    /// У загранпаспорта нет поля «Кем выдан» — вместо пустой карточки показывается файл
    func testMissingFieldFallsBackToDocument() async throws {
        let folder = try makeFolder("Паспорта")
        add(Fixture.savinTravel, named: "загран.txt", to: folder)
        await indexAll()
        let travel = try await document(.passportIntl)

        let answer = await reply("кем выдан загранпаспорт")
        XCTAssertEqual(answer.cards, [.document(documentID: travel.id)])
    }

    /// Сценарий спецификации: «мой паспорт», если их два (РФ и загран), — чипы уточнения
    /// Владелец 12.10.2026: «паспорт савина илья» — сразу данные паспорта и файл.
    /// «Паспорт» без уточнения — внутренний паспорт, а загранпаспорт того же
    /// человека остаётся чипом под ответом (уточнение из спецификации не пропало)
    func testPlainPassportAnswersRussianAndOffersTravelChip() async throws {
        let folder = try makeFolder("Паспорта")
        add(Fixture.savinRussian, named: "паспорт РФ.txt", to: folder)
        add(Fixture.savinTravel, named: "загран.txt", to: folder)
        await indexAll()
        let russian = try await document(.passportRU)
        let travel = try await document(.passportIntl)

        let answer = await reply("мой паспорт")
        guard case .fields(let fieldsID, _) = answer.cards.first else {
            return XCTFail("ждали данные паспорта РФ, пришло \(answer.cards)")
        }
        XCTAssertEqual(fieldsID, russian.id)
        XCTAssertTrue(answer.cards.contains(.document(documentID: russian.id)))
        guard case .clarify(_, let options) = answer.cards.last else {
            return XCTFail("ждали чип загранпаспорта под ответом: \(answer.cards)")
        }
        XCTAssertEqual(options.map(\.title), ["Загранпаспорт"])

        // Тап по чипу отправляет его запрос — он должен однозначно выбрать загранпаспорт
        let followUp = await reply(options[0].query)
        guard case .fields(let chosen, _) = followUp.cards.first else {
            return XCTFail("чип не выбрал документ: \(followUp.cards)")
        }
        XCTAssertEqual(chosen, travel.id)
    }

    func testOwnerNamePicksTheRightPassport() async throws {
        let folder = try makeFolder("Паспорта")
        add(Fixture.savinRussian, named: "savin.txt", to: folder)
        add(Fixture.ivanovaRussian, named: "ivanova.txt", to: folder)
        await indexAll()
        let savin = try await document(.passportRU, owner: "Савин Илья Андреевич")
        let ivanova = try await document(.passportRU, owner: "Иванова Анна Сергеевна")

        let first = await reply("паспорт савина илья")
        XCTAssertEqual(first.cards.map(\.documentIDs), [[savin.id], [savin.id]])
        guard case .fields = first.cards.first else { return XCTFail("ждали поля, пришло \(first.cards)") }

        // Склонение фамилии не мешает: «ивановой» — та же основа, что «Иванова»
        let second = await reply("паспорт ивановой")
        XCTAssertEqual(second.cards.map(\.documentIDs), [[ivanova.id], [ivanova.id]])

        // Без имени паспортов два — уточнение с именами владельцев на чипах
        let both = await reply("мой паспорт")
        guard case .clarify(_, let options) = both.cards.first else {
            return XCTFail("ждали уточнение, пришло \(both.cards)")
        }
        XCTAssertEqual(options.count, 2)
        XCTAssertTrue(options.contains { $0.title.contains("Савин И. А.") })
        XCTAssertTrue(options.contains { $0.title.contains("Иванова А. С.") })
    }

    func testUnknownOwnerListsExistingPassports() async throws {
        let folder = try makeFolder("Паспорта")
        add(Fixture.savinRussian, named: "savin.txt", to: folder)
        add(Fixture.ivanovaRussian, named: "ivanova.txt", to: folder)
        await indexAll()
        let savin = try await document(.passportRU, owner: "Савин Илья Андреевич")
        let ivanova = try await document(.passportRU, owner: "Иванова Анна Сергеевна")

        let answer = await reply("паспорт петрова")
        XCTAssertEqual(answer.cards.count, 1)
        guard case .clarify(_, let options) = answer.cards.first else {
            return XCTFail("ждали список существующих паспортов, пришло \(answer.cards)")
        }
        XCTAssertEqual(options.count, 2)

        var chosen = Set<Int64>()
        for option in options {
            let followUp = await reply(option.query)
            if let id = followUp.cards.first?.documentIDs.first { chosen.insert(id) }
        }
        XCTAssertEqual(chosen, [savin.id, ivanova.id], "каждый чип должен вести к своему паспорту")
    }

    func testExpiryQuestionAnswersWithTravelPassport() async throws {
        let folder = try makeFolder("Паспорта")
        add(Fixture.savinRussian, named: "паспорт РФ.txt", to: folder)
        add(Fixture.savinTravel, named: "загран.txt", to: folder)
        await indexAll()
        let travel = try await document(.passportIntl)

        let answer = await reply("когда истекает загран")
        XCTAssertEqual(answer.cards, [.expiry(documentID: travel.id)])

        // Дата приходит из базы, а не из ответа роутера
        let resolved = await ChatCardResolver(search: search).resolve(answer.cards)
        guard let content = resolved.first?.content, case .expiry(let document, let validity) = content else {
            return XCTFail("карточка срока не собралась: \(resolved.map(\.card))")
        }
        XCTAssertEqual(document.id, travel.id)
        XCTAssertEqual(validity.status, .until(try day("15.03.2031")))
    }

    func testDiplomaDocumentsListTheirFolder() async throws {
        let folder = try makeFolder("Бакалавриат RUDN")
        add("РОССИЙСКИЙ УНИВЕРСИТЕТ ДРУЖБЫ НАРОДОВ\nДИПЛОМ БАКАЛАВРА", named: "диплом.txt", to: folder)
        add("Учебный план направления подготовки", named: "план.txt", to: folder)
        await indexAll()
        let diploma = try await document(named: "диплом.txt")
        let plan = try await document(named: "план.txt")
        XCTAssertEqual(diploma.type, .diploma)

        let answer = await reply("дипломные документы")
        XCTAssertEqual(answer.cards, [.fileList(documentIDs: [diploma.id, plan.id])], "сначала дипломы, потом остальное из их папки")
    }

    /// Сценарий спецификации: карточка файла и строка с найденным фрагментом текста
    func testTextQueryAnswersWithSnippet() async throws {
        let folder = try makeFolder("Наука")
        add("""
        СПРАВКА
        Редакция журнала подтверждает принятие статьи к публикации в номере 4 за 2025 год
        """, named: "IMG_2041.txt", to: folder)
        await indexAll()
        let article = try await document(named: "IMG_2041.txt")

        let (answer, hits) = await ChatRouter(search: search).reply(to: "справка о принятии статьи")
        XCTAssertEqual(answer.cards, [.snippet(documentID: article.id, page: nil)])
        XCTAssertNotNil(hits[article.id]?.snippet)

        let resolved = await ChatCardResolver(search: search).resolve(answer.cards, hits: hits)
        guard let content = resolved.first?.content, case .snippet(let document, _, let snippet) = content else {
            return XCTFail("фрагмент не собрался: \(resolved.map(\.card))")
        }
        XCTAssertEqual(document.id, article.id)
        XCTAssertNotNil(snippet, "рендерер подставляет фрагмент с подсветкой")
    }

    func testNothingFoundGivesMessageWithoutCards() async throws {
        let folder = try makeFolder("Работа")
        add("Трудовой договор", named: "договор.txt", to: folder)
        await indexAll()

        let answer = await reply("квантовая хромодинамика")
        XCTAssertEqual(answer.cards, [])
        XCTAssertFalse(answer.text.isEmpty, "пустой ответ должен объяснить, что ничего не нашлось")
    }

    // MARK: - Суперскрытые папки

    func testSuperHiddenPassportIsNeverAnswered() async throws {
        let hidden = try makeFolder("Тайник", hidden: true)
        add(Fixture.savinRussian, named: "паспорт.txt", to: hidden)
        try makeFolder("Обычная")
        await indexAll()

        let indexed = await search.indexedFiles()
        XCTAssertFalse(indexed.contains { $0.folderID == hidden.id })
        for query in ["мой паспорт", "номер паспорта", "паспорт савина илья", "когда менять паспорт", "тайник", "мвд"] {
            let answer = await reply(query)
            XCTAssertEqual(answer.cards.flatMap(\.documentIDs), [], "«\(query)» выдал документ суперскрытой папки")
            let clarifyTitles = answer.cards.compactMap { card -> [String]? in
                if case .clarify(_, let options) = card { return options.map(\.title) }
                return nil
            }
            XCTAssertEqual(clarifyTitles, [], "«\(query)» подсказал вариант из суперскрытой папки")
        }
    }

    /// Скрытый паспорт не должен ни появиться в чипах, ни выдать себя счётом:
    /// «нашлось несколько документов» уже сказало бы, что он есть
    func testHiddenPassportDoesNotLeakIntoClarifyOrCount() async throws {
        let visible = try makeFolder("Паспорта")
        let hidden = try makeFolder("Тайник", hidden: true)
        add(Fixture.savinRussian, named: "savin.txt", to: visible)
        add(Fixture.ivanovaRussian, named: "ivanova.txt", to: hidden)
        await indexAll()
        let savin = try await document(.passportRU)

        let mine = await reply("мой паспорт")
        XCTAssertEqual(mine.cards.map(\.documentIDs), [[savin.id], [savin.id]])

        for query in ["паспорт петрова", "паспорт ивановой анны"] {
            let answer = await reply(query)
            guard case .clarify(_, let options) = answer.cards.first else {
                XCTFail("«\(query)»: ждали список видимых паспортов, пришло \(answer.cards)")
                continue
            }
            XCTAssertEqual(options.count, 1, "«\(query)»: в чипах только видимый паспорт")
            XCTAssertFalse(
                options.contains { $0.title.contains("Иванова") || $0.query.contains("Иванова") },
                "«\(query)»: чип выдал владельца скрытого паспорта"
            )
        }
    }

    func testHidingFolderStopsAnswersAndStaleCards() async throws {
        let folder = try makeFolder("Паспорта")
        add(Fixture.savinRussian, named: "паспорт.txt", to: folder)
        await indexAll()
        let passport = try await document(.passportRU)
        let before = await reply("мой паспорт")
        XCTAssertEqual(before.cards.first?.documentIDs, [passport.id])

        store.setSuperHidden(true, for: folder.id)

        // Ещё до того, как индекс стёр папку, ни новый ответ, ни старые
        // карточки её документ не показывают
        let after = await reply("мой паспорт")
        XCTAssertEqual(after.cards.flatMap(\.documentIDs), [])
        let stale = await ChatCardResolver(search: search).resolve(before.cards)
        XCTAssertTrue(stale.isEmpty, "карточка со старым id не должна раскрыть скрытый документ")

        await search.waitUntilIdle()
        let indexed = await search.indexedFiles()
        XCTAssertFalse(indexed.contains { $0.folderID == folder.id })
    }

    // MARK: - Подстановка значений

    /// Модель или роутер могут назвать только ключи из базы: выдуманный ключ
    /// отбрасывается, а значение приходит из индекса
    func testResolverDropsUnknownFieldKeys() async throws {
        let folder = try makeFolder("Паспорта")
        add(Fixture.savinRussian, named: "паспорт.txt", to: folder)
        await indexAll()
        let passport = try await document(.passportRU)

        let resolved = await ChatCardResolver(search: search).resolve([
            .fields(documentID: passport.id, keys: [FieldKey.seriesNumber, "invented_key"]),
            .fields(documentID: passport.id, keys: ["invented_key"]),
            .document(documentID: 999_999),
        ])
        XCTAssertEqual(resolved.count, 1)
        guard let content = resolved.first?.content, case .fields(let document, let keys) = content else {
            return XCTFail("карточка полей не собралась: \(resolved.map(\.card))")
        }
        XCTAssertEqual(keys, [FieldKey.seriesNumber])
        XCTAssertEqual(document.field(FieldKey.seriesNumber)?.value, "4601 123456")
    }

    // MARK: - Сессия

    func testSessionAnswersAndForgetsOnReset() async throws {
        let folder = try makeFolder("Паспорта")
        add(Fixture.savinRussian, named: "паспорт.txt", to: folder)
        await indexAll()
        let passport = try await document(.passportRU)
        let session = ChatSession(search: search)

        session.send("   ")
        XCTAssertTrue(session.messages.isEmpty, "пустой запрос не отправляется")

        session.send("мой паспорт")
        XCTAssertEqual(session.messages.map(\.role), [.user, .assistant])
        XCTAssertTrue(session.isAnswering)
        session.send("ещё вопрос")
        XCTAssertEqual(session.messages.count, 2, "пока идёт ответ, новый вопрос не принимается")

        try await waitForAnswer(session)
        let answer = try XCTUnwrap(session.messages.last)
        XCTAssertFalse(answer.isPending)
        XCTAssertEqual(answer.cards.map(\.card.documentIDs), [[passport.id], [passport.id]])

        session.revealsSensitive = true
        session.reset()
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertFalse(session.revealsSensitive, "открытые номера закрываются вместе с историей")
    }

    // MARK: - JSON каталога

    func testDecodesSpecificationExample() throws {
        let json = """
        {"cards": [
          {"type": "fields", "documentId": "d42", "keys": ["series_number", "issued_by", "issue_date"]},
          {"type": "document", "documentId": "d42"}
        ]}
        """
        let payload = try JSONDecoder().decode(ChatCardsPayload.self, from: Data(json.utf8))
        XCTAssertNil(payload.text)
        XCTAssertEqual(payload.cards, [
            .fields(documentID: 42, keys: [FieldKey.seriesNumber, FieldKey.issuedBy, FieldKey.issueDate]),
            .document(documentID: 42),
        ])
    }

    func testEveryCardTypeRoundTrips() throws {
        let cards: [ChatCard] = [
            .fields(documentID: 1, keys: [FieldKey.seriesNumber, FieldKey.issueDate]),
            .document(documentID: 2),
            .fileList(documentIDs: [3, 4, 5]),
            .snippet(documentID: 6, page: 3),
            .snippet(documentID: 7, page: nil),
            .clarify(question: "Какой паспорт?", options: [
                ClarifyOption(title: "Паспорт РФ", query: "паспорт РФ"),
                ClarifyOption(title: "Загранпаспорт", query: "загранпаспорт"),
            ]),
            .clarify(question: nil, options: [ClarifyOption(title: "Паспорт РФ", query: "паспорт РФ")]),
            .expiry(documentID: 8),
        ]
        let data = try JSONEncoder().encode(ChatCardsPayload(text: "Вот что нашлось", cards: cards))
        let decoded = try JSONDecoder().decode(ChatCardsPayload.self, from: data)
        XCTAssertEqual(decoded.cards, cards)
        XCTAssertEqual(decoded.text, "Вот что нашлось")
    }

    func testEncodedIDsUseSpecificationFormat() throws {
        let list = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatCard.fileList(documentIDs: [42, 7])))
        let listObject = try XCTUnwrap(list as? [String: Any])
        XCTAssertEqual(listObject["type"] as? String, "fileList")
        XCTAssertEqual(listObject["documentIds"] as? [String], ["d42", "d7"])

        let single = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatCard.document(documentID: 42)))
        let singleObject = try XCTUnwrap(single as? [String: Any])
        XCTAssertEqual(singleObject["type"] as? String, "document")
        XCTAssertEqual(singleObject["documentId"] as? String, "d42")

        XCTAssertEqual(ChatCard.decodeID("d42"), 42)
        XCTAssertEqual(ChatCard.decodeID("42"), 42)
        XCTAssertNil(ChatCard.decodeID("паспорт"))
    }

    /// Только одобренные компоненты: неизвестный тип или битый id не превращаются в карточку
    func testInvalidCardsFailDecoding() {
        let badID = #"{"type": "document", "documentId": "dx"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ChatCard.self, from: Data(badID.utf8)))
        let unknownType = #"{"type": "chart", "documentId": "d1"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ChatCard.self, from: Data(unknownType.utf8)))
    }

    // MARK: - Срок действия

    func testTravelPassportValidUntilExpiryDate() throws {
        let validity = DocumentValidity.of(type: .passportIntl, fields: [FieldKey.expiryDate: "15.03.2031"])
        XCTAssertEqual(validity.status, .until(try day("15.03.2031")))
    }

    func testRussianPassportIssuedBefore20IsReplacedAt20() throws {
        let validity = DocumentValidity.of(type: .passportRU, fields: [
            FieldKey.birthDate: "01.01.1990",
            FieldKey.issueDate: "15.05.2004",
        ])
        XCTAssertEqual(validity.status, .replaceAtAge(20, try day("01.01.2010")))
    }

    func testRussianPassportIssuedAfter20IsReplacedAt45() throws {
        let validity = DocumentValidity.of(type: .passportRU, fields: [
            FieldKey.birthDate: "01.01.1990",
            FieldKey.issueDate: "20.06.2010",
        ])
        XCTAssertEqual(validity.status, .replaceAtAge(45, try day("01.01.2035")))
    }

    func testRussianPassportIssuedAfter45IsIndefinite() {
        let validity = DocumentValidity.of(type: .passportRU, fields: [
            FieldKey.birthDate: "01.01.1970",
            FieldKey.issueDate: "10.02.2016",
        ])
        XCTAssertEqual(validity.status, .indefinite)
        XCTAssertNil(validity.date)
        XCTAssertNil(validity.remainingText())
    }

    /// Даты выдачи нет — возраст считается на сегодня
    func testRussianPassportWithoutIssueDateUsesToday() throws {
        let today = try day("12.10.2026")
        let adult = DocumentValidity.of(type: .passportRU, fields: [FieldKey.birthDate: "01.01.1990"], today: today)
        XCTAssertEqual(adult.status, .replaceAtAge(45, try day("01.01.2035")))
        let teenager = DocumentValidity.of(type: .passportRU, fields: [FieldKey.birthDate: "15.06.2010"], today: today)
        XCTAssertEqual(teenager.status, .replaceAtAge(20, try day("15.06.2030")))
    }

    func testValidityUnknownWithoutDates() {
        XCTAssertEqual(DocumentValidity.of(type: .passportIntl, fields: [:]).status, .unknown)
        XCTAssertEqual(DocumentValidity.of(type: .passportRU, fields: [:]).status, .unknown)
        XCTAssertEqual(DocumentValidity.of(type: .diploma, fields: [FieldKey.expiryDate: "15.03.2031"]).status, .unknown)
    }

    func testRemainingTextWording() throws {
        let today = try day("12.10.2026")
        func text(_ date: String) throws -> String? {
            DocumentValidity(status: .until(try day(date))).remainingText(today: today)
        }
        XCTAssertEqual(try text("15.03.2031"), "осталось 4 года 5 месяцев")
        XCTAssertEqual(try text("12.10.2027"), "осталось 1 год")
        XCTAssertEqual(try text("20.10.2026"), "осталось 8 дней")
        XCTAssertEqual(try text("12.10.2026"), "истекает сегодня")
        XCTAssertEqual(try text("01.08.2026"), "истёк 2 месяца назад")

        XCTAssertTrue(DocumentValidity(status: .until(try day("01.08.2026"))).isExpired(today: today))
        XCTAssertFalse(DocumentValidity(status: .until(try day("15.03.2031"))).isExpired(today: today))
    }

    // MARK: - Имена

    func testNameMatchesDeclinedCyrillicName() {
        XCTAssertTrue(ChatRouter.nameMatches(["савина", "илья"], owner: "Савин Илья Андреевич"))
        XCTAssertTrue(ChatRouter.nameMatches(["ивановой"], owner: "Иванова Анна Сергеевна"))
        XCTAssertFalse(ChatRouter.nameMatches(["петрова"], owner: "Савин Илья Андреевич"))
        XCTAssertFalse(ChatRouter.nameMatches(["савин"], owner: ""), "без распознанного ФИО совпадения нет")
    }

    /// В загранпаспорте имя латиницей: запрос переводится по ИКАО
    func testNameMatchesLatinOwnerThroughTransliteration() {
        XCTAssertTrue(ChatRouter.nameMatches(["савина", "илья"], owner: "SAVIN ILIA"))
        XCTAssertTrue(ChatRouter.nameMatches(["savin"], owner: "SAVIN ILIA"))
        XCTAssertFalse(ChatRouter.nameMatches(["иванова"], owner: "SAVIN ILIA"))
    }

    func testTransliterationFollowsICAO() {
        XCTAssertEqual(ChatRouter.transliterate("Илья"), "ilia")
        XCTAssertEqual(ChatRouter.transliterate("Щукин"), "shchukin")
        XCTAssertEqual(ChatRouter.transliterate("Юлия"), "iuliia")
        XCTAssertEqual(ChatRouter.transliterate("Жуков"), "zhukov")
    }

    func testShortName() {
        XCTAssertEqual(ChatRouter.shortName("Савин Илья Андреевич"), "Савин И. А.")
        XCTAssertEqual(ChatRouter.shortName("SAVIN ILIA"), "SAVIN I.")
        XCTAssertEqual(ChatRouter.shortName("Савин"), "Савин")
        XCTAssertEqual(ChatRouter.shortName(""), "")
    }
}
