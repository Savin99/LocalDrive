import XCTest
@testable import LocalDrive

// Вопросы о человеке без вида документа и просьбы разложить файлы — то, что
// владелец 24.10.2026 спрашивал на iPhone: «дата рождения Ольги» думала больше
// 30 с, хотя паспорт уже распознан. Теперь такой ответ — правила из базы, сразу.
// Паспорта — текстом с MRZ, векторы те же, что в ChatRouterTests (посчитаны
// независимо от приложения)
@MainActor
final class ChatPersonTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDrivePersonTests-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
        search = SearchService(store: store, databaseURL: nil)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        search = nil
        store = nil
        root = nil
    }

    /// Савин Илья Андреевич, родился 01.01.1990
    private static let savinRussian = """
    ПАСПОРТ
    Паспорт выдан ГУ МВД РОССИИ ПО Г. МОСКВЕ
    Дата выдачи 20.06.2010 Код подразделения 770-120
    PNRUSSAVIN<<IL98<ANDREEVI3<<<<<<<<<<<<<<<<<<
    4601234561RUS9001011M<<<<<<<1100620770120<34
    """

    /// Иванова Анна Сергеевна, родилась 12.05.1985
    private static let ivanovaRussian = """
    ПАСПОРТ
    PNRUSIVANOVA<<ANNA<SERGEEVNA<<<<<<<<<<<<<<<<
    4516543213RUS8505121F<<<<<<<0120315690001<44
    """

    @discardableResult
    private func makeFolder(_ name: String) throws -> VaultFolder {
        store.createFolder(name: name, icon: "folder.fill", color: "indigo")
        return try XCTUnwrap(store.folders.last)
    }

    private func indexPassports() async throws -> VaultFolder {
        let folder = try makeFolder("Паспорта")
        store.importData(Data(Self.savinRussian.utf8), preferredName: "савин.txt", to: folder)
        store.importData(Data(Self.ivanovaRussian.utf8), preferredName: "иванова.txt", to: folder)
        search.reconcile()
        await search.waitUntilIdle()
        return folder
    }

    private func passport(of owner: String) async throws -> StoredDocument {
        let documents = await search.documents(ofTypes: [.passportRU])
        let fields = await search.fields(for: documents.map(\.id))
        return try XCTUnwrap(documents.first { document in
            fields[document.id]?.contains { $0.key == FieldKey.fullName && $0.value == owner } == true
        })
    }

    private func reply(_ text: String, previous: String? = nil) async -> ChatReply {
        await ChatRouter(search: search).reply(to: text, previous: previous).0
    }

    // MARK: - Человек без вида документа

    func testBirthDateByNameAloneIsAnsweredFromFields() async throws {
        _ = try await indexPassports()
        let anna = try await passport(of: "Иванова Анна Сергеевна")

        let answer = await reply("дата рождения Анны")
        XCTAssertEqual(answer.cards, [.fields(documentID: anna.id, keys: [FieldKey.birthDate])])
        XCTAssertTrue(answer.isConfident, "точный ответ ушёл бы в модель или облако")
    }

    func testAgeQuestionMeansBirthDate() async throws {
        _ = try await indexPassports()
        let anna = try await passport(of: "Иванова Анна Сергеевна")

        XCTAssertEqual(ChatIntent("сколько лет Анне").fieldKeys, [FieldKey.birthDate])
        let answer = await reply("сколько лет Анне")
        XCTAssertEqual(answer.cards, [.fields(documentID: anna.id, keys: [FieldKey.birthDate])])
    }

    func testNameAloneShowsPersonOverview() async throws {
        _ = try await indexPassports()
        let anna = try await passport(of: "Иванова Анна Сергеевна")

        let answer = await reply("что есть на Анну")
        XCTAssertTrue(answer.isConfident)
        XCTAssertTrue(answer.text.contains("Иванова А. С."), answer.text)
        guard case .fields(let id, let keys) = answer.cards.first else { return XCTFail("нет карточки полей: \(answer.cards)") }
        XCTAssertEqual(id, anna.id)
        XCTAssertTrue(keys.contains(FieldKey.fullName))
        XCTAssertEqual(answer.cards.last, .fileList(documentIDs: [anna.id]))
    }

    func testFollowUpAboutAnotherPerson() async throws {
        _ = try await indexPassports()
        let anna = try await passport(of: "Иванова Анна Сергеевна")

        let answer = await reply("а у Анны?", previous: "дата рождения Ильи")
        XCTAssertEqual(answer.cards, [.fields(documentID: anna.id, keys: [FieldKey.birthDate])])
    }

    func testTwoPeopleWithOneNameAreAskedAbout() async throws {
        let folder = try await indexPassports()
        // Свидетельство о рождении дочери: поля вписаны руками, вид — «другое»
        store.importData(Data("Свидетельство о рождении".utf8), preferredName: "свидетельство.txt", to: folder)
        search.reconcile()
        await search.waitUntilIdle()
        let all = await search.documents(ofTypes: DocumentType.allCases)
        let certificate = try XCTUnwrap(all.first { $0.fileName == "свидетельство.txt" })
        await search.setManualField(documentID: certificate.id, key: FieldKey.fullName, value: "Савина Анна Ильинична")
        await search.setManualField(documentID: certificate.id, key: FieldKey.birthDate, value: "03.04.2015")

        let answer = await reply("дата рождения Анны")
        guard case .clarify(_, let options) = answer.cards.first else { return XCTFail("не спросил, о ком: \(answer.cards)") }
        XCTAssertEqual(options.count, 2)
        XCTAssertTrue(answer.isConfident)

        // Полное имя — сразу её свидетельство, без вопроса
        let daughter = await reply("дата рождения Савиной Анны")
        XCTAssertEqual(daughter.cards, [.fields(documentID: certificate.id, keys: [FieldKey.birthDate])])
    }

    /// «Фото паспорта Анны», «скинь скан Анны» — сам файл, а не поля
    func testFileRequestShowsTheFile() async throws {
        _ = try await indexPassports()
        let anna = try await passport(of: "Иванова Анна Сергеевна")

        XCTAssertTrue(ChatIntent("дошли фото паспорта").wantsFile)
        XCTAssertEqual(ChatIntent("дошли фото паспорта").nameWords, [], "«дошли» — просьба, не имя")
        let photo = await reply("фото паспорта Анны")
        XCTAssertEqual(photo.cards, [.document(documentID: anna.id)])
        let scan = await reply("скинь скан Анны")
        XCTAssertEqual(scan.cards, [.fileList(documentIDs: [anna.id])])
        XCTAssertTrue(scan.isConfident)
    }

    func testWordBesidesNameIsTextSearch() async throws {
        _ = try await indexPassports()
        let answer = await reply("договор Анны")
        XCTAssertFalse(answer.isConfident, "«договор Анны» — поиск по тексту, а не данные человека")
        XCTAssertFalse(answer.cards.contains { if case .fields = $0 { true } else { false } })
    }

    func testRulesAnswerHasRealSteps() async throws {
        _ = try await indexPassports()
        var steps: [ChatStep.Kind] = []
        var router = ChatRouter(search: search)
        router.onStep = { kind, _ in steps.append(kind) }
        _ = await router.reply(to: "дата рождения Анны")
        XCTAssertEqual(steps.first, .understand)
        XCTAssertTrue(steps.contains(.people), "не видно, что перебирал людей: \(steps)")
        XCTAssertTrue(steps.contains(.open), "не видно, какой документ открыл: \(steps)")
    }

    // MARK: - «Положи в …»

    func testFileCommandParsing() throws {
        let plain = try XCTUnwrap(ChatFileCommand("положи в папку Семья"))
        XCTAssertEqual(plain.destination, "Семья")
        XCTAssertTrue(plain.refersToContext)

        let named = try XCTUnwrap(ChatFileCommand("перенеси паспорт Ольги в Документы"))
        XCTAssertEqual(named.subject, "паспорт Ольги")
        XCTAssertEqual(named.destination, "Документы")
        XCTAssertFalse(named.refersToContext)

        let quoted = try XCTUnwrap(ChatFileCommand("Хорошо, сохрани это во «Входящие»"))
        XCTAssertEqual(quoted.destination, "Входящие")
        XCTAssertTrue(quoted.refersToContext)

        XCTAssertNil(ChatFileCommand("я положил паспорт в сейф"), "рассказ — не просьба")
        XCTAssertNil(ChatFileCommand("паспорт Ольги"))
    }

    func testFileCommandFindsFolderByStem() throws {
        let family = try makeFolder("Семья")
        XCTAssertEqual(ChatFileCommand("положи в семью")?.target(in: store), .existing(family.id))
        XCTAssertEqual(ChatFileCommand("закинь его в работу")?.target(in: store), .new(name: "Работа"))
        XCTAssertEqual(ChatFileCommand("положи в папку Учёба")?.target(in: store), .new(name: "Учёба"))
    }

    func testAttachmentWithCommandProposesThatFolder() async throws {
        let passports = try await indexPassports()
        let inbox = ChatAttachmentInbox(directory: root.appendingPathComponent("Inbox", isDirectory: true))
        let session = ChatSession(search: search, inbox: inbox)
        session.useFiles(store)
        let added = await inbox.add(data: Data("скан".utf8), named: "скан.txt")
        let attachment = try XCTUnwrap(added)

        session.send("положи в Паспорта", attaching: inbox.takeDraft())
        var attempts = 0
        while session.isAnswering, attempts < 300 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        let answer = try XCTUnwrap(session.messages.last)
        guard case .proposal(let proposal) = answer.cards.first?.content else { return XCTFail("нет предложения: \(answer.text)") }
        XCTAssertEqual(proposal.actions, [.saveAttachment(attachmentID: attachment.id, folder: .existing(passports.id), name: nil)])
        XCTAssertFalse(answer.steps.isEmpty)
    }

    func testMoveCommandMovesDocumentOfPreviousAnswer() async throws {
        _ = try await indexPassports()
        let family = try makeFolder("Семья")
        let anna = try await passport(of: "Иванова Анна Сергеевна")
        let session = ChatSession(search: search)
        session.useFiles(store)

        session.send("паспорт Анны")
        try await waitForAnswer(session)
        session.send("перенеси его в Семью")
        try await waitForAnswer(session)

        let answer = try XCTUnwrap(session.messages.last)
        guard case .proposal(let proposal) = answer.cards.first?.content else { return XCTFail("нет предложения: \(answer.text)") }
        XCTAssertEqual(proposal.actions, [.moveFiles(files: [FileRef(folderID: anna.folderID, name: anna.fileName)], folder: .existing(family.id))])
    }

    private func waitForAnswer(_ session: ChatSession) async throws {
        var attempts = 0
        while session.isAnswering, attempts < 300 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        XCTAssertFalse(session.isAnswering)
    }
}
