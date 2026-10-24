import SwiftUI

// Правка поля, которое OCR прочитал неверно. Сохранённое значение помечается
// как проверенное, и следующая переиндексация его не трогает
struct FieldEditSheet: View {
    let field: DocumentField
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @State private var isSaving = false
    @FocusState private var isFocused: Bool

    init(field: DocumentField, onSave: @escaping (String) async -> Void) {
        self.field = field
        self.onSave = onSave
        _value = State(initialValue: field.value)
    }

    private var trimmed: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmed.isEmpty && trimmed != field.value && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(FieldKey.title(field.key), text: $value, axis: .vertical)
                        .lineLimit(1...6)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                        .accessibilityIdentifier("fieldEditInput")
                } footer: {
                    Text("Исправленное значение больше не перезаписывается распознаванием")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(FieldKey.title(field.key))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let newValue = trimmed
        Task {
            await onSave(newValue)
            dismiss()
        }
    }
}
