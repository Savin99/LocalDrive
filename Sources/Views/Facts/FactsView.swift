import SwiftUI

// Третья страница главного экрана — библиотека карточек фактов. Карточки
// стоят одной колонкой целиком: домофон и адрес видны и нажимаются сразу,
// без перехода внутрь. Шапка карточки открывает её экран с правкой и
// удалением, «+» — редактор новой
struct FactsView: View {
    @Environment(FactStore.self) private var store
    @Environment(\.isOffscreenPage) private var isOffscreenPage

    @State private var query = ""
    @State private var isCreating = false
    /// Открытые карточки. По глубине главный экран прячет переключатель страниц
    @State private var path: [UUID] = []

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.background.ignoresSafeArea()

                if store.cards.isEmpty {
                    EmptyStateView(
                        icon: "square.text.square",
                        title: "Карточек пока нет",
                        subtitle: "Попросите чат: «запомни: у Камилы домофон 45, этаж 3, адрес Тверская 5» — или нажмите +",
                        actionTitle: "Создать карточку",
                        action: { isCreating = true }
                    )
                } else if isSearching {
                    results
                } else {
                    list(store.cards.map { FactSearch.Match(card: $0, itemIDs: [], score: 0) })
                }
            }
            .accessibilityIdentifier("factsPage")
            .navigationTitle("Карточки")
            .navigationBarTitleDisplayMode(.inline)
            // Посередине шапки стоит общий переключатель страниц, как у «Файлов»
            .toolbar(removing: .title)
            .searchable(text: $query, prompt: "Найти: дом Камилы, домофон")
            // Страница за краем экрана прячется от VoiceOver изнутри, см. MainView
            .accessibilityHidden(isOffscreenPage)
            .navigationDestination(for: UUID.self) { id in
                FactDetailView(cardID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isCreating = true
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel("Новая карточка")
                    .accessibilityIdentifier("factAdd")
                }
            }
            .sheet(isPresented: $isCreating) {
                FactEditorView(card: nil) { card in
                    withAnimation(.snappy) { store.add(card) }
                }
            }
        }
        .preference(key: FactsNavigationDepthKey.self, value: path.count)
    }

    @ViewBuilder
    private var results: some View {
        let found = store.matches(query)
        if found.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "Ничего не нашлось",
                subtitle: "Попробуйте имя или название поля: «Камила», «домофон»"
            )
        } else {
            list(found)
        }
    }

    private func list(_ matches: [FactSearch.Match]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text(pluralize(matches.count, "карточка", "карточки", "карточек"))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 4)

                ForEach(matches, id: \.card.id) { match in
                    FactCardView(card: match.card, highlighted: match.itemIDs) {
                        path.append(match.card.id)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .animation(.snappy(duration: 0.25), value: matches.map(\.card))
    }
}

/// Глубина навигации «Карточек»: открыта ли карточка. Главный экран по ней
/// выключает листание, как по `FilesNavigationDepthKey`
struct FactsNavigationDepthKey: PreferenceKey {
    static let defaultValue = 0

    static func reduce(value: inout Int, nextValue: () -> Int) {
        value = max(value, nextValue())
    }
}
