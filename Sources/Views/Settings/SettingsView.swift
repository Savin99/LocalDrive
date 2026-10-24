import SwiftUI

struct SettingsView: View {
    @Environment(LockManager.self) private var lock
    @Environment(SearchService.self) private var search
    @Environment(\.dismiss) private var dismiss
    @State private var isChangingPin = false

    var body: some View {
        NavigationStack {
            List {
                Section("Безопасность") {
                    NavigationLink {
                        BackupSettingsView()
                    } label: {
                        Label("Защита и восстановление", systemImage: "lock.shield.fill")
                    }

                    Button {
                        isChangingPin = true
                    } label: {
                        Label("Сменить код", systemImage: "key.fill")
                    }

                    Button {
                        dismiss()
                        lock.lock()
                    } label: {
                        Label("Заблокировать сейчас", systemImage: "lock.fill")
                    }
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
            .sheet(isPresented: $isChangingPin) {
                ChangePinView()
            }
        }
    }
}
