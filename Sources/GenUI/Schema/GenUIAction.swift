import Foundation

/// Действие кнопки, пункта списка или формы — только из белого списка.
/// Локальные (`set`, `reset`) выполняет сам движок, остальные передаются
/// приложению (`GenUIActionPerformer`), а меняющие данные — с подтверждением
enum GenUIAction: Hashable, Sendable {
    case set(variable: String, value: GenUIValue)
    case reset(variables: [String]?)
    case submit(include: [String]?, message: GenUITemplate?)
    case regenerate(blockID: String, instruction: String?)
    case ask(text: GenUITemplate)
    case openDocument(documentID: Int64)
    case showFields(documentID: Int64, keys: [String])
    case copyField(documentID: Int64, key: String)
    case openFolder(folderID: UUID)
    case remind(documentID: Int64)
    /// Аргументы как у инструмента `propose_file_actions`: их проверяет и
    /// показывает карточкой FileProposalBuilder, выполняет только «Выполнить»
    case proposeFileActions(arguments: JSONValue)

    enum Kind: String, CaseIterable, Sendable {
        case set
        case reset
        case submit
        case regenerate
        case ask
        case openDocument = "open_document"
        case showFields = "show_fields"
        case copyField = "copy_field"
        case openFolder = "open_folder"
        case remind
        case proposeFileActions = "propose_file_actions"
    }

    var kind: Kind {
        switch self {
        case .set: .set
        case .reset: .reset
        case .submit: .submit
        case .regenerate: .regenerate
        case .ask: .ask
        case .openDocument: .openDocument
        case .showFields: .showFields
        case .copyField: .copyField
        case .openFolder: .openFolder
        case .remind: .remind
        case .proposeFileActions: .proposeFileActions
        }
    }

    /// Выполняется в самом сообщении, без приложения и модели
    var isLocal: Bool {
        kind == .set || kind == .reset
    }

    /// Меняет данные приложения: без подтверждения человека не выполняется
    var needsConfirmation: Bool {
        kind == .remind || kind == .proposeFileActions
    }

    /// Вызывает модель ещё раз: отправка формы, перестройка блока, вопрос
    var talksToModel: Bool {
        kind == .submit || kind == .regenerate || kind == .ask
    }
}

/// Источник документа в JSON: «d42» или 42
enum GenUIDocumentID {
    static func parse(_ json: JSONValue?) -> Int64? {
        switch json {
        case .string(let text): ChatCard.decodeID(text)
        case .number(let value): value >= 0 && value == value.rounded() ? Int64(value) : nil
        default: nil
        }
    }
}
