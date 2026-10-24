import Foundation

// Куда положить вложение без облака. Тот же разбор, что у индекса: текст и тип
// документа. Паспорт идёт туда, где уже лежат паспорта; иначе — в папку, чьё
// название встречается в имени файла или тексте; иначе — во «Входящие».
// Имя удостоверения — по типу и владельцу: «Паспорт РФ — Иванов И. И.»
@MainActor
struct FilePlacementAdvisor {
    let store: VaultStore
    let search: SearchService

    /// Папка для того, что не удалось разложить
    static let inboxFolderName = "Входящие"

    func suggest(for attachment: ChatAttachment) async -> FileProposal {
        await Self.suggest(for: attachment, store: store, search: search)
    }

    static func suggest(for attachment: ChatAttachment, store: VaultStore, search: SearchService) async -> FileProposal {
        let placement = await place(attachment, store: store, search: search)
        return FileProposal(summary: placement.headline, actions: [placement.action])
    }

    /// Ответ чата на вложения без облака: одно предложение на все файлы
    func localReply(for attachments: [ChatAttachment]) async -> ChatReply {
        guard !attachments.isEmpty else {
            return ChatReply(text: "Пришлите файл — подскажу, куда его положить.", cards: [])
        }
        var placements: [Placement] = []
        for attachment in attachments {
            placements.append(await Self.place(attachment, store: store, search: search))
        }
        let proposal = FileProposal(
            summary: placements.count == 1
                ? placements[0].headline
                : "Разложить \(pluralize(placements.count, "файл", "файла", "файлов"))",
            actions: placements.map(\.action)
        )
        // Строки действий — в карточке, текст ответа их не повторяет
        let text = "Предлагаю так. Ничего не изменится, пока вы не нажмёте «Выполнить»:"
        return ChatReply(text: text, cards: [.proposal(proposal)])
    }

    // MARK: - Разбор

    struct Placement {
        let action: FileProposal.Action
        /// «скан.jpg» — паспорт РФ → «Паспорта», как «Паспорт РФ — Иванов И. И»
        let line: String
        /// Заголовок карточки: что это за файл. Куда его положить, видно в строке действия
        let headline: String
    }

    static func place(_ attachment: ChatAttachment, store: VaultStore, search: SearchService) async -> Placement {
        let extracted = (try? await DocumentTextExtractor.extract(from: attachment.url)) ?? .empty
        let analysis = DocumentAnalyzer.analyze(extracted)
        let text = extracted.pages.map(\.text).joined(separator: "\n")

        var target: FolderTarget?
        var reason = ""
        if analysis.type != .other, let folder = await folderOfType(analysis.type, store: store, search: search) {
            target = .existing(folder.id)
            reason = analysis.type.spokenTitle
        }
        if target == nil, let folder = folderNamed(in: attachment.name + "\n" + String(text.prefix(4000)), store: store) {
            target = .existing(folder.id)
        }
        let destination: FolderTarget = target
            ?? FileProposalBuilder.visibleFolder(named: inboxFolderName, store: store).map { FolderTarget.existing($0.id) }
            ?? .new(name: inboxFolderName)

        let name = documentName(for: attachment, analysis: analysis)
        var line = "«\(attachment.name)»"
        if !reason.isEmpty { line += " — \(reason)" }
        line += " → «\(FileProposalBuilder.folderTitle(destination, store: store))»"
        if let name { line += " как «\((name as NSString).deletingPathExtension)»" }
        let headline = reason.isEmpty ? "Куда положить файл" : "Похоже на \(reason)"
        return Placement(
            action: .saveAttachment(attachmentID: attachment.id, folder: destination, name: name),
            line: line,
            headline: headline
        )
    }

    /// Папка, где больше всего документов этого типа. Индекс знает только папки,
    /// доступные для поиска, — суперскрытая сюда не попадёт
    static func folderOfType(_ type: DocumentType, store: VaultStore, search: SearchService) async -> VaultFolder? {
        let documents = await search.documents(ofTypes: [type])
        let counts = Dictionary(grouping: documents, by: \.folderID).mapValues(\.count)
        return counts.sorted { $0.value > $1.value }
            .compactMap { store.folder(by: $0.key) }
            .first { $0.isIndexable }
    }

    /// Папка, чьё название встречается в имени файла или тексте: «Договор
    /// аренды.pdf» → «Договоры». Сравнение по основам слов
    static func folderNamed(in text: String, store: VaultStore) -> VaultFolder? {
        let stems = Set(SearchText.tokens(in: text).map(\.stem).filter { $0.count >= 3 })
        guard !stems.isEmpty else { return nil }
        var best: (folder: VaultFolder, score: Int)?
        for folder in store.folders where folder.isIndexable && folder.name != inboxFolderName {
            let words = SearchText.tokens(in: folder.name).map(\.stem).filter { $0.count >= 3 }
            let score = words.filter(stems.contains).count
            if score > 0, score > (best?.score ?? 0) { best = (folder, score) }
        }
        return best?.folder
    }

    /// «Паспорт РФ — Иванов И. И.jpg»: у удостоверения с владельцем имя по
    /// типу и ФИО. Остальное сохраняется под своим именем
    static func documentName(for attachment: ChatAttachment, analysis: DocumentAnalysis) -> String? {
        guard analysis.type.isPersonal,
              let owner = analysis.fields.first(where: { $0.key == FieldKey.fullName })?.value,
              !owner.isEmpty else { return nil }
        let country = analysis.fields.first { $0.key == FieldKey.country }?.value
        var short = ChatRouter.shortName(owner)
        // Точка инициала слилась бы с точкой расширения
        while short.hasSuffix(".") { short.removeLast() }
        let base = "\(analysis.type.title(country: country)) — \(short)"
        let ext = (attachment.name as NSString).pathExtension
        return ext.isEmpty ? base : "\(base).\(ext)"
    }
}
