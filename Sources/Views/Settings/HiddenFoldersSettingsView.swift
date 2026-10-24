import SwiftUI

// Настройки скрытых папок: свой знак вместо встроенной Z, пароль на случай,
// если знак не получается, и смена пароля. Решение владельца от 24.10.2026.
// Сам знак здесь не показывается никогда: кто откроет настройки на чужом
// телефоне, не должен его увидеть. Сменить знак или вернуть Z можно только
// с текущим паролем — иначе любой нарисовал бы свой и открыл папки

/// «Настройки» → «Скрытые папки» → «Знак»
struct HiddenSymbolSettingsView: View {
    @Environment(HiddenFolders.self) private var hiddenFolders

    @State private var showsRecorder = false
    @State private var asksResetPassword = false
    @State private var resetPassword = ""
    @State private var resetFailed = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    // Свой знак не рисуется даже здесь — только значок
                    Group {
                        if hiddenFolders.hasCustomSymbol {
                            Image(systemName: "scribble.variable")
                        } else {
                            Text(verbatim: "Z")
                        }
                    }
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 48, height: 48)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hiddenFolders.hasCustomSymbol ? "Свой знак" : "Буква Z")
                            .font(.headline)
                        Text("Нарисуйте его одним движением в любом месте «Файлов». Пока палец рисует, следа на экране нет.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Button {
                    showsRecorder = true
                } label: {
                    Label(
                        hiddenFolders.hasCustomSymbol ? "Нарисовать новый знак" : "Нарисовать свой знак",
                        systemImage: "hand.draw"
                    )
                }
                .accessibilityIdentifier("drawSymbol")

                if hiddenFolders.hasCustomSymbol {
                    Button {
                        resetPassword = ""
                        asksResetPassword = true
                    } label: {
                        Label("Вернуть Z", systemImage: "arrow.uturn.backward")
                    }
                    .accessibilityIdentifier("resetSymbol")
                }
            } footer: {
                Text(hiddenFolders.hasPassword
                    ? "Сменить знак или вернуть Z можно только с паролем скрытых папок."
                    : "Вместе со знаком вы зададите пароль: он откроет скрытые папки, если знак не получится.")
            }

            if hiddenFolders.hasPassword {
                Section {
                    NavigationLink {
                        ChangeHiddenPasswordView()
                    } label: {
                        Label("Сменить пароль", systemImage: "key")
                    }
                    .accessibilityIdentifier("changeHiddenPassword")
                } footer: {
                    Text("Пароль нельзя восстановить: если забыть и пароль, и знак, скрытые папки не открыть.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Знак")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showsRecorder) {
            SymbolRecorderView()
        }
        .alert("Вернуть Z?", isPresented: $asksResetPassword) {
            SecureField("Пароль скрытых папок", text: $resetPassword)
            Button("Вернуть") {
                let password = resetPassword
                resetPassword = ""
                Task {
                    if !(await hiddenFolders.resetSymbol(password: password)) { resetFailed = true }
                }
            }
            Button("Отмена", role: .cancel) { resetPassword = "" }
        } message: {
            Text("Свой знак перестанет открывать скрытые папки — снова будет работать буква Z.")
        }
        .alert("Неверный пароль", isPresented: $resetFailed) {
            Button("Понятно", role: .cancel) {}
        }
    }
}

// MARK: - Запись знака

/// Полный экран, чтобы штрих вниз не закрывал лист настроек. Знак рисуют
/// трижды; образцы должны совпасть друг с другом, иначе — заново
private struct SymbolRecorderView: View {
    @Environment(HiddenFolders.self) private var hiddenFolders
    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        case drawing
        case preview
        case password
    }

    @State private var stage: Stage = .drawing
    @State private var samples: [[CGPoint]] = []
    @State private var issue: String?
    @State private var attempts = 0
    @State private var password = ""
    @State private var repeatedPassword = ""
    @State private var passwordError: String?
    @State private var isSaving = false
    @FocusState private var focusedField: Int?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch stage {
                case .drawing: drawing
                case .preview: preview
                case .password: passwordForm
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Свой знак")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
            .animation(.smooth(duration: 0.25), value: stage)
        }
    }

    private var drawingTitle: String {
        switch samples.count {
        case 0: "Нарисуйте знак"
        case 1: "Ещё раз — так же"
        default: "И последний раз"
        }
    }

    private var drawing: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text(drawingTitle)
                    .font(.system(.title2, weight: .semibold))
                    .contentTransition(.opacity)
                Text(issue ?? "Одним движением, не отрывая палец. Буквы и цифры подходят, прямая линия — нет")
                    .font(.subheadline)
                    .foregroundStyle(issue == nil ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 40, alignment: .top)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            HStack(spacing: 8) {
                ForEach(0..<SecretSymbol.sampleCount, id: \.self) { index in
                    Circle()
                        .fill(index < samples.count ? Theme.ink : Theme.border)
                        .frame(width: 9, height: 9)
                }
            }
            .modifier(ShakeEffect(animatableData: CGFloat(attempts)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Нарисовано \(samples.count) из \(SecretSymbol.sampleCount)")

            SymbolCanvas(ghosts: samples, onStroke: handle(stroke:))
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
    }

    private var preview: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)
            Text("Знак готов")
                .font(.system(.title2, weight: .semibold))
            SymbolPreview(stroke: samples.first ?? [])
                .frame(width: 220, height: 220)
                .padding(18)
                .cardStyle(cornerRadius: 24)
            Text("Рисуйте его так же: с той же точки, в ту же сторону. Размер и место на экране не важны.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 10) {
                Button {
                    stage = .password
                    focusedField = 0
                } label: {
                    Text("Дальше")
                        .font(.system(.body, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .primaryCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("symbolNext")
                Button("Нарисовать заново") { restart(message: nil) }
                    .foregroundStyle(Theme.ink)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private var passwordForm: some View {
        Form {
            Section {
                SecureField(
                    hiddenFolders.hasPassword ? "Текущий пароль" : "Пароль, от \(HiddenFolders.minimumPasswordLength) символов",
                    text: $password
                )
                .focused($focusedField, equals: 0)
                .submitLabel(hiddenFolders.hasPassword ? .done : .next)
                .onSubmit {
                    if hiddenFolders.hasPassword { save() } else { focusedField = 1 }
                }
                .accessibilityIdentifier("symbolPassword")

                if !hiddenFolders.hasPassword {
                    SecureField("Повторите пароль", text: $repeatedPassword)
                        .focused($focusedField, equals: 1)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("symbolPasswordRepeat")
                }
            } header: {
                Text(hiddenFolders.hasPassword ? "Пароль скрытых папок" : "Пароль на всякий случай")
            } footer: {
                if let passwordError {
                    Text(passwordError).foregroundStyle(.red)
                } else {
                    Text(hiddenFolders.hasPassword
                        ? "Новый знак сохранится после проверки пароля."
                        : "Если знак не получится, скрытые папки откроются по паролю: «Настройки» → «Открыть по паролю». Восстановить пароль нельзя.")
                }
            }

            Section {
                Button(action: save) {
                    HStack {
                        Text("Сохранить знак")
                        Spacer()
                        if isSaving { ProgressView() }
                    }
                }
                .disabled(isSaving || password.isEmpty)
                .accessibilityIdentifier("symbolSave")
            }
        }
        .scrollContentBackground(.hidden)
        .modifier(ShakeEffect(animatableData: CGFloat(attempts)))
    }

    private func handle(stroke: [CGPoint]) {
        switch SecretSymbol.check(sample: stroke, against: samples) {
        case nil:
            issue = nil
            samples.append(stroke)
            if samples.count == SecretSymbol.sampleCount {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                stage = .preview
            }
        case .tooSmall:
            fail("Нарисуйте крупнее — почти на всё поле")
        case .tooSimple:
            fail("Слишком просто: так выглядит обычный свайп. Нужен поворот или петля")
        case .mismatch:
            restart(message: "Не совпало с прошлым разом — нарисуйте знак заново три раза")
        }
    }

    private func fail(_ message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.linear(duration: 0.4)) { attempts += 1 }
        issue = message
    }

    private func restart(message: String?) {
        samples = []
        stage = .drawing
        if let message { fail(message) } else { issue = nil }
    }

    private func save() {
        guard !isSaving else { return }
        if !hiddenFolders.hasPassword {
            guard password.count >= HiddenFolders.minimumPasswordLength else {
                return passwordFailed("Пароль — не короче \(HiddenFolders.minimumPasswordLength) символов")
            }
            guard password == repeatedPassword else {
                repeatedPassword = ""
                return passwordFailed("Пароли не совпадают")
            }
        }
        guard let symbol = SecretSymbol(strokes: samples) else { return restart(message: "Знак не получился — нарисуйте заново") }
        isSaving = true
        let hadPassword = hiddenFolders.hasPassword
        Task {
            let saved = await hiddenFolders.saveSymbol(symbol, password: password)
            isSaving = false
            if saved {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                password = ""
                repeatedPassword = ""
                dismiss()
            } else {
                password = ""
                passwordFailed(hadPassword ? "Неверный пароль" : "Не удалось сохранить — попробуйте ещё раз")
            }
        }
    }

    private func passwordFailed(_ message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.linear(duration: 0.4)) { attempts += 1 }
        passwordError = message
    }
}

/// Поле для рисования. Здесь след виден — в отличие от «Файлов»: владелец
/// учится рисовать свой знак. Прежние образцы видны бледно, чтобы повторить их
private struct SymbolCanvas: View {
    let ghosts: [[CGPoint]]
    let onStroke: ([CGPoint]) -> Void

    @State private var current: [CGPoint] = []

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.surface)
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [6, 6]))

            ForEach(Array(ghosts.enumerated()), id: \.offset) { _, ghost in
                StrokePath(points: ghost)
                    .stroke(Theme.ink.opacity(0.14), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            StrokePath(points: current)
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if current.isEmpty { current.append(value.startLocation) }
                    current.append(value.location)
                }
                .onEnded { _ in
                    let stroke = current
                    current = []
                    onStroke(stroke)
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Поле для знака")
        .accessibilityIdentifier("symbolCanvas")
    }
}

/// Нарисованный образец, вписанный в квадрат, с точкой начала
private struct SymbolPreview: View {
    let stroke: [CGPoint]

    var body: some View {
        GeometryReader { proxy in
            let fitted = fit(stroke, in: proxy.size)
            ZStack {
                StrokePath(points: fitted)
                    .stroke(Theme.ink, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                if let start = fitted.first {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 16, height: 16)
                        .position(start)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Ваш знак. Зелёная точка — начало")
    }

    private func fit(_ points: [CGPoint], in size: CGSize) -> [CGPoint] {
        guard let bounds = StrokeMatcher.boundingBox(points), size.width > 0 else { return [] }
        let side = max(bounds.width, bounds.height, 1)
        let scale = min(size.width, size.height) / side
        let offset = CGPoint(
            x: (size.width - bounds.width * scale) / 2,
            y: (size.height - bounds.height * scale) / 2
        )
        return points.map {
            CGPoint(x: ($0.x - bounds.minX) * scale + offset.x, y: ($0.y - bounds.minY) * scale + offset.y)
        }
    }
}

private struct StrokePath: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

// MARK: - Пароль

/// «Настройки» → «Открыть по паролю»: на случай, если знак не получается.
/// После пароля настройки закрываются и открываются «Файлы» со скрытыми папками
struct HiddenPasswordRevealView: View {
    let onRevealed: () -> Void

    @Environment(HiddenFolders.self) private var hiddenFolders
    @State private var password = ""
    @State private var isChecking = false
    @State private var failed = false
    @State private var attempts = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
            Section {
                SecureField("Пароль скрытых папок", text: $password)
                    .focused($isFocused)
                    .submitLabel(.go)
                    .onSubmit(open)
                    .accessibilityIdentifier("hiddenPasswordField")
            } footer: {
                Text(failed ? "Неверный пароль" : "Пароль задаётся вместе со своим знаком.")
                    .foregroundStyle(failed ? Color.red : Color.secondary)
            }
            .modifier(ShakeEffect(animatableData: CGFloat(attempts)))

            Section {
                Button(action: open) {
                    HStack {
                        Text("Открыть скрытые папки")
                        Spacer()
                        if isChecking { ProgressView() }
                    }
                }
                .disabled(password.isEmpty || isChecking)
                .accessibilityIdentifier("hiddenPasswordOpen")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Открыть по паролю")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { isFocused = true }
    }

    private func open() {
        guard !password.isEmpty, !isChecking else { return }
        isChecking = true
        let candidate = password
        Task {
            let opened = await hiddenFolders.reveal(password: candidate)
            isChecking = false
            password = ""
            if opened {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onRevealed()
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                withAnimation(.linear(duration: 0.4)) { attempts += 1 }
                failed = true
            }
        }
    }
}

/// Смена пароля: текущий, новый и повтор
private struct ChangeHiddenPasswordView: View {
    @Environment(HiddenFolders.self) private var hiddenFolders
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var new = ""
    @State private var repeated = ""
    @State private var error: String?
    @State private var isSaving = false
    @State private var attempts = 0

    var body: some View {
        Form {
            Section {
                SecureField("Текущий пароль", text: $current)
            }
            Section {
                SecureField("Новый пароль, от \(HiddenFolders.minimumPasswordLength) символов", text: $new)
                SecureField("Повторите новый пароль", text: $repeated)
            } footer: {
                if let error { Text(error).foregroundStyle(.red) }
            }
            .modifier(ShakeEffect(animatableData: CGFloat(attempts)))

            Section {
                Button(action: save) {
                    HStack {
                        Text("Сменить пароль")
                        Spacer()
                        if isSaving { ProgressView() }
                    }
                }
                .disabled(current.isEmpty || new.isEmpty || isSaving)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Смена пароля")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() {
        guard new.count >= HiddenFolders.minimumPasswordLength else {
            return fail("Новый пароль — не короче \(HiddenFolders.minimumPasswordLength) символов")
        }
        guard new == repeated else {
            repeated = ""
            return fail("Новые пароли не совпадают")
        }
        isSaving = true
        Task {
            let changed = await hiddenFolders.changePassword(current: current, new: new)
            isSaving = false
            if changed {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } else {
                current = ""
                fail("Неверный текущий пароль")
            }
        }
    }

    private func fail(_ message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.linear(duration: 0.4)) { attempts += 1 }
        error = message
    }
}

/// «Дрожание» при ошибке — как было у кода входа
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 10
    var shakes = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: travel * sin(animatableData * .pi * CGFloat(shakes * 2)),
                y: 0
            )
        )
    }
}
