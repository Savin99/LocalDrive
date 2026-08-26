import SwiftUI

// Создание и редактирование папки: имя, иконка, цвет
struct FolderEditorView: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let folder: VaultFolder?

    @State private var name: String
    @State private var icon: String
    @State private var color: String

    init(folder: VaultFolder?) {
        self.folder = folder
        _name = State(initialValue: folder?.name ?? "")
        _icon = State(initialValue: folder?.icon ?? "folder.fill")
        _color = State(initialValue: folder?.color ?? "indigo")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        preview

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
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(trimmedName.isEmpty ? .secondary : .primary)
        }
        .animation(.snappy(duration: 0.2), value: icon)
        .animation(.snappy(duration: 0.2), value: color)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        if let folder {
            store.updateFolder(id: folder.id, name: trimmedName, icon: icon, color: color)
        } else {
            store.createFolder(name: trimmedName, icon: icon, color: color)
        }
        dismiss()
    }
}
