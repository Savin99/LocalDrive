import SwiftUI

/// Что переносим или копируем — лист выбора папки
struct FileTransfer: Identifiable {
    enum Mode {
        case move
        case copy
    }

    let id = UUID()
    let mode: Mode
    let files: [VaultFile]
}

// Куда положить файлы: дерево папок хранилища с отступами. Текущая папка видна
// бледной строкой без нажатия — ради вложенных в неё. Суперскрытых нет никогда,
// даже когда они открыты, и вместе с ними всего, что внутри: лист не должен
// выдавать, что они есть
struct FolderPickerSheet: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let transfer: FileTransfer
    /// Папка, из которой открыли лист; nil — из чата, где исходной папки нет
    let currentFolderID: UUID?
    let onPick: (VaultFolder) -> Void
    /// Заголовок и подпись для вложений чата: файлов хранилища у них ещё нет
    var customTitle: String? = nil
    var customSubject: String? = nil

    private var tree: [(folder: VaultFolder, depth: Int)] {
        store.tree(includingHidden: false)
    }

    private var title: String {
        if let customTitle { return customTitle }
        return switch transfer.mode {
        case .move: "Переместить в папку"
        case .copy: "Копировать в папку"
        }
    }

    private var subject: String {
        if let customSubject { return customSubject }
        if transfer.files.count == 1, let file = transfer.files.first { return "«\(file.name)»" }
        return pluralize(transfer.files.count, "файл", "файла", "файлов")
    }

    var body: some View {
        let tree = self.tree
        NavigationStack {
            Group {
                if !tree.contains(where: { $0.folder.id != currentFolderID }) {
                    ContentUnavailableView(
                        "Других папок нет",
                        systemImage: "folder.badge.plus",
                        description: Text("Создайте папку на экране «Файлы» и повторите.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(tree, id: \.folder.id) { entry in
                                row(entry.folder, depth: entry.depth)
                            }
                        } header: {
                            Text(subject)
                                .textCase(nil)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .listRowBackground(Theme.card)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .tint(Theme.ink)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func row(_ folder: VaultFolder, depth: Int) -> some View {
        let label = FolderRow(
            folder: folder,
            stats: store.stats(for: folder),
            depth: depth,
            marksUnsearchable: !store.isIndexable(folder),
            showsChevron: folder.id != currentFolderID
        )
        if folder.id == currentFolderID {
            // Файлы уже здесь: строка остаётся только как узел дерева
            label
                .opacity(0.45)
                .accessibilityIdentifier("currentFolder-\(folder.name)")
        } else {
            Button {
                onPick(folder)
                dismiss()
            } label: {
                label
            }
            .accessibilityIdentifier("moveDestination-\(folder.name)")
        }
    }
}

// Куда переложить папку: «Мои файлы» (верхний уровень) или другая обычная
// папка. Самой папки и её поддерева в листе нет — в себя её не положить;
// лент тоже нет — папок они не держат. Суперскрытых нет, как и в листе для файлов
struct FolderMoveSheet: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let folder: VaultFolder
    /// Выбранный родитель; nil — верхний уровень
    let onPick: (UUID?) -> Void

    private var destinations: [(folder: VaultFolder, depth: Int)] {
        let excluded = Set([folder.id] + store.descendants(of: folder.id).map(\.id))
        var skippedDepth: Int?
        var result: [(folder: VaultFolder, depth: Int)] = []
        for entry in store.tree(includingHidden: false) {
            // Поддерево самой папки пропускается целиком
            if let depth = skippedDepth, entry.depth > depth { continue }
            skippedDepth = nil
            if excluded.contains(entry.folder.id) {
                skippedDepth = entry.depth
                continue
            }
            if entry.folder.canContainSubfolders { result.append(entry) }
        }
        return result
    }

    private var currentParentID: UUID? {
        store.folder(by: folder.id)?.parentID ?? folder.parentID
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        pick(nil)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "house")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 36, height: 36)
                                .background(Theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Мои файлы")
                                    .font(.system(.body, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                Text(currentParentID == nil ? "Папка уже здесь" : "Верхний уровень")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .disabled(currentParentID == nil)
                    .opacity(currentParentID == nil ? 0.45 : 1)
                    .accessibilityIdentifier("folderDestination-root")

                    ForEach(destinations, id: \.folder.id) { entry in
                        let isCurrent = entry.folder.id == currentParentID
                        Button {
                            pick(entry.folder.id)
                        } label: {
                            FolderRow(
                                folder: entry.folder,
                                stats: store.stats(for: entry.folder),
                                depth: entry.depth + 1,
                                marksUnsearchable: !store.isIndexable(entry.folder),
                                showsChevron: !isCurrent
                            )
                        }
                        .disabled(isCurrent)
                        .opacity(isCurrent ? 0.45 : 1)
                        .accessibilityIdentifier("folderDestination-\(entry.folder.name)")
                    }
                } header: {
                    Text("«\(folder.name)»")
                        .textCase(nil)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } footer: {
                    Text("Папка переедет вместе со всем, что внутри.")
                }
                .listRowBackground(Theme.card)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Переместить папку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .tint(Theme.ink)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func pick(_ parentID: UUID?) {
        onPick(parentID)
        dismiss()
    }
}
