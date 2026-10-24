import SwiftUI

// Строка списка: небольшая миниатюра слева, имя и метаданные справа
struct FileRow: View {
    let file: VaultFile
    let accent: Color
    /// В режимах сортировки по дате файла показываем именно её, а не дату добавления
    var showsContentDate = false
    /// В режиме выбора строка файл не открывает — стрелка обещала бы переход
    var showsChevron = true

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
                Text("\(RussianFormat.size(file.size)) · \(dateText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var dateText: String {
        let date = showsContentDate ? file.contentDate : file.addedAt
        return date.formatted(.dateTime.day().month(.abbreviated).year().locale(RussianFormat.locale))
    }
}
