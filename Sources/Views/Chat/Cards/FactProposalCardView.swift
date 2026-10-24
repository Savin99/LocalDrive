import SwiftUI

// Черновик карточки из чата: «запомни: у Камилы домофон 45, этаж 3» или
// скриншот, разобранный облаком. Как и с файлами, чат только предлагает: в
// «Карточки» черновик попадает по «Сохранить». Карточка с тем же id уже есть —
// это правка, «Сохранить» её обновит
struct FactProposalCardView: View {
    let draft: FactCard

    @Environment(FactStore.self) private var facts
    @State private var editing = false
    @State private var edited: FactCard?
    @State private var saveTick = 0

    private var current: FactCard { edited ?? draft }
    private var existing: FactCard? { facts.card(id: draft.id) }
    /// Сохранено, если в «Карточках» лежит ровно это
    private var isSaved: Bool {
        guard let existing else { return false }
        return existing.title == current.title && existing.items == current.items && existing.symbol == current.symbol
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FactCardView(card: current)
            HStack(spacing: 8) {
                if isSaved {
                    Label("Сохранено в «Карточках»", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("factSaved")
                } else {
                    Button {
                        if existing == nil { facts.add(current) } else { facts.update(current) }
                        saveTick &+= 1
                    } label: {
                        Label(existing == nil ? "Сохранить" : "Обновить", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ink)
                    .accessibilityIdentifier("factSave")
                    Button {
                        editing = true
                    } label: {
                        Label("Изменить", systemImage: "pencil")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.ink)
                    .accessibilityIdentifier("factEdit")
                }
            }
        }
        .sensoryFeedback(.success, trigger: saveTick)
        .sheet(isPresented: $editing) {
            FactEditorView(card: current) { updated in
                edited = updated
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatCard-factProposal")
    }
}
