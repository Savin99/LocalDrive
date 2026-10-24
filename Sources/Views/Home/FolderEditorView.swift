import SwiftUI

// Создание и редактирование папки: тип, видимость, имя, иконка, цвет.
// Вложенная папка наследует скрытость и «вне поиска» от папок выше: такие
// переключатели показывают унаследованное и не меняются
struct FolderEditorView: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let folder: VaultFolder?
    /// Внутри какой папки создать новую; nil — на верхнем уровне
    let parentID: UUID?

    @State private var name: String
    @State private var icon: String
    @State private var color: String
    @State private var kind: VaultFolderKind
    @State private var isSuperHidden: Bool
    @State private var searchable: Bool

    init(folder: VaultFolder?, parentID: UUID? = nil) {
        self.folder = folder
        self.parentID = folder?.parentID ?? parentID
        _name = State(initialValue: folder?.name ?? "")
        _icon = State(initialValue: folder?.icon ?? "folder.fill")
        _color = State(initialValue: folder?.color ?? "indigo")
        _kind = State(initialValue: folder?.kind ?? .files)
        _isSuperHidden = State(initialValue: folder?.isSuperHidden ?? false)
        _searchable = State(initialValue: folder?.searchable ?? true)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parent: VaultFolder? {
        parentID.flatMap(store.folder(by:))
    }

    /// Папки выше этой, от верхнего уровня до родителя
    private var ancestors: [VaultFolder] {
        parent.map(store.lineage(of:)) ?? []
    }

    /// Ближайшая суперскрытая папка выше: она прячет и эту
    private var hidingAncestor: VaultFolder? {
        ancestors.last(where: \.isSuperHidden)
    }

    /// Ближайшая папка выше, выключенная из поиска: выключает и эту
    private var unsearchableAncestor: VaultFolder? {
        ancestors.last { !$0.isIndexable }
    }

    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        preview

                        if folder == nil {
                            folderKindPicker
                        }

                        visibilityPicker

                        VStack(alignment: .leading, spacing: 8) {
                            Text("НАЗВАНИЕ")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("Например, Документы", text: $name)
                                .font(.body)
                                .padding(14)
                                .cardStyle(cornerRadius: 14)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("ЦВЕТ")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                ForEach(Theme.palette, id: \.name) { item in
                                    Button {
                                        color = item.name
                                    } label: {
                                        Circle()
                                            .fill(item.color)
                                            .frame(width: 32, height: 32)
                                            .overlay {
                                                if color == item.name {
                                                    Circle()
                                                        .stroke(item.color.opacity(0.4), lineWidth: 3)
                                                        .padding(-4)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .cardStyle(cornerRadius: 14)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("ИКОНКА")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: iconColumns, spacing: 12) {
                                ForEach(Theme.folderIcons, id: \.self) { name in
                                    Button {
                                        icon = name
                                    } label: {
                                        Image(systemName: name)
                                            .font(.system(size: 19))
                                            .foregroundStyle(icon == name ? .white : .primary.opacity(0.7))
                                            .frame(width: 46, height: 46)
                                            .background(
                                                icon == name ? Theme.color(color) : Color.black.opacity(0.04),
                                                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(14)
                            .cardStyle(cornerRadius: 14)
                        }

                        // В конце формы, а не над названием: выше поле названия
                        // уезжало бы под клавиатуру, и форма прокручивалась при вводе
                        searchPicker
                    }
                    .padding(20)
                }
            }
            .navigationTitle(folder == nil ? "Новая папка" : "Изменить папку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { save() }
                        .fontWeight(.semibold)
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    private var preview: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.color(color).opacity(0.15))
                    .frame(width: 76, height: 76)
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Theme.color(color))
            }
            Text(trimmedName.isEmpty ? "Без названия" : trimmedName)
                .font(.system(.headline))
                .foregroundStyle(trimmedName.isEmpty ? .secondary : .primary)
            Text(kind.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let parent {
                Label("В папке «\(store.path(of: parent))»", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if isSuperHidden || hidingAncestor != nil {
                Label("Суперскрытая", systemImage: "eye.slash.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.color(color))
            }
        }
        .animation(.snappy(duration: 0.2), value: icon)
        .animation(.snappy(duration: 0.2), value: color)
    }

    private var visibilityPicker: some View {
        Toggle(isOn: Binding(
            get: { isSuperHidden || hidingAncestor != nil },
            set: { isSuperHidden = $0 }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Суперскрытая папка", systemImage: "eye.slash.fill")
                    .font(.system(.subheadline, weight: .semibold))
                Text(visibilityCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Theme.color(color))
        .disabled(hidingAncestor != nil)
        .padding(14)
        .cardStyle(cornerRadius: 14)
    }

    private var visibilityCaption: String {
        if let hidingAncestor {
            return "Скрыта вместе с папкой «\(hidingAncestor.name)»"
        }
        return parent == nil
            ? "Не показывать на главном экране и в недавних до секретного жеста"
            : "Не показывать в папке и в недавних до секретного жеста"
    }

    /// У суперскрытой папки переключатель выключен и не включается: то, чего
    /// нет в индексе, поиск найти не может
    private var searchPicker: some View {
        let hidden = isSuperHidden || hidingAncestor != nil
        let inherited = !hidden && unsearchableAncestor != nil
        return Toggle(isOn: Binding(
            get: { searchable && !hidden && !inherited },
            set: { searchable = $0 }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Доступна для поиска", systemImage: "text.magnifyingglass")
                    .font(.system(.subheadline, weight: .semibold))
                Text(searchCaption(hidden: hidden))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Theme.color(color))
        .disabled(hidden || inherited)
        .padding(14)
        .cardStyle(cornerRadius: 14)
        .accessibilityIdentifier("folderSearchable")
    }

    private func searchCaption(hidden: Bool) -> String {
        if hidden { return "Суперскрытые папки не распознаются и не ищутся" }
        if let unsearchableAncestor {
            return "Поиск выключен у папки «\(unsearchableAncestor.name)» — и для всего внутри неё"
        }
        return "Текст документов распознаётся на iPhone и находится в поиске"
    }

    private var folderKindPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ФОРМАТ")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                ForEach(VaultFolderKind.allCases, id: \.rawValue) { item in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            kind = item
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(kind == item ? .white : Theme.color(color))
                            Text(item.title)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(kind == item ? .white : .primary)
                            Text(item.subtitle)
                                .font(.caption2)
                                .foregroundStyle(kind == item ? .white.opacity(0.8) : .secondary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
                        .padding(14)
                        .background(
                            kind == item ? Theme.color(color) : Theme.card,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(kind == item ? .clear : Theme.hairline, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("folderKind-\(item.rawValue)")
                }
            }
        }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        if let folder {
            store.updateFolder(
                id: folder.id,
                name: trimmedName,
                icon: icon,
                color: color,
                isSuperHidden: isSuperHidden,
                searchable: searchable
            )
        } else {
            store.createFolder(
                name: trimmedName,
                icon: icon,
                color: color,
                kind: kind,
                isSuperHidden: isSuperHidden,
                searchable: searchable,
                parentID: parentID
            )
        }
        dismiss()
    }
}
