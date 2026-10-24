import SwiftUI

// Карточка фактов: плитка цвета карточки, название и поля строками. Адрес,
// ссылка, телефон и почта — не текст, а кнопка: касание открывает Карты,
// браузер, звонок или письмо. Остальное копируется касанием, как поля
// документа в чате. Долгое нажатие — «Скопировать», «Открыть», «Поделиться».
// Карточка живёт и на странице «Карточки», и в ответах чата, поэтому своей
// навигации у неё нет
struct FactCardView: View {
    let card: FactCard
    /// Поля, о которых спросили: «домофон Камилы» подсвечивает домофон
    var highlighted: Set<UUID> = []
    /// Касание шапки открывает карточку. nil — шапка не нажимается, вместо
    /// стрелки в ней «Скопировать всё»
    var onOpen: (() -> Void)? = nil

    @Environment(\.openURL) private var openURL

    /// Строка, у которой значок на миг стал галочкой
    @State private var copiedID: UUID?
    /// Счётчик копирований — повод для тактильного отклика
    @State private var copyTick = 0

    private var accent: Color { Theme.color(card.color) }

    private var items: [FactItem] {
        card.items.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if !items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            // Рядом с подсвеченной строкой линия резала бы подложку
                            let nearHighlight = highlighted.contains(item.id)
                                || highlighted.contains(items[index - 1].id)
                            Rectangle()
                                .fill(nearHighlight ? Color.clear : Theme.hairline)
                                .frame(height: 1)
                                .padding(.leading, 50)
                        }
                        row(item)
                    }
                }
                // Подсветка выходит за край текста, а сам текст стоит ровно под шапкой
                .padding(.horizontal, -8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(cornerRadius: 18)
        .sensoryFeedback(.impact(weight: .light), trigger: copyTick)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("factCard-\(card.title)")
    }

    // MARK: - Шапка

    @ViewBuilder
    private var header: some View {
        if let onOpen {
            Button(action: onOpen) {
                headerContent {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Открыть карточку")
        } else {
            headerContent {
                if items.count > 1 { copyAllButton }
            }
        }
    }

    private func headerContent<Trailing: View>(@ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: FactSymbols.symbol(for: card))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(card.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(pluralize(items.count, "поле", "поля", "полей"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            trailing()
        }
        .contentShape(Rectangle())
    }

    private var copyAllButton: some View {
        let copied = copiedID == Self.allID
        return Button {
            Task { await copy(card.plainText, mark: Self.allID) }
        } label: {
            Label(copied ? "Скопировано" : "Всё", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Theme.surface, in: Capsule())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Скопировать все поля")
        .accessibilityIdentifier("factCopyAll")
    }

    /// Отметка «скопировано всё» в `copiedID`
    private static let allID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    // MARK: - Строка поля

    private func row(_ item: FactItem) -> some View {
        let action = FactLinks.primaryAction(for: item)
        let isHighlighted = highlighted.contains(item.id)

        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: FactSymbols.symbol(for: item))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isHighlighted ? accent : Theme.ink.opacity(0.72))
                .frame(width: 30, height: 30)
                .background(
                    isHighlighted ? accent.opacity(0.16) : Theme.surface,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayLabel)
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? accent : Color.secondary)
                Text(displayValue(item))
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
                    .multilineTextAlignment(.leading)
                    .lineLimit(item.kind == .note ? 8 : 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing(for: item, action: action)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 8)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(0.09))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { perform(action, on: item) }
        .contextMenu { menu(for: item, action: action) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.displayLabel): \(item.value)")
        .accessibilityHint(action.hint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { perform(action, on: item) }
        .accessibilityIdentifier("factItem-\(item.displayLabel)")
    }

    /// Справа — что сделает касание. Открытие — цветная круглая кнопка,
    /// копирование — серый значок, как у полей документа в чате
    @ViewBuilder
    private func trailing(for item: FactItem, action: FactItemAction) -> some View {
        let copied = copiedID == item.id
        if action == .copy {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(copied ? Theme.accent : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
        } else {
            Image(systemName: copied ? "checkmark" : FactSymbols.actionGlyph(for: action))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(accent.opacity(0.14), in: Circle())
        }
    }

    private func displayValue(_ item: FactItem) -> String {
        item.kind == .link ? FactLinks.displayLink(item.value) : item.value
    }

    @ViewBuilder
    private func menu(for item: FactItem, action: FactItemAction) -> some View {
        Button {
            Task { await copy(item.value, mark: item.id) }
        } label: {
            Label("Скопировать", systemImage: "doc.on.doc")
        }
        if action != .copy {
            Button {
                perform(action, on: item)
            } label: {
                Label(action.title, systemImage: FactSymbols.actionGlyph(for: action))
            }
        }
        ShareLink(item: item.value) {
            Label("Поделиться", systemImage: "square.and.arrow.up")
        }
    }

    // MARK: - Действия

    private func perform(_ action: FactItemAction, on item: FactItem) {
        if action != .copy, let url = FactLinks.url(for: item) {
            openURL(url)
        } else {
            Task { await copy(item.value, mark: item.id) }
        }
    }

    private func copy(_ value: String, mark: UUID) async {
        FactClipboard.copy(value)
        copyTick &+= 1
        withAnimation(.snappy(duration: 0.2)) { copiedID = mark }
        try? await Task.sleep(for: .seconds(1.5))
        if copiedID == mark {
            withAnimation(.snappy(duration: 0.2)) { copiedID = nil }
        }
    }
}
