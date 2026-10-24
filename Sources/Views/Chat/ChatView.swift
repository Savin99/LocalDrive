import SwiftUI
import UniformTypeIdentifiers

// Главная страница: переписка с поиском по документам. Ответ приходит сразу
// текстом и карточками из каталога, без набора по буквам — поиск занимает
// доли секунды. Всё, что карточки делают с файлами и полями, они просят у
// этого экрана через chatActions
struct ChatView: View {
    let session: ChatSession

    @Environment(SearchService.self) private var search
    @Environment(LockManager.self) private var lock
    @Environment(VaultStore.self) private var store
    @Environment(\.isOffscreenPage) private var isOffscreenPage

    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var showsSettings = false
    @State private var opened: OpenedFile?
    @State private var editing: FieldEditRequest?
    /// Высота поля ввода с подсказками: над ней свайп листает страницы
    @State private var composerAreaHeight: CGFloat = 0
    /// Файл тащат над чатом — подсветить, что его примут
    @State private var isDropTargeted = false
    /// Подтверждение действия из ответа интерфейсом: напоминание
    @State private var confirmation: GenUIConfirmation?

    /// Подсказки пустого чата: текст уходит сообщением, значок — серый, как в ChatGPT
    private static let suggestions: [(text: String, symbol: String)] = [
        ("Мой паспорт", "person.text.rectangle"),
        ("Номер паспорта", "number"),
        ("Когда истекает загран", "calendar"),
        ("Дипломные документы", "graduationcap"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if session.messages.isEmpty {
                    welcome
                } else {
                    transcript
                }
            }
            // Файлы из «Файлов», «Фото» и Safari можно бросить прямо в чат
            .chatAttachmentDrop(into: session.inbox, isTargeted: $isDropTargeted) { _ in
                composerFocused = false
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if session.messages.isEmpty, session.inbox.draft.isEmpty {
                        suggestionsRow
                    }
                    if let status = IndexStatusLine.text(for: search.progress) {
                        IndexStatusLine(text: status)
                    }
                    ChatAttachmentStrip(inbox: session.inbox)
                    composer
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerAreaHeight = $0 }
            }
            // Чат за краем экрана, пока открыты «Файлы»
            .accessibilityHidden(isOffscreenPage)
            .navigationTitle("Чат")
            .navigationBarTitleDisplayMode(.inline)
            // Посередине шапки стоит общий переключатель «Чат | Файлы»
            .toolbar(removing: .title)
            .toolbar {
                // Монохромные контурные значки — как в шапке ChatGPT
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel("Настройки")
                }
                if !session.messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) { session.reset() }
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .foregroundStyle(Theme.ink)
                        }
                        .accessibilityLabel("Новый чат")
                    }
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
            }
            .sheet(item: $opened) { opened in
                FilePagerView(
                    files: opened.files,
                    initialFile: opened.file,
                    initialPage: opened.page
                ) { self.opened = nil }
                    .ignoresSafeArea()
            }
            .sheet(item: $editing) { request in
                FieldEditSheet(field: request.field) { value in
                    await search.setManualField(documentID: request.document.id, key: request.field.key, value: value)
                    await session.refresh(documentID: request.document.id)
                }
            }
        }
        .environment(\.chatActions, actions)
        .environment(\.chatRevealsSensitive, session.revealsSensitive)
        // Карточки предложений сохраняют вложения из этого ящика
        .environment(session.inbox)
        .onAppear {
            session.useFiles(store)
            session.useGenUIHooks(genuiHooks)
        }
        .confirmationDialog(
            confirmation?.title ?? "",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { resolveConfirmation(false) } }),
            titleVisibility: .visible
        ) {
            Button("Подтвердить") { resolveConfirmation(true) }
            Button("Отмена", role: .cancel) { resolveConfirmation(false) }
        }
        // MainView не листает страницы свайпом, начатым над полем ввода
        .preference(key: ChatComposerHeightKey.self, value: composerAreaHeight)
    }

    // MARK: - Пустой чат

    /// Куда уходят данные — честно: с облаком «без сети» было бы неправдой
    private var privacyLine: String {
        let cloud = search.cloud
        if cloud.chatAvailable && cloud.chatModel != .local {
            return "Ответы — из ваших файлов. Вопросы и вложения уходят в \(cloud.provider.company) по вашему ключу"
        }
        if cloud.isEnabled && cloud.hasKey {
            return "Ответы — из ваших файлов, на iPhone. Фото документов распознаёт облако по вашему ключу"
        }
        return "Ответы — из ваших файлов, прямо на iPhone, без сети"
    }

    /// Как в ChatGPT: одно приветствие по центру, без иконок и плашек
    private var welcome: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    Text("Чем помочь?")
                        .font(.system(.title, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(privacyLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// Подсказки прямо над полем ввода — лентой, которую листают пальцем
    private var suggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.text) { suggestion in
                    Button {
                        send(suggestion.text)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: suggestion.symbol)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(suggestion.text)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.ink)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chatSuggestion")
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
    }

    // MARK: - Переписка

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(session.messages) { message in
                        MessageRow(message: message, onRemember: { session.rememberOwner($0) })
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            // Плотный край под шапкой: системный мягкий здесь не срабатывал, и
            // карточки просвечивали сквозь кнопки и переключатель (снимок владельца)
            .scrollEdgeEffectStyle(.hard, for: .top)
            .scrollDismissesKeyboard(.interactively)
            .onAppear { scrollToEnd(proxy, animated: false) }
            // Новый вопрос — вниз, к индикатору ответа
            .onChange(of: session.messages.count) { _, _ in scrollToEnd(proxy) }
            // Ответ готов — показываем его с начала вместе с вопросом, как в
            // чатах: высокая карточка иначе уехала бы верхом за край экрана
            .onChange(of: session.messages.last?.isPending) { _, isPending in
                guard isPending == false else { return }
                scrollToLastQuestion(proxy)
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let last = session.messages.last?.id else { return }
        withAnimation(animated ? .snappy(duration: 0.3) : nil) {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    private func scrollToLastQuestion(_ proxy: ScrollViewProxy) {
        guard let question = session.messages.last(where: { $0.role == .user })?.id else { return }
        withAnimation(.snappy(duration: 0.3)) {
            proxy.scrollTo(question, anchor: .top)
        }
    }

    // MARK: - Поле ввода

    private var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !session.inbox.draft.isEmpty) && !session.isAnswering
    }

    /// Плавающее поле в духе ChatGPT, но в одну строку: кнопка отправки стоит
    /// рядом с текстом. Владелец на iPhone: нижняя панель занимала слишком
    /// много места. Поле растёт только при многострочном вводе, кнопка тогда
    /// остаётся внизу справа, у последней строки
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            attachButton
            TextField("Спросить или найти", text: $draft, axis: .vertical)
                .font(.body)
                .foregroundStyle(Theme.ink)
                .lineLimit(1...5)
                .submitLabel(.send)
                .onSubmit { send() }
                // В многострочном поле Return вставляет перевод строки, а не
                // отправляет: строка, закончившаяся переводом, — это отправка
                .onChange(of: draft) { _, value in
                    guard value.hasSuffix("\n") else { return }
                    draft = String(value.dropLast())
                    send()
                }
                .focused($composerFocused)
                // Высота строки с отступами — 44 pt, как у кнопки: при одной
                // строке кнопка стоит ровно по центру поля
                .padding(.vertical, 11)
                .accessibilityIdentifier("chatInput")

            ComposerChips(cloud: search.cloud)
                .padding(.bottom, 6)

            // Пока отвечает облако, на месте «Отправить» — «Стоп»: ответ
            // обрывается, а то, что успело прийти, остаётся
            if session.answeringInCloud {
                Button {
                    session.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 32, height: 32)
                        .background(Theme.ink, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
                .accessibilityLabel("Стоп")
                .accessibilityIdentifier("chatStop")
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend ? AnyShapeStyle(Theme.background) : AnyShapeStyle(.tertiary))
                        .frame(width: 32, height: 32)
                        .background(canSend ? Theme.ink : Theme.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .animation(.snappy(duration: 0.15), value: canSend)
                .padding(.bottom, 6)
                .accessibilityLabel("Отправить")
                .accessibilityIdentifier("chatSend")
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// «+» — вложения: фото, файл, вставка из буфера. Брошенные файлы видны
    /// над строкой ввода, в хранилище они попадают только по «Выполнить»
    private var attachButton: some View {
        ChatAttachmentMenu(inbox: session.inbox) { _ in
            composerFocused = false
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 32, height: 32)
                .background(Theme.surface, in: Circle())
                .accessibilityLabel("Вложение")
        }
        .padding(.bottom, 6)
    }

    /// `text == nil` — отправить поле ввода и очистить его; иначе это чип,
    /// и начатый в поле вопрос остаётся на месте. Вложения уходят только с
    /// полем ввода, не с чипом
    private func send(_ text: String? = nil, documentID: Int64? = nil) {
        let message = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isAnswering else { return }
        if text == nil, documentID == nil, !session.inbox.draft.isEmpty {
            session.send(message, attaching: session.inbox.takeDraft())
        } else {
            guard !message.isEmpty else { return }
            session.send(message, documentID: documentID)
        }
        if text == nil { draft = "" }
        // Ответ — это карточки, по которым тапают: клавиатура закрывала бы их
        composerFocused = false
    }

    // MARK: - Действия ответа интерфейсом

    /// Кнопки и формы ответа интерфейсом: вопрос — в чат, файл — в просмотр,
    /// номер — после Face ID, напоминание — с подтверждением
    private var genuiHooks: GenUIChatHooks {
        GenUIChatHooks(
            send: { text in send(text) },
            open: { document in opened = OpenedFile(file: document.file, files: [document.file], page: nil) },
            copy: { _, field in
                if FieldKey.isSensitive(field.key) {
                    guard await setRevealed(true) else { return false }
                }
                copy(field.value)
                return true
            },
            remind: { document, validity in await remind(document, validity) },
            confirm: { title in
                await withCheckedContinuation { continuation in
                    confirmation = GenUIConfirmation(title: title) { continuation.resume(returning: $0) }
                }
            }
        )
    }

    private func resolveConfirmation(_ confirmed: Bool) {
        let pending = confirmation
        confirmation = nil
        pending?.resume(confirmed)
    }

    // MARK: - Действия карточек

    private var actions: ChatActions {
        ChatActions(
            open: { file, list, page in
                opened = OpenedFile(file: file, files: list, page: page)
            },
            send: { text in send(text) },
            choose: { option in send(option.query, documentID: option.documentID) },
            copy: { value in copy(value) },
            setRevealed: { revealed in await setRevealed(revealed) },
            edit: { document, field in
                Task { await startEditing(field, of: document) }
            },
            verify: { document, field in
                await search.verifyField(documentID: document.id, key: field.key)
                await session.refresh(documentID: document.id)
            },
            remind: { document, validity in await remind(document, validity) }
        )
    }

    /// Буфер только этого iPhone и на две минуты: копируются номера документов.
    /// Тактильный отклик даёт сама карточка — здесь только запись в буфер
    private func copy(_ value: String) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: value]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(120),
            ]
        )
    }

    private func setRevealed(_ revealed: Bool) async -> Bool {
        guard revealed else {
            session.revealsSensitive = false
            return false
        }
        if session.revealsSensitive { return true }
        let confirmed = await lock.confirmOwner(reason: "Показать номер документа")
        session.revealsSensitive = confirmed
        return confirmed
    }

    /// Лист правки показывает значение целиком — номер открывается только после Face ID
    private func startEditing(_ field: DocumentField, of document: ChatDocument) async {
        if FieldKey.isSensitive(field.key) {
            guard await setRevealed(true) else { return }
        }
        editing = FieldEditRequest(document: document, field: field)
    }

    private func remind(_ document: ChatDocument, _ validity: DocumentValidity) async -> String {
        do {
            let date = try await ReminderScheduler.schedule(for: document, validity: validity)
            return "Напомню \(Self.reminderFormatter.string(from: date))"
        } catch ReminderScheduler.Failure.accessDenied {
            return "Нет доступа к «Напоминаниям» — разрешите его в Настройках iPhone"
        } catch ReminderScheduler.Failure.noDate {
            return "У документа нет даты, к которой можно привязать напоминание"
        } catch ReminderScheduler.Failure.noList {
            return "В «Напоминаниях» нет списка по умолчанию"
        } catch {
            return "Не удалось создать напоминание"
        }
    }

    private static let reminderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy 'в' HH:mm"
        return formatter
    }()
}

// MARK: - Сообщения

private struct OpenedFile: Identifiable {
    let file: VaultFile
    let files: [VaultFile]
    let page: Int?

    var id: String { file.id }
}

/// Вопрос «Подтвердить?» к действию из ответа интерфейсом
private struct GenUIConfirmation {
    let title: String
    let resume: (Bool) -> Void
}

private struct FieldEditRequest: Identifiable {
    let document: ChatDocument
    let field: DocumentField

    var id: String { "\(document.id)-\(field.key)" }
}

private struct MessageRow: View {
    let message: ChatSession.Message
    var onRemember: (OwnerSuggestion) -> Void = { _ in }
    @Environment(SearchService.self) private var search

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                // Вложения вопроса — над пузырём, как в ChatGPT
                ForEach(message.attachments, id: \.self) { id in
                    ChatAttachmentCardView(id: id)
                        .containerRelativeFrame(.horizontal, alignment: .trailing) { length, _ in length * 0.7 }
                }
                if !message.text.isEmpty {
                    // Серый пузырь вопроса и тёмный текст — как в ChatGPT
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        // Пузырь облегает текст, но не шире 80% экрана
                        .containerRelativeFrame(.horizontal, alignment: .trailing) { length, _ in length * 0.8 }
                        .accessibilityIdentifier("chatUserMessage")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if let notice = message.notice {
                    Label(notice, systemImage: "icloud.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("chatNotice")
                }
                // Облако думает: одна строка «Думает · N с», рассуждение — по касанию
                let thinking = message.isPending && message.startedAt != nil && message.text.isEmpty && message.cards.isEmpty
                    && (message.genui?.blocks.isEmpty ?? true)
                if !message.thoughts.isEmpty || thinking {
                    ReasoningBlock(text: message.thoughts, seconds: message.thinkingSeconds, startedAt: message.startedAt, isLive: thinking)
                }
                if let genui = message.genui {
                    // Ответ интерфейсом: текст, состояние и блоки — по мере прихода
                    GenUIMessageView(model: genui, environment: GenUIEnvironment(
                        dataProvider: GenUIIndexDataProvider(search: search),
                        actionPerformer: message.genuiPerformer,
                        appCard: { card in AnyView(GenUIAppCardView(card: card)) }
                    ))
                    .accessibilityIdentifier("chatInterface")
                } else if message.isPending, message.text.isEmpty, message.cards.isEmpty, message.startedAt == nil {
                    TypingIndicator()
                } else if !message.text.isEmpty {
                    // Ответ без пузыря: текст прямо на странице; у облака он
                    // приходит по частям, пока идёт ответ
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("chatAssistantMessage")
                }
                // Карточки облака приходят до текста ответа — показываем сразу
                ForEach(message.cards) { card in
                    ChatCardView(card: card)
                }
                if let suggestion = message.ownerSuggestion {
                    Button {
                        onRemember(suggestion)
                    } label: {
                        Label("Запомнить: это я — \(suggestion.name)", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("chatRememberOwner")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Три точки, пока роутер ищет ответ
private struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(isAnimating ? 1 : 0.3)
                    .scaleEffect(isAnimating ? 1 : 0.75)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.55)
                            .repeatForever()
                            .delay(Double(index) * 0.18),
                        value: isAnimating
                    )
            }
        }
        .padding(.vertical, 8)
        .onAppear { isAnimating = !reduceMotion }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ищу…")
    }
}

/// Тонкая строка над полем ввода, пока идёт работа с документами: иначе
/// «ничего не нашёл» сразу после загрузки выглядит поломкой
struct IndexStatusLine: View {
    let text: String

    /// Что показать. nil — работы нет, строка скрыта. Модель без памяти не
    /// «перечитывает» — об этом говорит экран модели, а не чат
    static func text(for progress: SearchIndexProgress) -> String? {
        if progress.pending > 0 {
            return "Распознаю документы… осталось \(progress.pending)"
        }
        if progress.cloudPending > 0, progress.cloudPaused == nil {
            return "Облако распознаёт документы… осталось \(progress.cloudPending)"
        }
        if progress.modelPending > 0, progress.modelUnavailable == nil {
            return "Модель перечитывает документы… осталось \(progress.modelPending)"
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("indexStatus")
    }
}

/// «Думает · 3 с», пока облако думает, и «Рассуждение · 4 с» после: одна
/// строка, итог размышлений — по касанию
private struct ReasoningBlock: View {
    let text: String
    let seconds: Double?
    let startedAt: Date?
    let isLive: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    if isLive, let startedAt {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text("Думает · \(max(0, Int(context.date.timeIntervalSince(startedAt)))) с")
                                .monospacedDigit()
                        }
                    } else {
                        Text(title)
                    }
                    if !text.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            .accessibilityIdentifier("chatReasoning")
            if expanded, !text.isEmpty {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.border).frame(width: 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var title: String {
        if isLive { return "Думает…" }
        guard let seconds else { return "Рассуждение" }
        return "Рассуждение · \(max(1, Int(seconds.rounded()))) с"
    }
}

/// Чипы на поле ввода: модель («Luna», «Sol», «Astra» или «Flash», «Lite» —
/// по выбранному сервису — и «iPhone») и сколько ей думать.
/// Подписи короткие — поле остаётся в одну строку. Пока облачный чат выключен
/// или нет ключа, облачные модели в меню недоступны
private struct ComposerChips: View {
    let cloud: CloudRecognitionStore

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Section {
                    ForEach(CloudChatModel.choices(for: cloud.provider), id: \.self) { model in
                        Button {
                            cloud.setChatModel(model)
                        } label: {
                            if effectiveModel == model {
                                Label(model.title, systemImage: "checkmark")
                            } else {
                                Text(model.title)
                            }
                        }
                        .disabled(model != .local && !cloud.chatAvailable)
                    }
                } footer: {
                    if !cloud.chatAvailable {
                        Text("Облачные модели — в «Настройки → Облачное распознавание → Чат через облако»")
                    }
                }
            } label: {
                chip(effectiveModel.chip)
            }
            .accessibilityIdentifier("chatModelChip")

            if effectiveModel != .local {
                Menu {
                    ForEach(CloudChatReasoning.allCases, id: \.self) { reasoning in
                        Button {
                            cloud.setChatReasoning(reasoning)
                        } label: {
                            if cloud.chatReasoning == reasoning {
                                Label(reasoning.title, systemImage: "checkmark")
                            } else {
                                Text(reasoning.title)
                            }
                        }
                    }
                } label: {
                    chip(cloud.chatReasoning.chip)
                }
                .accessibilityIdentifier("chatReasoningChip")
            }
        }
    }

    /// Без облачного чата отвечает iPhone, что бы ни было выбрано
    private var effectiveModel: CloudChatModel {
        cloud.chatAvailable ? cloud.chatModel : .local
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(Theme.surface, in: Capsule())
    }
}
