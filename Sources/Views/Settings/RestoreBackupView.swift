import SwiftUI
import UniformTypeIdentifiers

// Восстановление из зашифрованной копии. Открывается из настроек: строкой
// «Восстановить из копии» (последняя версия) и из истории копий (выбранная).
// Раньше его показывал первый запуск, пока там придумывали код входа
struct RestoreBackupView: View {
    var targetSummary: BackupSummary?

    @Environment(BackupManager.self) private var backup
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var code = ""
    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var activeAlert: RestoreAlert?
    @State private var showsFolderPicker = false

    private enum RestoreAlert: String, Identifiable {
        case help
        case restored

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Spacer(minLength: 18)

                    Image("RecoveryFolder")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 156, height: 132)
                        .shadow(color: .black.opacity(0.08), radius: 20, y: 8)

                    VStack(spacing: 8) {
                        Text("Введите код восстановления — и LocalDrive вернёт ваши папки и файлы")
                            .font(.system(.title3, weight: .semibold))
                            .multilineTextAlignment(.center)
                        Text("Код проверяется только на этом iPhone")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        showsFolderPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: backup.hasBackupLocation ? "folder.fill.badge.checkmark" : "folder.badge.plus")
                                .font(.title3)
                                .foregroundStyle(Theme.ink)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(backup.hasBackupLocation ? "Папка с копиями" : "Выбрать папку с копией")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(backup.hasBackupLocation ? backup.backupLocationName : "Откройте её в iCloud Drive через «Файлы»")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(16)
                        .cardStyle(cornerRadius: 18)
                    }
                    .buttonStyle(.plain)

                    // Видно заранее, какая именно версия будет восстановлена
                    Text(plannedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Код восстановления")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        SecureField("XXXX-XXXX-XXXX-…", text: $code)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                            .padding(16)
                            .background(Theme.well, in: RoundedRectangle(cornerRadius: 14))

                        HStack {
                            Button {
                                if let value = UIPasteboard.general.string { code = value }
                            } label: {
                                Label("Вставить код", systemImage: "doc.on.clipboard")
                            }
                            Spacer()
                            Button("Где найти код?") { activeAlert = .help }
                        }
                        .font(.subheadline)
                    }
                    .padding(18)
                    .cardStyle()

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }

                    Button(action: restore) {
                        HStack {
                            if isRestoring { ProgressView().tint(Theme.background) }
                            Text(isRestoring ? "Восстанавливаем…" : "Найти резервную копию")
                        }
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 17))
                    }
                    .disabled(
                        !backup.hasBackupLocation ||
                        code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        isRestoring
                    )

                }
                .padding(24)
            }
            .background(
                ZStack {
                    Theme.background
                    RadialGradient(
                        colors: [Theme.color("purple").opacity(0.13), .clear],
                        center: .center,
                        startRadius: 30,
                        endRadius: 360
                    )
                }
                .ignoresSafeArea()
            )
            .navigationTitle("Восстановление файлов")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .accessibilityIdentifier("restore-cancel")
                }
            }
            .alert(item: $activeAlert) { alert in
                switch alert {
                case .help:
                    Alert(
                        title: Text("Где найти код?"),
                        message: Text("Это код, который LocalDrive показал при настройке резервной копии. Проверьте приложение «Пароли», менеджер паролей или распечатанную копию."),
                        dismissButton: .cancel(Text("Понятно"))
                    )
                case .restored:
                    Alert(
                        title: Text("Файлы восстановлены"),
                        message: Text("Папки и файлы из копии снова на этом iPhone."),
                        dismissButton: .default(Text("Готово")) { dismissAfterAlert() }
                    )
                }
            }
            .fileImporter(
                isPresented: $showsFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: handleFolderSelection
            )
            .task { await backup.refresh() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await backup.refresh() }
            }
        }
    }

    private var plannedSummary: BackupSummary? {
        targetSummary ?? backup.summaries.first
    }

    private var plannedDescription: String {
        guard let planned = plannedSummary else {
            return "Или положите копию в «Файлы» → «На iPhone» → LocalDrive"
        }
        let date = planned.createdAt.formatted(date: .abbreviated, time: .shortened)
        let size = ByteCountFormatter.string(fromByteCount: planned.encryptedBytes, countStyle: .file)
        let total = backup.summaries.count
        let suffix = (targetSummary == nil && total > 1) ? " · всего версий: \(total)" : ""
        return "Будет восстановлена копия от \(date) · \(size)\(suffix)"
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { throw BackupFolderError.notSelected }
            try backup.selectBackupFolder(url)
            errorMessage = nil
            Task {
                await backup.refresh()
                if backup.summaries.isEmpty {
                    errorMessage = backup.errorMessage
                        ?? "В этой папке нет резервных копий LocalDrive. Выберите папку «\(EncryptedBackupEngine.folderName)» или ту, в которой она лежит."
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore() {
        isRestoring = true
        errorMessage = nil
        Task {
            do {
                if let targetSummary {
                    _ = try await backup.restore(targetSummary, using: code)
                } else {
                    _ = try await backup.restoreLatest(using: code)
                }
                store.reload()
                activeAlert = .restored
            } catch {
                errorMessage = error.localizedDescription
            }
            isRestoring = false
        }
    }

    private func dismissAfterAlert() {
        activeAlert = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            dismiss()
        }
    }
}
