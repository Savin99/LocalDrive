import SwiftUI

// Выдача поиска на главном экране: файл, его папка и место в тексте,
// где нашлись слова запроса
struct SearchResultsView: View {
    @Environment(SearchService.self) private var search

    let query: String
    let onOpen: (SearchResult, [SearchResult]) -> Void

    @State private var results: [SearchResult] = []
    /// Запрос, для которого показаны `results`: пока новый ищется, старые
    /// результаты остаются на экране и не мигают
    @State private var shownQuery: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if search.progress.isIndexing {
                    indexingNote
                }

                ForEach(results) { result in
                    Button {
                        onOpen(result, results)
                    } label: {
                        SearchResultRow(result: result)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("searchResult")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .overlay {
            if let shownQuery, results.isEmpty {
                // Системный вариант пишет по-английски: у приложения нет локализаций
                ContentUnavailableView {
                    Label("Ничего не нашлось", systemImage: "magnifyingglass")
                } description: {
                    Text(search.progress.isIndexing
                        ? "По запросу «\(shownQuery)» пока пусто. Часть документов ещё распознаётся — выдача обновится сама"
                        : "По запросу «\(shownQuery)» документов нет. Попробуйте другое слово или его начало")
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        // Новый документ в индексе — повод пересобрать выдачу: человек мог
        // искать, пока его файлы ещё распознавались
        .task(id: SearchKey(query: query, indexed: search.progress.indexed)) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let found = await search.search(query)
            guard !Task.isCancelled else { return }
            results = found
            shownQuery = query
        }
    }

    private var indexingNote: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            Text("Распознаю документы · осталось \(search.progress.pending)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.well, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private struct SearchKey: Equatable {
        let query: String
        let indexed: Int
    }
}

struct SearchResultRow: View {
    @Environment(VaultStore.self) private var store

    let result: SearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Заглушка превью нейтральная: цвет папки — только в точке источника
            FileThumbnail(
                file: result.file,
                accent: Theme.ink,
                size: CGSize(width: 52, height: 52),
                cornerRadius: 12
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(result.file.displayName)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 5) {
                    Circle()
                        .fill(Theme.color(result.folder.color))
                        .frame(width: 6, height: 6)
                    // Файл нашёлся по названию папки — показываем, чем он совпал.
                    // Путь: в выдаче одноимённые папки из разных мест не путаются,
                    // а папка выше у найденного всегда доступна для поиска
                    Text(store.path(of: result.folder))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .fontWeight(result.matchedFolder ? .semibold : .regular)
                        .foregroundStyle(result.matchedFolder ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.secondary))
                    if let page = result.page {
                        Text("· стр. \(page)")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let snippet = result.snippet {
                    Text(ChatSnippetHighlight.highlighted(snippet))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .cardStyle(cornerRadius: 16)
        .contentShape(Rectangle())
    }
}
