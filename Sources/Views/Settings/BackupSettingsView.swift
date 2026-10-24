import SwiftUI
import UniformTypeIdentifiers

struct BackupSettingsView: View {
    @Environment(BackupManager.self) private var backup

    @State private var recoverySheet: RecoverySheet?
    @State private var showsHistory = false
    @State private var confirmsDelete = false
    @State private var setupError: String?
    @State private var showsFolderPicker = false

    private enum RecoverySheet: Identifiable {
        case setup(String)
        case reveal(String)

        var id: String {
            switch self {
            case .setup: "setup"
            case .reveal: "reveal"
            }
        }

        var code: String {
            switch self {
            case .setup(let code), .reveal(let code): code
            }
        }

        var isSetup: Bool {
            if case .setup = self { return true }
            return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                statusCard
                settingsGroup
                createButton

                Text("Файлы остаются на iPhone. В iCloud Drive хранится только зашифрованная копия.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                if backup.versionCount > 0 {
                    Button(role: .destructive) {
                        confirmsDelete = true
                    } label: {
                        Label("Удалить резервные копии", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .cardStyle(cornerRadius: 20)
                    }
                    .buttonStyle(.plain)
                }

                if let error = setupError ?? backup.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Защита и восстановление")
        .navigationBarTitleDisplayMode(.inline)
        .task { await backup.refresh() }
        .sheet(item: $recoverySheet) { sheet in
            RecoveryCodeView(code: sheet.code, requiresConfirmation: sheet.isSetup) {
                recoverySheet = nil
                if sheet.isSetup {
                    Task { await backup.enableAndCreateFirstBackup() }
                }
            } onCancel: {
                if sheet.isSetup { backup.discardRecoveryCode() }
                recoverySheet = nil
            }
        }
        .sheet(isPresented: $showsHistory) {
            BackupHistoryView()
        }
        .fileImporter(
            isPresented: $showsFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderSelection
        )
        .confirmationDialog(
            "Удалить все резервные копии?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("Удалить из выбранной папки", role: .destructive) {
                Task { await backup.deleteBackups() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Локальные файлы на этом iPhone останутся на месте.")
        }
    }

    private var statusCard: some View {
        HStack(spacing: 18) {
            Image("BackupShield")
                .resizable()
                .scaledToFit()
                .frame(width: 68, height: 68)

            VStack(alignment: .leading, spacing: 5) {
                Text(statusTitle)
                    .font(.system(.headline, weight: .semibold))
                Text(statusSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if backup.isWorking { ProgressView() }
        }
        .padding(20)
        .cardStyle()
    }

    private var settingsGroup: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Автоматическая копия")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { backup.isEnabled },
                    set: { setAutomaticBackup($0) }
                ))
                .labelsHidden()
                .tint(Theme.accent)
                .disabled(backup.isWorking)
            }
            .padding(18)

            Divider().padding(.leading, 18)
            settingsRow(
                title: "Хранилище",
                value: backup.hasBackupLocation ? backup.backupLocationName : "Выбрать папку",
                action: requestFolder
            )
            Divider().padding(.leading, 18)
            settingsRow(
                title: "Код восстановления",
                value: backup.hasRecoveryKey ? "Сохранён" : "Не создан",
                action: revealRecoveryCode
            )
            Divider().padding(.leading, 18)
            settingsRow(
                title: "История копий",
                value: pluralize(backup.versionCount, "версия", "версии", "версий"),
                action: backup.versionCount > 0 ? { showsHistory = true } : nil
            )
        }
        .cardStyle(cornerRadius: 20)
    }

    @ViewBuilder
    private func settingsRow(title: String, value: String, action: (() -> Void)?) -> some View {
        if let action {
            Button(action: action) {
                rowContent(title: title, value: value, showsChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            rowContent(title: title, value: value, showsChevron: false)
        }
    }

    private func rowContent(title: String, value: String, showsChevron: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(18)
    }

    private var createButton: some View {
        Button {
            if !backup.hasBackupLocation {
                requestFolder()
            } else if backup.hasRecoveryKey {
                Task { await backup.createBackup() }
            } else {
                beginRecoverySetup()
            }
        } label: {
            Label("Создать копию сейчас", systemImage: "arrow.clockwise")
                .font(.system(.body, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .cardStyle(cornerRadius: 20)
        }
        .buttonStyle(.plain)
        .disabled(backup.isWorking)
    }

    private var statusTitle: String {
        if backup.isWorking { return "Создаём защищённую копию" }
        if backup.lastBackupDate != nil { return "Копия актуальна" }
        if !backup.hasBackupLocation { return "Выберите папку для копий" }
        if backup.isEnabled && !backup.storageAvailable { return "Папка с копиями недоступна" }
        return "Резервная копия не настроена"
    }

    private var statusSubtitle: String {
        if backup.isWorking { return "Можно продолжать пользоваться приложением" }
        guard let date = backup.lastBackupDate else {
            if !backup.hasBackupLocation {
                return "Подойдёт папка в iCloud Drive через «Файлы»"
            }
            return "Настройте один раз, дальше — автоматически"
        }
        let dateText: String
        if Calendar.current.isDateInToday(date) {
            dateText = "Сегодня, \(date.formatted(date: .omitted, time: .shortened))"
        } else {
            dateText = date.formatted(date: .abbreviated, time: .shortened)
        }
        let sizeText = ByteCountFormatter.string(fromByteCount: backup.lastBackupSize, countStyle: .file)
        return "\(dateText) · \(sizeText)"
    }

    private func setAutomaticBackup(_ enabled: Bool) {
        if !enabled {
            backup.isEnabled = false
        } else if !backup.hasBackupLocation {
            requestFolder()
        } else if backup.hasRecoveryKey {
            backup.isEnabled = true
            Task { await backup.createBackup() }
        } else {
            beginRecoverySetup()
        }
    }

    private func beginRecoverySetup() {
        do {
            setupError = nil
            recoverySheet = .setup(try backup.createRecoveryCode())
        } catch {
            recoverySheet = nil
            setupError = error.localizedDescription
        }
    }

    private func revealRecoveryCode() {
        if let code = backup.recoveryCode {
            recoverySheet = .reveal(code)
        } else {
            beginRecoverySetup()
        }
    }

    private func requestFolder() {
        setupError = nil
        showsFolderPicker = true
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { throw BackupFolderError.notSelected }
            try backup.selectBackupFolder(url)

            Task {
                await backup.refresh()
                if backup.hasRecoveryKey {
                    await backup.createBackup()
                } else {
                    // лист нельзя показывать, пока пикер ещё анимирует закрытие
                    try? await Task.sleep(for: .milliseconds(300))
                    beginRecoverySetup()
                }
            }
        } catch {
            setupError = error.localizedDescription
        }
    }
}

private struct BackupHistoryView: View {
    @Environment(BackupManager.self) private var backup
    @Environment(\.dismiss) private var dismiss
    @State private var pendingSummary: BackupSummary?
    @State private var restoreSummary: BackupSummary?
    @State private var confirmsRestore = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(backup.summaries) { summary in
                        Button {
                            pendingSummary = summary
                            confirmsRestore = true
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "lock.icloud.fill")
                                    .foregroundStyle(Theme.ink)
                                    .frame(width: 34, height: 34)
                                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .foregroundStyle(.primary)
                                    Text(ByteCountFormatter.string(fromByteCount: summary.encryptedBytes, countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("LocalDrive хранит до трёх последних зашифрованных версий.")
                }
            }
            .navigationTitle("История копий")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .confirmationDialog(
                "Восстановить эту версию?",
                isPresented: $confirmsRestore,
                titleVisibility: .visible
            ) {
                Button("Продолжить") {
                    restoreSummary = pendingSummary
                    pendingSummary = nil
                }
                Button("Отмена", role: .cancel) { pendingSummary = nil }
            } message: {
                Text("После ввода кода восстановления текущее локальное хранилище будет заменено выбранной копией.")
            }
            .sheet(item: $restoreSummary) { summary in
                RestoreBackupView(allowsEmptyStart: false, targetSummary: summary)
            }
        }
    }
}

private struct RecoveryCodeView: View {
    let code: String
    let requiresConfirmation: Bool
    let onDone: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hasCopied = false
    @State private var confirmsSaved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "key.viewfinder")
                        .font(.system(size: 46, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 94, height: 94)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28))

                    VStack(spacing: 8) {
                        Text(requiresConfirmation ? "Сохраните код восстановления" : "Код восстановления")
                            .font(.system(.title2, weight: .bold))
                        Text("Он понадобится, если этот iPhone потеряется. Без кода восстановить файлы не сможет никто.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Text(code)
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                        .padding(18)
                        .frame(maxWidth: .infinity)
                        .cardStyle(cornerRadius: 18)

                    Button {
                        copyLocally(code)
                        hasCopied = true
                    } label: {
                        Label(hasCopied ? "Код скопирован" : "Скопировать код", systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .foregroundStyle(Theme.background)
                            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 16))
                    }

                    Text("Сохраните его в приложении «Пароли», менеджере паролей или распечатайте. Буфер обмена очистится через 5 минут и не синхронизируется с другими устройствами.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button(requiresConfirmation ? "Я сохранил код" : "Готово") {
                        if requiresConfirmation { confirmsSaved = true }
                        else { dismiss(); onDone() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(requiresConfirmation && !hasCopied)
                }
                .padding(24)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Восстановление")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(requiresConfirmation)
            .toolbar {
                if requiresConfirmation {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Отмена") {
                            dismiss()
                            onCancel()
                        }
                    }
                }
            }
            .confirmationDialog(
                "Код точно сохранён отдельно от этого iPhone?",
                isPresented: $confirmsSaved,
                titleVisibility: .visible
            ) {
                Button("Да, создать первую копию") {
                    dismiss()
                    onDone()
                }
                Button("Проверить ещё раз", role: .cancel) {}
            }
        }
    }

    private func copyLocally(_ value: String) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: value]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(5 * 60),
            ]
        )
    }
}
