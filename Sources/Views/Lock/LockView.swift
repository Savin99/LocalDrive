import SwiftUI

struct LockView: View {
    @Environment(LockManager.self) private var lock
    @State private var pin = ""
    @State private var attempts = 0

    private let pinLength = 4

    var body: some View {
        ZStack {
            LockBackdrop()

            VStack(spacing: 0) {
                Spacer()

                LockMark()

                Text("LocalDrive")
                    .font(.system(.title2, weight: .semibold))
                    .padding(.top, 20)

                Text("Введите код")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                PinDots(filled: pin.count, total: pinLength)
                    .padding(.top, 28)
                    .modifier(ShakeEffect(animatableData: CGFloat(attempts)))

                Spacer()

                PinPad(
                    showsBiometry: lock.biometryAvailable,
                    onDigit: append(digit:),
                    onDelete: { if !pin.isEmpty { pin.removeLast() } },
                    onBiometry: { Task { _ = await lock.unlockWithBiometrics() } }
                )
                .padding(.bottom, 40)
            }
        }
        .task {
            // Холодный старт: onChange(scenePhase) здесь ещё не срабатывает
            await lock.autoUnlock()
        }
    }

    private func append(digit: String) {
        guard pin.count < pinLength else { return }
        pin += digit
        guard pin.count == pinLength else { return }

        if lock.verify(pin) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            pin = ""
            lock.unlock()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            withAnimation(.linear(duration: 0.4)) { attempts += 1 }
            pin = ""
        }
    }
}
