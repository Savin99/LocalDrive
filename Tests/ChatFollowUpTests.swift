import XCTest
@testable import LocalDrive

// Уточнения к прошлому ответу и адрес. Снимок владельца 12.10.2026: после
// карточки паспорта «Адрес какой» ответил «Ничего не нашёл» — чат не понял,
// что речь о том же паспорте, и не знал, где в паспорте адрес
@MainActor
final class ChatFollowUpTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDriveFollowUpTests-\(UUID().uuidString)", isDirectory: true)
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
        /// Савин Илья Андреевич, 4601 123456, выдан 20.06.2010 — синтетика
        static let savin = """
        ПАСПОРТ
        Фамилия САВИН
        Имя ИЛЬЯ
        Отчество АНДРЕЕВИЧ
        PNRUSSAVIN<<IL98<ANDREEVI3<<<<<<<<<<<<<<<<<<
        4601234561RUS9001011M<<<<<<<1100620770120<34
        """
        static let ivanova = """
        ПАСПОРТ
        PNRUSIVANOVA<<ANNA<SERGEEVNA<<<<<<<<<<<<<<<<
        4516543213RUS8505121F<<<<<<<0120315690001<44
        """
        /// Разворот «Место жительства» со штампом — без имени
        static let registration = """
        МЕСТО ЖИТЕЛЬСТВА
        ЗАРЕГИСТРИРОВАН
        г. Москва, ул. Тверская, д. 1, кв. 1
        15.07.2023
        """
        static let contract = """
        ДОГОВОР АРЕНДЫ № 17
        Номер договора 17
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

    private func reply(_ text: String, context: [Int64] = []) async -> ChatReply {
        await ChatRouter(search: search).reply(to: text, context: context).0
    }

    func testAddressWordsAreUnderstood() {
        XCTAssertTrue(ChatIntent("Адрес какой").wantsAddress)
        XCTAssertTrue(ChatIntent("где прописан").wantsAddress)
        let named = ChatIntent("адрес регистрации савина")
        XCTAssertTrue(named.wantsAddress)
        XCTAssertEqual(named.nameWords, ["савина"])
        XCTAssertFalse(ChatIntent("мой паспорт").wantsAddress)
    }

    func testAddressFollowUpShowsRegistrationPageOfSamePassport() async throws {
        let passports = try folder("Паспорта")
        add(Fixture.savin, named: "savin.txt", to: passports)
        add(Fixture.registration, named: "прописка.txt", to: passports)
        await indexAll()
        let savin = try await document(named: "savin.txt")
        let page = try await document(named: "прописка.txt")

        // Штамп распознан полями — ответ карточкой полей этой страницы
        // (поведение с 13.10.2026; раньше — фрагментом текста страницы)
        let answer = await reply("Адрес какой", context: [savin.id])
        XCTAssertEqual(answer.cards, [.fields(documentID: page.id, keys: [FieldKey.registrationAddress, FieldKey.registrationDate])])
        XCTAssertEqual(answer.text, "Регистрация по месту жительства — со страницы «Место жительства»:")
    }

    func testAddressInSharedFolderSaysWhoseIsUnclear() async throws {
        let passports = try folder("Паспорта")
        add(Fixture.savin, named: "savin.txt", to: passports)
        add(Fixture.ivanova, named: "ivanova.txt", to: passports)
        add(Fixture.registration, named: "прописка.txt", to: passports)
        await indexAll()
        let savin = try await document(named: "savin.txt")

        let answer = await reply("Адрес какой", context: [savin.id])
        XCTAssertFalse(answer.cards.isEmpty)
        XCTAssertEqual(answer.text, "Нашёл страницы с пропиской. Чья из них — видно на фото:")
    }

    func testAddressWithoutRegistrationPageExplainsWhatToAdd() async throws {
        let passports = try folder("Паспорта")
        add(Fixture.savin, named: "savin.txt", to: passports)
        await indexAll()
        let savin = try await document(named: "savin.txt")

        let answer = await reply("Адрес какой", context: [savin.id])
        XCTAssertEqual(answer.cards, [])
        XCTAssertTrue(answer.text.contains("Место жительства"), answer.text)
    }

    func testFieldFollowUpUsesDocumentFromPreviousAnswer() async throws {
        let passports = try folder("Паспорта")
        add(Fixture.savin, named: "savin.txt", to: passports)
        add(Fixture.ivanova, named: "ivanova.txt", to: passports)
        await indexAll()
        let savin = try await document(named: "savin.txt")

        let answer = await reply("а дата выдачи?", context: [savin.id])
        XCTAssertEqual(answer.cards, [.fields(documentID: savin.id, keys: [FieldKey.issueDate])])
    }

    func testOtherDocumentWordIsNotAFollowUp() async throws {
        let passports = try folder("Паспорта")
        add(Fixture.savin, named: "savin.txt", to: passports)
        add(Fixture.contract, named: "договор.txt", to: try folder("Работа"))
        await indexAll()
        let savin = try await document(named: "savin.txt")

        let answer = await reply("номер договора", context: [savin.id])
        XCTAssertFalse(answer.cards.flatMap(\.documentIDs).contains(savin.id), "«номер договора» — не номер паспорта")
    }

    /// «Сааин илья паспорт» — опечатка в «Савин»: ответ о Савине с оговоркой
    func testNameTypoFindsClosestOwner() async throws {
        let passports = try folder("Паспорта")
        add(Fixture.savin, named: "savin.txt", to: passports)
        add(Fixture.ivanova, named: "ivanova.txt", to: passports)
        await indexAll()
        let savin = try await document(named: "savin.txt")

        let answer = await reply("сааин илья паспорт")
        XCTAssertEqual(answer.cards.first?.documentIDs, [savin.id])
        XCTAssertTrue(answer.text.hasPrefix("Похоже, вы про «Савин И. А.»"), answer.text)
    }

    /// Чипов всего четыре — первыми идут самые похожие имена
    func testUnknownNameChipsStartWithClosestOwner() async throws {
        let passports = try folder("Паспорта")
        add(Fixture.savin, named: "savin.txt", to: passports)
        add(Fixture.ivanova, named: "ivanova.txt", to: passports)
        await indexAll()
        let ivanova = try await document(named: "ivanova.txt")

        let answer = await reply("паспорт ивонова петра")
        guard case .clarify(_, let options) = answer.cards.first else {
            return XCTFail("ждали список паспортов, пришло \(answer.cards)")
        }
        XCTAssertEqual(options.first?.documentID, ivanova.id)
    }

    /// Уточнение через сессию: она сама передаёт документы прошлого ответа
    func testSessionFollowUpUsesPreviousAnswer() async throws {
        let passports = try folder("Паспорта")
        add(Fixture.savin, named: "savin.txt", to: passports)
        await indexAll()
        let session = ChatSession(search: search)
        session.send("мой паспорт")
        var attempts = 0
        while session.isAnswering, attempts < 300 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        XCTAssertEqual(session.messages.count, 2)

        // Уточнение видит документ прошлого ответа
        session.send("а код подразделения?")
        attempts = 0
        while session.isAnswering, attempts < 300 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        guard case .fields(_, let keys) = session.messages.last?.cards.first?.card else {
            return XCTFail("ждали поле паспорта, пришло \(String(describing: session.messages.last?.cards.map(\.card)))")
        }
        XCTAssertEqual(keys, [FieldKey.departmentCode])
    }
}
