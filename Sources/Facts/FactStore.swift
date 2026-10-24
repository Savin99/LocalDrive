import Foundation
import Observation
import os
import UIKit

extension Notification.Name {
    /// Хранилище заменено резервной копией: всё, что читалось из него, надо
    /// перечитать. Шлёт `BackupManager.restore`
    static let vaultDidRestore = Notification.Name("LocalDrive.vaultDidRestore")
}

// Карточки хранятся одним файлом `facts.json` в корне хранилища — рядом с
// vault.json. Поэтому они попадают в зашифрованную копию сами (копия берёт
// всё, что лежит в Vault), а запись идёт так же, как у остальных файлов:
// атомарно и с защитой `.completeFileProtection`. Значения в журнал не пишутся
@MainActor
@Observable
final class FactStore {
    static let fileName = "facts.json"

    /// Сначала недавно изменённые
    private(set) var cards: [FactCard] = []
    /// Счётчик сохранений: по нему главный экран планирует автокопию, как по
    /// `VaultStore.revision`
    private(set) var revision = 0

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let log = Logger(subsystem: "com.ilyaqa.LocalDrive", category: "facts")
    /// Файл есть, но не прочитался: на заблокированном iPhone защищённые файлы
    /// закрыты. Запись поверх стёрла бы карточки, поэтому до успешного чтения
    /// файл не трогаем
    @ObservationIgnored private var isUnreadable = false
    /// Пишется только в init, читается в deinit — вне главного актора
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    private struct Payload: Codable {
        var version: Int
        var cards: [FactCard]
    }

    init(rootURL: URL) {
        fileURL = rootURL.appendingPathComponent(Self.fileName)
        try? FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        load()

        let center = NotificationCenter.default
        // После восстановления из копии файл другой — перечитываем сами,
        // экрану восстановления не нужно знать о карточках
        observers.append(center.addObserver(forName: .vaultDidRestore, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        // Запуск в фоне при заблокированном экране: файл закрыт, читаем,
        // как только iPhone разблокируют
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isUnreadable else { return }
                self.reload()
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Изменения

    /// Карточка с тем же id заменяется: агент мог прислать её повторно
    func add(_ card: FactCard) {
        retryReadIfNeeded()
        cards.removeAll { $0.id == card.id }
        cards.append(card)
        commit()
    }

    /// Заменяет карточку с тем же id и отмечает время изменения
    func update(_ card: FactCard) {
        retryReadIfNeeded()
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        var changed = card
        changed.createdAt = cards[index].createdAt
        changed.updatedAt = Date()
        cards[index] = changed
        commit()
    }

    func delete(id: UUID) {
        retryReadIfNeeded()
        guard cards.contains(where: { $0.id == id }) else { return }
        cards.removeAll { $0.id == id }
        commit()
    }

    func card(id: UUID) -> FactCard? {
        cards.first { $0.id == id }
    }

    // MARK: - Поиск

    /// Карточки по запросу «дом Камилы», сначала лучшие. Пустой запрос — все
    func search(_ query: String) -> [FactCard] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return cards }
        return FactSearch.matches(query, in: cards).map(\.card)
    }

    /// То же с полями, о которых спросили: их подсвечивает `FactCardView`
    func matches(_ query: String) -> [FactSearch.Match] {
        FactSearch.matches(query, in: cards)
    }

    // MARK: - Диск

    /// Перечитать с диска — после восстановления из копии
    func reload() {
        cards = []
        load()
        revision &+= 1
    }

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            isUnreadable = false
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            isUnreadable = true
            log.error("facts.json is not readable yet: \(String(describing: type(of: error)), privacy: .public)")
            return
        }
        isUnreadable = false
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            cards = sorted(payload.cards)
            log.info("Loaded \(payload.cards.count, privacy: .public) fact cards")
        } catch {
            // Испорченный файл откладываем рядом, а не затираем: его можно
            // разобрать вручную, и он уйдёт в резервную копию
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = fileURL.deletingLastPathComponent()
                .appendingPathComponent("facts.damaged-\(stamp).json")
            try? fm.moveItem(at: fileURL, to: aside)
            log.error("facts.json could not be decoded, moved aside")
        }
    }

    private func retryReadIfNeeded() {
        if isUnreadable { load() }
    }

    private func commit() {
        cards = sorted(cards)
        revision &+= 1
        save()
    }

    private func save() {
        guard !isUnreadable else {
            log.error("facts.json is still unreadable, skipping write")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Payload(version: 1, cards: cards))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            log.error("Saving facts failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func sorted(_ cards: [FactCard]) -> [FactCard] {
        cards.sorted { $0.updatedAt > $1.updatedAt }
    }
}
