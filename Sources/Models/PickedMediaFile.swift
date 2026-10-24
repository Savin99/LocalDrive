import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Фото или видео из галереи — файлом во временной папке, а не данными в
/// памяти. Раньше выбор грузился как `Data`: видео целиком ложилось в память,
/// а если оригинал ещё в iCloud и не скачался, `try?` молча давал nil — файл
/// пропускался, а приложение всё равно отвечало «успех». Владелец 24.10.2026:
/// «нажимаю плюсик — из галереи не добавляется». Теперь каждая неудача видна
struct PickedMediaFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        // Файл системы живёт только до выхода из обработчика — копируем сразу
        FileRepresentation(importedContentType: .item) { received in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PickedMedia", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMediaFile(url: copy)
        }
    }

    /// Выбранное в галерее — файлами с именами «Фото 2026-10-24 18.05.12.heic»
    /// (у видео — «Видео …»). `failed` — сколько не удалось получить
    @MainActor
    static func load(_ items: [PhotosPickerItem], stamp: Date = Date()) async -> (files: [URL], failed: Int) {
        var files: [URL] = []
        var failed = 0
        for (index, item) in items.enumerated() {
            do {
                guard let picked = try await item.loadTransferable(type: PickedMediaFile.self) else {
                    failed += 1
                    continue
                }
                let ext = picked.url.pathExtension.isEmpty
                    ? (item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg")
                    : picked.url.pathExtension
                let isVideo = UTType(filenameExtension: ext)?.conforms(to: .audiovisualContent) == true
                // Секунда на файл: у снимков одной серии имена не совпадают
                let date = nameFormatter.string(from: stamp.addingTimeInterval(Double(index)))
                let named = picked.url.deletingLastPathComponent()
                    .appendingPathComponent("\(isVideo ? "Видео" : "Фото") \(date).\(ext.lowercased())")
                try FileManager.default.moveItem(at: picked.url, to: named)
                files.append(named)
            } catch {
                failed += 1
            }
        }
        return (files, failed)
    }

    /// Временные копии больше не нужны: файл уже в хранилище или во вложениях
    static func cleanUp(_ files: [URL]) {
        for file in files {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}
