import UIKit
import UniformTypeIdentifiers

// Файлы хранилища и системный буфер обмена
enum FileClipboard {
    /// Что принимает «Вставить». Кнопка сама гаснет, когда в буфере ничего
    /// такого нет; ссылки и свои внутренние типы отсеивает импорт
    static let pasteTypes: [UTType] = [.image, .audiovisualContent, .pdf, .data]

    /// Через 10 минут система сама очищает буфер: документ не должен лежать
    /// там, когда о нём уже забыли
    static let lifetime: TimeInterval = 10 * 60

    /// Файлы — в буфер. Не только для этого iPhone: через универсальный буфер
    /// обмена их можно вставить и на Mac
    @discardableResult
    static func copy(_ files: [VaultFile]) -> Bool {
        let providers = files.compactMap(provider(for:))
        guard !providers.isEmpty else { return false }
        UIPasteboard.general.setItemProviders(
            providers,
            localOnly: false,
            expirationDate: Date().addingTimeInterval(lifetime)
        )
        return true
    }

    /// Без подсказки имени получатель назвал бы файл по типу — «PDF document.pdf».
    /// Имя с расширением: система не допишет его второй раз
    static func provider(for file: VaultFile) -> NSItemProvider? {
        let provider = NSItemProvider(contentsOf: file.url)
        provider?.suggestedName = file.name
        return provider
    }
}
