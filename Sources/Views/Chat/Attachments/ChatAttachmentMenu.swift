import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// «+» у поля ввода: фото, файл, вставка из буфера. Вложения становятся
// временными копиями, а в хранилище попадают только через предложение в чате.
// Камеры нет: ей нужен свой доступ в Info.plist и обёртка UIKit
struct ChatAttachmentMenu<Content: View>: View {
    let inbox: ChatAttachmentInbox
    let onAdded: ([ChatAttachment]) -> Void
    let label: () -> Content

    @State private var pickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false

    init(
        inbox: ChatAttachmentInbox,
        onAdded: @escaping ([ChatAttachment]) -> Void = { _ in },
        @ViewBuilder label: @escaping () -> Content
    ) {
        self.inbox = inbox
        self.onAdded = onAdded
        self.label = label
    }

    var body: some View {
        Menu {
            Button {
                pickingPhotos = true
            } label: {
                Label("Фото", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("chatAttachPhoto")

            Button {
                importing = true
            } label: {
                Label("Файл", systemImage: "doc")
            }
            .accessibilityIdentifier("chatAttachFile")

            // Кнопка, а не PasteButton: в меню PasteButton не встаёт. iOS
            // спросит разрешение на вставку — это её правило
            Button {
                let loading = inbox.beginAdding(providers: UIPasteboard.general.itemProviders)
                Task { onAdded(await loading.value) }
            } label: {
                Label("Вставить", systemImage: "doc.on.clipboard")
            }
            .accessibilityIdentifier("chatAttachPaste")
        } label: {
            label()
        }
        .accessibilityIdentifier("chatAttach")
        .photosPicker(
            isPresented: $pickingPhotos,
            selection: $photos,
            maxSelectionCount: 10,
            matching: .any(of: [.images, .screenshots])
        )
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task { onAdded(await addPhotos(items)) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { onAdded(await inbox.add(urls: urls)) }
        }
    }

    /// Фото из галереи приходят данными, без имени файла — имя по дате, как
    /// у фото, импортированных в папку
    private func addPhotos(_ items: [PhotosPickerItem]) async -> [ChatAttachment] {
        var added: [ChatAttachment] = []
        let stamp = Date()
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
            let name = VaultStore.pastedName(suggested: nil, type: type, date: stamp.addingTimeInterval(Double(added.count)))
            if let attachment = await inbox.add(data: data, named: name) { added.append(attachment) }
        }
        return added
    }
}

extension ChatAttachmentMenu where Content == ChatAttachmentPlusLabel {
    /// Меню с круглой кнопкой «+», как у поля ввода ChatGPT
    init(inbox: ChatAttachmentInbox, onAdded: @escaping ([ChatAttachment]) -> Void = { _ in }) {
        self.init(inbox: inbox, onAdded: onAdded) { ChatAttachmentPlusLabel() }
    }
}

struct ChatAttachmentPlusLabel: View {
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 36

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: side * 0.47, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(width: side, height: side)
            .background(Theme.surface, in: Circle())
            .contentShape(Circle())
            .accessibilityLabel("Добавить файл")
    }
}
