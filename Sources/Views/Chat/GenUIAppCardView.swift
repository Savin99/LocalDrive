import SwiftUI

/// Блок `app_card` в ответе интерфейсом: карточка прежнего каталога чата.
/// Значения — из базы, как у show_cards. Документ, которого нет или который
/// убрали из поиска, не показывается вовсе
struct GenUIAppCardView: View {
    let card: ChatCard

    @Environment(SearchService.self) private var search
    @State private var resolved: ResolvedCard?
    @State private var loaded = false

    var body: some View {
        Group {
            if let resolved {
                ChatCardView(card: resolved)
            } else if !loaded {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.surface)
                    .frame(height: 72)
                    .accessibilityHidden(true)
            }
        }
        .task(id: card) {
            resolved = await ChatCardResolver(search: search).resolve([card]).first
            loaded = true
        }
        .accessibilityIdentifier("genui-app-card")
    }
}
