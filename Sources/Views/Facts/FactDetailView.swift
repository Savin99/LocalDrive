import SwiftUI

// Экран одной карточки: сама карточка, когда создана и изменена, правка,
// «Поделиться» и удаление
struct FactDetailView: View {
    let cardID: UUID

    @Environment(FactStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var confirmsDelete = false

    private var card: FactCard? { store.card(id: cardID) }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if let card {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        FactCardView(card: card)
                        Text(dates(of: card))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
        }
        .navigationTitle(card?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let card {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Изменить") { isEditing = true }
                        .accessibilityIdentifier("factEdit")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ShareLink(item: card.plainText) {
                            Label("Поделиться", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            confirmsDelete = true
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                        .accessibilityIdentifier("factDelete")
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Ещё")
                    .accessibilityIdentifier("factMore")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            if let card {
                FactEditorView(card: card) { edited in
                    store.update(edited)
                }
            }
        }
        .confirmationDialog(
            "Удалить карточку «\(card?.title ?? "")»?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            // Экран закроет onChange ниже: карточки больше нет
            Button("Удалить", role: .destructive) {
                store.delete(id: cardID)
            }
            Button("Отмена", role: .cancel) {}
        }
        // Карточку удалили из чата или восстановили копию без неё
        .onChange(of: card == nil) { _, isGone in
            if isGone { dismiss() }
        }
    }

    private func dates(of card: FactCard) -> String {
        let created = "Создана \(RussianFormat.dateTime(card.createdAt))"
        guard card.updatedAt.timeIntervalSince(card.createdAt) > 60 else { return created }
        return "\(created) · изменена \(RussianFormat.dateTime(card.updatedAt))"
    }
}
