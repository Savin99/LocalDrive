import XCTest
@testable import LocalDrive

// Паспорт РФ, снятый двумя разворотами: на одном фото, ФИО и MRZ, на другом
// «Паспорт выдан» без имени и номера. Для чата это один документ: данные с
// обоих разворотов, каждая карточка ведёт к своему файлу.
//
// MRZ — те же независимо посчитанные векторы, что в ChatRouterTests. Разворот
// «кем выдан» распознаётся как паспорт РФ по подписям («паспорт», «российская
// федерация», «выдан»), а имени и номера «NN NN NNNNNN» на нём нет
@MainActor
final class ChatSpreadsTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var search: SearchService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDriveSpreadsTests-\(UUID().uuidString)", isDirectory: true)
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
        /// Разворот с фото: только MRZ, без «кем выдан». Савин Илья Андреевич,
        /// 4601 123456, выдан 20.06.2010, код 770-120, родился 01.01.1990
        static let photoSpread = """
        РОССИЙСКАЯ ФЕДЕРАЦИЯ
        PNRUSSAVIN<<IL98<ANDREEVI3<<<<<<<<<<<<<<<<<<
        4601234561RUS9001011M<<<<<<<1100620770120<34
        """

        /// Разворот «Паспорт выдан» того же паспорта: ни имени, ни номера
        static let issuedSpread = """
        РОССИЙСКАЯ ФЕДЕРАЦИЯ
        Паспорт выдан ГУ МВД РОССИИ ПО Г. МОСКВЕ
        Дата выдачи 20.06.2010 Код подразделения 770-120
        Личная подпись
        """

        /// Такой же безымянный разворот, но другого паспорта и в другой папке
        static let otherIssuedSpread = """
        РОССИЙСКАЯ ФЕДЕРАЦИЯ
        Паспорт выдан ОТДЕЛОМ УФМС РОССИИ ПО ТВЕРСКОЙ ОБЛ.
        Дата выдачи 15.03.2012 Код подразделения 690-001
        Личная подпись
        """

        /// SAVIN ILIA, 72 1234567, родился 01.01.1990, действует до 15.03.2031
        static let savinTravel = """
        ЗАГРАНИЧНЫЙ ПАСПОРТ
        P<RUSSAVIN<<ILIA<<<<<<<<<<<<<<<<<<<<<<<<<<<<
        7212345673RUS9001011M3103153<<<<<<<<<<<<<<02
        """
    }

    /// Поля разворота с фото — всё из MRZ, в порядке карточки
    private let photoKeys = [
        FieldKey.fullName, FieldKey.seriesNumber, FieldKey.issueDate,
        FieldKey.departmentCode, FieldKey.birthDate, FieldKey.sex,
    ]

    @discardableResult
    private func makeFolder(_ name: String) throws -> VaultFolder {
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

    private func keys(of document: StoredDocument) async -> Set<String> {
        let fields = await search.fields(for: [document.id])
        return Set(fields[document.id]?.map(\.key) ?? [])
    }

    private func reply(_ text: String) async -> ChatReply {
        await ChatRouter(search: search).reply(to: text).0
    }

    private func day(_ text: String) throws -> Date {
        try XCTUnwrap(DocumentValidity.parse(text))
    }

    /// Два разворота одного паспорта в папке «Паспорта». Проверяет и сами
    /// фикстуры: если анализатор прочтёт их иначе, тесты ниже потеряют смысл
    private func makeSpreads() async throws -> (photo: StoredDocument, page: StoredDocument) {
        let folder = try makeFolder("Паспорта")
        add(Fixture.photoSpread, named: "паспорт фото.txt", to: folder)
        add(Fixture.issuedSpread, named: "паспорт выдан.txt", to: folder)
        await indexAll()
        let photo = try await document(named: "паспорт фото.txt")
        let page = try await document(named: "паспорт выдан.txt")
        XCTAssertEqual(photo.type, .passportRU)
        XCTAssertEqual(page.type, .passportRU, "разворот «кем выдан» должен распознаться как паспорт РФ")
        let photoAvailable = await keys(of: photo)
        XCTAssertEqual(photoAvailable, Set(photoKeys))
        let pageAvailable = await keys(of: page)
        XCTAssertEqual(pageAvailable, [FieldKey.issuedBy, FieldKey.issueDate, FieldKey.departmentCode],
                       "на развороте «кем выдан» не должно быть ни имени, ни номера")
        return (photo, page)
    }

    // MARK: - Развороты

    func testSpreadsAnswerAsOneDocument() async throws {
        let (photo, page) = try await makeSpreads()

        let answer = await reply("мой паспорт")
        XCTAssertEqual(answer.cards, [
            .fields(documentID: photo.id, keys: photoKeys),
            // Со второго разворота — только то, чего нет на первом
            .fields(documentID: page.id, keys: [FieldKey.issuedBy]),
            .fileList(documentIDs: [photo.id, page.id]),
        ])
        XCTAssertFalse(answer.cards.contains { if case .clarify = $0 { true } else { false } },
                       "развороты одного паспорта — не повод переспрашивать")
    }

    /// Каждая карточка ведёт к своему файлу, значения — из базы
    func testSpreadCardsResolveToTheirOwnFiles() async throws {
        let (photo, page) = try await makeSpreads()

        let answer = await reply("мой паспорт")
        let resolved = await ChatCardResolver(search: search).resolve(answer.cards)
        XCTAssertEqual(resolved.count, 3)
        guard resolved.count == 3 else { return }

        guard case .fields(let first, let firstKeys) = resolved[0].content else {
            return XCTFail("первая карточка — не поля: \(resolved[0].card)")
        }
        XCTAssertEqual(first.id, photo.id)
        XCTAssertEqual(first.file.name, "паспорт фото.txt")
        XCTAssertEqual(firstKeys, photoKeys)
        XCTAssertEqual(first.field(FieldKey.seriesNumber)?.value, "4601 123456")

        guard case .fields(let second, let secondKeys) = resolved[1].content else {
            return XCTFail("вторая карточка — не поля: \(resolved[1].card)")
        }
        XCTAssertEqual(second.id, page.id)
        XCTAssertEqual(second.file.name, "паспорт выдан.txt")
        XCTAssertEqual(secondKeys, [FieldKey.issuedBy])
        XCTAssertEqual(second.field(FieldKey.issuedBy)?.value, "ГУ МВД РОССИИ ПО Г. МОСКВЕ")

        guard case .fileList(let files) = resolved[2].content else {
            return XCTFail("третья карточка — не список файлов: \(resolved[2].card)")
        }
        XCTAssertEqual(files.map(\.file.name), ["паспорт фото.txt", "паспорт выдан.txt"])
    }

    func testIssuedByComesFromTheSecondSpreadOnly() async throws {
        let (_, page) = try await makeSpreads()

        let answer = await reply("кем выдан паспорт")
        XCTAssertEqual(answer.cards, [.fields(documentID: page.id, keys: [FieldKey.issuedBy])])
    }

    /// Срок считается по развороту с датой рождения: 45 лет — 01.01.2035
    func testExpiryUsesThePhotoSpread() async throws {
        let (photo, _) = try await makeSpreads()

        let answer = await reply("когда менять паспорт")
        XCTAssertEqual(answer.cards, [.expiry(documentID: photo.id)])

        let resolved = await ChatCardResolver(search: search).resolve(answer.cards)
        guard let content = resolved.first?.content, case .expiry(let document, let validity) = content else {
            return XCTFail("карточка срока не собралась: \(resolved.map(\.card))")
        }
        XCTAssertEqual(document.id, photo.id)
        XCTAssertEqual(validity.status, .replaceAtAge(45, try day("01.01.2035")))
    }

    // MARK: - Фильтр по имени

    /// Фильтр по фамилии оставляет безымянный разворот из той же папки,
    /// а такой же разворот из другой папки к ответу не прицепляет
    func testNameFilterKeepsAnonymousSpreadFromSameFolder() async throws {
        let (photo, page) = try await makeSpreads()
        let elsewhere = try makeFolder("Старое")
        add(Fixture.otherIssuedSpread, named: "чужой разворот.txt", to: elsewhere)
        await indexAll()
        let stranger = try await document(named: "чужой разворот.txt")
        XCTAssertEqual(stranger.type, .passportRU)
        let strangerKeys = await keys(of: stranger)
        XCTAssertFalse(strangerKeys.contains(FieldKey.fullName))

        let answer = await reply("паспорт савина илья")
        XCTAssertEqual(answer.cards, [
            .fields(documentID: photo.id, keys: photoKeys),
            .fields(documentID: page.id, keys: [FieldKey.issuedBy]),
            .fileList(documentIDs: [photo.id, page.id]),
        ])
        XCTAssertFalse(answer.cards.flatMap(\.documentIDs).contains(stranger.id),
                       "разворот из другой папки не принадлежит этому паспорту")
    }

    // MARK: - Развороты и загранпаспорт

    /// «Мой паспорт» — данные паспорта РФ с обоих разворотов, а загранпаспорт
    /// того же человека — чипом в конце ответа
    func testSpreadsWithTravelPassportOfferTravelChip() async throws {
        let (photo, page) = try await makeSpreads()
        let folder = try XCTUnwrap(store.folders.first { $0.name == "Паспорта" })
        add(Fixture.savinTravel, named: "загран.txt", to: folder)
        await indexAll()
        let travel = try await document(named: "загран.txt")
        XCTAssertEqual(travel.type, .passportIntl)

        let answer = await reply("мой паспорт")
        XCTAssertEqual(Array(answer.cards.prefix(3)), [
            .fields(documentID: photo.id, keys: photoKeys),
            .fields(documentID: page.id, keys: [FieldKey.issuedBy]),
            .fileList(documentIDs: [photo.id, page.id]),
        ])
        XCTAssertEqual(answer.cards.count, 4)
        guard case .clarify(_, let options) = answer.cards.last else {
            return XCTFail("ждали чип загранпаспорта в конце: \(answer.cards)")
        }
        // Человек один — имя на чипе не нужно
        XCTAssertEqual(options.map(\.title), ["Загранпаспорт"])

        let followUp = await reply(options[0].query)
        guard case .fields(let chosen, _) = followUp.cards.first else {
            return XCTFail("чип не выбрал загранпаспорт: \(followUp.cards)")
        }
        XCTAssertEqual(chosen, travel.id)
    }
}
