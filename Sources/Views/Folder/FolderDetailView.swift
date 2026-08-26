import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// Способ отображения файлов, общий для всех папок
enum FileDisplayMode: String, CaseIterable {
    case grid
    case list

    var icon: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }

    var title: String {
        switch self {
        case .grid: "Карточками"
        case .list: "Списком"
        }
    }
}

struct FolderDetailView: View {
    @Environment(VaultStore.self) private var store
    @AppStorage("fileDisplayMode") private var displayModeRaw = FileDisplayMode.grid.rawValue

    let folder: VaultFolder

    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var previewFile: VaultFile?
    @State private var filePendingDelete: VaultFile?
    @State private var fileBeingRenamed: VaultFile?
    @State private var newName = ""
    @State private var search = ""
    @State private var isImporting = false

    private var displayMode: FileDisplayMode {
        FileDisplayMode(rawValue: displayModeRaw) ?? .grid
    }

    private var accent: Color { Theme.color(folder.color) }

    private var files: [VaultFile] {
        let all = store.files(in: folder)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            // Экран подхватывает цвет папки: мягкий градиент из-под заголовка
            LinearGradient(
                colors: [accent.opacity(0.22), accent.opacity(0.04), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 320)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if store.files(in: folder).isEmpty {
                EmptyStateView(
                    icon: "tray.and.arrow.down",
                    title: "Папка пуста",
                    subtitle: "Добавьте документы из «Файлов» или фото из галереи",
                    accent: accent
                )
            } else {
                content
                    .searchable(text: $search, prompt: "Поиск в папке")
                    .overlay {
                        if files.isEmpty && !search.isEmpty {
                            ContentUnavailableView.search(text: search)
                        }
                    }
            }

            if isImporting {
                ProgressView()
                    .controlSize(.large)
                    .padding(24)
                    .cardStyle()
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.large)
        .tint(accent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Отображение", selection: $displayModeRaw) {
                        ForEach(FileDisplayMode.allCases, id: \.rawValue) { mode in
                            Label(mode.title, systemImage: mode.icon).tag(mode.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: displayMode.icon)
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("Вид отображения")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Документ из «Файлов»", systemImage: "folder")
                    }
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("Фото или видео", systemImage: "photo")
                    }
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.semibold)
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("Добавить файл")
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            importPickedFiles(urls)
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: 20,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            importPickedPhotos(items)
        }
        .sheet(item: $previewFile) { file in
            FilePreviewView(url: file.url) { previewFile = nil }
                .ignoresSafeArea()
        }
        .confirmationDialog(
            "Удалить «\(filePendingDelete?.name ?? "")»?",
            isPresented: Binding(
                get: { filePendingDelete != nil },
                set: { if !$0 { filePendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let file = filePendingDelete {
                    withAnimation { store.deleteFile(file) }
                }
                filePendingDelete = nil
            }
            Button("Отмена", role: .cancel) { filePendingDelete = nil }
        }
        .alert("Новое имя", isPresented: Binding(
            get: { fileBeingRenamed != nil },
            set: { if !$0 { fileBeingRenamed = nil } }
        )) {
            TextField("Имя файла", text: $newName)
            Button("Сохранить") {
                if let file = fileBeingRenamed {
                    store.renameFile(file, to: newName)
                }
                fileBeingRenamed = nil
            }
            Button("Отмена", role: .cancel) { fileBeingRenamed = nil }
        }
    }

    // MARK: - Содержимое

    @ViewBuilder
    private var content: some View {
        switch displayMode {
        case .list: listContent
        case .grid: gridContent
        }
    }

    private var listContent: some View {
        List {
            ForEach(files) { file in
                Button {
                    previewFile = file
                } label: {
                    FileRow(file: file, accent: accent)
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.card)
                .listRowSeparatorTint(.black.opacity(0.06))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        filePendingDelete = file
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                    .tint(.red)
                    Button {
                        startRename(file)
                    } label: {
                        Label("Имя", systemImage: "pencil")
                    }
                    .tint(Theme.accent)
                }
                .contextMenu { fileMenu(for: file) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var gridContent: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 14
            let padding: CGFloat = 20
            let side = (geo.size.width - padding * 2 - spacing) / 2

            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.fixed(side), spacing: spacing),
                        GridItem(.fixed(side), spacing: spacing),
                    ],
                    spacing: spacing
                ) {
                    ForEach(files) { file in
                        Button {
                            previewFile = file
                        } label: {
                            FileGridCell(file: file, accent: accent, side: side)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { fileMenu(for: file) }
                    }
                }
                .padding(padding)
            }
        }
    }

    @ViewBuilder
    private func fileMenu(for file: VaultFile) -> some View {
        ShareLink(item: file.url) {
            Label("Поделиться", systemImage: "square.and.arrow.up")
        }
        Button {
            startRename(file)
        } label: {
            Label("Переименовать", systemImage: "pencil")
        }
        Button(role: .destructive) {
            filePendingDelete = file
        } label: {
            Label("Удалить", systemImage: "trash")
        }
    }

    private func startRename(_ file: VaultFile) {
        newName = file.url.deletingPathExtension().lastPathComponent
        fileBeingRenamed = file
    }

    // MARK: - Импорт

    private func importPickedFiles(_ urls: [URL]) {
        isImporting = true
        for url in urls {
            // Доступ к файлу вне песочницы нужно открыть явно
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            store.importFile(from: url, to: folder)
        }
        isImporting = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func importPickedPhotos(_ items: [PhotosPickerItem]) {
        isImporting = true
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let stamp = Self.nameFormatter.string(from: Date())
                store.importData(data, preferredName: "Фото \(stamp).\(ext)", to: folder)
            }
            photoItems = []
            isImporting = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}
