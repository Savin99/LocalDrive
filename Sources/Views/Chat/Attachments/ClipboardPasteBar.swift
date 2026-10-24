import SwiftUI
import UniformTypeIdentifiers

// «В буфере фото — вставить?» над полем ввода. Владелец 24.10.2026: «если в
// буфере документ, над чатом сразу появляется кнопка “Вставить”». Что лежит в
// буфере, проверяется по типам — без чтения содержимого, поэтому iOS не
// показывает плашку «разрешить вставку». Сама вставка — системная PasteButton:
// она читает буфер без запроса. Текст сюда не относится: вставить вопрос можно
// и в поле ввода; номер, скопированный из карточки, тоже текст
struct ClipboardPasteBar: View {
    let kind: ClipboardKind
    let inbox: ChatAttachmentInbox
    /// Вставили или отказались — строка уходит до следующего содержимого буфера
    var onHandled: () -> Void
    var onAdded: ([ChatAttachment]) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 30, height: 30)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text("В буфере \(kind.title)")
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            PasteButton(supportedContentTypes: FileClipboard.pasteTypes) { providers in
                // Загрузка начинается прямо в обработчике: после него
                // содержимое буфера уже недоступно
                let loading = inbox.beginAdding(providers: providers)
                Task { @MainActor in
                    onHandled()
                    onAdded(await loading.value)
                }
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.capsule)
            .tint(Theme.ink)
            .accessibilityIdentifier("chatClipboardPaste")
            Button(action: onHandled) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Не вставлять")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatClipboardBar")
    }
}

/// Следит за буфером: при появлении экрана, возвращении в приложение и
/// смене буфера. Висит на экране чата, а не на строке: строки, пока буфер
/// пуст, нет вовсе — и её onAppear не сработал бы никогда
struct ClipboardWatcher: ViewModifier {
    @Binding var kind: ClipboardKind?
    @Environment(\.scenePhase) private var scenePhase
    /// Номер содержимого буфера, которое уже вставили или отклонили: то же
    /// самое второй раз не предлагается
    @AppStorage("chatClipboardHandled") private var handledChange = -1

    func body(content: Content) -> some View {
        content
            .onAppear(perform: refresh)
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in refresh() }
            .onChange(of: kind) { old, new in
                // Строку закрыли — это содержимое больше не предлагать
                if old != nil, new == nil { handledChange = UIPasteboard.general.changeCount }
            }
    }

    private func refresh() {
        let pasteboard = UIPasteboard.general
        let found = pasteboard.changeCount == handledChange ? nil : ClipboardKind.detect(in: pasteboard)
        guard found != kind else { return }
        withAnimation(.snappy(duration: 0.2)) { kind = found }
    }
}

/// Что лежит в буфере — по типам, без чтения содержимого
enum ClipboardKind: Equatable {
    case photo
    case pdf
    case video
    case file

    var title: String {
        switch self {
        case .photo: "фото"
        case .pdf: "PDF-документ"
        case .video: "видео"
        case .file: "файл"
        }
    }

    var symbol: String {
        switch self {
        case .photo: "photo"
        case .pdf: "doc.richtext"
        case .video: "video"
        case .file: "doc"
        }
    }

    /// Свои внутренние типы (блоки ленты, имена файлов) и ссылки — не файл
    static func detect(in pasteboard: UIPasteboard) -> ClipboardKind? {
        guard pasteboard.numberOfItems > 0 else { return nil }
        if pasteboard.contains(pasteboardTypes: [UTType.pdf.identifier]) { return .pdf }
        if pasteboard.hasImages || pasteboard.contains(pasteboardTypes: [UTType.image.identifier]) { return .photo }
        if pasteboard.contains(pasteboardTypes: [UTType.movie.identifier, UTType.audiovisualContent.identifier]) { return .video }
        let own = ["com.ilyaqa.LocalDrive.feed-block", "com.ilyaqa.LocalDrive.file-name"]
        if pasteboard.contains(pasteboardTypes: own) { return nil }
        // Файл из «Файлов» — data без текста и ссылки
        if pasteboard.contains(pasteboardTypes: [UTType.data.identifier]),
           !pasteboard.hasStrings, !pasteboard.hasURLs { return .file }
        return nil
    }
}
