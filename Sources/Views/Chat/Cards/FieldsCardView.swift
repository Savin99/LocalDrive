import SwiftUI

// Поля документа. Значения приходят из базы, номер закрыт маской до Face ID.
// Тап по строке копирует значение, долгое нажатие — правка и сверка с фото
struct FieldsCardView: View {
    let document: ChatDocument
    let keys: [String]

    @Environment(\.chatActions) private var actions
    @Environment(\.chatRevealsSensitive) private var revealed

    /// Строка, у которой иконка копирования на миг стала галочкой
    @State private var copiedKey: String?
    /// Счётчик копирований — повод для тактильного отклика
    @State private var copyTick = 0
    @State private var isTogglingReveal = false

    private var fields: [DocumentField] { keys.compactMap { document.field($0) } }
    private var hasSensitive: Bool { fields.contains { FieldKey.isSensitive($0.key) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChatCardHeader(document: document) {
                if hasSensitive { revealButton }
            }

            VStack(spacing: 0) {
                ForEach(Array(fields.enumerated()), id: \.element.key) { index, field in
                    if index > 0 {
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(height: 1)
                    }
                    row(field)
                }
            }
        }
        .chatCardSurface()
        .sensoryFeedback(.impact(weight: .light), trigger: copyTick)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatCard-fields")
    }

    // MARK: - Строка поля

    private func row(_ field: DocumentField) -> some View {
        let shown = FieldMask.display(field, revealed: revealed)
        let copied = copiedKey == field.key

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(FieldKey.title(field.key))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if field.needsReview {
                        // OCR не уверен: поле надо сверить с фото, а не верить молча
                        Label("проверьте", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Text(shown)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(copied ? Theme.accent : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { Task { await copy(field) } }
        .contextMenu { menu(for: field) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel(field))
        .accessibilityHint("Нажмите, чтобы скопировать")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { Task { await copy(field) } }
        .accessibilityIdentifier("chatField-\(field.key)")
    }

    /// Маску VoiceOver прочёл бы как «точка, точка, точка» — говорим словами
    private func spokenLabel(_ field: DocumentField) -> String {
        let title = FieldKey.title(field.key)
        let review = field.needsReview ? ", проверьте" : ""
        guard FieldKey.isSensitive(field.key), !revealed else { return "\(title): \(field.value)\(review)" }
        let tail = String(field.value.filter(\.isNumber).suffix(2))
        return "\(title): скрыт, заканчивается на \(tail)\(review)"
    }

    @ViewBuilder
    private func menu(for field: DocumentField) -> some View {
        Button {
            Task { await copy(field) }
        } label: {
            Label("Скопировать", systemImage: "doc.on.doc")
        }
        Button {
            Task { await edit(field) }
        } label: {
            Label("Исправить…", systemImage: "pencil")
        }
        Button {
            actions.open(document.file, [document.file], nil)
        } label: {
            Label("Сверить с фото", systemImage: "photo")
        }
        if field.needsReview {
            Button {
                Task { await actions.verify(document, field) }
            } label: {
                Label("Всё верно", systemImage: "checkmark.seal")
            }
        }
    }

    // MARK: - Действия

    /// Закрытый номер копируется только после Face ID: копирование — тот же показ
    private func copy(_ field: DocumentField) async {
        if FieldKey.isSensitive(field.key), !revealed {
            guard await actions.setRevealed(true) else { return }
        }
        actions.copy(field.value)
        copyTick &+= 1
        withAnimation(.snappy(duration: 0.2)) { copiedKey = field.key }
        try? await Task.sleep(for: .seconds(1.5))
        if copiedKey == field.key {
            withAnimation(.snappy(duration: 0.2)) { copiedKey = nil }
        }
    }

    /// Лист правки показывает значение целиком — для номера сначала Face ID
    private func edit(_ field: DocumentField) async {
        if FieldKey.isSensitive(field.key), !revealed {
            guard await actions.setRevealed(true) else { return }
        }
        actions.edit(document, field)
    }

    private var revealButton: some View {
        Button {
            Task {
                isTogglingReveal = true
                _ = await actions.setRevealed(!revealed)
                isTogglingReveal = false
            }
        } label: {
            Image(systemName: revealed ? "eye" : "eye.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 34, height: 34)
                .background(Theme.surface, in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(isTogglingReveal)
        .accessibilityLabel(revealed ? "Скрыть номер" : "Показать номер")
        .accessibilityIdentifier("chatReveal")
    }
}

// MARK: - Общее для карточек чата

extension DocumentType {
    /// Значок типа в шапке карточки
    var chatSymbol: String {
        switch self {
        case .passportRU, .passportIntl: "person.text.rectangle.fill"
        default: "doc.text.fill"
        }
    }
}

/// Подложка карточки ответа — плоская, с тонкой рамкой, как остальные карточки
struct ChatCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(cornerRadius: 18)
    }
}

extension View {
    func chatCardSurface() -> some View {
        modifier(ChatCardSurface())
    }
}

/// Цветная точка и название папки: у каждого ответа виден источник
struct ChatFolderChip: View {
    let folder: VaultFolder

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.color(folder.color))
                .frame(width: 6, height: 6)
            Text(folder.name)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Шапка карточки документа: значок типа в плитке цвета папки, тип и папка
struct ChatCardHeader<Trailing: View>: View {
    let document: ChatDocument
    let trailing: Trailing

    init(document: ChatDocument, @ViewBuilder trailing: () -> Trailing) {
        self.document = document
        self.trailing = trailing()
    }

    var body: some View {
        // Плитка нейтральная: цвет папки остаётся только в точке источника
        HStack(spacing: 10) {
            Image(systemName: document.type.chatSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 26, height: 26)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(document.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                ChatFolderChip(folder: document.folder)
            }

            Spacer(minLength: 8)
            trailing
        }
    }
}

extension ChatCardHeader where Trailing == EmptyView {
    init(document: ChatDocument) {
        self.init(document: document) { EmptyView() }
    }
}
