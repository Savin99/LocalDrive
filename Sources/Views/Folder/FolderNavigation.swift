import SwiftUI

// Навигация по дереву папок. Стек живёт в HomeView (`NavigationStack(path:)`),
// вложенные экраны получают его через окружение: открыть вложенную папку —
// дописать её UUID, нажать на крошку — обрезать путь до своего уровня
extension EnvironmentValues {
    /// Путь стека «Файлов»; nil — экран открыт вне него
    @Entry var folderPath: Binding<[UUID]>? = nil
    /// Открыты ли суперскрытые папки секретным жестом. Без него суперскрытая
    /// вложенная папка не видна и внутри обычной
    @Entry var revealsHiddenFolders = false
    /// Пространство имён зума: карточка папки раскрывается в её экран
    @Entry var folderZoomNamespace: Namespace.ID? = nil
}

// Крошки над вложенной папкой: «Мои файлы › Документы › Паспорта». Каждая,
// кроме последней, возвращает на свой уровень. Длинный путь листается вбок
// и сразу показывает свой конец — текущую папку
struct FolderBreadcrumbs: View {
    /// Папки от верхнего уровня до текущей включительно
    let lineage: [VaultFolder]
    let accent: Color
    /// Сколько папок оставить в стеке: 0 — вернуться к «Моим файлам»
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                crumb("Мои файлы", depth: 0, isCurrent: false)
                    .accessibilityIdentifier("breadcrumb-root")
                ForEach(Array(lineage.enumerated()), id: \.element.id) { index, folder in
                    Image(systemName: "chevron.compact.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    crumb(folder.name, depth: index + 1, isCurrent: index == lineage.count - 1)
                        .accessibilityIdentifier("breadcrumb-\(folder.name)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        // Длинный путь открывается своим концом — текущей папкой. Короткий
        // остаётся у левого края: якорь только для начального положения
        .defaultScrollAnchor(.trailing, for: .initialOffset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Путь к папке")
    }

    @ViewBuilder
    private func crumb(_ title: String, depth: Int, isCurrent: Bool) -> some View {
        if isCurrent {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .accessibilityAddTraits(.isHeader)
        } else {
            Button {
                onSelect(depth)
            } label: {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(accent.opacity(0.10), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Значок суперскрытой папки в углу карточки
struct HiddenFolderBadge: View {
    var body: some View {
        Image(systemName: "eye.slash.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.52), in: Circle())
            .padding(8)
            .accessibilityLabel("Суперскрытая папка")
    }
}

/// Подтверждение удаления папки: что уйдёт вместе с ней
enum FolderDeletion {
    static let confirmTitle = "Удалить вместе с содержимым"

    static func title(for folder: VaultFolder?) -> String {
        "Удалить папку «\(folder?.name ?? "")»?"
    }

    /// «Вместе с ней удалятся 3 файла и 2 папки.» Считается всё поддерево
    static func message(for folder: VaultFolder, in store: VaultStore) -> String {
        let contents = store.subtreeContents(of: folder)
        var parts: [String] = []
        if contents.files > 0 { parts.append(pluralize(contents.files, "файл", "файла", "файлов")) }
        if contents.folders > 0 { parts.append(pluralize(contents.folders, "папка", "папки", "папок")) }
        guard !parts.isEmpty else { return "Папка пуста." }
        return "Вместе с ней удалятся \(parts.joined(separator: " и ")). Это не отменить."
    }
}

extension View {
    /// Карточка, из которой экран папки раскрывается зумом. Без пространства
    /// имён — обычный переход
    @ViewBuilder
    func zoomSource(_ id: UUID, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}
