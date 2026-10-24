import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Лента как документ: одна страница, блоки лежат прямо на ней, текст правится
// инлайн, ряды фото верстаются по пропорциям. Карточек, теней и ручек
// перетаскивания у блоков больше нет — их роль играет сама страница.
struct FeedFolderView: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let folder: VaultFolder

    /// Локальный черновик: правки видны сразу, на диск уходят по завершении ввода
    @State private var blocks: [FeedBlock] = []
    @State private var aspects: [String: Double] = [:]
    @State private var focus: FeedFocus?
    /// nil — режим выделения выключен
    @State private var selection: Set<UUID>?

    @State private var hoveredGap: Int?
    @State private var hoveredSeam: FeedSeam?

    @State private var previewFile: VaultFile?

    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importError: String?

    @State private var pendingDelete: Set<UUID>?
    @State private var titleOpacity: Double = 0

    @Namespace private var zoomNamespace

    private var accent: Color { Theme.color(folder.color) }
    private var isSelecting: Bool { selection != nil }
    private var previewFiles: [VaultFile] {
        // Порядок тот же, что на странице ленты:
        // фото, видео и документы входят в одну цепочку.
        blocks.flatMap(resolvedFiles)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()

            page

            FeedStickyHeader(
                folder: folder,
                accent: accent,
                titleOpacity: titleOpacity,
                isSelecting: isSelecting,
                shareURLs: headerShareURLs,
                onBack: { dismiss() },
                onStartSelecting: { beginSelection(with: nil) },
                onFinishSelecting: { endSelection() },
                onSelectAll: { beginSelection(with: nil, all: true) }
            )

            if isImporting {
                ProgressView()
                    .controlSize(.large)
                    .padding(24)
                    .cardStyle()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .tint(accent)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .task {
            syncFromStore()
            await backfillAspects()
        }
        .onChange(of: store.revision) { _, _ in syncFromStore() }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                importPickedFiles(urls)
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert(
            "Файл не добавлен",
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: 30,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            importPickedPhotos(items)
        }
        .sheet(item: $previewFile) { file in
            FilePagerView(files: previewFiles, initialFile: file) { previewFile = nil }
                .ignoresSafeArea()
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let ids = pendingDelete {
                    withAnimation(.snappy) { store.deleteFeedBlocks(ids: ids, in: folder) }
                    selection = selection.map { $0.subtracting(ids) }
                }
                pendingDelete = nil
            }
            Button("Отмена", role: .cancel) { pendingDelete = nil }
        } message: {
            if deletesFiles {
                Text("Вложенные файлы также удалятся с устройства.")
            }
        }
    }

    // MARK: - Страница

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(folder.name)
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, FeedPage.textInset)
                    .padding(.bottom, 14)

                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, FeedPage.textInset)

                blockList
            }
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: FeedPage.pageRadius, style: .continuous))
            .padding(.horizontal, FeedPage.sideInset)
            .padding(.top, 58)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            // Заголовок страницы уходит под шапку — проявляем название в ней
            let target = min(1, max(0, (offset - 46) / 34))
            if abs(target - titleOpacity) > 0.01 { titleOpacity = target }
        }
    }

    private var blockList: some View {
        VStack(spacing: 0) {
            gap(at: 0)

            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                blockRow(block)
                gap(at: index + 1)
            }

            tailTapArea
        }
    }

    private func gap(at index: Int) -> some View {
        FeedInsertionGap(
            index: index,
            accent: accent,
            height: FeedPage.blockGap,
            onDrop: handleBlockDrop,
            hovered: $hoveredGap
        )
    }

    /// Пустое место под последним блоком: тап здесь начинает новый абзац,
    /// как продолжение документа
    private var tailTapArea: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if blocks.isEmpty {
                Text("Начните печатать, добавьте фото или документ")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, FeedPage.textInset)
            }
        }
        .frame(height: 60)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { appendParagraph() }
        .accessibilityIdentifier("feedTail")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Добавить абзац")
    }

    // MARK: - Блок

    // Жесты разведены намеренно: contextMenu и draggable на одном вью в SwiftUI
    // не уживаются — меню забирает долгое нажатие, и перетаскивание не стартует.
    // Поэтому блоки тянутся в режиме выделения (как в референсе), фото — всегда,
    // а меню остаётся там, где отдельных перетаскиваемых элементов внутри нет.
    @ViewBuilder
    private func blockRow(_ block: FeedBlock) -> some View {
        let content = blockRowBody(block)

        if isSelecting {
            content.draggable(dragPayload(for: block)) {
                FeedDragPreview(block: block, accent: accent, count: dragCount(for: block))
            }
        } else if block.kind == .media {
            content
        } else {
            content.contextMenu { blockMenu(block) }
        }
    }

    @ViewBuilder
    private func blockRowBody(_ block: FeedBlock) -> some View {
        let selected = selection?.contains(block.id) == true

        HStack(alignment: .top, spacing: 8) {
            blockContent(block)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isSelecting {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? accent : Color.secondary.opacity(0.5))
                    .padding(.trailing, FeedPage.textInset)
                    .padding(.top, block.kind == .text ? 0 : 6)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityIdentifier("feedBlockToggle")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(selected ? "Снять выделение" : "Выделить блок")
                    .accessibilityAction { toggleSelection(block.id) }
            }
        }
        .padding(.vertical, isSelecting ? 4 : 0)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.10))
                    .padding(.horizontal, FeedPage.mediaInset - 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelecting else { return }
            toggleSelection(block.id)
        }
    }

    @ViewBuilder
    private func blockContent(_ block: FeedBlock) -> some View {
        switch block.kind {
        case .text:
            FeedTextBlockEditor(
                blockID: block.id,
                text: textBinding(block.id),
                isFocused: focus?.id == block.id,
                isEnabled: !isSelecting,
                placeholder: blocks.count == 1 ? "Начните печатать…" : "",
                caret: focus?.id == block.id ? focus?.caret : nil,
                onFocus: { caret in focus = FeedFocus(block.id, caret: caret) },
                onBlur: { commitText(block.id) },
                onSplit: { prefix, suffix in splitBlock(block.id, prefix: prefix, suffix: suffix) },
                onMergeBackward: { _ in mergeBackward(block.id) }
            )
            .padding(.horizontal, FeedPage.textInset)

        case .media:
            let files = resolvedFiles(block)
            if files.isEmpty {
                missingContent
            } else {
                FeedMediaRow(
                    block: block,
                    files: files,
                    aspects: files.map { aspects[$0.name] ?? MediaAspect.fallback },
                    accent: accent,
                    isSelecting: isSelecting,
                    zoomNamespace: zoomNamespace,
                    onOpen: openMedia,
                    onDropMedia: handleSeamDrop,
                    hoveredSeam: $hoveredSeam
                )
                .padding(.horizontal, FeedPage.mediaInset)
            }

        case .file:
            if let file = resolvedFiles(block).first {
                Button {
                    guard !isSelecting else { return }
                    previewFile = file
                } label: {
                    FileRow(file: file, accent: accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Theme.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, FeedPage.mediaInset)
            } else {
                missingContent
            }
        }
    }

    private var missingContent: some View {
        Label("Вложение недоступно", systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, FeedPage.textInset)
    }

    @ViewBuilder
    private func blockMenu(_ block: FeedBlock) -> some View {
        if block.kind == .text {
            Button {
                focus = FeedFocus(block.id)
            } label: {
                Label("Редактировать", systemImage: "pencil")
            }
        }

        let urls = resolvedFiles(block).map(\.url)
        if !urls.isEmpty {
            ShareLink(items: urls) {
                Label("Поделиться", systemImage: "square.and.arrow.up")
            }
        }

        Button {
            beginSelection(with: block.id)
        } label: {
            Label("Выбрать", systemImage: "checkmark.circle")
        }

        if store.canMergeMediaBlockWithPrevious(block, in: folder) {
            Button {
                withAnimation(.snappy) { store.mergeMediaBlockWithPrevious(block, in: folder) }
            } label: {
                Label("В ряд с предыдущими", systemImage: "rectangle.split.3x1")
            }
        }

        if block.kind == .media, block.fileNames.count > 1 {
            Button {
                withAnimation(.snappy) { store.splitMediaBlock(block, in: folder) }
            } label: {
                Label("Разделить ряд", systemImage: "rectangle.split.1x2")
            }
        }

        Button {
            withAnimation(.snappy) { store.moveFeedBlock(id: block.id, offset: -1, in: folder) }
        } label: {
            Label("Переместить выше", systemImage: "arrow.up")
        }
        .disabled(!store.canMoveFeedBlock(id: block.id, offset: -1, in: folder))

        Button {
            withAnimation(.snappy) { store.moveFeedBlock(id: block.id, offset: 1, in: folder) }
        } label: {
            Label("Переместить ниже", systemImage: "arrow.down")
        }
        .disabled(!store.canMoveFeedBlock(id: block.id, offset: 1, in: folder))

        Divider()

        Button(role: .destructive) {
            requestDelete([block.id])
        } label: {
            Label("Удалить блок", systemImage: "trash")
        }
    }

    // MARK: - Нижняя панель

    @ViewBuilder
    private var bottomBar: some View {
        if isSelecting {
            FeedSelectionToolbar(
                accent: accent,
                canMerge: store.canMergeMediaBlocks(ids: selection ?? [], in: folder),
                canSplit: canSplitSelection,
                shareURLs: selectionShareURLs,
                canMoveUp: canMoveSelection(by: -1),
                canMoveDown: canMoveSelection(by: 1),
                onMerge: {
                    withAnimation(.snappy) { store.mergeMediaBlocks(ids: selection ?? [], in: folder) }
                    endSelection()
                },
                onSplit: {
                    withAnimation(.snappy) { store.splitMediaBlocks(ids: selection ?? [], in: folder) }
                    endSelection()
                },
                onDelete: { requestDelete(selection ?? []) },
                onMoveUp: { moveSelection(by: -1) },
                onMoveDown: { moveSelection(by: 1) }
            )
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            composer
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            if !blocks.isEmpty {
                Button {
                    beginSelection(with: nil)
                } label: {
                    Label("Выбрать", systemImage: "checkmark.circle")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 0.8))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            Menu {
                Button {
                    appendParagraph()
                } label: {
                    Label("Текст", systemImage: "text.alignleft")
                }
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Фото или видео", systemImage: "photo.on.rectangle")
                }
                Button {
                    showFileImporter = true
                } label: {
                    Label("Документ из «Файлов»", systemImage: "paperclip")
                }
                Section {
                    PasteButton(supportedContentTypes: FileClipboard.pasteTypes) { providers in
                        pasteItems(providers)
                    }
                    .accessibilityIdentifier("filePaste")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(accent, in: Circle())
                    .shadow(color: accent.opacity(0.35), radius: 12, y: 4)
            }
            .accessibilityLabel("Добавить блок")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: - Черновик и синхронизация

    private func syncFromStore() {
        let document = store.feedDocument(in: folder)
        aspects = document.aspects

        // Текст блока в фокусе живёт в UITextView — из хранилища его не перетираем
        if let editing = focus?.id,
           let local = blocks.first(where: { $0.id == editing }),
           var incoming = Optional(document.blocks),
           let index = incoming.firstIndex(where: { $0.id == editing }) {
            incoming[index].text = local.text
            blocks = incoming
        } else {
            blocks = document.blocks
        }

        if let current = selection {
            let alive = current.intersection(Set(blocks.map(\.id)))
            selection = alive
        }
        if let focused = focus?.id, !blocks.contains(where: { $0.id == focused }) {
            focus = nil
        }
    }

    private func textBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { blocks.first(where: { $0.id == id })?.text ?? "" },
            set: { value in
                guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
                blocks[index].text = value
            }
        )
    }

    private func commitText(_ id: UUID) {
        guard let block = blocks.first(where: { $0.id == id }) else { return }
        store.updateTextBlock(id: id, text: block.text ?? "", in: folder)
        if focus?.id == id { focus = nil }
    }

    private func resolvedFiles(_ block: FeedBlock) -> [VaultFile] {
        block.fileNames.compactMap { store.file(named: $0, in: folder) }
    }

    // MARK: - Правка текста

    private func appendParagraph() {
        let index = insertionIndex()
        // Пустой абзац на этом месте уже есть — просто ставим в него каретку
        if index > 0, index - 1 < blocks.count,
           blocks[index - 1].kind == .text,
           (blocks[index - 1].text ?? "").isEmpty {
            focus = FeedFocus(blocks[index - 1].id)
            return
        }
        let block = store.addTextBlock("", to: folder, at: index)
        focus = FeedFocus(block.id)
    }

    private func splitBlock(_ id: UUID, prefix: String, suffix: String) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].text = prefix
        store.updateTextBlock(id: id, text: prefix, in: folder)
        let created = store.addTextBlock(suffix, to: folder, at: index + 1)
        focus = FeedFocus(created.id, caret: 0)
    }

    private func mergeBackward(_ id: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let current = blocks[index].text ?? ""
        let previous = blocks[index - 1]

        if previous.kind == .text {
            let head = previous.text ?? ""
            // Черновик правим до записи в хранилище: syncFromStore бережёт текст
            // блока в фокусе, и устаревшее локальное значение затёрло бы склейку
            blocks[index - 1].text = head + current
            store.updateTextBlock(id: previous.id, text: head + current, in: folder)
            store.deleteFeedBlocks(ids: [id], in: folder)
            focus = FeedFocus(previous.id, caret: head.utf16.count)
        } else if current.isEmpty {
            // Пустой абзац под фото просто исчезает
            let above = blocks[..<index].last(where: { $0.kind == .text })
            store.deleteFeedBlocks(ids: [id], in: folder)
            focus = above.map { FeedFocus($0.id) }
        }
    }

    /// Куда вставлять новое содержимое: сразу под тем блоком, где стоит каретка
    private func insertionIndex() -> Int {
        if let focused = focus?.id, let index = blocks.firstIndex(where: { $0.id == focused }) {
            return index + 1
        }
        if let selected = selection, let last = blocks.lastIndex(where: { selected.contains($0.id) }) {
            return last + 1
        }
        return blocks.count
    }

    // MARK: - Перетаскивание

    private func dragPayload(for block: FeedBlock) -> FeedDragPayload {
        if let selected = selection, selected.contains(block.id), selected.count > 1 {
            return .blocks(blocks.filter { selected.contains($0.id) }.map(\.id))
        }
        return .blocks([block.id])
    }

    private func dragCount(for block: FeedBlock) -> Int {
        if let selected = selection, selected.contains(block.id) { return selected.count }
        return 1
    }

    private func handleBlockDrop(_ payload: FeedDragPayload, at index: Int) -> Bool {
        withAnimation(.snappy) {
            switch payload {
            case .blocks(let ids):
                store.moveFeedBlocks(ids: Set(ids), toIndex: index, in: folder)
            case .media(let blockID, let fileName):
                store.extractFeedMedia(fileName: fileName, from: blockID, toBlockIndex: index, in: folder)
            }
        }
        hoveredGap = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }

    private func handleSeamDrop(_ payload: FeedDragPayload, seam: FeedSeam) -> Bool {
        guard case .media(let blockID, let fileName) = payload else { return false }
        withAnimation(.snappy) {
            store.moveFeedMedia(
                fileName: fileName,
                from: blockID,
                to: seam.blockID,
                atIndex: seam.index,
                in: folder
            )
        }
        hoveredSeam = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }

    // MARK: - Выделение

    private func beginSelection(with id: UUID?, all: Bool = false) {
        focus = nil
        withAnimation(.snappy) {
            if all {
                selection = Set(blocks.map(\.id))
            } else if let id {
                selection = [id]
            } else {
                selection = []
            }
        }
    }

    private func endSelection() {
        withAnimation(.snappy) { selection = nil }
    }

    private func toggleSelection(_ id: UUID) {
        guard var current = selection else { return }
        if current.contains(id) { current.remove(id) } else { current.insert(id) }
        withAnimation(.snappy(duration: 0.15)) { selection = current }
    }

    /// Выделение двигается как единое целое: считаем по краю в нужную сторону
    private func canMoveSelection(by offset: Int) -> Bool {
        guard let selected = selection, !selected.isEmpty else { return false }
        let indices = blocks.indices.filter { selected.contains(blocks[$0].id) }
        guard let first = indices.first, let last = indices.last else { return false }
        return offset < 0 ? first > 0 : last < blocks.count - 1
    }

    private func moveSelection(by offset: Int) {
        guard let selected = selection, canMoveSelection(by: offset) else { return }
        let indices = blocks.indices.filter { selected.contains(blocks[$0].id) }
        guard let first = indices.first, let last = indices.last else { return }
        // Индекс в координатах исходного массива: вверх — за соседа сверху,
        // вниз — за соседа снизу
        let target = offset < 0 ? first - 1 : last + 2
        withAnimation(.snappy) {
            store.moveFeedBlocks(ids: selected, toIndex: target, in: folder)
        }
    }

    private var canSplitSelection: Bool {
        guard let selected = selection else { return false }
        return blocks.contains { selected.contains($0.id) && $0.kind == .media && $0.fileNames.count > 1 }
    }

    // Обе подборки собираются из черновика по именам: они считаются на каждую
    // перерисовку, а обращение к диску здесь означало бы stat на каждое нажатие
    private var selectionShareURLs: [URL] {
        guard let selected = selection else { return [] }
        let dir = store.folderURL(folder)
        return blocks
            .filter { selected.contains($0.id) }
            .flatMap(\.fileNames)
            .map { dir.appendingPathComponent($0) }
    }

    private var headerShareURLs: [URL] {
        let dir = store.folderURL(folder)
        return blocks
            .flatMap(\.fileNames)
            .prefix(40)
            .map { dir.appendingPathComponent($0) }
    }

    // MARK: - Просмотр медиа

    private func openMedia(_ fileName: String) {
        guard let file = previewFiles.first(where: { $0.name == fileName }) else { return }
        focus = nil
        previewFile = file
    }

    // MARK: - Удаление

    private func requestDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDelete = ids
    }

    private var deleteTitle: String {
        guard let ids = pendingDelete else { return "Удалить блок?" }
        if ids.count > 1 { return "Удалить \(pluralize(ids.count, "блок", "блока", "блоков"))?" }
        guard let block = blocks.first(where: { ids.contains($0.id) }) else { return "Удалить блок?" }
        return switch block.kind {
        case .text: "Удалить текстовый блок?"
        case .media: "Удалить ряд медиа?"
        case .file: "Удалить файл?"
        }
    }

    private var deletesFiles: Bool {
        guard let ids = pendingDelete else { return false }
        return blocks.contains { ids.contains($0.id) && !$0.fileNames.isEmpty }
    }

    // MARK: - Импорт

    private func importPickedFiles(_ urls: [URL]) {
        isImporting = true
        Task {
            let result = await store.importFiles(urls, to: folder)
            await insert(result.imported)
            isImporting = false
            if result.failed.isEmpty {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                importError = FolderDetailView.importFailureMessage(result.failed)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    /// Вставка из буфера: файлы встают блоками туда же, куда и импорт.
    /// Загрузка начинается в store сразу — потом буфер уже недоступен
    private func pasteItems(_ providers: [NSItemProvider]) {
        let loading = store.importItems(providers, to: folder)
        isImporting = true
        Task {
            let result = await loading.value
            await insert(result.imported)
            isImporting = false
            if !result.failed.isEmpty {
                importError = FolderDetailView.importFailureMessage(result.failed)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            } else if result.imported.isEmpty {
                importError = "В буфере обмена нет файла или фото — например, только ссылка."
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private func importPickedPhotos(_ items: [PhotosPickerItem]) {
        isImporting = true
        Task {
            var names: [String] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let stamp = Self.nameFormatter.string(from: Date())
                if let name = store.importData(data, preferredName: "Медиа \(stamp).\(ext)", to: folder) {
                    names.append(name)
                }
            }
            await insert(names)
            photoItems = []
            isImporting = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// Медиа уходит в ряды, остальное — в отдельные блоки-файлы
    private func insert(_ names: [String]) async {
        guard !names.isEmpty else { return }
        let dir = store.folderURL(folder)
        var media: [String] = []
        var documents: [String] = []
        var probed: [String: Double] = [:]

        for name in names {
            let url = dir.appendingPathComponent(name)
            if MediaAspect.isMedia(url) {
                media.append(name)
                probed[name] = await MediaAspect.probe(url) ?? MediaAspect.fallback
            } else {
                documents.append(name)
            }
        }

        let index = insertionIndex()
        withAnimation(.snappy) {
            store.addMediaBlocks(media, to: folder, at: index, aspects: probed)
            store.addFileBlocks(documents, to: folder, at: index + (media.isEmpty ? 0 : rowCount(media)))
        }
        focus = nil
    }

    private func rowCount(_ names: [String]) -> Int {
        Int(ceil(Double(names.count) / 3))
    }

    /// Пропорции для лент, созданных до появления justified-раскладки
    private func backfillAspects() async {
        let missing = store.fileNamesMissingAspect(in: folder)
        guard !missing.isEmpty else { return }
        let dir = store.folderURL(folder)
        var found: [String: Double] = [:]
        for name in missing {
            found[name] = await MediaAspect.probe(dir.appendingPathComponent(name)) ?? MediaAspect.fallback
        }
        store.setAspects(found, in: folder)
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}

// Превью перетаскивания: у группы — бейдж с числом блоков, как в референсе
private struct FeedDragPreview: View {
    let block: FeedBlock
    let accent: Color
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(accent)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.card, in: Capsule())
        .overlay(alignment: .topTrailing) {
            if count > 1 {
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(accent, in: Circle())
                    .offset(x: 6, y: -6)
            }
        }
        .shadow(radius: 8)
    }

    private var icon: String {
        switch block.kind {
        case .text: "text.alignleft"
        case .media: "photo.on.rectangle"
        case .file: "doc"
        }
    }

    private var title: String {
        switch block.kind {
        case .text:
            let text = (block.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Пустой абзац" : text
        case .media:
            return pluralize(block.fileNames.count, "фото", "фото", "фото")
        case .file:
            return block.fileNames.first ?? "Файл"
        }
    }
}
