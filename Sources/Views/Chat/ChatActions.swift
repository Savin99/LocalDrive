import SwiftUI

// Контракт между экраном чата и карточками. Карточки ничего не делают сами:
// открыть файл, скопировать, показать номер, исправить поле, отправить
// уточнение — всё это просят у экрана через окружение
struct ChatActions {
    /// Открыть файл в полноэкранном просмотре; `list` — что можно листать, `page` — страница PDF
    var open: @MainActor (_ file: VaultFile, _ list: [VaultFile], _ page: Int?) -> Void = { _, _, _ in }
    /// Отправить текст как новое сообщение
    var send: @MainActor (_ text: String) -> Void = { _ in }
    /// Тап по чипу уточнения: его текст уходит сообщением, а документ, если
    /// чип на него указывает, выбирается напрямую
    var choose: @MainActor (_ option: ClarifyOption) -> Void = { _ in }
    /// Скопировать значение в буфер только этого iPhone, со сроком жизни
    var copy: @MainActor (_ value: String) -> Void = { _ in }
    /// Открыть (true) или закрыть (false) номера документов; возвращает,
    /// открыты ли номера после вызова
    var setRevealed: @MainActor (_ revealed: Bool) async -> Bool = { _ in false }
    /// Показать лист правки поля
    var edit: @MainActor (_ document: ChatDocument, _ field: DocumentField) -> Void = { _, _ in }
    /// Отметить поле как сверенное с фото
    var verify: @MainActor (_ document: ChatDocument, _ field: DocumentField) async -> Void = { _, _ in }
    /// Поставить напоминание о сроке; вернуть текст подтверждения или ошибки
    var remind: @MainActor (_ document: ChatDocument, _ validity: DocumentValidity) async -> String = { _, _ in "" }
}

extension EnvironmentValues {
    @Entry var chatActions = ChatActions()
    /// Номера документов открыты касанием «глаза»
    @Entry var chatRevealsSensitive = false
}

/// Маска номера: видны только две последние цифры — «•••• ••••56»
enum FieldMask {
    static func masked(_ value: String) -> String {
        let digits = value.filter(\.isNumber).count
        var remaining = digits
        return String(value.map { character in
            guard character.isNumber else { return character }
            remaining -= 1
            return remaining < 2 ? character : "•"
        })
    }

    static func display(_ field: DocumentField, revealed: Bool) -> String {
        FieldKey.isSensitive(field.key) && !revealed ? masked(field.value) : field.value
    }
}

/// Карточка ответа: выбирает вью по типу из каталога
struct ChatCardView: View {
    let card: ResolvedCard

    var body: some View {
        switch card.content {
        case .fields(let document, let keys):
            FieldsCardView(document: document, keys: keys)
        case .document(let document):
            DocumentCardView(document: document)
        case .fileList(let documents):
            FileListCardView(documents: documents)
        case .snippet(let document, let page, let snippet):
            SnippetCardView(document: document, page: page, snippet: snippet)
        case .clarify(let question, let options):
            ClarifyCardView(question: question, options: options)
        case .expiry(let document, let validity):
            ExpiryCardView(document: document, validity: validity)
        case .proposal(let proposal):
            FileProposalCardView(proposal: proposal)
        case .attachment(let id):
            ChatAttachmentCardView(id: id)
        case .fact(let card, let highlighted):
            FactCardView(card: card, highlighted: highlighted)
        case .factProposal(let draft):
            FactProposalCardView(draft: draft)
        }
    }
}
