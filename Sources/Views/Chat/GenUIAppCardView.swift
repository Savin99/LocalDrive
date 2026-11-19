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
            let resolver = ChatCardResolver(search: search)
            resolved = await resolver.resolve([card]).first
            // Полей у документа нет (договор, свидетельство) или модель назвала
            // чужие ключи — показываем сам документ, а не пустое место
            // (живая проверка 19.11.2026). Выдуманных значений так не бывает
            if resolved == nil, case .fields(let id, _) = card {
                resolved = await resolver.resolve([.document(documentID: id)]).first
            }
            loaded = true
        }
        .accessibilityIdentifier("genui-app-card")
    }
}
