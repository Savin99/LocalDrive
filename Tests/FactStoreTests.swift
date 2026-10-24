import XCTest
@testable import LocalDrive

@MainActor
final class FactStoreTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUp() async throws {
        root = fm.temporaryDirectory.appendingPathComponent("FactStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let root { try? fm.removeItem(at: root) }
        root = nil
    }

    private var fileURL: URL { root.appendingPathComponent(FactStore.fileName) }

    private func kamila(updatedAt: Date = Date()) -> FactCard {
        FactCard(
            title: "Дом Камилы",
            symbol: "house.fill",
            color: "teal",
            items: [
                FactItem(kind: .code, label: "Домофон", value: "45К1234"),
                FactItem(kind: .number, label: "Этаж", value: "3"),
                FactItem(kind: .address, label: "Адрес", value: "Москва, Тверская 5"),
            ],
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - Изменения

    func testAddUpdateDeleteAndLookup() throws {
        let store = FactStore(rootURL: root)
        XCTAssertTrue(store.cards.isEmpty)

        let card = kamila()
        store.add(card)
        XCTAssertEqual(store.cards.map(\.id), [card.id])
        XCTAssertEqual(store.card(id: card.id), card)

        // Повторное добавление того же id — замена, а не дубль
        store.add(card)
        XCTAssertEqual(store.cards.count, 1)

        var edited = card
        edited.title = "Квартира Камилы"
        edited.createdAt = Date(timeIntervalSince1970: 0)
        store.update(edited)
        let stored = try XCTUnwrap(store.card(id: card.id))
        XCTAssertEqual(stored.title, "Квартира Камилы")
        XCTAssertEqual(stored.createdAt, card.createdAt, "Дата создания не должна меняться правкой")
        XCTAssertGreaterThanOrEqual(stored.updatedAt, card.updatedAt)

        store.delete(id: card.id)
        XCTAssertNil(store.card(id: card.id))
        XCTAssertTrue(store.cards.isEmpty)
    }

    func testUpdateOfUnknownCardDoesNothing() {
        let store = FactStore(rootURL: root)
        store.update(kamila())
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: fileURL.path))
    }

    func testCardsAreNewestUpdatedFirst() throws {
        let store = FactStore(rootURL: root)
        let old = FactCard(title: "Дача", items: [FactItem(kind: .wifi, label: "Wi-Fi", value: "dacha123")],
                           createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000))
        let new = FactCard(title: "Офис", items: [FactItem(kind: .text, label: "Охрана", value: "пропуск 12")],
                           createdAt: Date(timeIntervalSince1970: 2_000), updatedAt: Date(timeIntervalSince1970: 2_000))
        store.add(old)
        store.add(new)
        XCTAssertEqual(store.cards.map(\.title), ["Офис", "Дача"])

        // Правка поднимает карточку наверх
        store.update(old)
        XCTAssertEqual(store.cards.map(\.title), ["Дача", "Офис"])
    }

    func testRevisionGrowsOnEveryChange() {
        let store = FactStore(rootURL: root)
        let start = store.revision
        let card = kamila()
        store.add(card)
        store.update(card)
        store.delete(id: card.id)
        XCTAssertEqual(store.revision, start + 3)
    }

    // MARK: - Диск

    func testPersistenceRoundTripKeepsEverything() throws {
        let store = FactStore(rootURL: root)
        var card = kamila(updatedAt: Date(timeIntervalSince1970: 1_234_567.891))
        card.items[0].symbol = "bell.fill"
        store.add(card)

        let reopened = FactStore(rootURL: root)
        XCTAssertEqual(reopened.cards, [card], "Карточка после перезапуска должна совпадать до поля и миллисекунды")
    }

    /// Класс защиты файла. Симулятор его не сообщает (замер: nil даже у
    /// файла, записанного с `.completeFileProtection`) — тогда проверка
    /// пропускается, а не считается пройденной
    private func protection(of url: URL) throws -> FileProtectionType? {
        let control = root.appendingPathComponent("control-\(UUID().uuidString)")
        try Data("x".utf8).write(to: control, options: [.atomic, .completeFileProtection])
        defer { try? fm.removeItem(at: control) }
        guard try fm.attributesOfItem(atPath: control.path)[.protectionKey] != nil else {
            throw XCTSkip("Симулятор не сообщает класс защиты файлов — проверяется только на iPhone")
        }
        return try fm.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
    }

    func testFileIsWrittenWithCompleteProtection() throws {
        let store = FactStore(rootURL: root)
        store.add(kamila())
        // Пропуск бросается вне XCTAssertEqual: внутри он считался бы ошибкой
        let protection = try protection(of: fileURL)
        XCTAssertEqual(protection, .complete)
    }

    func testFileHasVersionedFormat() throws {
        // Файл — JSON с версией: формат можно развивать без потери данных
        let store = FactStore(rootURL: root)
        store.add(kamila())
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, 1)
        XCTAssertEqual((object?["cards"] as? [Any])?.count, 1)
    }

    func testReloadPicksUpChangesMadeOnDisk() throws {
        let store = FactStore(rootURL: root)
        store.add(kamila())
        // Другая копия хранилища пишет в тот же файл — как восстановление из копии
        let other = FactStore(rootURL: root)
        other.delete(id: try XCTUnwrap(other.cards.first).id)

        XCTAssertEqual(store.cards.count, 1)
        store.reload()
        XCTAssertTrue(store.cards.isEmpty)
    }

    func testRestoreNotificationReloadsCards() throws {
        let store = FactStore(rootURL: root)
        let other = FactStore(rootURL: root)
        other.add(kamila())
        XCTAssertTrue(store.cards.isEmpty)

        NotificationCenter.default.post(name: .vaultDidRestore, object: nil)
        XCTAssertEqual(store.cards.map(\.title), ["Дом Камилы"])
    }

    func testDamagedFileIsMovedAsideNotOverwritten() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{ испорчено".utf8).write(to: fileURL)

        let store = FactStore(rootURL: root)
        XCTAssertTrue(store.cards.isEmpty)
        let names = try fm.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("facts.damaged-") }, "Испорченный файл должен остаться рядом: \(names)")

        store.add(kamila())
        XCTAssertEqual(FactStore(rootURL: root).cards.count, 1)
    }

    func testUnknownKindAndMissingFieldsDecodeGracefully() throws {
        let json = """
        {"version": 1, "cards": [{"title": "Машина", "items": [
            {"kind": "licensePlate", "label": "Номер", "value": "А123ВС77"},
            {"label": "Парковка", "value": "-2, место 14"}
        ]}]}
        """
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)

        let card = try XCTUnwrap(FactStore(rootURL: root).cards.first)
        XCTAssertEqual(card.title, "Машина")
        XCTAssertEqual(card.symbol, FactCard.defaultSymbol)
        XCTAssertEqual(card.color, FactCard.defaultColor)
        XCTAssertEqual(card.items.map(\.kind), [.text, .text])
        XCTAssertEqual(card.items.map(\.value), ["А123ВС77", "-2, место 14"])
    }

    // MARK: - Резервная копия

    /// facts.json лежит в Vault, поэтому копия берёт его сама. После
    /// восстановления уведомление перечитывает карточки
    func testEncryptedBackupRoundTripsFacts() throws {
        let vault = root.appendingPathComponent("Vault", isDirectory: true)
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let key = Data((0..<32).map(UInt8.init))
        let engine = EncryptedBackupEngine()

        let store = FactStore(rootURL: vault)
        let card = kamila(updatedAt: Date(timeIntervalSince1970: 5_000))
        store.add(card)
        _ = try engine.createBackup(vaultURL: vault, backupRootURL: backups, keyData: key)

        // После копии карточку удалили — восстановление должно её вернуть
        store.delete(id: card.id)
        XCTAssertTrue(store.cards.isEmpty)

        _ = try engine.restoreLatest(backupRootURL: backups, vaultURL: vault, keyData: key)
        NotificationCenter.default.post(name: .vaultDidRestore, object: nil)

        XCTAssertEqual(store.cards, [card])
    }
}
