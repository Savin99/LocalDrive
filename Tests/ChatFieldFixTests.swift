import XCTest
@testable import LocalDrive

// «В фамилии ошибка» — поправка поля, которое распознавание прочитало неверно.
// Владелец 24.10.2026: «загрузил док в папку, в чате говорю — в фамилии
// ошибка, он не исправляет». Чат показывает «было → станет», поле меняется
// по кнопке и становится ручным. Паспорт — текстом с MRZ, вектор тот же, что в
// ChatRouterTests (посчитан независимо от приложения)
@MainActor
final class ChatFieldFixTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDriveFieldFix-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(rootURL: root)
        search = SearchService(store: store, databaseURL: nil)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        search = nil
        store = nil
        root = nil
    }

    /// Иванова Анна Сергеевна, родилась 12.05.1985
    private static let ivanovaRussian = """
    ПАСПОРТ
    PNRUSIVANOVA<<ANNA<SERGEEVNA<<<<<<<<<<<<<<<<
    4516543213RUS8505121F<<<<<<<0120315690001<44
    """

    private func indexPassport() async throws -> StoredDocument {
        store.createFolder(name: "Паспорта", icon: "folder.fill", color: "indigo")
        let folder = try XCTUnwrap(store.folders.last)
        store.importData(Data(Self.ivanovaRussian.utf8), preferredName: "иванова.txt", to: folder)
        search.reconcile()
        await search.waitUntilIdle()
        let passports = await search.documents(ofTypes: [.passportRU])
        return try XCTUnwrap(passports.first)
    }

    private func ask(_ session: ChatSession, _ text: String) async throws -> ChatSession.Message {
        session.send(text)
        for _ in 0..<300 where session.isAnswering { try await Task.sleep(for: .milliseconds(10)) }
        return try XCTUnwrap(session.messages.last)
    }

    private func fix(in message: ChatSession.Message) -> (Int64, String, String)? {
        for card in message.cards {
            if case .fieldFix(let id, let key, let value) = card.card { return (id, key, value) }
        }
        return nil
    }

    // MARK: - Разбор

    func testParsing() throws {
        let date = try XCTUnwrap(ChatFieldFix("исправь дату рождения на 12.5.85"))
        XCTAssertEqual(date.key, FieldKey.birthDate)
        XCTAssertEqual(date.value, "12.05.1985")

        let surname = try XCTUnwrap(ChatFieldFix("в фамилии ошибка"))
        XCTAssertEqual(surname.key, FieldKey.fullName)
        XCTAssertEqual(surname.namePart, .surname)
        XCTAssertNil(surname.value, "значение не сказано — чат спросит")

        let notBut = try XCTUnwrap(ChatFieldFix("фамилия не Трошина, а Трошкина"))
        XCTAssertEqual(notBut.replacing, "Трошина")
        XCTAssertEqual(notBut.value, "Трошкина")
        XCTAssertEqual(notBut.resolvedValue(current: "Трошина Ольга Петровна"), "Трошкина Ольга Петровна")

        let correct = try XCTUnwrap(ChatFieldFix("в фамилии ошибка, правильно Трошкина"))
        XCTAssertEqual(correct.resolvedValue(current: "Трошина Ольга Петровна"), "Трошкина Ольга Петровна")

        XCTAssertNotNil(ChatFieldFix("фамилия не так написана"))
        XCTAssertNotNil(ChatFieldFix("что-то не так с фамилией"))
        XCTAssertNil(ChatFieldFix("что-то не так"), "поле не названо — не поправка")
        XCTAssertNil(ChatFieldFix("какая дата рождения у Анны"), "вопрос — не поправка")
        XCTAssertNil(ChatFieldFix("паспорт Ольги"))
    }

    /// Модель берёт ФИО из описи — с инициалами; в поле уходит полное
    func testInitialsFromIndexExpandToFullName() {
        let current = "Трошина Ольга Петровна"
        XCTAssertEqual(ChatFieldFix.expandingInitials("Трошкина О. П.", current: current), "Трошкина Ольга Петровна")
        XCTAssertEqual(ChatFieldFix.expandingInitials("Трошкина О.П.", current: current), "Трошкина О.П.",
                       "слитные инициалы не угадываем — человек увидит «станет» до кнопки")
        XCTAssertEqual(ChatFieldFix.expandingInitials("Трошкина Ольга Петровна", current: current), "Трошкина Ольга Петровна")
        XCTAssertEqual(ChatFieldFix.expandingInitials("Трошина А. П.", current: current), "Трошина А. П.",
                       "другая буква — это поправка имени, не инициал")
    }

    /// Ответы модели из живой проверки: правка ложится на текущее ФИО
    func testModelNameVariantsLandOnCurrentName() {
        let current = "Трошина Ольга Петровна"
        XCTAssertEqual(ChatFieldFix.correctedName("Трошкина О. П.", current: current), "Трошкина Ольга Петровна")
        XCTAssertEqual(ChatFieldFix.correctedName("Ольга Трошкина", current: current), "Трошкина Ольга Петровна")
        XCTAssertEqual(ChatFieldFix.correctedName("Трошкина Ольга Петровна", current: current), "Трошкина Ольга Петровна")
        XCTAssertEqual(ChatFieldFix.correctedName("Трошина Ольга Павловна", current: current), "Трошина Ольга Павловна")
        XCTAssertEqual(ChatFieldFix.correctedName("Анна Иванова", current: current), "Анна Иванова",
                       "два новых слова — не поправка одного, значение как есть")
    }

    // MARK: - В чате

    func testSurnameErrorAsksThenProposesFix() async throws {
        let anna = try await indexPassport()
        let session = ChatSession(search: search)

        _ = try await ask(session, "паспорт Анны")
        let question = try await ask(session, "в фамилии ошибка")
        XCTAssertTrue(question.text.contains("Как правильно"), question.text)
        XCTAssertNil(fix(in: question))

        let proposal = try await ask(session, "Иванчук")
        let (id, key, value) = try XCTUnwrap(fix(in: proposal), proposal.text)
        XCTAssertEqual(id, anna.id)
        XCTAssertEqual(key, FieldKey.fullName)
        XCTAssertEqual(value, "Иванчук Анна Сергеевна")

        // «Принять» — поле ручное, и дальше чат отвечает уже им
        await search.setManualField(documentID: id, key: key, value: value)
        let fields = await search.fields(for: [id])[id] ?? []
        let name = try XCTUnwrap(fields.first { $0.key == FieldKey.fullName })
        XCTAssertEqual(name.value, "Иванчук Анна Сергеевна")
        XCTAssertEqual(name.source, .manual)
    }

    /// Ответ на «как правильно?» разными словами — та же поправка, тот же
    /// документ, отчество на месте (владелец 25.10.2026)
    func testAnswerToHowIsItRightInOtherWords() async throws {
        let anna = try await indexPassport()
        for answer in ["правильно Иванчук", "фамилия Иванчук", "должна быть Иванчук", "Иванчук Анна"] {
            let session = ChatSession(search: search)
            _ = try await ask(session, "паспорт Анны")
            let question = try await ask(session, "там фамилия неправильно написана")
            XCTAssertTrue(question.text.contains("правильную фамилию"), question.text)
            let proposal = try await ask(session, answer)
            let (id, key, value) = try XCTUnwrap(fix(in: proposal), "«\(answer)»: \(proposal.text)")
            XCTAssertEqual(id, anna.id, answer)
            XCTAssertEqual(key, FieldKey.fullName, answer)
            XCTAssertEqual(value, "Иванчук Анна Сергеевна", answer)
        }
    }

    func testDateFixWithValueInOneMessage() async throws {
        let anna = try await indexPassport()
        let session = ChatSession(search: search)

        _ = try await ask(session, "паспорт Анны")
        let proposal = try await ask(session, "исправь дату рождения на 13.05.1985")
        let (id, key, value) = try XCTUnwrap(fix(in: proposal), proposal.text)
        XCTAssertEqual(id, anna.id)
        XCTAssertEqual(key, FieldKey.birthDate)
        XCTAssertEqual(value, "13.05.1985")
    }

    func testNotButWithoutFieldName() async throws {
        let anna = try await indexPassport()
        let session = ChatSession(search: search)

        _ = try await ask(session, "паспорт Анны")
        let proposal = try await ask(session, "не Иванова, а Иванчук")
        let (id, key, value) = try XCTUnwrap(fix(in: proposal), proposal.text)
        XCTAssertEqual(id, anna.id)
        XCTAssertEqual(key, FieldKey.fullName)
        XCTAssertEqual(value, "Иванчук Анна Сергеевна")
    }

    /// Только что загрузил в папку и сразу пишет об ошибке — без прошлого ответа
    func testFixRightAfterUploadTargetsNewDocument() async throws {
        let anna = try await indexPassport()
        let session = ChatSession(search: search)

        let proposal = try await ask(session, "в паспорте ошибка в фамилии, правильно Иванчук")
        let (id, _, value) = try XCTUnwrap(fix(in: proposal), proposal.text)
        XCTAssertEqual(id, anna.id)
        XCTAssertEqual(value, "Иванчук Анна Сергеевна")
    }

    /// «В паспорте Анны ошибка…» без прошлого ответа — документ по имени
    func testFixFindsDocumentByNameInRequest() async throws {
        let anna = try await indexPassport()
        let session = ChatSession(search: search)
        // Паспорт добавлен давно — «только что загруженный» не сработал бы
        try await Task.sleep(for: .milliseconds(10))

        let proposal = try await ask(session, "в паспорте Анны ошибка в фамилии, правильно Иванчук")
        let (id, key, value) = try XCTUnwrap(fix(in: proposal), proposal.text)
        XCTAssertEqual(id, anna.id)
        XCTAssertEqual(key, FieldKey.fullName)
        XCTAssertEqual(value, "Иванчук Анна Сергеевна")
    }
}
