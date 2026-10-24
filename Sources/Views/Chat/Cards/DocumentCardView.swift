import SwiftUI

// Один документ: превью, название, папка и одно-два ключевых поля.
// Кнопки ведут к самому файлу — у ответа всегда есть источник
struct DocumentCardView: View {
    let document: ChatDocument

    @Environment(\.chatActions) private var actions
    @Environment(\.chatRevealsSensitive) private var revealed

    /// Номер — под той же маской, что и в карточке полей
    private var keyFields: [DocumentField] {
        [FieldKey.seriesNumber, FieldKey.fullName].compactMap { document.field($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // Заглушка превью нейтральная: цвет папки — только в точке источника
                FileThumbnail(
                    file: document.file,
                    accent: Theme.ink,
                    size: CGSize(width: 60, height: 60),
                    cornerRadius: 12
                )
                .overlay(alignment: .bottomLeading) {
                    // Для документа без типа расширение подсказывает, что откроется
                    if document.type == .other, let badge = document.file.extensionBadge {
                        TypeBadge(text: badge)
                            .padding(4)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(document.file.displayName)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 5) {
                        ChatFolderChip(folder: document.folder)
                        if document.type != .other {
                            Text("· \(document.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    ForEach(keyFields, id: \.key) { field in
                        Text("\(FieldKey.title(field.key)): \(FieldMask.display(field, revealed: revealed))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button {
                    actions.open(document.file, [document.file], nil)
                } label: {
                    Label("Открыть", systemImage: "arrow.up.forward.app")
                        .chatButtonPadding()
                        .primaryCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chatOpen")

                ShareLink(item: document.file.url) {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                        .chatButtonPadding()
                        .secondaryCapsule()
                }
                .buttonStyle(.plain)
            }
            .font(.subheadline.weight(.semibold))
        }
        .chatCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatCard-document")
    }
}
