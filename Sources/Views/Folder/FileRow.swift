import SwiftUI

// Строка списка: небольшая миниатюра слева, имя и метаданные справа
struct FileRow: View {
    let file: VaultFile
    let accent: Color

    var body: some View {
        HStack(spacing: 14) {
            FileThumbnail(
                file: file,
                accent: accent,
                size: CGSize(width: 44, height: 44),
                cornerRadius: 11
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(.subheadline, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(file.sizeText) · \(dateText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var dateText: String {
        file.addedAt.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
