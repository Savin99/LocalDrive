import SwiftUI

/// Экран «Диагностика и логи» в Настройках (`app-logs` v1).
struct TelemetryDiagnosticsView: View {
    @Environment(AppTelemetry.self) private var telemetry

    @State private var showingBugPrompt = false
    @State private var bugNote = ""
    @State private var alertTitle: String?
    @State private var alertMessage = ""

    var body: some View {
        List {
            Section {
                Toggle("Отправлять логи каждые 5 ч", isOn: Binding(
                    get: { telemetry.isEnabled },
                    set: { telemetry.isEnabled = $0 }
                ))
                LabeledContent("Приёмник", value: telemetry.isConfigured ? "Подключён" : "Не настроен")
                LabeledContent("В очереди", value: "\(telemetry.pendingCount)")
                LabeledContent("Последняя отправка", value: lastSentValue)
            } header: {
                Text("Автоматическая отправка")
            } footer: {
                Text(statusFootnote)
            }

            Section {
                Button {
                    sendNow()
                } label: {
                    Label(telemetry.isSending ? "Отправляем…" : "Отправить логи сейчас", systemImage: "paperplane")
                }
                .disabled(telemetry.isSending || !telemetry.isConfigured)
                .accessibilityIdentifier("telemetrySendNow")

                Button {
                    bugNote = ""
                    showingBugPrompt = true
                } label: {
                    Label("Заметил баг", systemImage: "ant")
                }
                .disabled(telemetry.isSending || !telemetry.isConfigured)
                .accessibilityIdentifier("telemetryReportBug")
            } header: {
                Text("Действия")
            } footer: {
                Text("Отправляются только обезличенные технические события: имена вызванных инструментов, тайминги, ошибки сети и краши MetricKit. Содержимое документов, тексты переписки, номера и API-ключи никогда не пишутся в логи.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Диагностика и логи")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { telemetry.recordScreen("Diagnostics") }
        .alert("Заметил баг", isPresented: $showingBugPrompt) {
            TextField("Что пошло не так (необязательно)", text: $bugNote)
            Button("Отправить") { submitUserBug() }
            Button("Отмена", role: .cancel) { bugNote = "" }
        } message: {
            Text("Вместе с заметкой улетят последние технические события и ошибки — их можно будет сразу разобрать.")
        }
        .alert(alertTitle ?? "", isPresented: Binding(get: { alertTitle != nil }, set: { if !$0 { alertTitle = nil } })) {
            Button("Хорошо", role: .cancel) { alertTitle = nil }
        } message: {
            Text(alertMessage)
        }
    }

    private var lastSentValue: String {
        guard let date = telemetry.lastSentAt else { return "Ещё не было" }
        return Self.dateFormatter.string(from: date)
    }

    private var statusFootnote: String {
        let base = "Логи уходят по защищённому HTTPS на личный приёмник раз в 5 часов и досрочно при ошибках."
        guard let failure = telemetry.lastFailure else { return base }
        return base + "\n\nПоследняя ошибка отправки: \(failure)"
    }

    private func sendNow() {
        Task {
            do {
                let count = try await telemetry.flushNow(trigger: .manual, bypassEnableCheck: true)
                alertTitle = "Логи отправлены"
                alertMessage = "Передано событий: \(count)."
            } catch {
                alertTitle = "Не удалось отправить"
                alertMessage = error.localizedDescription
            }
        }
    }

    private func submitUserBug() {
        let note = bugNote
        bugNote = ""
        Task {
            do {
                let count = try await telemetry.reportUserIssue(note: note)
                alertTitle = "Отметка отправлена"
                alertMessage = "Передано событий: \(count)."
            } catch {
                alertTitle = "Не удалось отправить"
                alertMessage = error.localizedDescription
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
