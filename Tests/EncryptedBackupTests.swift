import XCTest
@testable import LocalDrive

final class EncryptedBackupTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var vault: URL!
    private var backups: URL!
    private let engine = EncryptedBackupEngine()

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("EncryptedBackupTests-\(UUID().uuidString)", isDirectory: true)
        vault = root.appendingPathComponent("Vault", isDirectory: true)
        backups = root.appendingPathComponent("Backups", isDirectory: true)
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        root = nil
        vault = nil
        backups = nil
    }

    func testBackupRoundTripIncludesHiddenFeedMetadata() throws {
        let folder = vault.appendingPathComponent("folder", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("metadata".utf8).write(to: vault.appendingPathComponent("vault.json"))
        try Data("feed".utf8).write(to: folder.appendingPathComponent(".feed.json"))
        try Data([0, 1, 2, 3, 4]).write(to: folder.appendingPathComponent("photo.bin"))
        let key = Data((0..<32).map(UInt8.init))

        _ = try engine.createBackup(vaultURL: vault, backupRootURL: backups, keyData: key)
        try fm.removeItem(at: vault)
        _ = try engine.restoreLatest(backupRootURL: backups, vaultURL: vault, keyData: key)

        XCTAssertEqual(try Data(contentsOf: vault.appendingPathComponent("vault.json")), Data("metadata".utf8))
        XCTAssertEqual(try Data(contentsOf: vault.appendingPathComponent("folder/.feed.json")), Data("feed".utf8))
        XCTAssertEqual(try Data(contentsOf: vault.appendingPathComponent("folder/photo.bin")), Data([0, 1, 2, 3, 4]))
    }

    // Регрессия: «Файлы» помечают папки, скопированные из iCloud Drive, как
    // скрытые. Такие копии перечислялись как отсутствующие, и восстановление
    // подхватывало более старую версию либо не находило ничего
    func testHiddenPackagesAreStillListed() throws {
        let key = Data(repeating: 5, count: 32)
        try Data("first".utf8).write(to: vault.appendingPathComponent("vault.json"), options: .atomic)
        let older = try engine.createBackup(vaultURL: vault, backupRootURL: backups, keyData: key)
        Thread.sleep(forTimeInterval: 0.01)
        try Data("second".utf8).write(to: vault.appendingPathComponent("vault.json"), options: .atomic)
        let newer = try engine.createBackup(vaultURL: vault, backupRootURL: backups, keyData: key)

        let newerPackage = backups.appendingPathComponent(
            "backup-\(newer.id.uuidString).\(EncryptedBackupEngine.packageExtension)",
            isDirectory: true
        )
        var resourceValues = URLResourceValues()
        resourceValues.isHidden = true
        var hiddenPackage = newerPackage
        try hiddenPackage.setResourceValues(resourceValues)

        let listed = try engine.listBackups(at: backups)
        XCTAssertEqual(listed.map(\.id), [newer.id, older.id], "Скрытая копия пропала из списка")

        try fm.removeItem(at: vault)
        let restored = try engine.restoreLatest(backupRootURL: backups, vaultURL: vault, keyData: key)
        XCTAssertEqual(restored.id, newer.id, "Восстановилась не самая свежая копия")
        XCTAssertEqual(try Data(contentsOf: vault.appendingPathComponent("vault.json")), Data("second".utf8))
    }

    func testWrongRecoveryKeyDoesNotReplaceExistingVault() throws {
        try Data("original".utf8).write(to: vault.appendingPathComponent("vault.json"))
        let correctKey = Data(repeating: 7, count: 32)
        let wrongKey = Data(repeating: 9, count: 32)
        _ = try engine.createBackup(vaultURL: vault, backupRootURL: backups, keyData: correctKey)
        try Data("new local data".utf8).write(to: vault.appendingPathComponent("vault.json"))

        XCTAssertThrowsError(
            try engine.restoreLatest(backupRootURL: backups, vaultURL: vault, keyData: wrongKey)
        )
        XCTAssertEqual(try Data(contentsOf: vault.appendingPathComponent("vault.json")), Data("new local data".utf8))
    }

    func testOnlyThreeLatestVersionsRemain() throws {
        let key = Data(repeating: 3, count: 32)
        for index in 0..<5 {
            try Data("version \(index)".utf8).write(to: vault.appendingPathComponent("vault.json"), options: .atomic)
            _ = try engine.createBackup(vaultURL: vault, backupRootURL: backups, keyData: key)
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertEqual(try engine.listBackups(at: backups).count, 3)
    }

    func testCanRestoreSelectedOlderVersion() throws {
        let key = Data(repeating: 4, count: 32)
        try Data("first".utf8).write(to: vault.appendingPathComponent("vault.json"), options: .atomic)
        let first = try engine.createBackup(vaultURL: vault, backupRootURL: backups, keyData: key)
        Thread.sleep(forTimeInterval: 0.01)
        try Data("second".utf8).write(to: vault.appendingPathComponent("vault.json"), options: .atomic)
        _ = try engine.createBackup(vaultURL: vault, backupRootURL: backups, keyData: key)

        _ = try engine.restore(first, backupRootURL: backups, vaultURL: vault, keyData: key)

        XCTAssertEqual(try Data(contentsOf: vault.appendingPathComponent("vault.json")), Data("first".utf8))
    }

    func testRecoveryCodeParserAcceptsFormatting() throws {
        let raw = Data((0..<32).map(UInt8.init))
        let compact = raw.base64EncodedString()
            .replacingOccurrences(of: "+", with: "~")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let formatted = stride(from: 0, to: compact.count, by: 4).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: min(4, compact.count - offset))
            return String(compact[start..<end])
        }.joined(separator: "-")

        XCTAssertEqual(try RecoveryKeyStore.keyData(from: formatted), raw)
    }
}
