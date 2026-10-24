import SwiftUI

// Скачивание модели для чата. Единственное место, откуда приложение выходит
// в сеть, — и только по нажатию кнопки
struct ChatModelSettingsView: View {
    @Environment(ChatModelStore.self) private var models
    @State private var confirmsDelete = false

    /// Модель одна: на стенде лёгкая вариация понимала вопросы заметно хуже
    private let model = ChatModelChoice.standard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro
                privacy
                modelCard
                status
            }
            .padding(20)
        }
        .background(Theme.background)
        .navigationTitle("Модель для чата")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Удалить модель?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { models.delete() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Чат продолжит отвечать на знакомые вопросы без неё. Скачать модель можно снова в любой момент.")
        }
    }

    // MARK: - Пояснения

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Без модели чат понимает знакомые вопросы: «мой паспорт», «номер паспорта», «когда истекает загран». С моделью — свободные вопросы и уточнения вроде «а загран?».")
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardStyle(cornerRadius: 18)
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 10) {
            point("iphone", "Работает на iPhone без сети")
            point("arrow.down.circle", "Скачивается один раз, только отсюда — это единственный выход приложения в сеть")
            point("eye.slash", "Не видит текста документов и значений полей: только ваш вопрос и список видов документов")
            point("number", "Номера и даты в ответе подставляет приложение — модель не может их напечатать")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardStyle(cornerRadius: 18)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Модель

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(model.modelName)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(Self.size(model.downloadBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .installed = models.state {
                    Text("установлена")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            Text("Открытая модель Qwen от Alibaba, сжатая до 4 бит для iPhone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if DocumentReaderFeature.isEnabled {
                MemoryBudgetLine(required: model.requiredMemoryBytes)
                    .accessibilityIdentifier("chatModelMemory")
            }
            if models.hasMemory(for: model) == false {
                Label("Сейчас приложению доступно меньше памяти, чем нужно модели. Чат продолжит отвечать на знакомые вопросы без неё.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(cornerRadius: 18)
    }

    // MARK: - Состояние

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !ChatModelStore.runsOnThisDevice {
                Text("В симуляторе модель не работает: ей нужен GPU iPhone. Чат здесь отвечает без неё.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            switch models.state {
            case .notInstalled:
                downloadButton(title: "Скачать · \(Self.size(model.downloadBytes))")
            case .downloading(let choice, let fraction):
                downloadProgress(choice, fraction: fraction)
            case .installed(let choice):
                Label("Готово: чат понимает свободные вопросы — \(choice.modelName)", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Button {
                    confirmsDelete = true
                } label: {
                    Text("Удалить модель")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .secondaryCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chatModelDelete")
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                downloadButton(title: "Попробовать снова")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func downloadButton(title: String) -> some View {
        Button {
            models.download(model)
        } label: {
            Label(title, systemImage: "arrow.down.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .primaryCapsule()
        }
        .buttonStyle(.plain)
        .disabled(!ChatModelStore.runsOnThisDevice)
        .opacity(ChatModelStore.runsOnThisDevice ? 1 : 0.4)
        .accessibilityIdentifier("chatModelDownload")
    }

    private func downloadProgress(_ choice: ChatModelChoice, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: fraction)
                .tint(Theme.accent)
            let done = Int64(Double(choice.downloadBytes) * fraction)
            Text("Скачано \(Self.size(done)) из \(Self.size(choice.downloadBytes))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("Не закрывайте приложение. Если связь прервётся, скачивание продолжится с того же места.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                models.cancelDownload()
            } label: {
                Text("Остановить")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .secondaryCapsule()
            }
            .buttonStyle(.plain)
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
