import SwiftUI

// Смена кода: текущий -> новый -> подтверждение
struct ChangePinView: View {
    @Environment(LockManager.self) private var lock
    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        case current
        case new
        case confirm

        var title: String {
            switch self {
            case .current: "Текущий код"
            case .new: "Новый код"
            case .confirm: "Повторите новый код"
            }
        }
    }

    @State private var stage: Stage = .current
    @State private var pin = ""
    @State private var newPin = ""
    @State private var attempts = 0
    @State private var hint: String?

    private let pinLength = 4

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    Text(stage.title)
                        .font(.system(.title2, weight: .semibold))

                    Text(hint ?? " ")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .padding(.top, 4)

                    PinDots(filled: pin.count, total: pinLength)
                        .padding(.top, 28)
                        .modifier(ShakeEffect(animatableData: CGFloat(attempts)))

                    Spacer()

                    PinPad(
                        onDigit: append(digit:),
                        onDelete: { if !pin.isEmpty { pin.removeLast() } }
                    )
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Смена кода")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
            .animation(.smooth(duration: 0.25), value: stage)
        }
    }

    private func append(digit: String) {
        guard pin.count < pinLength else { return }
        pin += digit
        guard pin.count == pinLength else { return }

        switch stage {
        case .current:
            if lock.verify(pin) {
                pin = ""
                hint = nil
                stage = .new
            } else {
                fail(message: "Неверный код")
            }
        case .new:
            newPin = pin
            pin = ""
            hint = nil
            stage = .confirm
        case .confirm:
            if pin == newPin {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                lock.setPIN(pin)
                dismiss()
            } else {
                newPin = ""
                stage = .new
                fail(message: "Коды не совпадают")
            }
        }
    }

    private func fail(message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.linear(duration: 0.4)) { attempts += 1 }
        pin = ""
        hint = message
    }
}
