import SwiftUI

// Модель для документов: читает фото удостоверений, когда распознавание текста
// не подтвердило ФИО, номер или даты. Скачивается только по кнопке отсюда
struct DocumentModelSettingsView: View {
    @Environment(SearchService.self) private var search
    @State private var deleting: DocumentModelChoice?
    @State private var available = DeviceMemory.available

    private var models: DocumentModelStore { search.documentModel }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro
                privacy
                if !models.installed.isEmpty { passCard }
                if let notice { noticeCard(notice) }
                ForEach(DocumentModelChoice.allCases, id: \.self) { choice in
                    modelCard(choice)
                }
                if !ChatModelStore.runsOnThisDevice {
                    Text("В симуляторе модель не работает: ей нужен GPU iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .background(Theme.background)
        .navigationTitle("Модель для документов")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                available = DeviceMemory.available
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog(
            "Удалить \(deleting?.modelName ?? "модель")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let deleting { models.delete(deleting) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Уже прочитанное останется в карточках. Скачать модель можно снова в любой момент.")
        }
    }

    // MARK: - Пояснения

    private var intro: some View {
        Text("Без модели ФИО, номер и даты берутся из распознанного текста и машиночитаемой строки паспорта. Модель смотрит на само фото паспорта или прав, когда распознавание что-то не подтвердило: тяжёлый снимок, поворот, срезанная строка внизу.")
            .font(.subheadline)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cardStyle(cornerRadius: 18)
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 10) {
            point("iphone", "Работает на iPhone без сети, фото никуда не уходят")
            point("arrow.down.circle", "Скачивается один раз, только отсюда")
            point("folder", "Видит только удостоверения из папок, доступных для поиска")
            point("checkmark.shield", "Проверенное контрольными цифрами и исправленное вами не меняет")
            point("exclamationmark.circle", "Её значения помечены «проверьте», пока не совпадут с текстом на фото")
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

    // MARK: - Ход чтения

    /// «Удостоверений: 12 · прочитано моделью: 3 · ждут: 2» и что модель делает сейчас
    private var passCard: some View {
        let progress = search.progress
        let state = Self.passState(progress)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Удостоверений: \(progress.identityDocuments) · прочитано моделью: \(progress.modelRead) · ждут: \(progress.modelPending)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
                .accessibilityIdentifier("documentModelCounts")
            Label(state.text, systemImage: state.symbol)
                .font(.footnote)
                .foregroundStyle(state.warning ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("documentModelProgress")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardStyle(cornerRadius: 18)
    }

    /// Что модель делает сейчас — одной строкой
    static func passState(_ progress: SearchIndexProgress) -> (text: String, symbol: String, warning: Bool) {
        if progress.modelReading {
            return ("Читает…", "doc.text.viewfinder", false)
        }
        if let reason = progress.modelUnavailable {
            return ("Ждёт: \(reason)", "exclamationmark.triangle.fill", true)
        }
        if progress.modelPending > 0, progress.pending > 0 {
            return ("Ждёт: сначала распознаётся текст — осталось \(progress.pending)", "hourglass", false)
        }
        if progress.modelPending > 0 {
            return ("Ждёт, пока приложение открыто: читает только на экране", "hourglass", false)
        }
        return ("Всё прочитано", "checkmark.circle.fill", false)
    }

    // MARK: - Модели

    /// Установленная модель не помещается в память — подсказка, что делать
    private var notice: String? {
        guard available > 0 else { return nil }
        let installed = models.installed
        if installed.contains(.standard), available < DocumentModelChoice.standard.requiredMemoryBytes {
            if installed.contains(.light) {
                return "Qwen3.5 4B не помещается в память этого iPhone — документы читает облегчённая. Qwen3.5 4B можно удалить и освободить \(Self.size(DocumentModelChoice.standard.downloadBytes))."
            }
            return "Qwen3.5 4B не помещается: приложению доступно \(Self.memory(available)), ей нужно \(Self.memory(DocumentModelChoice.standard.requiredMemoryBytes)). Облегчённая помещается."
        }
        return nil
    }

    private func noticeCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if models.installed.contains(.light) {
                Button {
                    deleting = .standard
                } label: {
                    Text("Удалить Qwen3.5 4B")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .secondaryCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("documentModelDeleteStandard")
            } else if models.state(.light) == .notInstalled || isFailed(.light) {
                downloadButton(.light, title: "Скачать облегчённую · \(Self.size(DocumentModelChoice.light.downloadBytes))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardStyle(cornerRadius: 18)
        .accessibilityIdentifier("documentModelNotice")
    }

    private func modelCard(_ choice: DocumentModelChoice) -> some View {
        let recommended = DocumentModelChoice.recommended(available: available) == choice
        let fits = available == 0 || available >= choice.requiredMemoryBytes
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(choice.modelName)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(Self.size(choice.downloadBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if models.state(choice) == .installed {
                    Text(models.activeChoice == choice ? "читает" : "установлена")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                } else if recommended {
                    Text("подходит этому iPhone")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            Text(choice == .standard
                 ? "Точнее облегчённой. Пока читает документ, занимает около 3,8 ГБ памяти."
                 : "Для iPhone, где приложению доступно меньше памяти. Пока читает документ, занимает около \(Self.memory(choice.measuredPeakMiB * 1_048_576)).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(
                "Нужно \(Self.memory(choice.requiredMemoryBytes)) памяти" + (available > 0 ? " · доступно \(Self.memory(available))" : ""),
                systemImage: fits ? "memorychip" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(fits ? Color.secondary : Color.orange)
            .accessibilityIdentifier("documentModelMemory-\(choice.rawValue)")
            actions(choice, recommended: recommended || fits)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(cornerRadius: 18)
    }

    @ViewBuilder
    private func actions(_ choice: DocumentModelChoice, recommended: Bool) -> some View {
        switch models.state(choice) {
        case .notInstalled:
            downloadButton(choice, title: "Скачать · \(Self.size(choice.downloadBytes))", prominent: recommended)
        case .downloading(let fraction):
            downloadProgress(choice, fraction: fraction)
        case .installed:
            Button {
                deleting = choice
            } label: {
                Text("Удалить модель")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .secondaryCapsule()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("documentModelDelete-\(choice.rawValue)")
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            downloadButton(choice, title: "Попробовать снова", prominent: true)
        }
    }

    private func isFailed(_ choice: DocumentModelChoice) -> Bool {
        if case .failed = models.state(choice) { return true }
        return false
    }

    @ViewBuilder
    private func downloadButton(_ choice: DocumentModelChoice, title: String, prominent: Bool = true) -> some View {
        let button = Button {
            models.download(choice)
        } label: {
            Label(title, systemImage: "arrow.down.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .disabled(!ChatModelStore.runsOnThisDevice || models.isDownloading)
        .opacity(ChatModelStore.runsOnThisDevice && !models.isDownloading ? 1 : 0.4)
        .accessibilityIdentifier("documentModelDownload-\(choice.rawValue)")
        if prominent {
            button.primaryCapsule()
        } else {
            button.secondaryCapsule()
        }
    }

    private func downloadProgress(_ choice: DocumentModelChoice, fraction: Double) -> some View {
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
            .accessibilityIdentifier("documentModelCancel")
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func memory(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

/// «Доступно приложению: 5,1 ГБ · модели нужно 4,1 ГБ». Лимит памяти без
/// increased-memory-limit на iPhone не измерен — эту строку владелец сообщит.
/// Число меняется, поэтому перечитывается раз в две секунды
struct MemoryBudgetLine: View {
    let required: Int64
    @State private var available = DeviceMemory.available

    var body: some View {
        Group {
            if available > 0 {
                let enough = available >= required
                Label(
                    "Доступно приложению: \(Self.size(available)) · модели нужно \(Self.size(required))",
                    systemImage: enough ? "memorychip" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(enough ? Color.secondary : Color.orange)
            } else {
                Label("Модели нужно \(Self.size(required)) памяти", systemImage: "memorychip")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            while !Task.isCancelled {
                available = DeviceMemory.available
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
