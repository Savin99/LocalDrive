import Foundation

// Карточки-факты в ответах правил: «дом Камилы», «домофон Камилы», «где живёт
// Камила». Ответ — сама карточка из «Карточек», нужные поля подсвечены. Поиск —
// `FactSearch`: имя выбирает карточку, слова поля («домофон», «живёт») — строку
extension ChatRouter {
    /// Ответ карточками. Без `force` — только если в вопросе есть слово поля
    /// или карточки («домофон», «дом», «живёт»): на одно имя («Камила») сначала
    /// отвечает `person` — документами человека, а карточки добавляет к ним.
    /// `force` — документов на имя нет, отвечают карточки
    func factAnswer(_ text: String, force: Bool = false) -> ChatReply? {
        guard let facts else { return nil }
        let matches = facts.matches(text)
        guard !matches.isEmpty else { return nil }
        let asksField = FactSearch.terms(in: text).contains(where: \.isGeneric)
        guard force || asksField || matches.contains(where: { !$0.itemIDs.isEmpty }) else { return nil }
        let shown = Array(matches.prefix(3))
        onStep?(.search, "Смотрю «Карточки»: " + shown.map(\.card.title).joined(separator: ", "))
        let asked = shown.flatMap { match in match.card.items.filter { match.itemIDs.contains($0.id) }.map(\.label) }
        let text: String
        if shown.count > 1 {
            text = "Нашёл в «Карточках»:"
        } else if asked.isEmpty {
            text = "\(shown[0].card.title) — нажмите на поле, чтобы скопировать или открыть:"
        } else {
            text = asked.joined(separator: ", ") + " — нажмите, чтобы скопировать или открыть:"
        }
        return ChatReply(
            text: text,
            cards: shown.map { .fact(id: $0.card.id, items: $0.card.items.map(\.id).filter($0.itemIDs.contains)) },
            isConfident: true
        )
    }

    /// Карточки о человеке — к ответу его документами: «Ольга» → паспорт и «Дом Ольги»
    func factCards(about text: String) -> [ChatCard] {
        guard let facts else { return [] }
        return facts.matches(text).prefix(3).map { .fact(id: $0.card.id, items: []) }
    }
}
