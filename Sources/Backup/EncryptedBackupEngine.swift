import CryptoKit
import Foundation

struct BackupSummary: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let encryptedBytes: Int64
    let schemaVersion: Int
}

enum BackupEngineError: LocalizedError {
    case noBackups
    case damagedBackup
    case unsafePath
    case wrongRecoveryCode

    var errorDescription: String? {
        switch self {
        case .noBackups:
            "Резервные копии LocalDrive не найдены."
        case .damagedBackup:
            "Резервная копия повреждена или загружена не полностью."
        case .unsafePath:
            "Резервная копия содержит недопустимый путь."
        case .wrongRecoveryCode:
            "Код не подходит к этой резервной копии."
        }
    }
}

struct EncryptedBackupEngine {
    static let folderName = "LocalDrive Backups"
    static let packageExtension = "ldbackup"

    private struct Manifest: Codable {
        let schemaVersion: Int
        let createdAt: Date
        let files: [Entry]
    }

    private struct Entry: Codable {
        let relativePath: String
        let blobName: String
    }

    private let fm = FileManager.default
    private let chunkSize = 1024 * 1024
    private let magic = Data("LDBK1".utf8)

    func createBackup(vaultURL: URL, backupRootURL: URL, keyData: Data, keepVersions: Int = 3) throws -> BackupSummary {
        guard keyData.count == 32 else { throw RecoveryKeyError.invalidCode }
        try fm.createDirectory(at: backupRootURL, withIntermediateDirectories: true)

        let summaryID = UUID()
        let createdAt = Date()
        let staging = backupRootURL.appendingPathComponent(".staging-\(summaryID.uuidString)", isDirectory: true)
        let final = backupRootURL.appendingPathComponent("backup-\(summaryID.uuidString).\(Self.packageExtension)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            let blobs = staging.appendingPathComponent("blobs", isDirectory: true)
            try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
            let key = SymmetricKey(data: keyData)
            let sourceFiles = try regularFiles(below: vaultURL)
            var entries: [Entry] = []
            var encryptedBytes: Int64 = 0

            for source in sourceFiles {
                let relative = try relativePath(of: source, below: vaultURL)
                let blobName = "\(UUID().uuidString).enc"
                let destination = blobs.appendingPathComponent(blobName)
                try encryptFile(source, to: destination, key: key, aad: Data(relative.utf8))
                encryptedBytes += Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                entries.append(Entry(relativePath: relative, blobName: blobName))
            }

            let manifest = Manifest(schemaVersion: 1, createdAt: createdAt, files: entries)
            let manifestData = try JSONEncoder().encode(manifest)
            let manifestPlain = fm.temporaryDirectory.appendingPathComponent("LocalDrive-manifest-\(UUID().uuidString).tmp")
            let manifestEncrypted = staging.appendingPathComponent("manifest.enc")
            defer { try? fm.removeItem(at: manifestPlain) }
            try manifestData.write(to: manifestPlain, options: [.atomic, .completeFileProtection])
            try encryptFile(manifestPlain, to: manifestEncrypted, key: key, aad: Data("manifest".utf8))
            try fm.removeItem(at: manifestPlain)
            encryptedBytes += Int64((try? manifestEncrypted.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

            let summary = BackupSummary(
                id: summaryID,
                createdAt: createdAt,
                encryptedBytes: encryptedBytes,
                schemaVersion: 1
            )
            let info = try JSONEncoder().encode(summary)
            try info.write(to: staging.appendingPathComponent("info.json"), options: [.atomic, .completeFileProtection])
            try fm.moveItem(at: staging, to: final)
            try pruneBackups(in: backupRootURL, keeping: max(1, keepVersions))
            return summary
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    func listBackups(at backupRootURL: URL) throws -> [BackupSummary] {
        guard fm.fileExists(atPath: backupRootURL.path) else { return [] }
        // Без .skipsHiddenFiles: «Файлы» ставят флаг Hidden на папки,
        // скопированные из iCloud Drive, и такие копии переставали находиться.
        // Лишнее отсеивает фильтр по расширению пакета ниже
        let packages = try fm.contentsOfDirectory(
            at: backupRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        return packages.compactMap { package in
            guard package.pathExtension == Self.packageExtension,
                  let data = try? Data(contentsOf: package.appendingPathComponent("info.json")),
                  let summary = try? JSONDecoder().decode(BackupSummary.self, from: data) else { return nil }
            return summary
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func restoreLatest(backupRootURL: URL, vaultURL: URL, keyData: Data) throws -> BackupSummary {
        let summaries = try listBackups(at: backupRootURL)
        guard let summary = summaries.first else { throw BackupEngineError.noBackups }
        return try restore(summary, backupRootURL: backupRootURL, vaultURL: vaultURL, keyData: keyData)
    }

    func restore(_ summary: BackupSummary, backupRootURL: URL, vaultURL: URL, keyData: Data) throws -> BackupSummary {
        let package = backupRootURL.appendingPathComponent("backup-\(summary.id.uuidString).\(Self.packageExtension)", isDirectory: true)
        let manifestEncrypted = package.appendingPathComponent("manifest.enc")
        guard fm.fileExists(atPath: manifestEncrypted.path) else { throw BackupEngineError.damagedBackup }

        let restoreRoot = vaultURL.deletingLastPathComponent()
            .appendingPathComponent(".Vault-restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: restoreRoot, withIntermediateDirectories: true)

        do {
            let key = SymmetricKey(data: keyData)
            let manifestPlain = restoreRoot.appendingPathComponent("manifest.json")
            do {
                try decryptFile(manifestEncrypted, to: manifestPlain, key: key, aad: Data("manifest".utf8))
            } catch is CryptoKitError {
                throw BackupEngineError.wrongRecoveryCode
            } catch BackupEngineError.wrongRecoveryCode {
                throw BackupEngineError.wrongRecoveryCode
            }

            let manifestData = try Data(contentsOf: manifestPlain)
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            guard manifest.schemaVersion == 1 else { throw BackupEngineError.damagedBackup }
            try fm.removeItem(at: manifestPlain)

            for entry in manifest.files {
                let relative = try validatedRelativePath(entry.relativePath)
                let source = package.appendingPathComponent("blobs", isDirectory: true).appendingPathComponent(entry.blobName)
                guard fm.fileExists(atPath: source.path) else { throw BackupEngineError.damagedBackup }
                let destination = restoreRoot.appendingPathComponent(relative)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try decryptFile(source, to: destination, key: key, aad: Data(relative.utf8))
                } catch is CryptoKitError {
                    throw BackupEngineError.wrongRecoveryCode
                }
                try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            }

            let oldVault = vaultURL.deletingLastPathComponent()
                .appendingPathComponent(".Vault-old-\(UUID().uuidString)", isDirectory: true)
            if fm.fileExists(atPath: vaultURL.path) {
                try fm.moveItem(at: vaultURL, to: oldVault)
            }
            do {
                try fm.moveItem(at: restoreRoot, to: vaultURL)
                try? fm.removeItem(at: oldVault)
            } catch {
                if fm.fileExists(atPath: oldVault.path), !fm.fileExists(atPath: vaultURL.path) {
                    try? fm.moveItem(at: oldVault, to: vaultURL)
                }
                throw error
            }
            return summary
        } catch {
            try? fm.removeItem(at: restoreRoot)
            throw error
        }
    }

    func deleteAllBackups(at backupRootURL: URL) throws {
        guard fm.fileExists(atPath: backupRootURL.path) else { return }
        for url in try fm.contentsOfDirectory(at: backupRootURL, includingPropertiesForKeys: nil) {
            if url.pathExtension == Self.packageExtension || url.lastPathComponent.hasPrefix(".staging-") {
                try fm.removeItem(at: url)
            }
        }
    }

    private func regularFiles(below root: URL) throws -> [URL] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
            } else if values.isRegularFile == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func relativePath(of url: URL, below root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { throw BackupEngineError.unsafePath }
        return try validatedRelativePath(String(filePath.dropFirst(rootPath.count)))
    }

    private func validatedRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/") else { throw BackupEngineError.unsafePath }
        let components = NSString(string: path).pathComponents
        guard !components.contains(".."), !components.contains("."), !components.contains("/") else {
            throw BackupEngineError.unsafePath
        }
        return components.joined(separator: "/")
    }

    private func pruneBackups(in root: URL, keeping limit: Int) throws {
        let summaries = try listBackups(at: root)
        for summary in summaries.dropFirst(limit) {
            let package = root.appendingPathComponent("backup-\(summary.id.uuidString).\(Self.packageExtension)", isDirectory: true)
            try? fm.removeItem(at: package)
        }
    }

    private func encryptFile(_ source: URL, to destination: URL, key: SymmetricKey, aad: Data) throws {
        fm.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        try output.write(contentsOf: magic)
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            let sealed = try AES.GCM.seal(chunk, using: key, authenticating: aad)
            guard let combined = sealed.combined else { throw BackupEngineError.damagedBackup }
            try output.write(contentsOf: lengthPrefix(combined.count))
            try output.write(contentsOf: combined)
        }
        try output.write(contentsOf: lengthPrefix(0))
        try output.synchronize()
    }

    private func decryptFile(_ source: URL, to destination: URL, key: SymmetricKey, aad: Data) throws {
        fm.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        let header = try input.read(upToCount: magic.count) ?? Data()
        guard header == magic else { throw BackupEngineError.damagedBackup }
        while true {
            let prefix = try input.read(upToCount: 4) ?? Data()
            guard prefix.count == 4 else { throw BackupEngineError.damagedBackup }
            let length = Int(prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            if length == 0 { break }
            guard length <= chunkSize + 64 else { throw BackupEngineError.damagedBackup }
            let combined = try input.read(upToCount: length) ?? Data()
            guard combined.count == length else { throw BackupEngineError.damagedBackup }
            do {
                let sealed = try AES.GCM.SealedBox(combined: combined)
                let plain = try AES.GCM.open(sealed, using: key, authenticating: aad)
                try output.write(contentsOf: plain)
            } catch {
                throw BackupEngineError.wrongRecoveryCode
            }
        }
        try output.synchronize()
    }

    private func lengthPrefix(_ value: Int) -> Data {
        let number = UInt32(value)
        return Data([
            UInt8((number >> 24) & 0xFF),
            UInt8((number >> 16) & 0xFF),
            UInt8((number >> 8) & 0xFF),
            UInt8(number & 0xFF),
        ])
    }
}
