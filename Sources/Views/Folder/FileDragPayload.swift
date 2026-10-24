import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Собственный тип: имена файлов не должны утекать перетаскиванием
    /// в чужие приложения, а сторонний текст — попадать в наш порядок
    static let localDriveFileName = UTType(exportedAs: "com.ilyaqa.LocalDrive.file-name")
}

struct FileDragPayload: Codable, Transferable, Hashable {
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .localDriveFileName)
    }
}
