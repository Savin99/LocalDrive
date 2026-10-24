import SwiftUI

struct HomeView: View {
    @Environment(VaultStore.self) private var store
    @Environment(LockManager.self) private var lock
    @Environment(\.isOffscreenPage) private var isOffscreenPage
    @Environment(\.scenePhase) private var scenePhase

    @State private var editingFolder: VaultFolder?
    @State private var isCreating = false
    @State private var showsSettings = false
    @State private var folderPendingDelete: VaultFolder?
    @State private var movingFolder: VaultFolder?
    @State private var recentPreview: VaultFile?
    @State private var areHiddenFoldersRevealed = false
    @State private var zGesturePoints: [CGPoint] = []
    @State private var toast: String?
    @State private var query = ""
    @State private var openedResult: OpenedResult?
    /// Открытые папки. По глубине MainView прячет переключатель страниц
    @State private var path: [UUID] = []
    @Namespace private var zoomNamespace

    /// Найденный файл и вся выдача: листать в просмотре можно по ней
    private struct OpenedResult: Identifiable {
        let file: VaultFile
        let page: Int?
        let files: [VaultFile]

        var id: String { file.id }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    /// Только верхний уровень: вложенные папки — внутри своих
    private var visibleFolders: [VaultFolder] {
        store.rootFolders.filter { areHiddenFoldersRevealed || !$0.isSuperHidden }
    }

    var body: some View {
        GeometryReader { proxy in
            NavigationStack(path: $path) {
                ZStack {
                    Theme.background.ignoresSafeArea()

                    if isSearching {
                        SearchResultsView(query: query) { result, all in
                            openedResult = OpenedResult(
                                file: result.file,
                                page: result.page,
                                files: all.map(\.file)
                            )
                        }
                    } else if visibleFolders.isEmpty {
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

                    if let toast {
                        toastBanner(toast)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(zGesture(in: proxy.size))
                .navigationTitle("Мои файлы")
                .navigationBarTitleDisplayMode(.inline)
                // Посередине шапки стоит общий переключатель «Чат | Файлы»
                .toolbar(removing: .title)
                .searchable(text: $query, prompt: "Найти в документах")
                // «Файлы» за краем экрана, пока открыт чат
                .accessibilityHidden(isOffscreenPage)
                .navigationDestination(for: UUID.self) { id in
                    if let folder = store.folder(by: id) {
                        Group {
                            if folder.kind == .feed {
                                FeedFolderView(folder: folder)
                            } else {
                                FolderDetailView(folder: folder)
                            }
                        }
                            .navigationTransition(.zoom(sourceID: id, in: zoomNamespace))
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showsSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Настройки")
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
                .sheet(item: $movingFolder) { folder in
                    FolderMoveSheet(folder: folder) { parentID in
                        moveFolder(folder, to: parentID)
                    }
                }
                .sheet(isPresented: $showsSettings) {
                    SettingsView()
                }
                .sheet(item: $recentPreview) { file in
                    let recentFiles = store.recentFiles(
                        limit: 12,
                        includingSuperHidden: areHiddenFoldersRevealed
                    ).map(\.file)
                    FilePagerView(files: recentFiles, initialFile: file) { recentPreview = nil }
                        .ignoresSafeArea()
                }
                .sheet(item: $openedResult) { opened in
                    FilePagerView(
                        files: opened.files,
                        initialFile: opened.file,
                        initialPage: opened.page
                    ) { openedResult = nil }
                        .ignoresSafeArea()
                }
                .confirmationDialog(
                    FolderDeletion.title(for: folderPendingDelete),
                    isPresented: Binding(
                        get: { folderPendingDelete != nil },
                        set: { if !$0 { folderPendingDelete = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: folderPendingDelete
                ) { folder in
                    Button(FolderDeletion.confirmTitle, role: .destructive) {
                        withAnimation { store.deleteFolder(folder) }
                        folderPendingDelete = nil
                    }
                    Button("Отмена", role: .cancel) { folderPendingDelete = nil }
                } message: { folder in
                    Text(FolderDeletion.message(for: folder, in: store))
                }
            }
            // Вложенные экраны открывают папки глубже и возвращаются крошками
            // через этот путь; им же нужно знать, открыты ли скрытые папки
            .environment(\.folderPath, $path)
            .environment(\.revealsHiddenFolders, areHiddenFoldersRevealed)
            .environment(\.folderZoomNamespace, zoomNamespace)
        }
        .preference(key: FilesNavigationDepthKey.self, value: path.count)
        .sensoryFeedback(.success, trigger: areHiddenFoldersRevealed)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                hideSuperHiddenFolders()
            }
        }
    }

    private var content: some View {
        let recent = store.recentFiles(limit: 12, includingSuperHidden: areHiddenFoldersRevealed)

        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if recent.count > 1 {
                    RecentStrip(items: recent) { recentPreview = $0 }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(pluralize(visibleFolders.count, "папка", "папки", "папок"))
                            .font(.system(.subheadline, weight: .semibold))

                        Spacer()

                        if areHiddenFoldersRevealed && store.folders.contains(where: \.isSuperHidden) {
                            Label("Скрытые открыты", systemImage: "eye.slash.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(Array(visibleFolders.enumerated()), id: \.element.id) { index, folder in
                            NavigationLink(value: folder.id) {
                                FolderCard(
                                    folder: folder,
                                    stats: store.stats(for: folder, includingHidden: areHiddenFoldersRevealed),
                                    preview: store.previewFiles(in: folder)
                                )
                                .overlay(alignment: .topTrailing) {
                                    if folder.isSuperHidden {
                                        HiddenFolderBadge()
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .matchedTransitionSource(id: folder.id, in: zoomNamespace)
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                            .appearSpring(delay: Double(index) * 0.04)
                            .contextMenu {
                                Button {
                                    editingFolder = folder
                                } label: {
                                    Label("Изменить папку", systemImage: "pencil")
                                }
                                Button {
                                    movingFolder = folder
                                } label: {
                                    Label("Переместить…", systemImage: "folder.badge.gearshape")
                                }
                                Button {
                                    toggleVisibility(of: folder)
                                } label: {
                                    if folder.isSuperHidden {
                                        Label("Показывать на главном", systemImage: "eye.fill")
                                    } else {
                                        Label("Скрыть папку", systemImage: "eye.slash.fill")
                                    }
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
        // Как в чате: папки не просвечивают сквозь кнопки шапки
        .scrollEdgeEffectStyle(.hard, for: .top)
    }

    private func toastBanner(_ text: String) -> some View {
        Label(text, systemImage: "eye.slash.fill")
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.black.opacity(0.78), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
            .padding(.top, 10)
            .frame(maxHeight: .infinity, alignment: .top)
            .transition(.move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(false)
    }

    /// Скрыть или вернуть папку прямо из меню: до этого видимость меняли
    /// только в редакторе, и найти её там было неоткуда
    private func toggleVisibility(of folder: VaultFolder) {
        let hides = !folder.isSuperHidden
        withAnimation(.snappy(duration: 0.25)) {
            store.setSuperHidden(hides, for: folder.id)
        }

        if hides, !areHiddenFoldersRevealed {
            // Папка только что исчезла с экрана — объясняем, как вернуть
            showToast("Папка скрыта — откройте жестом Z")
        } else {
            showToast(hides ? "Папка скрыта" : "Папка снова на главном")
        }
    }

    /// Папка ушла внутрь другой и с главного экрана пропадает — это и есть
    /// ответ. Тост главного экрана занят скрытыми папками, поэтому только отклик
    private func moveFolder(_ folder: VaultFolder, to parentID: UUID?) {
        guard withAnimation(.snappy(duration: 0.25), { store.moveFolder(folder.id, to: parentID) }) else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            toast = text
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.2)) {
                toast = nil
            }
        }
    }

    private func zGesture(in size: CGSize) -> some Gesture {
        // Порог больше, чем у свайпа страниц (~10 pt): начавшись первым, жест Z
        // не давал свайпу от края вернуться к чату. Точка начала Z от порога
        // не зависит — DragGesture помнит её с касания
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { value in
                guard !areHiddenFoldersRevealed else { return }
                if zGesturePoints.isEmpty {
                    zGesturePoints.append(value.startLocation)
                }
                zGesturePoints.append(value.location)
            }
            .onEnded { _ in
                defer { zGesturePoints.removeAll(keepingCapacity: true) }
                // Поверх выдачи жест не нужен: суперскрытые папки в поиск не входят
                guard !areHiddenFoldersRevealed, !isSearching,
                      store.folders.contains(where: \.isSuperHidden),
                      ZGestureRecognizer.matches(points: zGesturePoints, in: size) else { return }

                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    areHiddenFoldersRevealed = true
                }
                showToast("Скрытые папки открыты")
            }
    }

    private func hideSuperHiddenFolders() {
        areHiddenFoldersRevealed = false
        toast = nil
        zGesturePoints.removeAll(keepingCapacity: true)
    }
}

/// Проверяет, что единый свайп образует три штриха Z и занимает центральную часть экрана.
enum ZGestureRecognizer {
    static func matches(points: [CGPoint], in size: CGSize) -> Bool {
        guard points.count >= 8, size.width > 0, size.height > 0 else { return false }

        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let width = maxX - minX
        let height = maxY - minY
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)

        guard width >= size.width * 0.32,
              height >= max(60, size.height * 0.09),
              height <= size.height * 0.45,
              center.x >= size.width * 0.25,
              center.x <= size.width * 0.75,
              center.y >= size.height * 0.24,
              center.y <= size.height * 0.76 else { return false }

        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - minX) / width, y: (point.y - minY) / height)
        }

        let normalizedPoints = points.map(normalized)
        guard let start = normalizedPoints.first,
              let end = normalizedPoints.last,
              start.x <= 0.28,
              start.y <= 0.30,
              end.x >= 0.72,
              end.y >= 0.70 else { return false }

        let lastIndex = normalizedPoints.count - 1
        let firstSearchEnd = max(2, Int(Double(lastIndex) * 0.68))
        guard let topRightIndex = (1...firstSearchEnd).max(by: {
            normalizedPoints[$0].x - normalizedPoints[$0].y * 0.35
                < normalizedPoints[$1].x - normalizedPoints[$1].y * 0.35
        }), topRightIndex < lastIndex - 2 else { return false }

        guard let bottomLeftIndex = ((topRightIndex + 1)..<lastIndex).max(by: {
            (1 - normalizedPoints[$0].x) + normalizedPoints[$0].y
                < (1 - normalizedPoints[$1].x) + normalizedPoints[$1].y
        }) else { return false }

        let topRight = normalizedPoints[topRightIndex]
        let bottomLeft = normalizedPoints[bottomLeftIndex]

        return topRight.x >= 0.72
            && topRight.y <= 0.38
            && bottomLeft.x <= 0.30
            && bottomLeft.y >= 0.62
            && bottomLeftIndex < lastIndex - 1
            && topRight.x - start.x >= 0.50
            && bottomLeft.x - topRight.x <= -0.45
            && bottomLeft.y - topRight.y >= 0.42
            && end.x - bottomLeft.x >= 0.45
            && abs(end.y - bottomLeft.y) <= 0.30
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
