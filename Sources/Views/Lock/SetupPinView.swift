import SwiftUI

// Первый запуск: придумать и подтвердить PIN-код
struct SetupPinView: View {
    @Environment(LockManager.self) private var lock
    @Environment(VaultStore.self) private var store

    private enum Stage {
        case create
        case confirm
    }

    @State private var stage: Stage = .create
    @State private var firstPin = ""
    @State private var pin = ""
    @State private var attempts = 0
    @State private var showMismatch = false
    @State private var showsRestore = false

    private let pinLength = 4

    var body: some View {
        ZStack {
            LockBackdrop()

            VStack(spacing: 0) {
                Spacer()

                LockMark()

                Text(stage == .create ? "Придумайте код" : "Повторите код")
                    .font(.system(.title2, weight: .semibold))
                    .padding(.top, 20)
                    .contentTransition(.opacity)

                Text(setupHint)
                    .font(.subheadline)
                    .foregroundStyle(showMismatch ? .red : .secondary)
                    .padding(.top, 4)

                if stage == .create && store.folders.isEmpty {
                    Button {
                        showsRestore = true
                    } label: {
                        Label("Восстановить файлы", systemImage: "icloud.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("restore-files")
                    .padding(.top, 6)
                }

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
        .animation(.smooth(duration: 0.25), value: stage)
        .fullScreenCover(isPresented: $showsRestore) {
            RestoreBackupView()
        }
    }

    private var setupHint: String {
        if showMismatch { return "Коды не совпадают — попробуйте ещё раз" }
        if !store.folders.isEmpty { return "Файлы восстановлены — придумайте новый код" }
        return "Код защищает доступ к вашим файлам"
    }

    private func append(digit: String) {
        guard pin.count < pinLength else { return }
        pin += digit
        guard pin.count == pinLength else { return }

        switch stage {
        case .create:
            firstPin = pin
            pin = ""
            showMismatch = false
            stage = .confirm
        case .confirm:
            if pin == firstPin {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                lock.setPIN(pin)
                lock.unlock()
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                withAnimation(.linear(duration: 0.4)) { attempts += 1 }
                pin = ""
                firstPin = ""
                showMismatch = true
                stage = .create
            }
        }
    }
}
