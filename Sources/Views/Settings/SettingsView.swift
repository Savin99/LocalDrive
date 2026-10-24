import SwiftUI

struct SettingsView: View {
    @Environment(HiddenFolders.self) private var hiddenFolders
    @Environment(SearchService.self) private var search
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showsRestore = false
    @State private var confirmsRestore = false

    var body: some View {
        NavigationStack {
            List {
                Section("Безопасность") {
                    NavigationLink {
                        BackupSettingsView()
                    } label: {
                        Label("Защита и восстановление", systemImage: "lock.shield.fill")
                    }

                    // Раньше восстановление предлагал первый запуск, пока
                    // придумывали код входа. Кода больше нет — вход здесь
                    Button {
                        if store.folders.isEmpty {
                            showsRestore = true
                        } else {
                            confirmsRestore = true
                        }
                    } label: {
                        Label("Восстановить из копии", systemImage: "icloud.and.arrow.down")
                    }
                    .accessibilityIdentifier("restore-files")
                }

                Section {
                    NavigationLink {
                        HiddenSymbolSettingsView()
                    } label: {
                        LabeledContent {
                            Text(hiddenFolders.hasCustomSymbol ? "Свой" : "Встроенный")
                        } label: {
                            Label("Знак", systemImage: "scribble")
                        }
                    }
                    .accessibilityIdentifier("settingsHiddenSymbol")

                    NavigationLink {
                        HiddenPasswordRevealView { dismiss() }
                    } label: {
                        Label("Открыть по паролю", systemImage: "key.fill")
                    }
                    .disabled(!hiddenFolders.hasPassword)
                    .accessibilityIdentifier("settingsHiddenPassword")
                } header: {
                    Text("Скрытые папки")
                } footer: {
                    Text(hiddenFolders.hasPassword
                        ? "Знак рисуют одним движением в любом месте «Файлов». Если не получается — откройте по паролю."
                        : "Знак рисуют одним движением в любом месте «Файлов». Пароль появится вместе со своим знаком.")
                }

                Section(DocumentReaderFeature.isEnabled ? "Модели на iPhone" : "Чат") {
                    NavigationLink {
                        ChatModelSettingsView()
                    } label: {
                        Label("Модель для чата", systemImage: "cpu")
                    }
                    if DocumentReaderFeature.isEnabled {
                        NavigationLink {
                            DocumentModelSettingsView()
                        } label: {
                            Label("Модель для документов", systemImage: "doc.text.viewfinder")
                        }
                        .accessibilityIdentifier("settingsDocumentModel")
                    }
                    NavigationLink {
                        CloudRecognitionSettingsView()
                    } label: {
                        Label("Облачное распознавание", systemImage: "cloud")
                    }
                    .accessibilityIdentifier("settingsCloud")
                }

                Section {
                    NavigationLink {
                        OwnerSettingsView()
                    } label: {
                        Label("Это я", systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier("settingsOwner")
                } footer: {
                    Text("Чей «мой паспорт» в чате.")
                }

                Section {
                    LabeledContent("Хранение", value: "Локально на iPhone")
                    LabeledContent("Версия", value: "1.0")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LocalDrive не отправляет файлы на серверы разработчика.")
                        if search.cloud.isEnabled, search.cloud.hasKey {
                            Text("Фото документов отправляются в \(search.cloud.provider.title) по вашему ключу.")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(isPresented: $showsRestore) {
                RestoreBackupView()
            }
            .confirmationDialog(
                "Заменить файлы копией?",
                isPresented: $confirmsRestore,
                titleVisibility: .visible
            ) {
                Button("Продолжить") { showsRestore = true }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("После ввода кода восстановления папки и файлы на этом iPhone будут заменены копией.")
            }
        }
    }
}
