import SwiftUI

struct HomeView: View {
    @Environment(VaultStore.self) private var store
    @Environment(LockManager.self) private var lock

    @State private var editingFolder: VaultFolder?
    @State private var isCreating = false
    @State private var isChangingPin = false
    @State private var folderPendingDelete: VaultFolder?
    @State private var recentPreview: VaultFile?
    @Namespace private var zoomNamespace

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if store.folders.isEmpty {
                    EmptyStateView(
                        icon: "folder.badge.plus",
                        title: "Здесь пока пусто",
                        subtitle: "Создайте первую папку — например «Документы» или «Паспорта»",
                        actionTitle: "Создать папку",
                        action: { isCreating = true }
                    )
                } else {
                    content
                }
            }
            .navigationTitle("Мои файлы")
            .navigationDestination(for: UUID.self) { id in
                if let folder = store.folder(by: id) {
                    FolderDetailView(folder: folder)
                        .navigationTransition(.zoom(sourceID: id, in: zoomNamespace))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            lock.lock()
                        } label: {
                            Label("Заблокировать", systemImage: "lock.fill")
                        }
                        Button {
                            isChangingPin = true
                        } label: {
                            Label("Сменить код", systemImage: "key.fill")
                        }
                    } label: {
                        Image(systemName: "lock.fill")
                    }
                    .accessibilityLabel("Защита")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isCreating = true
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel("Новая папка")
                }
            }
            .sheet(isPresented: $isCreating) {
                FolderEditorView(folder: nil)
            }
            .sheet(item: $editingFolder) { folder in
                FolderEditorView(folder: folder)
            }
            .sheet(isPresented: $isChangingPin) {
                ChangePinView()
            }
            .sheet(item: $recentPreview) { file in
                FilePreviewView(url: file.url) { recentPreview = nil }
                    .ignoresSafeArea()
            }
            .confirmationDialog(
                "Удалить папку «\(folderPendingDelete?.name ?? "")»?",
                isPresented: Binding(
                    get: { folderPendingDelete != nil },
                    set: { if !$0 { folderPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Удалить вместе с файлами", role: .destructive) {
                    if let folder = folderPendingDelete {
                        withAnimation { store.deleteFolder(folder) }
                    }
                    folderPendingDelete = nil
                }
                Button("Отмена", role: .cancel) { folderPendingDelete = nil }
            }
        }
    }

    private var content: some View {
        let recent = store.recentFiles(limit: 12)

        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if recent.count > 1 {
                    RecentStrip(items: recent) { recentPreview = $0 }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(pluralize(store.folders.count, "папка", "папки", "папок"))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(Array(store.folders.enumerated()), id: \.element.id) { index, folder in
                            NavigationLink(value: folder.id) {
                                FolderCard(
                                    folder: folder,
                                    stats: store.stats(for: folder),
                                    preview: store.previewFiles(in: folder)
                                )
                            }
                            .buttonStyle(.plain)
                            .matchedTransitionSource(id: folder.id, in: zoomNamespace)
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                            .appearSpring(delay: Double(index) * 0.04)
                            .contextMenu {
                                Button {
                                    editingFolder = folder
                                } label: {
                                    Label("Переименовать", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    folderPendingDelete = folder
                                } label: {
                                    Label("Удалить папку", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
    }
}

// Пружинное появление с задержкой — карточки «выкладываются» по очереди
private struct AppearSpring: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.94)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.78).delay(delay)) {
                    shown = true
                }
            }
    }
}

extension View {
    func appearSpring(delay: Double = 0) -> some View {
        modifier(AppearSpring(delay: delay))
    }
}
