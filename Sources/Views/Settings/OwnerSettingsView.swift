import SwiftUI

/// «Это я»: чей «мой паспорт». Люди — из документов в папках, доступных для
/// поиска. Хранится только на этом iPhone
struct OwnerSettingsView: View {
    @Environment(SearchService.self) private var search
    @State private var people: [String] = []

    var body: some View {
        Form {
            Section {
                ForEach(people, id: \.self) { fullName in
                    Button {
                        search.owner.set(fullName: fullName)
                    } label: {
                        HStack {
                            Text(ChatRouter.shortName(fullName))
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            if search.owner.owns(fullName: fullName) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .accessibilityIdentifier("ownerPerson")
                }
                if people.isEmpty {
                    Text("Людей в документах пока нет: распознанные паспорта появятся здесь.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("«Мой паспорт» в чате — документы этого человека. Хранится только на этом iPhone; в облачный чат уходит лишь строка «Владелец: Савин И. А.».")
            }
            if search.owner.owner != nil {
                Section {
                    Button("Не указывать", role: .destructive) { search.owner.clear() }
                        .accessibilityIdentifier("ownerClear")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Это я")
        .navigationBarTitleDisplayMode(.inline)
        .task { people = await search.peopleNames() }
    }
}
