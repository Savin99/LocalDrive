import Foundation
import UniformTypeIdentifiers

/// Куда положить: существующая папка или новая
enum FolderTarget: Hashable, Codable, Sendable {
    case existing(UUID)
    case new(name: String)
}

/// Файл хранилища: папка и имя
struct FileRef: Hashable, Codable, Sendable {
    let folderID: UUID
    let name: String
}

/// Предложение разложить файлы. Его составляет модель или подсказка без сети,
/// а выполняет человек кнопкой «Принять» — до неё в хранилище ничего не меняется
struct FileProposal: Identifiable, Hashable, Codable, Sendable {
    enum Action: Hashable, Codable, Sendable {
        /// Вложение чата — в папку; `name` — новое имя с расширением, nil — исходное
        case saveAttachment(attachmentID: String, folder: FolderTarget, name: String?)
        case moveFiles(files: [FileRef], folder: FolderTarget)
        /// `newName` — без расширения: оно остаётся прежним
        case renameFile(file: FileRef, newName: String)
        case createFolder(name: String)
    }

    let id: UUID
    var summary: String
    var actions: [Action]
    /// Внутри какой папки встаёт новая: имя новой папки в нижнем регистре →
    /// родитель. Новая папка в предложении узнаётся по имени — так же, как
    /// `FolderTarget.new`; без записи она встаёт на верхний уровень. Отдельным
    /// полем, а не в действии: форму действий читает карточка в переписке
    var newFolderParents: [String: UUID]

    init(id: UUID = UUID(), summary: String, actions: [Action], newFolderParents: [String: UUID] = [:]) {
        self.id = id
        self.summary = summary
        self.actions = actions
        self.newFolderParents = newFolderParents
    }

    private enum CodingKeys: String, CodingKey {
        case id, summary, actions, newFolderParents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        summary = try container.decode(String.self, forKey: .summary)
        actions = try container.decode([Action].self, forKey: .actions)
        // Предложения до вложенных папок родителей не знали
        newFolderParents = try container.decodeIfPresent([String: UUID].self, forKey: .newFolderParents) ?? [:]
    }

    /// Родитель новой папки с этим именем; nil — верхний уровень
    func parent(ofNewFolder name: String) -> UUID? {
        newFolderParents[name.lowercased()]
    }

    /// Предложение с другой папкой для всех сохранений и переносов — «Другая папка…»
    func retargeted(to folderID: UUID) -> FileProposal {
        var copy = self
        copy.actions = actions.map { action in
            switch action {
            case .saveAttachment(let id, _, let name): .saveAttachment(attachmentID: id, folder: .existing(folderID), name: name)
            case .moveFiles(let files, _): .moveFiles(files: files.filter { $0.folderID != folderID }, folder: .existing(folderID))
            case .renameFile, .createFolder: action
            }
        }
        return copy
    }

    /// Есть что положить в папку — тогда предлагается выбрать другую
    var placesFiles: Bool {
        actions.contains { action in
            switch action {
            case .saveAttachment, .moveFiles: true
            case .renameFile, .createFolder: false
            }
        }
    }
}

/// Почему предложение нельзя принять или выполнить. Суперскрытая папка для
/// модели и для текста ошибки не существует: «не найдена», как любая чужая
enum FileProposalError: LocalizedError, Equatable {
    case malformed
    case noActions
    case unknownAction(String)
    case missingAttachment(String)
    case missingFolder
    case unknownFolder(String)
    /// Внутри ленты папку не создать: её содержимое — блоки
    case feedParent(String)
    case missingFile(String)
    case fromFeed(String)
    case emptyName
    case sameFolder
    case attachmentsUnavailable
    case nothingDone([String])

    var errorDescription: String? {
        switch self {
        case .malformed: "Предложение пришло в непонятном виде."
        case .noActions: "В предложении нет ни одного действия."
        case .unknownAction(let name): "Неизвестное действие «\(name)»."
        case .missingAttachment(let id): "Вложения «\(id)» уже нет в чате."
        case .missingFolder: "Не указано, в какую папку положить."
        case .unknownFolder(let name): "Папка «\(name)» не найдена."
        case .feedParent(let name): "В ленте «\(name)» нельзя создать папку."
        case .missingFile(let name): "Файла «\(name)» нет в папке."
        case .fromFeed(let name): "Из ленты «\(name)» файлы не переносятся и не переименовываются: там они часть блоков."
        case .emptyName: "Пустое имя."
        case .sameFolder: "Файлы уже лежат в этой папке."
        case .attachmentsUnavailable: "Вложения чата недоступны — пришлите файл ещё раз."
        case .nothingDone(let failed):
            failed.isEmpty ? "Ничего не сделано." : "Не получилось: " + failed.map { "«\($0)»" }.joined(separator: ", ") + "."
        }
    }
}

// Аргументы вызова propose_file_actions от модели. Форма действия — с полем
// «type» или объект с одним ключом-названием:
//   {"summary": "…", "actions": [
//     {"type": "save_attachment", "attachment_id": "a1", "folder_id": "<UUID>", "name": "Паспорт.jpg"},
//     {"move_files": {"files": [{"folder_id": "<UUID>", "name": "скан.pdf"}], "new_folder_name": "Входящие"}},
//     {"type": "rename_file", "file": {"folder_id": "<UUID>", "name": "IMG_1.jpg"}, "new_name": "Договор"},
//     {"type": "create_folder", "name": "Счета", "parent_folder_id": "<UUID>"}]}
// Папку модель называет её UUID; точное имя или путь «Документы / Паспорта»
// тоже принимаются. Каждая папка и каждый файл сверяются с хранилищем: модель
// видит только папки, доступные для поиска, и сослаться на другую не может.
// `parent_folder_id` у create_folder и new_folder_name — внутри какой папки
// создать новую; та тоже должна быть видна модели и не быть лентой
enum FileProposalBuilder {
    @MainActor
    static func make(from arguments: JSONValue, store: VaultStore, inbox: ChatAttachmentInbox) throws -> FileProposal {
        guard let object = arguments.object else { throw FileProposalError.malformed }
        guard let raw = object["actions"]?.array, !raw.isEmpty else { throw FileProposalError.noActions }
        var actions: [FileProposal.Action] = []
        var parents: [String: UUID] = [:]
        for item in raw {
            let (action, parent) = try action(from: item, store: store, inbox: inbox)
            actions.append(action)
            if let parent, let name = newFolderName(in: action) { parents[name.lowercased()] = parent }
        }
        let summary = object["summary"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposal = FileProposal(summary: "", actions: actions, newFolderParents: parents)
        let text = (summary?.isEmpty == false ? summary! : describe(proposal, store: store, inbox: inbox))
        return FileProposal(id: proposal.id, summary: String(text.prefix(300)), actions: actions, newFolderParents: parents)
    }

    /// Имя новой папки, которую заводит действие
    private static func newFolderName(in action: FileProposal.Action) -> String? {
        switch action {
        case .createFolder(let name): name
        case .saveAttachment(_, .new(let name), _), .moveFiles(_, .new(let name)): name
        default: nil
        }
    }

    // MARK: - Действия

    private static let kinds = ["save_attachment", "move_files", "rename_file", "create_folder"]

    /// Действие и родитель новой папки, если действие её заводит
    @MainActor
    private static func action(from raw: JSONValue, store: VaultStore, inbox: ChatAttachmentInbox) throws -> (FileProposal.Action, UUID?) {
        guard let object = raw.object else { throw FileProposalError.malformed }
        var kind = (object["type"] ?? object["kind"] ?? object["action"])?.string
        var body = object
        if kind == nil, object.count == 1, let entry = object.first, let nested = entry.value.object {
            kind = entry.key
            body = nested
        }
        guard let kind else { throw FileProposalError.malformed }
        let parent = try parentFolder(body, store: store)
        switch normalized(kind) {
        case "save_attachment":
            guard let id = string(body, "attachment_id") else { throw FileProposalError.malformed }
            guard let attachment = inbox.item(id) else { throw FileProposalError.missingAttachment(id) }
            let target = try folderTarget(body, parent: parent, store: store)
            let name = try string(body, "name").map { try attachmentName($0, for: attachment) }
            return (.saveAttachment(attachmentID: id, folder: target, name: name), parent?.id)

        case "move_files":
            guard let list = (body["files"] ?? body["file"].map { JSONValue.array([$0]) })?.array, !list.isEmpty else {
                throw FileProposalError.malformed
            }
            var refs: [FileRef] = []
            for item in list {
                let ref = try fileRef(item, store: store)
                if !refs.contains(ref) { refs.append(ref) }
            }
            let target = try folderTarget(body, parent: parent, store: store)
            if case .existing(let id) = target, refs.allSatisfy({ $0.folderID == id }) {
                throw FileProposalError.sameFolder
            }
            return (.moveFiles(files: refs, folder: target), parent?.id)

        case "rename_file":
            guard let file = body["file"] else { throw FileProposalError.malformed }
            let ref = try fileRef(file, store: store)
            guard let raw = string(body, "new_name") else { throw FileProposalError.emptyName }
            return (.renameFile(file: ref, newName: try baseName(raw, keeping: ref.name)), nil)

        case "create_folder":
            guard let raw = string(body, "name") ?? string(body, "folder_name") else { throw FileProposalError.emptyName }
            return (.createFolder(name: try folderName(raw)), parent?.id)

        default:
            throw FileProposalError.unknownAction(kind)
        }
    }

    /// «saveAttachment» и «save-attachment» — то же, что «save_attachment»
    private static func normalized(_ kind: String) -> String {
        var result = ""
        for character in kind {
            if character.isUppercase {
                result += "_" + character.lowercased()
            } else {
                result.append(character == "-" ? "_" : character)
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /// Поле с подчёркиванием или в верблюжьей записи: «attachment_id», «attachmentId»
    private static func string(_ body: [String: JSONValue], _ key: String) -> String? {
        let parts = key.split(separator: "_")
        let camel = parts.enumerated().map { $0 == 0 ? String($1) : $1.capitalized }.joined()
        guard let value = (body[key] ?? body[camel])?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Папки и файлы

    /// `parent` — внутри какой папки искать или заводить новую; nil — где угодно
    /// при поиске и на верхнем уровне при создании
    @MainActor
    static func folderTarget(_ body: [String: JSONValue], parent: VaultFolder? = nil, store: VaultStore) throws -> FolderTarget {
        if let raw = string(body, "folder_id") {
            return .existing(try visibleFolder(raw, store: store).id)
        }
        if let raw = string(body, "new_folder_name") ?? string(body, "folder_name") {
            let name = try folderName(raw)
            // Папка с таким именем уже есть — кладём в неё, а не заводим двойник
            if let existing = visibleFolder(named: name, in: parent?.id, store: store) { return .existing(existing.id) }
            return .new(name: name)
        }
        throw FileProposalError.missingFolder
    }

    /// Родитель новой папки: `parent_folder_id` (или `parent_id`). Как и любая
    /// папка от модели — только доступная для поиска; лента папок не держит
    @MainActor
    private static func parentFolder(_ body: [String: JSONValue], store: VaultStore) throws -> VaultFolder? {
        guard let raw = string(body, "parent_folder_id") ?? string(body, "parent_id") else { return nil }
        let parent = try visibleFolder(raw, store: store)
        guard parent.canContainSubfolders else { throw FileProposalError.feedParent(parent.name) }
        return parent
    }

    /// Папка, о которой модели можно знать: доступна для поиска и не
    /// суперскрытая — она сама и все папки выше
    @MainActor
    static func visibleFolder(_ raw: String, store: VaultStore) throws -> VaultFolder {
        if let id = UUID(uuidString: raw), let folder = store.folder(by: id), store.isIndexable(folder) {
            return folder
        }
        if let folder = visibleFolder(named: raw, store: store) { return folder }
        throw FileProposalError.unknownFolder(raw)
    }

    /// Папка по имени или пути «Документы / Паспорта». Путь точнее: с ним
    /// одноимённые папки в разных местах не путаются. `parentID` — только
    /// среди вложенных в эту папку
    @MainActor
    static func visibleFolder(named name: String, in parentID: UUID? = nil, store: VaultStore) -> VaultFolder? {
        func same(_ lhs: String, _ rhs: String) -> Bool {
            lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let candidates = store.folders.filter { folder in
            store.isIndexable(folder) && (parentID == nil || folder.parentID == parentID)
        }
        let wanted = name.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " / ")
        return candidates.first { same(store.path(of: $0), wanted) }
            ?? candidates.first { same($0.name, name) }
    }

    @MainActor
    private static func fileRef(_ raw: JSONValue, store: VaultStore) throws -> FileRef {
        guard let object = raw.object, let folderRaw = string(object, "folder_id"), let name = string(object, "name") else {
            throw FileProposalError.malformed
        }
        let folder = try visibleFolder(folderRaw, store: store)
        guard folder.kind == .files else { throw FileProposalError.fromFeed(folder.name) }
        guard store.file(named: name, in: folder) != nil else { throw FileProposalError.missingFile(name) }
        return FileRef(folderID: folder.id, name: name)
    }

    // MARK: - Имена

    /// Имя новой папки: без разделителей пути и не длиннее 60 знаков
    static func folderName(_ raw: String) throws -> String {
        guard let clean = VaultStore.cleanedName(raw).map({ String($0.prefix(60)).trimmingCharacters(in: .whitespaces) }),
              !clean.isEmpty else { throw FileProposalError.emptyName }
        return clean
    }

    /// Имя вложения в хранилище — всегда с его настоящим расширением: модель
    /// может его потерять или выдумать другое
    static func attachmentName(_ raw: String, for attachment: ChatAttachment) throws -> String {
        let base = try baseName(raw, keeping: attachment.name)
        let ext = (attachment.name as NSString).pathExtension
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Имя без расширения. Расширение, дописанное моделью, снимается: и своё
    /// («скан.jpeg»), и чужое известное («Паспорт.jpg» у файла .jpeg). Точка
    /// внутри имени («Отчёт v1.2») расширением не считается
    static func baseName(_ raw: String, keeping original: String) throws -> String {
        guard var clean = VaultStore.cleanedName(raw) else { throw FileProposalError.emptyName }
        let ext = (original as NSString).pathExtension.lowercased()
        let proposed = (clean as NSString).pathExtension.lowercased()
        if !proposed.isEmpty,
           proposed == ext || UTType(filenameExtension: proposed).map({ !$0.isDynamic }) == true {
            clean = (clean as NSString).deletingPathExtension
        }
        clean = String(clean.prefix(120)).trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { throw FileProposalError.emptyName }
        return clean
    }

    // MARK: - Подпись

    /// Подпись карточки, если модель её не дала: «Положить 2 файла в «Паспорта»»
    @MainActor
    static func describe(_ proposal: FileProposal, store: VaultStore, inbox: ChatAttachmentInbox) -> String {
        var parts: [String] = []
        var saves: [String: Int] = [:]
        var order: [String] = []
        for action in proposal.actions {
            switch action {
            case .saveAttachment(_, let folder, _):
                let name = folderTitle(folder, store: store)
                if saves[name] == nil { order.append(name) }
                saves[name, default: 0] += 1
            case .moveFiles(let files, let folder):
                parts.append("перенести \(pluralize(files.count, "файл", "файла", "файлов")) в «\(folderTitle(folder, store: store))»")
            case .renameFile(let file, let newName):
                parts.append("переименовать «\(file.name)» в «\(newName)»")
            case .createFolder(let name):
                if let parentID = proposal.parent(ofNewFolder: name), let parent = store.folder(by: parentID) {
                    parts.append("создать папку «\(name)» в «\(store.path(of: parent))»")
                } else {
                    parts.append("создать папку «\(name)»")
                }
            }
        }
        let saving = order.map { "положить \(pluralize(saves[$0] ?? 0, "файл", "файла", "файлов")) в «\($0)»" }
        let text = (saving + parts).joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    @MainActor
    static func folderTitle(_ target: FolderTarget, store: VaultStore) -> String {
        switch target {
        case .existing(let id): store.folder(by: id).map { store.path(of: $0) } ?? "папку"
        case .new(let name): name
        }
    }
}

// Выполнение: папки создаются первыми, затем сохранения, переносы и
// переименования — существующими методами хранилища. Индекс узнаёт о
// переносах и переименованиях событиями, о новых файлах — сверкой по ревизии
@MainActor
enum FileProposalExecutor {
    static func apply(_ proposal: FileProposal, store: VaultStore, inbox: ChatAttachmentInbox) async throws -> String {
        var created: [String: VaultFolder] = [:]
        var report: [String] = []
        var failed: [String] = []

        func folder(for target: FolderTarget) -> VaultFolder? {
            switch target {
            case .existing(let id):
                guard let folder = store.folder(by: id), !store.isHidden(folder) else { return nil }
                return folder
            case .new(let name):
                let key = name.lowercased()
                if let folder = created[key] { return folder }
                // Родитель за время до «Принять» мог пропасть или скрыться —
                // тогда папку не создаём: на верхнем уровне её не ждут
                var parent: VaultFolder?
                if let parentID = proposal.parent(ofNewFolder: name) {
                    guard let found = store.folder(by: parentID), !store.isHidden(found), found.canContainSubfolders else {
                        return nil
                    }
                    parent = found
                }
                if let folder = FileProposalBuilder.visibleFolder(named: name, in: parent?.id, store: store) {
                    created[key] = folder
                    return folder
                }
                guard let folder = store.addFolder(named: name, parentID: parent?.id) else { return nil }
                created[key] = folder
                report.append("создал папку «\(store.path(of: folder))»")
                return folder
            }
        }

        for case .createFolder(let name) in proposal.actions {
            if folder(for: .new(name: name)) == nil { failed.append(name) }
        }

        // Сохранения — по папкам, чтобы отчёт был «2 файла в «Паспорта»»
        var saved: [(folder: VaultFolder, count: Int)] = []
        var used: [(id: String, folder: String)] = []
        for case .saveAttachment(let id, let target, let name) in proposal.actions {
            guard let attachment = inbox.item(id) else {
                failed.append(inbox.names[id] ?? id)
                continue
            }
            guard let destination = folder(for: target) else {
                failed.append(attachment.name)
                continue
            }
            guard await store.saveFile(at: attachment.url, named: name ?? attachment.name, to: destination) != nil else {
                failed.append(attachment.name)
                continue
            }
            used.append((id, store.path(of: destination)))
            if let index = saved.firstIndex(where: { $0.folder.id == destination.id }) {
                saved[index].count += 1
            } else {
                saved.append((destination, 1))
            }
        }
        for entry in saved {
            report.append("сохранил \(pluralize(entry.count, "файл", "файла", "файлов")) в «\(store.path(of: entry.folder))»")
        }

        for case .moveFiles(let refs, let target) in proposal.actions {
            guard let destination = folder(for: target) else {
                failed += refs.map(\.name)
                continue
            }
            var moved = 0
            for (sourceID, group) in Dictionary(grouping: refs, by: \.folderID) {
                guard let source = store.folder(by: sourceID), !store.isHidden(source), source.id != destination.id else {
                    failed += group.map(\.name)
                    continue
                }
                let files = group.compactMap { store.file(named: $0.name, in: source) }
                failed += group.filter { ref in !files.contains { $0.name == ref.name } }.map(\.name)
                guard !files.isEmpty else { continue }
                let result = await store.moveFiles(files, from: source, to: destination)
                moved += result.imported.count
                failed += result.failed
            }
            if moved > 0 {
                report.append("перенёс \(pluralize(moved, "файл", "файла", "файлов")) в «\(store.path(of: destination))»")
            }
        }

        for case .renameFile(let ref, let newName) in proposal.actions {
            guard let source = store.folder(by: ref.folderID), !store.isHidden(source), source.kind == .files,
                  let file = store.file(named: ref.name, in: source) else {
                failed.append(ref.name)
                continue
            }
            store.renameFile(file, to: newName)
            report.append("переименовал «\(file.displayName)» в «\(newName)»")
        }

        for item in used { inbox.markSaved(item.id, in: item.folder) }
        guard !report.isEmpty else { throw FileProposalError.nothingDone(failed) }
        var text = report.joined(separator: ", ")
        text = text.prefix(1).uppercased() + text.dropFirst() + "."
        if !failed.isEmpty {
            text += " Не получилось: " + failed.map { "«\($0)»" }.joined(separator: ", ") + "."
        }
        return text
    }
}

/// Что стало с предложением. Карточку в переписке SwiftUI может пересоздать,
/// а выполнить предложение дважды нельзя — поэтому состояние живёт здесь,
/// до перезапуска приложения
@MainActor
@Observable
final class FileProposalLedger {
    static let shared = FileProposalLedger()

    enum Status: Equatable {
        case pending
        case running
        case done(String)
        case failed(String)
        case cancelled
    }

    private(set) var statuses: [UUID: Status] = [:]
    /// Папка, выбранная человеком вместо предложенной
    private(set) var retargets: [UUID: UUID] = [:]

    func status(of id: UUID) -> Status {
        statuses[id] ?? .pending
    }

    /// Предложение с учётом выбора «Другая папка…»
    func effective(_ proposal: FileProposal) -> FileProposal {
        retargets[proposal.id].map(proposal.retargeted) ?? proposal
    }

    func retarget(_ id: UUID, to folderID: UUID) {
        guard status(of: id) == .pending else { return }
        retargets[id] = folderID
    }

    func cancel(_ id: UUID) {
        guard status(of: id) == .pending else { return }
        statuses[id] = .cancelled
    }

    /// После ошибки можно попробовать снова
    func reset(_ id: UUID) {
        guard case .failed = status(of: id) else { return }
        statuses[id] = .pending
    }

    func run(_ proposal: FileProposal, store: VaultStore, inbox: ChatAttachmentInbox) async {
        guard status(of: proposal.id) == .pending else { return }
        statuses[proposal.id] = .running
        do {
            let text = try await FileProposalExecutor.apply(effective(proposal), store: store, inbox: inbox)
            statuses[proposal.id] = .done(text)
        } catch {
            statuses[proposal.id] = .failed(error.localizedDescription)
        }
    }
}
