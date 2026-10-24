import Foundation

// Шаги облачного чата для экрана: какой инструмент модель зовёт и с чем —
// «Ищу в документах: прописка», «Смотрю страницы: Паспорт РФ — Трошина О. В.».
// Описание строится из тех же аргументов, с которыми инструмент выполнится.
// Номеров здесь нет: в аргументах их не бывает, а цифры длиннее трёх закрываются
@MainActor
enum CloudChatSteps {
    static func step(for name: String, arguments: CloudJSON, search: SearchService, facts: FactStore? = nil) async -> (ChatStep.Kind, String)? {
        switch name {
        case "search_documents":
            let query = masked(arguments["query"]?.string ?? "")
            let owner = arguments["owner"]?.string.map { " · \($0)" } ?? ""
            return (.search, query.isEmpty ? "Ищу в документах" + owner : "Ищу в документах: «\(query)»" + owner)
        case "list_documents":
            let type = arguments["type"]?.string.flatMap(DocumentType.init(rawValue:))
            let folder = folderName(arguments["folder_id"]?.string, search: search)
            let what = [type?.title, folder.map { "папка «\($0)»" }].compactMap { $0 }.joined(separator: ", ")
            return (.files, what.isEmpty ? "Перебираю документы" : "Перебираю документы: \(what)")
        case "list_folders":
            return (.folders, "Смотрю папки")
        case "list_files":
            let folder = folderName(arguments["folder_id"]?.string, search: search)
            return (.files, folder.map { "Перебираю файлы папки «\($0)»" } ?? "Перебираю файлы")
        case "get_document":
            return (.open, await documentTitle(arguments["id"]?.string, search: search).map { "Открываю: \($0)" } ?? "Открываю документ")
        case "view_document":
            return (.look, await documentTitle(arguments["id"]?.string, search: search).map { "Смотрю страницы: \($0)" } ?? "Смотрю страницы документа")
        case "list_expiring":
            return (.expiry, "Проверяю сроки документов")
        case "show_cards":
            return (.open, "Готовлю карточки")
        case "propose_file_actions":
            return (.propose, "Готовлю, куда разложить файлы")
        case "find_fact_cards":
            let query = masked(arguments["query"]?.string ?? "")
            return (.search, query.isEmpty ? "Смотрю «Карточки»" : "Ищу в «Карточках»: «\(query)»")
        case "show_fact_card":
            let title = arguments["id"]?.string.flatMap { CloudChatFactTools.decodeID($0) }.flatMap { facts?.card(id: $0)?.title }
            return (.open, title.map { "Открываю карточку «\($0)»" } ?? "Открываю карточку")
        case "propose_fact_card":
            let title = arguments["title"]?.string ?? ""
            return (.propose, title.isEmpty ? "Раскладываю по полям" : "Раскладываю по полям: «\(title)»")
        default:
            return nil
        }
    }

    /// «Паспорт РФ — Трошина О. В.» или имя файла
    private static func documentTitle(_ raw: String?, search: SearchService) async -> String? {
        guard let raw, let id = ChatCard.decodeID(raw), let document = await search.documents(ids: [id]).first else { return nil }
        let fields = await search.fields(for: [id])[id] ?? []
        let owner = fields.first { $0.key == FieldKey.fullName }?.value ?? ""
        let country = fields.first { $0.key == FieldKey.country }?.value
        let title = document.type == .other ? masked(document.fileName) : document.type.title(country: country)
        return owner.isEmpty ? title : "\(title) — \(ChatRouter.shortName(owner))"
    }

    private static func folderName(_ raw: String?, search: SearchService) -> String? {
        guard let id = raw.flatMap(UUID.init(uuidString:)) else { return nil }
        return search.searchableFolders.first { $0.id == id }?.name
    }

    private static func masked(_ text: String) -> String {
        text.replacingOccurrences(of: #"\d{4,}"#, with: "…", options: .regularExpression)
    }
}
