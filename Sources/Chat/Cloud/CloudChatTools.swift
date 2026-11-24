import Foundation

// Инструменты облачного чата на iPhone. Модели видны только папки, доступные
// для поиска: суперскрытых для неё не существует. Серия и номер документа
// уходят только маской «•••• ••••85»; из выдержек текста вырезаются строки
// MRZ и сами номера. Изменения файлов модель только предлагает — решает человек
@MainActor
final class CloudChatTools {
    private let search: SearchService
    private let proposals: FileProposalMaker?
    /// Вложения текущего чата: для инструмента view_attachment
    var inbox: ChatAttachmentInbox?
    /// «Карточки»: найти, показать, предложить новую (CloudChatFactTools)
    var facts: FactStore?
    /// Номера и коды документов, которые проходили через инструменты: в
    /// ответе модели они закрываются маской, даже если она их угадала
    private var sensitive: Set<String> = []

    init(search: SearchService, proposals: FileProposalMaker?, inbox: ChatAttachmentInbox? = nil) {
        self.search = search
        self.proposals = proposals
        self.inbox = inbox
    }

    func forgetSensitive() {
        sensitive = []
    }

    func run(_ name: String, arguments: CloudJSON, cards: inout [ChatCard]) async -> CloudJSON {
        if CloudChatFactTools.names.contains(name) {
            return CloudChatFactTools.run(name, arguments: arguments, facts: facts, cards: &cards)
        }
        switch name {
        case "search_documents": return await searchDocuments(arguments)
        case "list_documents": return await listDocuments(arguments)
        case "list_folders": return listFolders()
        case "list_files": return listFiles(arguments)
        case "get_document": return await getDocument(arguments)
        case "list_expiring": return await listExpiring(arguments)
        case "view_document": return await viewDocument(arguments)
        case "view_attachment": return await viewAttachment(arguments)
        case "show_cards": return await showCards(arguments, cards: &cards)
        case "propose_file_actions": return await proposeFileActions(arguments, cards: &cards)
        case "propose_field_fix": return await proposeFieldFix(arguments, cards: &cards)
        default: return ["error": .string("Нет такого инструмента: \(name)")]
        }
    }

    // MARK: - Чтение

    private func searchDocuments(_ arguments: CloudJSON) async -> CloudJSON {
        let query = arguments["query"]?.string ?? ""
        let types = Set((arguments["types"]?.array ?? []).compactMap { $0.string.flatMap(DocumentType.init(rawValue:)) })
        let owner = arguments["owner"]?.string.map { SearchText.tokens(in: $0).map(\.word) } ?? []
        // Слово запроса и его синонимы: «регистрация» найдёт «место жительства»
        var results: [SearchResult] = []
        var seen = Set<Int64>()
        for variant in CloudChatSynonyms.variants(of: query) {
            for result in await search.search(variant, limit: 20) {
                guard let id = result.documentID, seen.insert(id).inserted else { continue }
                results.append(result)
            }
        }
        let ids = results.compactMap(\.documentID)
        let fields = await search.fields(for: ids)
        let metadata = await search.metadata(for: ids)
        var documents: [CloudJSON] = []
        // Владелец сужает поиск, но не теряет найденное: у свидетельства о
        // браке и договора поля «владелец» нет (стенд агента, 24.10.2026)
        let owned = owner.isEmpty ? [] : results.filter { result in
            result.documentID.map { id in ChatRouter.nameMatches(owner, owner: fields[id]?.first { $0.key == FieldKey.fullName }?.value ?? "") } ?? false
        }
        let filterByOwner = !owned.isEmpty
        for result in results {
            guard let id = result.documentID else { continue }
            if !types.isEmpty, !types.contains(result.type) { continue }
            let name = fields[id]?.first { $0.key == FieldKey.fullName }?.value ?? ""
            if filterByOwner, !ChatRouter.nameMatches(owner, owner: name) { continue }
            remember(fields[id] ?? [])
            var summary = summary(id: id, title: result.file.name, type: result.type, folder: result.folder, owner: name)
            if let snippet = result.snippet { summary["snippet"] = .string(clean(String(snippet.characters), fields: fields[id] ?? [])) }
            if let meta = metadata[id] { summary["meta"] = describe(meta) }
            documents.append(.object(summary))
        }
        guard documents.isEmpty else { return ["documents": .array(documents)] }
        // Пусто по тексту — это ещё не «нет»: штамп мог не распознаться
        return ["documents": [], "hint": "По тексту ничего не нашлось. Не отвечай «не нашёл»: посмотри страницы вероятного документа через view_document — штампы и отметки бывают только на скане."]
    }

    /// Страницы документа картинками: модель смотрит скан сама.
    /// Если передан id вложения чата (`a1`…), прозрачно открывает вложение.
    private func viewDocument(_ arguments: CloudJSON) async -> CloudJSON {
        if let raw = arguments["id"]?.string, raw.hasPrefix("a"), inbox != nil {
            return await viewAttachment(arguments)
        }
        guard let raw = arguments["id"]?.string, let id = ChatCard.decodeID(raw),
              let document = await search.documents(ids: [id]).first,
              let folder = search.searchableFolders.first(where: { $0.id == document.folderID }),
              let url = search.fileURL(for: document) else {
            return ["error": "Документ не найден"]
        }
        let fields = await search.fields(for: [id])[id] ?? []
        remember(fields)
        let pages = arguments["pages"]?.array?.compactMap(\.int)
        let owner = fields.first { $0.key == FieldKey.fullName }?.value ?? ""
        var result = summary(id: id, title: document.fileName, type: document.type, folder: folder, owner: owner)
        if let spreads = await spreads(of: document) { result["other_pages"] = spreads }
        let loaded = await Task.detached(priority: .userInitiated) { CloudChatPages.load(url, pages: pages) }.value
        guard let loaded, !loaded.images.isEmpty else {
            // Текстовый файл — его текст
            if let text = await search.documentText(id: id) {
                result["text"] = .string(String(clean(text, fields: fields).prefix(3000)))
            }
            result["note"] = "У файла нет страниц-картинок — его текст выше. Прописка, отметки о браке и детях бывают на других разворотах: смотри other_pages и search_documents."
            return .object(result)
        }
        result["pages_total"] = .number(Double(loaded.total))
        result["pages_shown"] = .array(loaded.images.map { .number(Double($0.number)) })
        result["note"] = "Страницы — картинками ниже. Номера документа в ответе не пиши."
        result["_images"] = .array(loaded.images.map { .string($0.jpeg.base64EncodedString()) })
        return .object(result)
    }

    /// Страницы и текст вложения текущего чата (`a1`, `a2`…): модель может
    /// пересмотреть присланный файл или полистать следующие страницы PDF.
    private func viewAttachment(_ arguments: CloudJSON) async -> CloudJSON {
        guard let inbox else { return ["error": "Вложения чата недоступны"] }
        guard let id = arguments["id"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return ["error": "Укажи id вложения, например a1"]
        }
        guard let item = inbox.item(id) else {
            if let folder = inbox.savedFolders[id] {
                let name = inbox.names[id] ?? id
                return ["error": .string("Вложение «\(name)» уже сохранено в папку «\(folder)» — найди его среди документов хранилища.")]
            }
            let available = inbox.items.map { "\($0.id) («\($0.name)»)" }.joined(separator: ", ")
            return ["error": .string(available.isEmpty ? "Вложение \(id) не найдено." : "Вложение \(id) не найдено. Доступные вложения чата: \(available).")]
        }
        let pages = arguments["pages"]?.array?.compactMap(\.int)
        var result: [String: CloudJSON] = [
            "id": .string(item.id),
            "name": .string(item.name),
        ]
        guard let loaded = await inbox.modelPages(id, pages: pages) else {
            result["note"] = "Этот формат файла нельзя показать картинкой или прочитать как текст."
            return .object(result)
        }
        result["pages_total"] = .number(Double(loaded.totalPages))
        if let text = loaded.text, !text.isEmpty {
            result["text"] = .string(text)
        }
        if !loaded.images.isEmpty {
            result["pages_shown"] = .array(loaded.images.map { .number(Double($0.number)) })
            result["note"] = "Страницы вложения — картинками ниже."
            result["_images"] = .array(loaded.images.map { .string($0.jpeg.base64EncodedString()) })
        }
        return .object(result)
    }

    private func listDocuments(_ arguments: CloudJSON) async -> CloudJSON {
        let type = arguments["type"]?.string.flatMap(DocumentType.init(rawValue:))
        let folderID = arguments["folder_id"]?.string.flatMap(UUID.init(uuidString:))
        let folders = Dictionary(uniqueKeysWithValues: search.searchableFolders.map { ($0.id, $0) })
        let stored = await search.documents(ofTypes: type.map { [$0] } ?? DocumentType.allCases)
            .filter { folderID == nil || $0.folderID == folderID }
            .prefix(40)
        let fields = await search.fields(for: stored.map(\.id))
        let documents: [CloudJSON] = stored.compactMap { document in
            guard let folder = folders[document.folderID] else { return nil }
            remember(fields[document.id] ?? [])
            let owner = fields[document.id]?.first { $0.key == FieldKey.fullName }?.value ?? ""
            return .object(summary(id: document.id, title: document.fileName, type: document.type, folder: folder, owner: owner))
        }
        return ["documents": .array(documents)]
    }

    /// Папки с деревом: `parent_id` — внутри какой лежит, `path` — путь от
    /// верхнего уровня. Родитель папки, доступной для поиска, тоже доступен:
    /// скрытая папка выше в путь не попадает, её поддерево модели не видно
    private func listFolders() -> CloudJSON {
        let folders: [CloudJSON] = search.searchableFolders.map { folder in
            [
                "id": .string(folder.id.uuidString),
                "name": .string(folder.name),
                "parent_id": folder.parentID.map { CloudJSON.string($0.uuidString) } ?? CloudJSON.null,
                "path": .string(search.path(of: folder)),
                "files": .number(Double(search.files(in: folder).count)),
            ]
        }
        return ["folders": .array(folders)]
    }

    private func listFiles(_ arguments: CloudJSON) -> CloudJSON {
        guard let id = arguments["folder_id"]?.string.flatMap(UUID.init(uuidString:)),
              let folder = search.searchableFolders.first(where: { $0.id == id }) else {
            return ["error": "Нет такой папки"]
        }
        let files: [CloudJSON] = search.files(in: folder).prefix(60).map { file in
            ["name": .string(file.name), "size": .number(Double(file.size)),
             "added": .string(ISO8601DateFormatter().string(from: file.addedAt))]
        }
        return ["folder": .string(search.path(of: folder)), "files": .array(files)]
    }

    private func getDocument(_ arguments: CloudJSON) async -> CloudJSON {
        guard let raw = arguments["id"]?.string, let id = ChatCard.decodeID(raw),
              let document = await search.documents(ids: [id]).first,
              let folder = search.searchableFolders.first(where: { $0.id == document.folderID }) else {
            return ["error": "Документ не найден"]
        }
        let fields = await search.fields(for: [id])[id] ?? []
        remember(fields)
        var values: [String: CloudJSON] = [:]
        for field in fields {
            values[field.key] = .string(field.key == FieldKey.seriesNumber ? FieldMask.masked(field.value) : field.value)
        }
        let owner = fields.first { $0.key == FieldKey.fullName }?.value ?? ""
        var result = summary(id: id, title: document.fileName, type: document.type, folder: folder, owner: owner)
        result["fields"] = .object(values)
        if let spreads = await spreads(of: document) { result["other_pages"] = spreads }
        if let meta = await search.metadata(for: [id])[id] {
            result["meta"] = describe(meta)
        }
        if let text = await search.documentText(id: id) {
            result["text"] = .string(String(clean(text, fields: fields).prefix(1200)))
        }
        return .object(result)
    }

    /// Что скоро истекает: срок из метаданных (valid_until) и сроки паспортов
    private func listExpiring(_ arguments: CloudJSON) async -> CloudJSON {
        let horizon = arguments["before"]?.string.flatMap(DocumentReadingMerge.date)
            ?? Calendar(identifier: .gregorian).date(byAdding: .year, value: 1, to: Date())
            ?? Date()
        let folders = Dictionary(uniqueKeysWithValues: search.searchableFolders.map { ($0.id, $0) })
        let stored = await search.documents(ofTypes: DocumentType.allCases)
        let ids = stored.map(\.id)
        let fields = await search.fields(for: ids)
        let metadata = await search.metadata(for: ids)
        var expiring: [(Date, CloudJSON)] = []
        for document in stored {
            guard let folder = folders[document.folderID] else { continue }
            let values = Dictionary((fields[document.id] ?? []).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            let until = metadata[document.id]?.validUntil.nilIfEmpty
            guard let date = DocumentValidity.of(type: document.type, fields: values, validUntil: until).date, date <= horizon else { continue }
            remember(fields[document.id] ?? [])
            var entry = summary(id: document.id, title: metadata[document.id]?.title.nilIfEmpty ?? document.fileName,
                                type: document.type, folder: folder, owner: values[FieldKey.fullName] ?? "")
            entry["valid_until"] = .string(DocumentAnalyzer.format(Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)))
            expiring.append((date, .object(entry)))
        }
        return ["documents": .array(expiring.sorted { $0.0 < $1.0 }.prefix(30).map(\.1))]
    }

    /// Другие развороты того же документа: документы того же вида в той же
    /// папке — паспорт РФ хранится разворотами, прописка — на своём
    private func spreads(of document: StoredDocument) async -> CloudJSON? {
        let others = await search.documents(ofTypes: [document.type])
            .filter { $0.folderID == document.folderID && $0.id != document.id }
            .prefix(8)
        guard !others.isEmpty else { return nil }
        return .array(others.map { ["id": .string(ChatCard.encodeID($0.id)), "title": .string($0.fileName)] })
    }

    /// Метаданные для модели: номера договоров и полисов — маской, их цифры
    /// закрываются и в ответе
    private func describe(_ meta: DocumentMetadata) -> CloudJSON {
        for identifier in meta.identifiers {
            let digits = identifier.value.filter(\.isNumber)
            if digits.count >= 4 { sensitive.insert(digits) }
        }
        var object: [String: CloudJSON] = [
            "title": .string(meta.title), "summary": .string(meta.summary), "kind": .string(meta.kind),
            "category": .string(meta.category), "tags": .array(meta.tags.map { .string($0) }),
            "people": .array(meta.people.map { ["name": .string($0.name), "role": .string($0.role)] }),
            "organizations": .array(meta.organizations.map { .string($0) }),
            "identifiers": .array(meta.identifiers.map { ["label": .string($0.label), "value": .string(FieldMask.masked($0.value))] }),
            "amounts": .array(meta.amounts.map { ["label": .string($0.label), "value": .string($0.value), "currency": .string($0.currency)] }),
        ]
        if !meta.documentDate.isEmpty { object["document_date"] = .string(meta.documentDate) }
        if !meta.validUntil.isEmpty { object["valid_until"] = .string(meta.validUntil) }
        return .object(object)
    }

    private func summary(id: Int64, title: String, type: DocumentType, folder: VaultFolder, owner: String) -> [String: CloudJSON] {
        var summary: [String: CloudJSON] = [
            "id": .string(ChatCard.encodeID(id)),
            "title": .string(title),
            "type": .string(type.rawValue),
            "folder_id": .string(folder.id.uuidString),
            "folder": .string(search.path(of: folder)),
        ]
        if !owner.isEmpty { summary["owner"] = .string(owner) }
        return summary
    }

    /// Выдержка для модели: без строк MRZ и без номеров документа. Выдержка
    /// поиска — одна строка, где MRZ идёт вперемешку с текстом: построчный
    /// фильтр её пропускал, и номер паспорта уходил модели целиком (нашёл тест
    /// агента 24.10.2026). Поэтому MRZ вырезается и по словам
    private func clean(_ text: String, fields: [DocumentField]) -> String {
        let lines = text.components(separatedBy: .newlines)
            .filter { !MRZNameReader.looksLikeMRZ($0) }
            .map { line in line.split(separator: " ", omittingEmptySubsequences: false).filter { !Self.looksLikeMRZFragment($0) }.joined(separator: " ") }
        let numbers = Set(fields.filter { $0.key == FieldKey.seriesNumber }.map { $0.value.filter(\.isNumber) })
        return CloudChatMask.apply(lines.joined(separator: "\n"), sensitive: numbers)
    }

    /// Кусок машиночитаемой строки: заполнитель «<» или длинное слово из
    /// латиницы и цифр, где цифр не меньше шести
    static func looksLikeMRZFragment(_ word: Substring) -> Bool {
        if word.contains("<") { return true }
        guard word.count >= 10 else { return false }
        let mrz = word.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
        return mrz && word.filter(\.isNumber).count >= 6
    }

    private func remember(_ fields: [DocumentField]) {
        for field in fields where field.key == FieldKey.seriesNumber || field.key == FieldKey.departmentCode {
            let digits = field.value.filter(\.isNumber)
            if digits.count >= 4 { sensitive.insert(digits) }
        }
    }

    func mask(_ text: String) -> String {
        CloudChatMask.apply(text, sensitive: sensitive)
    }

    // MARK: - Карточки и предложения

    /// Карточки из каталога — в том же JSON, что у чата на правилах. Документ
    /// вне разрешённых папок отпадёт при подстановке значений
    private func showCards(_ arguments: CloudJSON, cards: inout [ChatCard]) async -> CloudJSON {
        var shown = 0
        for raw in arguments["cards"]?.array ?? [] {
            guard let card = try? JSONDecoder().decode(ChatCard.self, from: raw.data) else { continue }
            let visible = await search.documents(ids: card.documentIDs)
            guard card.documentIDs.allSatisfy({ id in visible.contains { $0.id == id } }) else { continue }
            cards.append(card)
            shown += 1
        }
        return ["shown": .number(Double(shown))]
    }

    /// Файл можно назвать id документа из описи: {"document_id": "d32"} вместо
    /// папки и точного имени. Модель видит в описи название документа, а не
    /// имя файла, и на стенде агента переносила «Договор аренды квартиры»,
    /// которого как файла нет (24.10.2026)
    private func resolvingDocuments(_ arguments: CloudJSON) async -> CloudJSON {
        func resolve(_ file: CloudJSON) async -> CloudJSON {
            guard let raw = file["document_id"]?.string, let id = ChatCard.decodeID(raw),
                  let document = await search.documents(ids: [id]).first else { return file }
            return ["folder_id": .string(document.folderID.uuidString), "name": .string(document.fileName)]
        }
        guard var object = arguments.object, let actions = arguments["actions"]?.array else { return arguments }
        var resolved: [CloudJSON] = []
        for action in actions {
            guard var fields = action.object else { resolved.append(action); continue }
            if let files = fields["files"]?.array {
                var list: [CloudJSON] = []
                for file in files { list.append(await resolve(file)) }
                fields["files"] = .array(list)
            }
            if let file = fields["file"] { fields["file"] = await resolve(file) }
            resolved.append(.object(fields))
        }
        object["actions"] = .array(resolved)
        return .object(object)
    }

    /// Поправка поля, распознанного с ошибкой: карточка «было → станет».
    /// Поле меняется только по кнопке человека
    private func proposeFieldFix(_ arguments: CloudJSON, cards: inout [ChatCard]) async -> CloudJSON {
        guard let raw = arguments["document_id"]?.string, let id = ChatCard.decodeID(raw),
              await !search.documents(ids: [id]).isEmpty else { return ["error": "Документ не найден"] }
        guard let key = arguments["key"]?.string, FieldKey.order.contains(key) else { return ["error": "Нет такого поля"] }
        // «?», «…» вместо значения — модель его не знает: пусть спросит.
        // Живая проверка 25.10.2026: карточка «станет: ?»
        guard let value = arguments["value"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.contains(where: { $0.isLetter || $0.isNumber }) else {
            return ["error": "Правильное значение неизвестно — спроси человека, как правильно, и не показывай карточку"]
        }
        var normalized = ChatFieldFix.isDate(key) ? (ChatFieldFix.normalizedDate(value) ?? value) : value
        // «Трошкина О. П.», «Ольга Трошкина», «Трошкина» — правка ложится на
        // текущее ФИО: одно новое слово заменяет самое похожее; ни на что не
        // похожее одно слово — фамилия
        if key == FieldKey.fullName,
           let current = await search.fields(for: [id])[id]?.first(where: { $0.key == key })?.value {
            let corrected = ChatFieldFix.correctedName(normalized, current: current)
            if corrected.contains(" ") {
                normalized = corrected
            } else {
                let fix = ChatFieldFix(key: key, namePart: .surname, answer: normalized)
                normalized = fix.resolvedValue(current: current) ?? normalized
            }
        }
        cards.append(.fieldFix(documentID: id, key: key, value: normalized))
        return ["shown": true, "note": "Карточка исправления показана пользователю. Изменение применится, только когда он нажмёт «Принять»."]
    }

    private func proposeFileActions(_ arguments: CloudJSON, cards: inout [ChatCard]) async -> CloudJSON {
        guard let proposals else { return ["error": "Действия с файлами пока недоступны в этой сборке"] }
        do {
            cards.append(try proposals(await resolvingDocuments(arguments).data))
            return ["proposed": true, "note": "Карточка предложения показана пользователю. Ничего не изменится, пока он не нажмёт «Принять». Если есть вопрос по сути или нужно что-то пояснить — напиши ответ пользователю."]
        } catch {
            return ["error": .string("Предложение не собралось: \(error.localizedDescription)")]
        }
    }
}

/// Синонимы понятий документов: штампы пишут по-разному. Запрос ищется и
/// словами каждой группы, где есть его слово
enum CloudChatSynonyms {
    static let groups: [[String]] = [
        ["регистрация", "прописка", "зарегистрирован", "место жительства", "адрес"],
        ["брак", "заключение брака", "семейное положение", "супруг", "супруга"],
        ["дети", "ребёнок", "сведения о детях", "сын", "дочь"],
        ["воинская обязанность", "военный билет", "воинский учёт"],
        ["ранее выданный паспорт", "ранее выданные паспорта"],
        ["группа крови", "резус"],
    ]

    /// Запрос и его варианты по синонимам — без повторов
    static func variants(of query: String) -> [String] {
        let stems = Set(SearchText.tokens(in: query).map(\.stem))
        var result = [query]
        for group in groups where group.contains(where: { term in SearchText.tokens(in: term).contains { stems.contains($0.stem) } }) {
            for term in group where !result.contains(term) { result.append(term) }
        }
        return result
    }
}

/// Номера документов в тексте модели закрываются маской: в ответе их быть не
/// должно, номера показывают карточки. Цифры номера могут идти с пробелами и
/// дефисами — «45 09 123456», «770-120»
enum CloudChatMask {
    static func apply(_ text: String, sensitive: Set<String>) -> String {
        guard !sensitive.isEmpty else { return text }
        var result = text
        for digits in sensitive.sorted(by: { $0.count > $1.count }) {
            let pattern = digits.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"[\s\-–—]?"#)
            guard let regex = try? NSRegularExpression(pattern: "(?<!\\d)\(pattern)(?!\\d)") else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "••••")
        }
        return result
    }
}

// MARK: - Инструкция и инструменты

/// Строгая схема OpenAI (Function calling, strict mode): у каждого объекта
/// additionalProperties: false и все поля в required, а необязательное поле
/// принимает null — тип с «null» в списке, как в примере документации
enum CloudSchema {
    static func strict(_ schema: CloudJSON) -> CloudJSON {
        guard case .object(var object) = schema else { return schema }
        if let properties = object["properties"]?.object {
            let required = Set(object["required"]?.array?.compactMap(\.string) ?? [])
            object["properties"] = .object(properties.mapValues(strict).reduce(into: [:]) { result, entry in
                result[entry.key] = required.contains(entry.key) ? entry.value : nullable(entry.value)
            })
            object["required"] = .array(properties.keys.sorted().map { .string($0) })
            object["additionalProperties"] = false
        }
        if let items = object["items"] { object["items"] = strict(items) }
        return .object(object)
    }

    private static func nullable(_ schema: CloudJSON) -> CloudJSON {
        guard case .object(var object) = schema else { return schema }
        switch object["type"] {
        case .string(let type)?: object["type"] = [.string(type), "null"]
        case .array(let types)? where !types.contains("null"): object["type"] = .array(types + ["null"])
        default: break
        }
        return .object(object)
    }
}

enum CloudChatPrompt {
    static var system: String {
        """
        \(AgentIdentity.instructions)

        Для показа полей документа, файла или уточнения вариантов используй инструмент show_cards (в fields включай все запрошенные поля — серию и номер тоже: карточка закроет их маской). Если документ есть в списке ниже, можно сразу показать его без поиска.
        """
    }

    private static let documentTypes: CloudJSON = .array(DocumentType.allCases.map { .string($0.rawValue) })
    private static let fieldKeys: CloudJSON = .array(FieldKey.order.map { .string($0) })

    /// Инструменты документов и файлов, а за ними — «Карточек»
    static let tools: CloudJSON = .array((documentTools.array ?? []) + CloudChatFactTools.tools)

    private static let documentTools: CloudJSON = [
        [
            "name": "search_documents",
            "description": "Поиск документов по тексту, названию, владельцу. Возвращает id (d…), вид, папку, владельца и выдержку.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Слова для поиска"],
                    "types": ["type": "array", "items": ["type": "string", "enum": documentTypes]],
                    "owner": ["type": "string", "description": "Имя владельца документа"],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "list_documents",
            "description": "Документы одного вида или одной папки.",
            "parameters": [
                "type": "object",
                "properties": [
                    "type": ["type": "string", "enum": documentTypes],
                    "folder_id": ["type": "string"],
                ],
            ],
        ],
        [
            "name": "list_folders",
            "description": "Папки хранилища: id, название, parent_id (внутри какой папки лежит, null — верхний уровень), path (путь «Документы / Паспорта»), сколько файлов.",
            "parameters": ["type": "object", "properties": [:]],
        ],
        [
            "name": "list_files",
            "description": "Файлы папки: имя, размер, когда добавлен.",
            "parameters": [
                "type": "object",
                "properties": ["folder_id": ["type": "string"]],
                "required": ["folder_id"],
            ],
        ],
        [
            "name": "get_document",
            "description": "Поля и выдержка текста документа из хранилища. Серия и номер приходят маской.",
            "parameters": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "id документа, например d42"]],
                "required": ["id"],
            ],
        ],
        [
            "name": "view_document",
            "description": "Посмотреть страницы документа из хранилища (d…) картинками: штампы, отметки, сканы, то, чего нет в тексте. До 4 страниц за вызов. Если передать id вложения чата (a…), откроет вложение.",
            "parameters": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "id документа (d42) или вложения чата (a1)"],
                    "pages": ["type": "array", "items": ["type": "integer"], "description": "Номера страниц с 1; по умолчанию первые 4"],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "view_attachment",
            "description": "Посмотреть страницы и текст файла, присланного пользователем в этот чат (a1, a2…): фото, скриншоты, PDF (до 4 страниц за вызов). Используй, чтобы прочитать, пересмотреть или полистать вложение.",
            "parameters": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "id вложения чата, например a1"],
                    "pages": ["type": "array", "items": ["type": "integer"], "description": "Номера страниц с 1; по умолчанию первые 4"],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "list_expiring",
            "description": "Документы, срок которых истекает до даты (по умолчанию — в ближайший год): паспорта, права, полисы, договоры.",
            "parameters": [
                "type": "object",
                "properties": ["before": ["type": "string", "description": "ДД.ММ.ГГГГ"]],
            ],
        ],
        [
            "name": "show_cards",
            "description": "Показать карточки под ответом. fields — поля документа (keys), document — сам файл, fileList — список файлов (documentIds), snippet — фрагмент текста, clarify — варианты на выбор (options: title, query, documentId), expiry — срок действия.",
            "parameters": [
                "type": "object",
                "properties": [
                    "cards": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "type": ["type": "string", "enum": ["fields", "document", "fileList", "snippet", "clarify", "expiry"]],
                                "documentId": ["type": "string"],
                                "documentIds": ["type": "array", "items": ["type": "string"]],
                                "keys": ["type": "array", "items": ["type": "string", "enum": fieldKeys]],
                                "page": ["type": "integer"],
                                "question": ["type": "string"],
                                "options": [
                                    "type": "array",
                                    "items": [
                                        "type": "object",
                                        "properties": [
                                            "title": ["type": "string"],
                                            "query": ["type": "string"],
                                            "documentId": ["type": "string"],
                                        ],
                                        "required": ["title", "query"],
                                    ],
                                ],
                            ],
                            "required": ["type"],
                        ],
                    ],
                ],
                "required": ["cards"],
            ],
        ],
        [
            "name": "propose_field_fix",
            "description": "Предложить исправление поля документа, распознанного с ошибкой (показывает «было → станет»). Поле меняется только после нажатия «Принять». Если названа одна фамилия/имя/отчество — передай её в value, остальное приложение сохранит из документа. Не вызывай с неизвестным значением.",
            "parameters": [
                "type": "object",
                "properties": [
                    "document_id": ["type": "string", "description": "id документа, например d42"],
                    "key": ["type": "string", "enum": fieldKeys],
                    "value": ["type": "string", "description": "Правильное значение: ФИО полностью или одно исправленное слово (фамилия); дата ДД.ММ.ГГГГ"],
                ],
                "required": ["document_id", "key", "value"],
            ],
        ],
        [
            "name": "propose_file_actions",
            "description": "Предложить действия с файлами: сохранить вложение в папку, перенести, переименовать файл или создать папку. Используй, когда пользователь просит сохранить/разложить файлы или это уместно по контексту; не вызывай автоматически, если человек просит прочитать, проверить или заполнить вложение. Ничего не меняется, пока человек не нажмёт «Принять». Не повторяй отклонённое предложение, пока пользователь не попросит снова.",
            "parameters": [
                "type": "object",
                "properties": [
                    "actions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "action": ["type": "string", "enum": ["save_attachment", "move_files", "rename_file", "create_folder"]],
                                "attachment_id": ["type": "string"],
                                "folder_id": ["type": "string"],
                                "new_folder_name": ["type": "string"],
                                "parent_folder_id": [
                                    "type": "string",
                                    "description": "Для create_folder и new_folder_name: id папки, внутри которой создать новую; без него — на верхнем уровне",
                                ],
                                "name": ["type": "string"],
                                "new_name": ["type": "string"],
                                "file": [
                                    "type": "object",
                                    "properties": ["document_id": ["type": "string", "description": "id документа из описи — вместо папки и имени"],
                                                   "folder_id": ["type": "string"], "name": ["type": "string"]],
                                ],
                                "files": [
                                    "type": "array",
                                    "items": [
                                        "type": "object",
                                        "properties": ["document_id": ["type": "string", "description": "id документа из описи — вместо папки и имени"],
                                                       "folder_id": ["type": "string"], "name": ["type": "string"]],
                                    ],
                                ],
                            ],
                            "required": ["action"],
                        ],
                    ],
                    "summary": ["type": "string", "description": "Одна фраза: что будет сделано"],
                ],
                "required": ["actions", "summary"],
            ],
        ],
    ]
}
