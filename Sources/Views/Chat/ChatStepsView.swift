import SwiftUI

// Что чат делает, пока отвечает: «Понял: дата рождения · Ольга» →
// «Перебираю людей: …» → «Открываю: Паспорт РФ — Трошина О. В.». Каждую строку
// ставит код, который это действие и выполняет (ChatStep), — это не анимация
// для вида. Пока ответ идёт, видно ленту, текущий шаг живой; когда ответ готов,
// лента сворачивается в строку «Нашёл за 0,2 с · 3 шага», раскрывается касанием
struct ChatStepsView: View {
    let steps: [ChatStep]
    let isLive: Bool
    let askedAt: Date
    let finishedAt: Date?

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Сколько последних шагов видно, пока ответ идёт
    private static let liveLimit = 5

    var body: some View {
        if isLive {
            list(Array(steps.suffix(Self.liveLimit)))
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: steps.map(\.id))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chatSteps")
        } else if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                        Text(summary)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chatStepsSummary")
                if expanded {
                    list(steps)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Theme.border).frame(width: 2)
                        }
                }
            }
        }
    }

    /// «Нашёл за 0,2 с · 3 шага»
    private var summary: String {
        let seconds = (finishedAt ?? Date()).timeIntervalSince(askedAt)
        let time = seconds < 10
            ? seconds.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "ru_RU")))
            : String(Int(seconds.rounded()))
        return "Ответ за \(time) с · \(pluralize(steps.count, "шаг", "шага", "шагов"))"
    }

    private func list(_ shown: [ChatStep]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(shown) { step in
                StepRow(step: step, isLive: isLive && step.isRunning)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
    }
}

private struct StepRow: View {
    let step: ChatStep
    let isLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: step.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isLive ? Theme.accent : Color.secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: isLive && !reduceMotion)
                .frame(width: 18)
            Text(step.text)
                .font(.footnote)
                .foregroundStyle(isLive ? Theme.ink : Color.secondary)
                .lineLimit(2)
            if isLive {
                // Живой счётчик — у долгих шагов: облако, модель на iPhone
                TimelineView(.periodic(from: step.startedAt, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(step.startedAt))
                    if seconds >= 1 {
                        Text("\(seconds) с")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
