import SwiftUI

struct SettingsView: View {
    @Environment(HiddenFolders.self) private var hiddenFolders
    @Environment(SearchService.self) private var search
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FolderCardStyle.storageKey) private var folderStyle = FolderCardStyle.standard.rawValue
    @State private var showsRestore = false
    @State private var confirmsRestore = false
    #if DEBUG
    @State private var showsFolderStyles = false
    #endif

    var body: some View {
        NavigationStack {
            List {
                Section("Оформление") {
                    AppearancePicker()
                    // Образцы папок — на своём экране: в списке они вытесняли
                    // «Безопасность» и «Скрытые папки» с первого экрана
                    NavigationLink {
                        FolderStyleSettingsView()
                    } label: {
                        LabeledContent("Вид папок", value: (FolderCardStyle(rawValue: folderStyle) ?? .standard).title)
                    }
                    .accessibilityIdentifier("settingsFolderStyle")
                }
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

                // Чат и разбор документов — облако (решение владельца 19.11.2026):
                // ключ — один раз, дальше всё включено само
                Section {
                    NavigationLink {
                        CloudRecognitionSettingsView()
                    } label: {
                        LabeledContent {
                            Text(search.cloud.hasKey ? search.cloud.provider.title : "Нет ключа")
                        } label: {
                            Label("Облако", systemImage: "sparkles")
                        }
                    }
                    .accessibilityIdentifier("settingsCloud")
                } header: {
                    Text("Чат и документы")
                } footer: {
                    Text(search.cloud.hasKey
                        ? "Чат отвечает и разбирает документы через облако по вашему ключу."
                        : "Вставьте ключ — чат и распознавание документов включатся сами.")
                }
                Section {
                    NavigationLink {
                        ChatModelSettingsView()
                    } label: {
                        Label("Модель для чата на iPhone", systemImage: "cpu")
                    }
                    if DocumentReaderFeature.isEnabled {
                        NavigationLink {
                            DocumentModelSettingsView()
                        } label: {
                            Label("Модель для документов", systemImage: "doc.text.viewfinder")
                        }
                        .accessibilityIdentifier("settingsDocumentModel")
                    }
                } header: {
                    Text("Запасной режим без сети")
                } footer: {
                    Text("Нужны, только если облако недоступно. Без них чат отвечает правилами на iPhone.")
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
            #if DEBUG
            // Скриншоты: «-OpenSettings -OpenFolderStyles» — сразу «Вид папок»
            .navigationDestination(isPresented: $showsFolderStyles) { FolderStyleSettingsView() }
            .task { showsFolderStyles = ProcessInfo.processInfo.arguments.contains("-OpenFolderStyles") }
            #endif
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
