import SwiftUI

// «Было → станет» для поля, которое распознавание прочитало неверно. Как и
// с файлами, чат только предлагает: поле меняется по «Исправить» и становится
// ручным — ни облако, ни модель на iPhone его больше не перезапишут. Значение
// в базе уже новое — карточка говорит «Исправлено»
struct FieldFixCardView: View {
    let document: ChatDocument
    let key: String
    let value: String

    @Environment(\.chatActions) private var actions
    @State private var isApplying = false
    @State private var dismissed = false
    @State private var tick = 0

    private var current: DocumentField? { document.field(key) }
    private var isApplied: Bool { current?.value == value }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChatCardHeader(document: document)
            VStack(alignment: .leading, spacing: 4) {
                Text(FieldKey.title(key))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let current, !isApplied {
                    Text(shown(current.value))
                        .font(.body)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Было: \(shown(current.value))")
                }
                Text(shown(value))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityLabel("Станет: \(shown(value))")
            }
            if isApplied {
                Label("Исправлено", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("fieldFixDone")
            } else if dismissed {
                Text("Оставил как было")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Button {
                        Task {
                            isApplying = true
                            await actions.fixField(document, key, value)
                            isApplying = false
                            tick &+= 1
                        }
                    } label: {
                        Label("Исправить", systemImage: "checkmark")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ink)
                    .disabled(isApplying)
                    .accessibilityIdentifier("fieldFixApply")
                    Button("Не надо") { dismissed = true }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(Theme.ink)
                }
            }
        }
        .chatCardSurface()
        .sensoryFeedback(.success, trigger: tick)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatCard-fieldFix")
    }

    /// Номер — маской, как в карточке полей
    private func shown(_ text: String) -> String {
        FieldKey.isSensitive(key) ? FieldMask.masked(text) : text
    }
}
