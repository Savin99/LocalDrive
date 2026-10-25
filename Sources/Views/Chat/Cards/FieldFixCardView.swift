import SwiftUI

// «Было → станет» для поля, которое распознавание прочитало неверно.
// Владелец 25.10.2026: «окошко — что было, что будет, принять или отклонить».
// Как и с файлами, чат только предлагает: поле меняется по «Принять» и
// становится ручным — ни облако, ни модель на iPhone его больше не перезапишут
struct FieldFixCardView: View {
    let document: ChatDocument
    let key: String
    let value: String

    @Environment(\.chatActions) private var actions
    @State private var isApplying = false
    @State private var rejected = false
    /// Старое значение, запомненное до «Принять»: после него в базе уже новое
    @State private var before: String?
    @State private var tick = 0

    private var current: String? { document.field(key)?.value }
    private var isApplied: Bool { current == value }
    private var was: String? { before ?? (isApplied ? nil : current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChatCardHeader(document: document)
            Text("Исправление: \(FieldKey.title(key))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 6) {
                if let was {
                    row("Было", shown(was), tint: .red, struck: true)
                }
                row("Станет", shown(value), tint: Theme.accent, struck: false)
            }
            footer
        }
        .chatCardSurface()
        .sensoryFeedback(.success, trigger: tick)
        .onAppear { if before == nil, !isApplied { before = current } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatCard-fieldFix")
    }

    private func row(_ title: String, _ text: String, tint: Color, struck: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 52, alignment: .leading)
            Text(text)
                .font(struck ? .body : .body.weight(.semibold))
                .strikethrough(struck)
                .foregroundStyle(struck ? .secondary : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(text)")
    }

    @ViewBuilder
    private var footer: some View {
        if isApplied {
            Label("Принято — поле исправлено", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("fieldFixDone")
        } else if rejected {
            Text("Отклонено — оставил как было")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("fieldFixRejected")
        } else {
            HStack(spacing: 8) {
                Button {
                    Task {
                        isApplying = true
                        before = current
                        await actions.fixField(document, key, value)
                        isApplying = false
                        tick &+= 1
                    }
                } label: {
                    Label("Принять", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .primaryCapsule()
                }
                .buttonStyle(.plain)
                .disabled(isApplying)
                .accessibilityIdentifier("fieldFixApply")
                Button {
                    rejected = true
                } label: {
                    Text("Отклонить")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .secondaryCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fieldFixReject")
            }
        }
    }

    /// Номер — маской, как в карточке полей
    private func shown(_ text: String) -> String {
        FieldKey.isSensitive(key) ? FieldMask.masked(text) : text
    }
}
