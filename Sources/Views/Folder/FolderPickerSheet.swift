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

// Куда положить файлы: список папок хранилища. Текущей папки в нём нет, а
// суперскрытых — никогда, даже когда они открыты: лист не должен выдавать,
// что они существуют
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

    private var destinations: [VaultFolder] {
        store.folders.filter { $0.id != currentFolderID && !$0.isSuperHidden }
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
        NavigationStack {
            Group {
                if destinations.isEmpty {
                    ContentUnavailableView(
                        "Других папок нет",
                        systemImage: "folder.badge.plus",
                        description: Text("Создайте папку на экране «Файлы» и повторите.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(destinations) { folder in
                                Button {
                                    onPick(folder)
                                    dismiss()
                                } label: {
                                    FolderPickerRow(folder: folder, stats: store.stats(for: folder))
                                }
                                .accessibilityIdentifier("moveDestination-\(folder.name)")
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
}

// Строка папки: значок её цвета, имя и что внутри
private struct FolderPickerRow: View {
    let folder: VaultFolder
    let stats: (count: Int, size: Int64)

    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 36

    private var accent: Color { Theme.color(folder.color) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: folder.icon)
                .font(.system(size: badge * 0.42, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: badge, height: badge)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: badge * 0.28, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if folder.kind == .feed {
            parts.append(stats.count == 0 ? "Лента · пусто" : "Лента · \(pluralize(stats.count, "блок", "блока", "блоков"))")
        } else {
            parts.append(stats.count == 0 ? "Пусто" : pluralize(stats.count, "файл", "файла", "файлов"))
        }
        // Документ, перенесённый сюда, пропадёт из ответов чата — это видно заранее
        if !folder.searchable { parts.append("вне поиска") }
        return parts.joined(separator: " · ")
    }
}
