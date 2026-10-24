import SwiftUI

// Срок действия: дата, сколько осталось и напоминание. Ведёт к файлу,
// из которого взяты даты
struct ExpiryCardView: View {
    let document: ChatDocument
    let validity: DocumentValidity

    @Environment(\.chatActions) private var actions

    @State private var isScheduling = false
    /// Подтверждение или ошибка от «Напоминаний»
    @State private var reminderNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChatCardHeader(document: document)

            VStack(alignment: .leading, spacing: 4) {
                Text(statusCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = validity.date {
                    Text(DocumentValidity.format(date))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.ink)
                        .monospacedDigit()
                }
                if let remaining = validity.remainingText() {
                    Text(remaining)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(remainingColor)
                }
            }

            HStack(spacing: 14) {
                Button {
                    Task { await remind() }
                } label: {
                    HStack(spacing: 6) {
                        if isScheduling {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Theme.background)
                        } else {
                            Image(systemName: "bell.fill")
                        }
                        Text("Напомнить")
                    }
                    .chatButtonPadding()
                    .primaryCapsule()
                    .opacity(validity.date == nil ? 0.35 : 1)
                }
                .buttonStyle(.plain)
                .disabled(validity.date == nil || isScheduling)
                .accessibilityIdentifier("chatRemind")

                Button {
                    actions.open(document.file, [document.file], nil)
                } label: {
                    Label("Открыть файл", systemImage: "doc")
                        .chatButtonPadding()
                        .secondaryCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chatOpen")
            }
            .font(.subheadline.weight(.semibold))

            if let reminderNote {
                Text(reminderNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .chatCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatCard-expiry")
    }

    private var statusCaption: String {
        switch validity.status {
        case .until: "Действует до"
        case .replaceAtAge(let age, _): "Паспорт меняют в \(age) лет"
        case .indefinite: "Бессрочный: после 45 лет паспорт не меняют"
        case .unknown: "Срок действия не распознан"
        }
    }

    /// Истёк — красный, меньше полугода — оранжевый: столько обычно
    /// требуют запаса по сроку для поездок
    private var remainingColor: Color {
        guard let date = validity.date else { return .secondary }
        if validity.isExpired() { return .red }
        if date.timeIntervalSinceNow < 180 * 24 * 60 * 60 { return .orange }
        return .secondary
    }

    private func remind() async {
        isScheduling = true
        let note = await actions.remind(document, validity)
        isScheduling = false
        withAnimation(.snappy(duration: 0.2)) {
            reminderNote = note.isEmpty ? nil : note
        }
    }
}
