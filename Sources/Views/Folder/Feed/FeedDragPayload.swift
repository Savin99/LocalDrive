import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Собственный тип: иначе лента подсвечивает линию вставки при перетаскивании
    /// любого текста из чужого приложения
    static let feedBlock = UTType(exportedAs: "com.ilyaqa.LocalDrive.feed-block")
}

enum FeedDragPayload: Codable, Transferable, Hashable {
    /// Один или несколько блоков целиком (второй случай — режим выделения)
    case blocks([UUID])
    /// Отдельное фото, вытащенное из ряда
    case media(blockID: UUID, fileName: String)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .feedBlock)
    }

    var blockIDs: Set<UUID> {
        switch self {
        case .blocks(let ids): Set(ids)
        case .media(let blockID, _): [blockID]
        }
    }
}
