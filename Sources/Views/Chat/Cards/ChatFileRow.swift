import SwiftUI

// Строка файла в ответе: превью самого документа, подпись и папка-источник.
// Одна и та же у списка найденных файлов, у кнопки «открыть документ», у
// источника под ответом и в подвале карточки полей — файл в чате везде
// выглядит одинаково и узнаётся по виду, а не только по названию
// (docs/design.md, «Чат: файлы, источник и следующий шаг»)
struct ChatFileRow: View {
    /// nil — документ ещё ищется или папку скрыли: место превью пустое
    let document: ChatDocument?
    /// Подпись модели («Чек продукты — 03.10.2026»); без неё — имя файла
    var title: String?
    /// Вторая строка модели; без неё — папка, где лежит файл
    var secondary: String?
    /// В карточке, у которой папка уже в шапке, вторая строка не нужна
    var showsFolder = true

    static let thumbnailSide: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                // Название — целиком, в две строки: рядом с превью текст
                // иначе сжимался в одну с многоточием и терял имя владельца
                Text(title ?? document?.file.displayName ?? "Документ")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if showsFolder, let document {
                    ChatFolderChip(folder: document.folder)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        let side = Self.thumbnailSide
        if let document {
            FileThumbnail(file: document.file, accent: Theme.ink, size: CGSize(width: side, height: side), cornerRadius: 10)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.well)
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        }
    }
}

/// Строка файла по id документа из ответа модели. Документ — только из
/// папок, доступных поиску: скрытая папка превью не покажет
struct ChatFileRowLoader: View {
    let documentID: Int64
    var title: String?
    var secondary: String?

    @Environment(SearchService.self) private var search
    @State private var document: ChatDocument?

    var body: some View {
        ChatFileRow(document: document, title: title, secondary: secondary)
            .task(id: documentID) {
                document = await ChatSources.documents([documentID], search: search).first
            }
    }
}

/// Документы, из которых взят ответ: строками под ответом, тап открывает
/// сам файл. Того, что уже показано карточкой или списком, здесь нет
struct ChatSourcesView: View {
    let documents: [ChatDocument]

    @Environment(\.chatActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(documents.enumerated()), id: \.element.id) { index, document in
                if index > 0 {
                    Divider().padding(.leading, ChatFileRow.thumbnailSide + 12)
                }
                Button {
                    actions.open(document.file, documents.map(\.file), nil)
                } label: {
                    ChatFileRow(document: document)
                        .padding(.vertical, documents.count > 1 ? 8 : 0)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Источник: \(document.file.displayName), папка «\(document.folder.name)»")
                .accessibilityIdentifier("chatSource")
            }
        }
        .chatCardSurface()
    }
}

enum ChatSources {
    @MainActor
    static func documents(_ ids: [Int64], search: SearchService) async -> [ChatDocument] {
        let cards = await ChatCardResolver(search: search).resolve(ids.map { .document(documentID: $0) })
        return cards.compactMap { card in
            if case .document(let document) = card.content { return document }
            return nil
        }
    }

    /// Документы, которые ответ уже показывает блоками: карточкой, списком,
    /// кнопкой. Источник под ответом их не повторяет
    static func shown(in blocks: [GenUIBlock]) -> Set<Int64> {
        var found = Set<Int64>()
        func walk(_ json: JSONValue) {
            switch json {
            case .object(let object):
                if let id = GenUIDocumentID.parse(object["document_id"]) { found.insert(id) }
                for id in object["document_ids"]?.array ?? [] {
                    if let id = GenUIDocumentID.parse(id) { found.insert(id) }
                }
                object.values.forEach(walk)
            case .array(let items):
                items.forEach(walk)
            default:
                break
            }
        }
        blocks.forEach { walk($0.raw) }
        return found
    }

    /// Ответ сам спрашивает — вариантами (действие ask) или формой: это ещё
    /// не ответ из документа, источнику и следующим вопросам под ним не место
    static func asks(in blocks: [GenUIBlock]) -> Bool {
        func walk(_ json: JSONValue) -> Bool {
            switch json {
            case .object(let object):
                if object["type"]?.string == "form" { return true }
                if let action = object["action"]?.object, (action["kind"]?.string ?? action["type"]?.string) == GenUIAction.Kind.ask.rawValue {
                    return true
                }
                return object.values.contains(where: walk)
            case .array(let items):
                return items.contains(where: walk)
            default:
                return false
            }
        }
        return blocks.contains { walk($0.raw) }
    }
}

/// Что спросить дальше: вопросы модели под последним ответом, тап отправляет
/// вопрос. Контурные капсулы — тише вариантов уточнения: это не обязательный шаг
struct ChatFollowUps: View {
    let questions: [String]

    @Environment(\.chatActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                Button {
                    actions.send(question)
                } label: {
                    Text(question)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.leading)
                        .chatButtonPadding()
                        .secondaryCapsule()
                        // Капсула — 38 pt, как у чипов уточнения; область
                        // касания — 44 pt
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chatFollowUp-\(index)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatFollowUps")
    }
}
