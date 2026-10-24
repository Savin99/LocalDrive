import SwiftUI

// Несколько файлов — сеткой превью, как в папке. Тап открывает просмотр,
// в котором можно листать весь список
struct FileListCardView: View {
    let documents: [ChatDocument]

    @Environment(\.chatActions) private var actions

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pluralize(documents.count, "файл", "файла", "файлов"))
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.ink)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(documents) { document in
                    Button {
                        actions.open(document.file, documents.map(\.file), nil)
                    } label: {
                        cell(document)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(document.file.displayName), папка «\(document.folder.name)»")
                    .accessibilityIdentifier("chatFile")
                }
            }
        }
        .chatCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatCard-fileList")
    }

    private func cell(_ document: ChatDocument) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // Квадрат задаёт пустая подложка, превью ложится в неё оверлеем.
            // Иначе горизонтальное фото разворота распирало ячейку и
            // наползало на соседнюю; size нужен только для запроса превью
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    FileThumbnail(
                        file: document.file,
                        accent: Theme.ink,
                        size: CGSize(width: 96, height: 96),
                        cornerRadius: 12,
                        fills: true
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if let badge = document.file.extensionBadge {
                    TypeBadge(text: badge)
                        .padding(5)
                }
            }

            // Без расширения и в две строки — иначе имя рвётся посередине
            Text(document.file.displayName)
                .font(.caption)
                .foregroundStyle(Theme.ink)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
        .contentShape(Rectangle())
    }
}
