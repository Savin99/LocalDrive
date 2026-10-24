import SwiftUI
import UniformTypeIdentifiers

// Вложения над полем ввода: превью и крестик. Только неотправленные — пусто,
// и полосы нет совсем
struct ChatAttachmentStrip: View {
    let inbox: ChatAttachmentInbox

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 56

    var body: some View {
        let draft = inbox.draft
        if !draft.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(draft) { item in
                        thumbnail(item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
            .scrollClipDisabled()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chatAttachmentStrip")
        }
    }

    private func thumbnail(_ item: ChatAttachment) -> some View {
        FileThumbnail(file: item.previewFile, accent: Theme.ink, size: CGSize(width: side, height: side), cornerRadius: 12)
            .frame(width: side, height: side)
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { inbox.remove(item.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 20, height: 20)
                        .background(Theme.ink, in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("Убрать «\(item.name)»")
                .accessibilityIdentifier("chatAttachmentRemove-\(item.name)")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(item.name)
    }
}

extension View {
    /// Перетаскивание файлов в чат из «Файлов», «Фото», Safari — во вложения.
    /// Свои перетаскивания (порядок файлов, блоки ленты) не принимаются
    func chatAttachmentDrop(
        into inbox: ChatAttachmentInbox,
        isTargeted: Binding<Bool>? = nil,
        onAdded: @escaping ([ChatAttachment]) -> Void = { _ in }
    ) -> some View {
        onDrop(of: [.item], isTargeted: isTargeted) { providers in
            let usable = providers.filter { VaultStore.isExternal($0) && VaultStore.importType(for: $0) != nil }
            guard !usable.isEmpty else { return false }
            // Загрузка начинается здесь же: после выхода из обработчика
            // содержимое перетаскивания уже недоступно
            let loading = MainActor.assumeIsolated { inbox.beginAdding(providers: usable) }
            Task { @MainActor in onAdded(await loading.value) }
            return true
        }
    }
}
