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
    /// Файлы, удаление которых ждёт подтверждения
    @State private var pendingDelete: [VaultFile] = []
    @State private var fileBeingRenamed: VaultFile?
    @State private var newName = ""
    @State private var search = ""
    @State private var isImporting = false
    @State private var failure: Failure?
    @State private var isReordering = false
    /// Файл, над которым сейчас палец: показываем, куда встанет перетаскиваемый
    @State private var dropTarget: String?
    /// Режим выбора, как в «Файлах»: nil — выключен, иначе имена отмеченных
    @State private var selection: Set<String>?
    @State private var transfer: FileTransfer?
    @State private var infoFile: VaultFile?
    @State private var toast: String?
    /// Над папкой держат файл из другого приложения
    @State private var isDropTargeted = false

    /// Что не получилось и что с этим делать
    private struct Failure {
        let title: String
        let message: String
    }

    private var displayMode: FileDisplayMode {
        FileDisplayMode(rawValue: displayModeRaw) ?? .grid
    }

    private var accent: Color { Theme.color(folder.color) }

    private var sortOrder: FileSortOrder {
        store.folder(by: folder.id)?.sortOrder ?? folder.sortOrder
    }

    private var files: [VaultFile] {
        let all = store.files(in: folder, sortedBy: sortOrder)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var isSelecting: Bool { selection != nil }

    /// Отмеченные файлы в порядке на экране. Поиск по папке выбор не сбрасывает:
    /// действие относится ко всему отмеченному
    private var selectedFiles: [VaultFile] {
        guard let selection, !selection.isEmpty else { return [] }
        return store.files(in: folder, sortedBy: sortOrder).filter { selection.contains($0.name) }
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
                emptyState
            } else {
                VStack(spacing: 0) {
                    if isReordering {
                        Label("Перетащите файл на место другого — порядок сохранится", systemImage: "hand.draw")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(accent.opacity(0.10))
                    }
                    content
                }
                    .searchable(text: $search, prompt: "Поиск в папке")
                    .overlay {
                        if files.isEmpty && !search.isEmpty {
                            ContentUnavailableView.search(text: search)
                        }
                    }
            }

            if isDropTargeted {
                dropHighlight
            }

            if isImporting {
                ProgressView()
                    .controlSize(.large)
                    .padding(24)
                    .cardStyle()
            }

            if let toast {
                ToastBanner(text: toast)
                    .id(toast)
            }
        }
        .onDrop(of: dropTypes, isTargeted: $isDropTargeted, perform: acceptDrop)
        .task(id: folder.id) { await backfillContentDates() }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.large)
        // В режиме выбора слева — «Выбрать все», как в «Файлах»
        .navigationBarBackButtonHidden(isSelecting)
        .tint(accent)
        .toolbar { toolbarContent }
        // Панель действий с выбранным встаёт на место вкладок
        .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
        .onChange(of: store.files(in: folder).map(\.name)) { _, names in
            pruneSelection(to: names)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                importPickedFiles(urls)
            case .failure(let error):
                failure = Failure(title: "Файл не добавлен", message: error.localizedDescription)
            }
        }
        .alert(
            failure?.title ?? "",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure?.message ?? "")
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
            FilePagerView(files: files, initialFile: file) { previewFile = nil }
                .ignoresSafeArea()
        }
        .sheet(item: $transfer) { transfer in
            FolderPickerSheet(transfer: transfer, currentFolderID: folder.id) { destination in
                perform(transfer, into: destination)
            }
        }
        .sheet(item: $infoFile) { file in
            FileInfoSheet(file: file, folder: store.folder(by: folder.id) ?? folder)
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { !pendingDelete.isEmpty },
                set: { if !$0 { pendingDelete = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                let doomed = pendingDelete
                withAnimation {
                    for file in doomed { store.deleteFile(file) }
                }
                pendingDelete = []
                if isSelecting { endSelection() }
            }
            Button("Отмена", role: .cancel) { pendingDelete = [] }
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

    private var navigationTitle: String {
        guard let selection else { return folder.name }
        return selection.isEmpty ? "Выберите файлы" : "Выбрано: \(selection.count)"
    }

    private var deleteTitle: String {
        if pendingDelete.count == 1, let file = pendingDelete.first {
            return "Удалить «\(file.name)»?"
        }
        return "Удалить \(pluralize(pendingDelete.count, "файл", "файла", "файлов"))?"
    }

    // MARK: - Панели

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(allVisibleSelected ? "Снять выбор" : "Выбрать все") {
                    toggleSelectAll()
                }
                .accessibilityIdentifier("fileSelectAll")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") { endSelection() }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("fileSelect")
            }
            ToolbarItem(placement: .bottomBar) { shareSelected }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItemGroup(placement: .bottomBar) {
                moveSelected
                copySelected
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { deleteSelected }
        } else if isReordering {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleReordering()
                } label: {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("Готово")
                .accessibilityIdentifier("reorder-files")
            }
        } else {
            if !store.files(in: folder).isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Выбрать") { beginSelection() }
                        .accessibilityIdentifier("fileSelect")
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) { viewMenu }
            ToolbarItem(placement: .topBarTrailing) { addMenu }
        }
    }

    private var viewMenu: some View {
        Menu {
            Picker("Отображение", selection: $displayModeRaw) {
                ForEach(FileDisplayMode.allCases, id: \.rawValue) { mode in
                    Label(mode.title, systemImage: mode.icon).tag(mode.rawValue)
                }
            }
            Section("Сортировка") {
                Picker("Сортировка", selection: sortBinding) {
                    ForEach(FileSortOrder.allCases, id: \.rawValue) { order in
                        Label(order.title, systemImage: order.icon).tag(order)
                    }
                }
            }
            if !files.isEmpty && search.isEmpty {
                Section {
                    Button {
                        toggleReordering()
                    } label: {
                        Label("Переставить файлы", systemImage: "arrow.up.arrow.down")
                    }
                    .accessibilityIdentifier("reorder-files")
                }
            }
        } label: {
            Image(systemName: displayMode.icon)
                .foregroundStyle(accent)
        }
        .accessibilityLabel("Вид отображения")
    }

    private var addMenu: some View {
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
            Section {
                pasteButton
            }
        } label: {
            Image(systemName: "plus")
                .fontWeight(.semibold)
                .foregroundStyle(accent)
        }
        .accessibilityLabel("Добавить файл")
    }

    // Действия с выбранным: иконки внизу, подписи — для VoiceOver

    private var shareSelected: some View {
        ShareLink(items: selectedFiles.map(\.url)) {
            Label("Поделиться", systemImage: "square.and.arrow.up")
        }
        .disabled(selectedFiles.isEmpty)
        .accessibilityIdentifier("bulkShare")
    }

    private var moveSelected: some View {
        Button {
            transfer = FileTransfer(mode: .move, files: selectedFiles)
        } label: {
            Label("Переместить", systemImage: "folder")
        }
        .disabled(selectedFiles.isEmpty)
        .accessibilityIdentifier("bulkMove")
    }

    /// Копировать — в буфер обмена или в другую папку
    private var copySelected: some View {
        Menu {
            Button {
                copyToClipboard(selectedFiles)
            } label: {
                Label("Скопировать", systemImage: "doc.on.doc")
            }
            Button {
                transfer = FileTransfer(mode: .copy, files: selectedFiles)
            } label: {
                Label("Копировать в папку…", systemImage: "folder.badge.plus")
            }
        } label: {
            Label("Копировать", systemImage: "doc.on.doc")
        }
        .disabled(selectedFiles.isEmpty)
        .accessibilityIdentifier("bulkCopy")
    }

    private var deleteSelected: some View {
        Button(role: .destructive) {
            pendingDelete = selectedFiles
        } label: {
            Label("Удалить", systemImage: "trash")
        }
        .tint(.red)
        .disabled(selectedFiles.isEmpty)
        .accessibilityIdentifier("bulkDelete")
    }

    // MARK: - Пустая папка и вставка

    private var emptyState: some View {
        VStack(spacing: 14) {
            EmptyStateView(
                icon: "tray.and.arrow.down",
                title: "Папка пуста",
                subtitle: "Добавьте документы из «Файлов», фото из галереи или вставьте скопированное",
                accent: accent,
                actionTitle: "Добавить из «Файлов»",
                action: { showFileImporter = true }
            )
            pasteButton
                .buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Долгое нажатие на пустое место — «Вставить», как в «Файлах»
        .contextMenu {
            pasteButton
        } preview: {
            pastePreview
        }
    }

    /// Системная кнопка: читает буфер без запроса разрешения и сама гаснет,
    /// когда вставлять нечего
    private var pasteButton: some View {
        PasteButton(supportedContentTypes: FileClipboard.pasteTypes) { providers in
            importItems(providers)
        }
        .accessibilityIdentifier("filePaste")
    }

    private var pastePreview: some View {
        Label("Вставить в «\(folder.name)»", systemImage: "doc.on.clipboard")
            .font(.headline)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(Theme.card)
    }

    /// Пустое место под сеткой и между карточками
    private var pasteArea: some View {
        Color.clear
            .contentShape(Rectangle())
            .contextMenu {
                pasteButton
            } preview: {
                pastePreview
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
                let row = FileRow(
                    file: file,
                    accent: accent,
                    showsContentDate: sortOrder.showsContentDate,
                    showsChevron: !isSelecting
                )
                Group {
                    if isReordering {
                        reorderable(file: file) { row }
                    } else if let selection {
                        let isSelected = selection.contains(file.name)
                        Button {
                            toggle(file)
                        } label: {
                            HStack(spacing: 12) {
                                FileSelectionMark(isSelected: isSelected, accent: accent, placement: .inRow)
                                row
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    } else {
                        Button { previewFile = file } label: { row }
                            .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Theme.card)
                .listRowSeparatorTint(.black.opacity(0.06))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !isSelecting && !isReordering {
                        Button(role: .destructive) {
                            pendingDelete = [file]
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                        .tint(.red)
                        Button {
                            startRename(file)
                        } label: {
                            Label("Имя", systemImage: "pencil")
                        }
                        // Серый: под белой подписью заливка цветом текста в тёмной теме пропала бы
                        .tint(.gray)
                    }
                }
                .contextMenu { if !isReordering && !isSelecting { fileMenu(for: file) } }
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
                        gridCell(for: file, side: side)
                    }
                }
                .padding(padding)
                // Пустое место под сеткой тоже отвечает на долгое нажатие
                .frame(minHeight: geo.size.height, alignment: .top)
                .background {
                    if !isSelecting && !isReordering { pasteArea }
                }
            }
        }
    }

    @ViewBuilder
    private func gridCell(for file: VaultFile, side: CGFloat) -> some View {
        let cell = FileGridCell(
            file: file,
            accent: accent,
            side: side,
            showsContentDate: sortOrder.showsContentDate
        )
        if isReordering {
            reorderable(file: file) {
                cell.overlay(alignment: .topTrailing) { dragHandle }
            }
        } else if let selection {
            let isSelected = selection.contains(file.name)
            Button {
                toggle(file)
            } label: {
                cell
                    // Слева сверху: справа у видео уже стоит значок воспроизведения
                    .overlay(alignment: .topLeading) {
                        FileSelectionMark(isSelected: isSelected, accent: accent)
                            .padding(10)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(accent, lineWidth: isSelected ? 2.5 : 0)
                    }
                    .scaleEffect(isSelected ? 0.97 : 1)
                    .animation(.snappy(duration: 0.18), value: isSelected)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            Button { previewFile = file } label: { cell }
                .buttonStyle(.plain)
                .contextMenu { fileMenu(for: file) }
        }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(accent, style: StrokeStyle(lineWidth: 2.5, dash: [9, 7]))
            .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                Label("Отпустите, чтобы добавить", systemImage: "tray.and.arrow.down")
                    .font(.headline)
                    .foregroundStyle(accent)
            }
            .padding(12)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: - Выбор

    private func beginSelection() {
        isReordering = false
        withAnimation(.snappy) { selection = [] }
        Self.targetHaptic.prepare()
    }

    private func endSelection() {
        withAnimation(.snappy) { selection = nil }
    }

    private func toggle(_ file: VaultFile) {
        guard var current = selection else { return }
        if current.contains(file.name) {
            current.remove(file.name)
        } else {
            current.insert(file.name)
        }
        selection = current
        Self.targetHaptic.selectionChanged()
    }

    private var allVisibleSelected: Bool {
        guard let selection, !files.isEmpty else { return false }
        return files.allSatisfy { selection.contains($0.name) }
    }

    private func toggleSelectAll() {
        guard let current = selection else { return }
        selection = allVisibleSelected ? [] : current.union(files.map(\.name))
    }

    /// Удалённые и перенесённые файлы выпадают из выбора, а в опустевшей
    /// папке выбирать нечего
    private func pruneSelection(to names: [String]) {
        guard let current = selection else { return }
        guard !names.isEmpty else {
            endSelection()
            return
        }
        let kept = current.intersection(names)
        if kept != current { selection = kept }
    }

    // MARK: - Перестановка

    // contextMenu и draggable на одном вью в SwiftUI не уживаются: меню
    // забирает долгое нажатие. Поэтому перетаскивание живёт в отдельном режиме
    @ViewBuilder
    private func reorderable<Content: View>(
        file: VaultFile,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let targeted = dropTarget == file.name
        content()
            .overlay(alignment: insertionEdge) {
                if targeted {
                    Capsule()
                        .fill(accent)
                        .frame(
                            width: displayMode == .grid ? 5 : nil,
                            height: displayMode == .grid ? nil : 5
                        )
                        .padding(displayMode == .grid ? .vertical : .horizontal, 2)
                }
            }
            .scaleEffect(targeted ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: targeted)
            .draggable(FileDragPayload(name: file.name)) {
                FileGridCell(file: file, accent: accent, side: 96, showsContentDate: false)
            }
            .dropDestination(for: FileDragPayload.self) { payload, _ in
                dropTarget = nil
                guard let dragged = payload.first?.name else { return false }
                let moved = move(dragged, before: file.name)
                if moved { Self.dropHaptic.impactOccurred() }
                return moved
            } isTargeted: { isTargeted in
                if isTargeted {
                    guard dropTarget != file.name else { return }
                    dropTarget = file.name
                    Self.targetHaptic.selectionChanged()
                    Self.targetHaptic.prepare()
                } else if dropTarget == file.name {
                    dropTarget = nil
                }
            }
    }

    /// Файл встаёт на место того, на который навели, — значит указатель
    /// рисуем с той стороны, откуда он «войдёт» в сетку или список
    private var insertionEdge: Alignment {
        displayMode == .grid ? .leading : .top
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(6)
            .background(accent.opacity(0.9), in: Circle())
            .padding(8)
    }

    private var sortBinding: Binding<FileSortOrder> {
        Binding(
            get: { sortOrder },
            set: { newValue in
                // Мутация состояния прямо в сеттере Picker теряется в его транзакции
                Task { @MainActor in
                    if newValue == .manual {
                        // Выбрали «Вручную» — значит хотят расставлять прямо сейчас
                        if !isReordering { toggleReordering() }
                    } else {
                        isReordering = false
                        store.setSortOrder(newValue, for: folder)
                    }
                }
            }
        )
    }

    private func toggleReordering() {
        if isReordering {
            isReordering = false
            return
        }
        // Выбор и перестановка друг друга исключают: у обоих своё касание
        selection = nil
        // Ручной порядок начинается с того, что человек видит на экране,
        // поэтому снимок делаем до переключения сортировки
        store.setFileOrder(files.map(\.name), in: folder)
        store.setSortOrder(.manual, for: folder)
        isReordering = true
        Self.dropHaptic.impactOccurred()
        Self.targetHaptic.prepare()
        Self.dropHaptic.prepare()
    }

    @discardableResult
    private func move(_ dragged: String, before target: String) -> Bool {
        guard dragged != target else { return false }
        var names = files.map(\.name)
        guard let from = names.firstIndex(of: dragged) else { return false }
        names.remove(at: from)
        guard let to = names.firstIndex(of: target) else { return false }
        names.insert(dragged, at: to)
        store.setFileOrder(names, in: folder)
        return true
    }

    // MARK: - Меню файла

    @ViewBuilder
    private func fileMenu(for file: VaultFile) -> some View {
        Section {
            ShareLink(item: file.url) {
                Label("Поделиться", systemImage: "square.and.arrow.up")
            }
            Button {
                copyToClipboard([file])
            } label: {
                Label("Скопировать", systemImage: "doc.on.doc")
            }
        }
        Section {
            Button {
                transfer = FileTransfer(mode: .move, files: [file])
            } label: {
                Label("Переместить…", systemImage: "folder")
            }
            Button {
                transfer = FileTransfer(mode: .copy, files: [file])
            } label: {
                Label("Копировать в…", systemImage: "folder.badge.plus")
            }
            Button {
                duplicate(file)
            } label: {
                Label("Дублировать", systemImage: "plus.square.on.square")
            }
            Button {
                startRename(file)
            } label: {
                Label("Переименовать", systemImage: "pencil")
            }
        }
        Section {
            Button {
                infoFile = file
            } label: {
                Label("Сведения", systemImage: "info.circle")
            }
            .accessibilityIdentifier("fileInfo")
            Button {
                toggleReordering()
            } label: {
                Label("Переставить файлы", systemImage: "arrow.up.arrow.down")
            }
        }
        Button(role: .destructive) {
            pendingDelete = [file]
        } label: {
            Label("Удалить", systemImage: "trash")
        }
    }

    private func startRename(_ file: VaultFile) {
        newName = file.url.deletingPathExtension().lastPathComponent
        fileBeingRenamed = file
    }

    // MARK: - Перенос и копии

    private func perform(_ transfer: FileTransfer, into destination: VaultFolder) {
        endSelection()
        Task {
            let result: VaultStore.ImportResult
            switch transfer.mode {
            case .move:
                result = await store.moveFiles(transfer.files, from: folder, to: destination)
            case .copy:
                result = await store.copyFiles(transfer.files, to: destination)
            }
            if !result.imported.isEmpty {
                let verb = transfer.mode == .move ? "Перемещено" : "Скопировано"
                showToast("\(verb) в «\(destination.name)»")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            if !result.failed.isEmpty {
                let verb = transfer.mode == .move ? "переместить" : "скопировать"
                failure = Failure(
                    title: transfer.mode == .move ? "Не всё перемещено" : "Не всё скопировано",
                    message: "Не удалось \(verb) \(Self.quotedList(result.failed))."
                )
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func duplicate(_ file: VaultFile) {
        Task {
            if await store.duplicate(file) != nil {
                showToast("Копия создана")
            }
        }
    }

    private func copyToClipboard(_ files: [VaultFile]) {
        guard FileClipboard.copy(files) else { return }
        // Буфер очистится сам: человеку стоит знать, сколько у него времени
        showToast("Скопировано на 10 минут")
        if isSelecting { endSelection() }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard toast == text else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    // MARK: - Импорт

    /// Перетаскивание из других приложений. Во время своей перестановки и
    /// выбора — нет: там у касаний другая работа
    private var dropTypes: [UTType] {
        isReordering || isSelecting ? [] : [.item]
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let usable = providers.filter { VaultStore.isExternal($0) && VaultStore.importType(for: $0) != nil }
        guard !usable.isEmpty else { return false }
        importItems(usable)
        return true
    }

    /// Вставка и перетаскивание. Загрузка начинается в store сразу, здесь
    /// только ждём итога
    private func importItems(_ providers: [NSItemProvider]) {
        let loading = store.importItems(providers, to: folder)
        isImporting = true
        Task {
            let result = await loading.value
            isImporting = false
            if !result.imported.isEmpty {
                let added = result.imported.count == 1
                    ? "Добавлен «\(result.imported[0])»"
                    : "Добавлено: \(pluralize(result.imported.count, "файл", "файла", "файлов"))"
                showToast(added)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            if !result.failed.isEmpty {
                failure = Failure(title: "Файл не добавлен", message: Self.importFailureMessage(result.failed))
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            } else if result.imported.isEmpty {
                failure = Failure(
                    title: "Нечего вставить",
                    message: "В буфере обмена нет файла или фото — например, только ссылка."
                )
            }
        }
    }

    private func importPickedFiles(_ urls: [URL]) {
        isImporting = true
        Task {
            let result = await store.importFiles(urls, to: folder)
            isImporting = false
            if result.failed.isEmpty {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                failure = Failure(title: "Файл не добавлен", message: Self.importFailureMessage(result.failed))
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    /// Раньше неудачное копирование молча пропускалось — и выглядело так,
    /// будто кнопка «Открыть» ничего не делает
    static func importFailureMessage(_ names: [String]) -> String {
        "Не удалось скопировать \(quotedList(names)). Если файл в iCloud Drive, проверьте подключение к интернету и попробуйте ещё раз."
    }

    /// «a», «b», «c» и ещё 2
    static func quotedList(_ names: [String]) -> String {
        let list = names.prefix(3).map { "«\($0)»" }.joined(separator: ", ")
        let more = names.count > 3 ? " и ещё \(names.count - 3)" : ""
        return list + more
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

    /// Дата съёмки для файлов, импортированных до появления сортировки по ней
    private func backfillContentDates() async {
        let missing = store.fileNamesMissingContentDate(in: folder)
        guard !missing.isEmpty else { return }
        let dir = store.folderURL(folder)
        let fallbacks = Dictionary(
            store.files(in: folder).map { ($0.name, $0.addedAt) },
            uniquingKeysWith: { first, _ in first }
        )
        let found = await Task.detached { () -> [String: Date] in
            var result: [String: Date] = [:]
            for name in missing {
                let url = dir.appendingPathComponent(name)
                result[name] = MediaDate.originalDate(of: url) ?? fallbacks[name] ?? Date()
            }
            return result
        }.value
        store.setContentDates(found, in: folder)
    }

    // Отклик держим лёгким: тик как у колеса выбора, при постановке — слабый толчок.
    // Генераторы переиспользуем, иначе первый отклик заметно запаздывает
    private static let targetHaptic = UISelectionFeedbackGenerator()
    private static let dropHaptic = UIImpactFeedbackGenerator(style: .light)

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}
