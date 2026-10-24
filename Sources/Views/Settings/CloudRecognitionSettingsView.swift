import SwiftUI

// Облачное распознавание: фото и сканы документов уходят в OpenAI (по
// умолчанию) или Google Gemini по ключу владельца. Выключено по умолчанию —
// включается только здесь, с честным предупреждением. У каждого сервиса свои
// ключ, модель и адрес
struct CloudRecognitionSettingsView: View {
    @Environment(SearchService.self) private var search
    @State private var keyDraft = ""
    @State private var modelDraft = ""
    @State private var urlDraft = ""
    @State private var showsAdvanced = false
    @State private var confirmsReread = false

    private var cloud: CloudRecognitionStore { search.cloud }

    var body: some View {
        Form {
            Section {
                Toggle("Распознавать в облаке", isOn: Binding(get: { cloud.isEnabled }, set: { cloud.setEnabled($0) }))
                    .accessibilityIdentifier("cloudToggle")
            } footer: {
                Text(Self.warning(cloud.provider))
            }

            Section {
                Toggle("Чат через облако", isOn: Binding(get: { cloud.chatEnabled }, set: { cloud.setChatEnabled($0) }))
                    .accessibilityIdentifier("cloudChatToggle")
            } footer: {
                Text("Вопросы чата уходят в \(cloud.provider.company) вместе с тем, что модель найдёт на iPhone: названия документов, папки, владельцы, поля — серия, номер и номера договоров маской, — и короткие выдержки текста. Вложения — картинками. Чтобы посмотреть документ — штамп, отметку, — модель может получить его страницы картинками, как при распознавании. Переписка хранится только в памяти iPhone. Модель на поле ввода выбирается чипом.")
            }

            Section("Сервис") {
                Picker("Сервис", selection: Binding(get: { cloud.provider }, set: { cloud.setProvider($0) })) {
                    ForEach(CloudProvider.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("cloudProvider")
                LabeledContent("Модель") {
                    HStack(spacing: 8) {
                        TextField(cloud.provider.defaultModel, text: $modelDraft)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { cloud.setModel(modelDraft) }
                            .accessibilityIdentifier("cloudModel")
                        Menu {
                            ForEach(cloud.provider.recognitionModels, id: \.id) { model in
                                Button(model.title) {
                                    modelDraft = model.id
                                    cloud.setModel(model.id)
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Выбрать модель")
                        .accessibilityIdentifier("cloudModelMenu")
                    }
                }
                DisclosureGroup("Дополнительно", isExpanded: $showsAdvanced) {
                    TextField(cloud.provider.defaultBaseURL, text: $urlDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit { cloud.setBaseURL(urlDraft) }
                        .accessibilityIdentifier("cloudBaseURL")
                    Text("Адрес сервиса — например, прокси на вашем VPN-сервере. Только https.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if cloud.hasKey {
                    LabeledContent("Ключ \(cloud.provider.title)", value: "сохранён на этом iPhone")
                    Button("Удалить ключ", role: .destructive) { cloud.removeKey() }
                        .accessibilityIdentifier("cloudRemoveKey")
                } else {
                    SecureField(cloud.provider == .openAI ? "Ключ API OpenAI (sk-…)" : "Ключ API Gemini", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveKey)
                        .accessibilityIdentifier("cloudKey")
                    Button("Сохранить ключ", action: saveKey)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("cloudSaveKey")
                }
            } header: {
                Text("Ключ")
            } footer: {
                Text("Ключ хранится в связке ключей только на этом iPhone: в резервные копии и на другие устройства он не попадает. У OpenAI и Gemini ключи свои — переключение сервиса их не стирает.")
            }

            Section {
                Button {
                    Task { await cloud.testConnection() }
                } label: {
                    Label("Проверить подключение", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(cloud.testResult == .running)
                .accessibilityIdentifier("cloudTest")
                if let result = cloud.testResult {
                    switch result {
                    case .running:
                        Label("Проверяю…", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    case .succeeded:
                        Label("Подключение работает", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text(cloud.provider == .openAI
                     ? "Проверка — бесплатный запрос сведений о модели: ключ, доступ к модели и страну он проверяет так же, как распознавание."
                     : "Проверка — короткий текстовый вопрос, без документов.")
            }

            if cloud.isEnabled, cloud.hasKey {
                Section {
                    let progress = search.progress
                    Text("Документов: \(progress.cloudDocuments) · распознано в облаке: \(progress.cloudRead) · ждут: \(progress.cloudPending)")
                        .monospacedDigit()
                        .accessibilityIdentifier("cloudCounts")
                    Label(Self.state(progress), systemImage: progress.cloudPaused == nil ? "cloud" : "exclamationmark.triangle.fill")
                        .foregroundStyle(progress.cloudPaused == nil ? Color.secondary : Color.orange)
                        .accessibilityIdentifier("cloudState")
                    // Смена модели прочитанное не перечитывает — только эта кнопка
                    Button("Перечитать все документы") { confirmsReread = true }
                        .disabled(progress.cloudDocuments == 0)
                        .accessibilityIdentifier("cloudReread")
                } header: {
                    Text("Ход работы")
                } footer: {
                    Text("Другая модель или сервис читают только новые документы. Прочитанные раньше остаются как есть, пока вы не нажмёте «Перечитать».")
                }
                .confirmationDialog(
                    "Отправить все документы заново?",
                    isPresented: $confirmsReread,
                    titleVisibility: .visible
                ) {
                    Button("Перечитать — \(cloud.model)") { search.rereadAll(cloud: true) }
                    Button("Отмена", role: .cancel) {}
                } message: {
                    Text("Документов: \(search.progress.cloudDocuments). Каждая страница — запрос к облаку и деньги на счёте.")
                }
            }

            Section("Расход") {
                LabeledContent("Отправлено страниц", value: "\(cloud.pagesSent)")
                if cloud.pagesSent > 0 {
                    LabeledContent("Примерно", value: Self.dollars(cloud.spentDollars))
                }
                if let perPage = CloudRecognitionStore.estimatedPagePrice(model: cloud.model) {
                    Text("Около \(Self.dollars(perPage)) за страницу по ценам \(cloud.provider.company) на 12.10.2026; рассуждение модели — сверху. Другая модель читает только новые документы.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Облачное распознавание")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            modelDraft = cloud.model
            urlDraft = cloud.baseURL
        }
        .onChange(of: cloud.provider) { _, _ in
            modelDraft = cloud.model
            urlDraft = cloud.baseURL
            keyDraft = ""
        }
        .onDisappear {
            cloud.setModel(modelDraft)
            cloud.setBaseURL(urlDraft)
        }
    }

    private func saveKey() {
        cloud.setKey(keyDraft)
        keyDraft = ""
    }

    /// Куда уходят данные и что с ними там бывает — по документации сервисов
    /// на 12.10.2026 (docs/cloud-reader.md)
    static func warning(_ provider: CloudProvider) -> String {
        switch provider {
        case .openAI:
            "Фото и сканы документов из папок, доступных для поиска, уходят в OpenAI по вашему ключу. На данных из API OpenAI не обучает модели, если вы сами не разрешили это в настройках организации. Ответы у OpenAI не хранятся (запросы идут с store=false), но журналы проверки на злоупотребления OpenAI держит до 30 дней. Из России OpenAI не работает — нужен VPN; по правилам OpenAI доступ из неподдерживаемой страны может привести к блокировке аккаунта. PDF с текстовым слоем не отправляются — их текст и так точный."
        case .gemini:
            "Фото и сканы документов из папок, доступных для поиска, уходят в Google по вашему ключу. Из России Gemini работает только с включённым VPN. Используйте платный ключ: на бесплатном Google читает данные и обучает на них модели. PDF с текстовым слоем не отправляются — их текст и так точный."
        }
    }

    static func state(_ progress: SearchIndexProgress) -> String {
        if let paused = progress.cloudPaused { return paused }
        if progress.cloudReading { return "Распознаёт…" }
        if progress.cloudPending > 0, progress.pending > 0 {
            return "Ждёт: сначала распознаётся текст на iPhone — осталось \(progress.pending)"
        }
        if progress.cloudPending > 0 { return "Ждёт, пока приложение открыто" }
        return "Всё распознано"
    }

    private static func dollars(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 1 ? 3 : 2)))
    }
}
