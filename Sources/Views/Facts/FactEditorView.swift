import SwiftUI

// Редактор карточки: название, поля (вид, подпись, значение, значок),
// цвет и значок карточки. Хранилище он не трогает: готовую карточку отдаёт
// в `onSave`, а добавить её или заменить решает тот, кто открыл редактор.
// card == nil — новая карточка; карточка, которой ещё нет в хранилище, —
// черновик от чата: всё заполнено, id сохраняется
struct FactEditorView: View {
    @Environment(\.dismiss) private var dismiss
    /// Только чтобы назвать экран «Изменить» или «Новая»: редактор работает и без хранилища
    @Environment(FactStore.self) private var store: FactStore?

    private let original: FactCard?
    private let onSave: (FactCard) -> Void

    @State private var title: String
    @State private var symbol: String
    @State private var color: String
    @State private var items: [FactItem]
    /// Значок выбран руками — больше не подбираем его по названию
    @State private var symbolChosen: Bool
    /// Поле, для которого открыт выбор значка
    @State private var symbolTarget: SymbolTarget?

    private struct SymbolTarget: Identifiable {
        let id: UUID
    }

    init(card: FactCard?, onSave: @escaping (FactCard) -> Void) {
        original = card
        self.onSave = onSave
        _title = State(initialValue: card?.title ?? "")
        _symbol = State(initialValue: card?.symbol ?? FactCard.defaultSymbol)
        _color = State(initialValue: card?.color ?? FactCard.defaultColor)
        let items = card?.items ?? []
        _items = State(initialValue: items.isEmpty ? [FactItem(kind: .text, label: "", value: "")] : items)
        _symbolChosen = State(initialValue: card != nil)
    }

    private var accent: Color { Theme.color(color) }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filledItems: [FactItem] {
        items.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var canSave: Bool { !trimmedTitle.isEmpty && !filledItems.isEmpty }

    private var validationHint: String? {
        switch (trimmedTitle.isEmpty, filledItems.isEmpty) {
        case (true, true): "Нужны название и хотя бы одно заполненное поле"
        case (true, false): "Добавьте название карточки"
        case (false, true): "Заполните хотя бы одно поле"
        case (false, false): nil
        }
    }

    private var isExisting: Bool {
        guard let original else { return false }
        return store?.card(id: original.id) != nil
    }

    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        preview

                        section("НАЗВАНИЕ") {
                            TextField("Например, Дом Камилы", text: $title)
                                .font(.body)
                                .padding(14)
                                .cardStyle(cornerRadius: 14)
                                .accessibilityIdentifier("factTitleField")
                        }

                        section("ПОЛЯ") {
                            VStack(spacing: 12) {
                                ForEach($items) { $item in
                                    itemEditor($item)
                                }
                                addItemMenu
                            }
                        }

                        section("ЦВЕТ") { colorPicker }
                        section("ЗНАЧОК") { iconPicker }

                        if let validationHint {
                            Text(validationHint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("factValidation")
                        }
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(isExisting ? "Изменить карточку" : "Новая карточка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                        .accessibilityIdentifier("factSave")
                }
            }
            .onChange(of: title) { _, newTitle in
                // «Дом Камилы» сам получает домик, «Wi-Fi на даче» — значок сети
                guard !symbolChosen else { return }
                symbol = FactSymbols.labelSymbol(newTitle) ?? FactCard.defaultSymbol
            }
            .sheet(item: $symbolTarget) { target in
                if let index = items.firstIndex(where: { $0.id == target.id }) {
                    FactSymbolPicker(
                        selection: items[index].symbol,
                        automatic: FactSymbols.defaultSymbol(kind: items[index].kind, label: items[index].label),
                        accent: accent
                    ) { picked in
                        items[index].symbol = picked
                    }
                }
            }
        }
    }

    // MARK: - Образец

    private var preview: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.15))
                    .frame(width: 72, height: 72)
                Image(systemName: FactSymbols.isAvailable(symbol) ? symbol : FactCard.defaultSymbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(accent)
            }
            Text(trimmedTitle.isEmpty ? "Без названия" : trimmedTitle)
                .font(.headline)
                .foregroundStyle(trimmedTitle.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.center)
            Text(pluralize(filledItems.count, "поле", "поля", "полей"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .animation(.snappy(duration: 0.2), value: symbol)
        .animation(.snappy(duration: 0.2), value: color)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Поле

    private func itemEditor(_ item: Binding<FactItem>) -> some View {
        let current = item.wrappedValue
        let index = items.firstIndex(where: { $0.id == current.id }) ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    symbolTarget = SymbolTarget(id: current.id)
                } label: {
                    Image(systemName: FactSymbols.symbol(for: current))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 34, height: 34)
                        .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Значок поля")

                kindMenu(for: current)

                Spacer(minLength: 0)

                Menu {
                    if index > 0 {
                        Button {
                            move(current.id, by: -1)
                        } label: {
                            Label("Выше", systemImage: "arrow.up")
                        }
                    }
                    if index < items.count - 1 {
                        Button {
                            move(current.id, by: 1)
                        } label: {
                            Label("Ниже", systemImage: "arrow.down")
                        }
                    }
                    Button(role: .destructive) {
                        remove(current.id)
                    } label: {
                        Label("Удалить поле", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 34, height: 34)
                        .background(Theme.surface, in: Circle())
                }
                .accessibilityLabel("Действия с полем")
            }

            TextField("Подпись, например «Домофон»", text: item.label)
                .font(.subheadline.weight(.medium))
                .accessibilityIdentifier("factLabelField")

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            TextField(Self.placeholder(for: current.kind), text: item.value, axis: .vertical)
                .font(.body)
                .lineLimit(1...5)
                .keyboardType(Self.keyboard(for: current.kind))
                .textInputAutocapitalization(Self.capitalization(for: current.kind))
                .autocorrectionDisabled(current.kind != .text && current.kind != .note && current.kind != .address)
                .accessibilityIdentifier("factValueField")
        }
        .padding(14)
        .cardStyle(cornerRadius: 14)
    }

    private func kindMenu(for item: FactItem) -> some View {
        Menu {
            ForEach(FactItem.Kind.allCases, id: \.self) { kind in
                Button {
                    setKind(kind, for: item.id)
                } label: {
                    Label(kind.title, systemImage: FactSymbols.kindSymbol(kind))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(item.kind.title)
                    .font(.footnote.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Theme.surface, in: Capsule())
        }
        .accessibilityLabel("Вид поля: \(item.kind.title)")
    }

    /// Заготовки полей: подпись и вид сразу правильные
    private static let presets: [(kind: FactItem.Kind, label: String)] = [
        (.address, "Адрес"),
        (.code, "Домофон"),
        (.number, "Подъезд"),
        (.number, "Этаж"),
        (.number, "Квартира"),
        (.phone, "Телефон"),
        (.wifi, "Wi-Fi"),
        (.link, "Ссылка"),
        (.email, "E-mail"),
        (.date, "Дата"),
        (.note, "Заметка"),
        (.text, ""),
    ]

    private var addItemMenu: some View {
        Menu {
            ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, preset in
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        items.append(FactItem(kind: preset.kind, label: preset.label, value: ""))
                    }
                } label: {
                    Label(
                        preset.label.isEmpty ? "Другое" : preset.label,
                        systemImage: FactSymbols.defaultSymbol(kind: preset.kind, label: preset.label)
                    )
                }
            }
        } label: {
            Label("Добавить поле", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .frame(height: 42)
                .secondaryCapsule()
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("factAddItem")
    }

    // MARK: - Цвет и значок карточки

    private var colorPicker: some View {
        HStack(spacing: 12) {
            ForEach(Theme.palette, id: \.name) { item in
                Button {
                    color = item.name
                } label: {
                    Circle()
                        .fill(item.color)
                        .frame(width: 30, height: 30)
                        .overlay {
                            if color == item.name {
                                Circle()
                                    .stroke(item.color.opacity(0.4), lineWidth: 3)
                                    .padding(-4)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.name)
                .accessibilityAddTraits(color == item.name ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .cardStyle(cornerRadius: 14)
    }

    private var iconPicker: some View {
        LazyVGrid(columns: iconColumns, spacing: 10) {
            ForEach(FactSymbols.cardChoices, id: \.self) { name in
                Button {
                    symbol = name
                    symbolChosen = true
                } label: {
                    Image(systemName: name)
                        .font(.system(size: 18))
                        .foregroundStyle(symbol == name ? .white : .primary.opacity(0.7))
                        .frame(width: 44, height: 44)
                        .background(
                            symbol == name ? accent : Theme.well,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityAddTraits(symbol == name ? .isSelected : [])
            }
        }
        .padding(14)
        .cardStyle(cornerRadius: 14)
    }

    // MARK: - Действия

    private func setKind(_ kind: FactItem.Kind, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[index]
        // Подпись по умолчанию меняется вместе с видом, своя — остаётся
        if old.label.trimmingCharacters(in: .whitespaces).isEmpty || old.label == old.kind.title {
            items[index].label = kind == .text ? "" : kind.title
        }
        items[index].kind = kind
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        withAnimation(.snappy(duration: 0.2)) { items.swapAt(index, target) }
    }

    private func remove(_ id: UUID) {
        withAnimation(.snappy(duration: 0.2)) {
            items.removeAll { $0.id == id }
            if items.isEmpty { items = [FactItem(kind: .text, label: "", value: "")] }
        }
    }

    private func save() {
        guard canSave else { return }
        let cleaned = filledItems.map { item in
            var item = item
            item.label = item.displayLabel
            item.value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let chosen = item.symbol, !FactSymbols.isAvailable(chosen) { item.symbol = nil }
            return item
        }
        var card = original ?? FactCard(title: trimmedTitle, items: [])
        card.title = trimmedTitle
        card.symbol = FactSymbols.isAvailable(symbol) ? symbol : FactCard.defaultSymbol
        card.color = Theme.palette.contains(where: { $0.name == color }) ? color : FactCard.defaultColor
        card.items = cleaned
        card.updatedAt = Date()
        onSave(card)
        dismiss()
    }

    // MARK: - Клавиатура по виду поля

    private static func placeholder(for kind: FactItem.Kind) -> String {
        switch kind {
        case .address: "Москва, Тверская 5"
        case .link: "ya.ru или https://…"
        case .phone: "+7 900 000-00-00"
        case .email: "name@example.com"
        case .code: "45К1234"
        case .text: "Значение"
        case .date: "12 октября"
        case .number: "3"
        case .wifi: "Пароль сети"
        case .note: "Текст заметки"
        }
    }

    private static func keyboard(for kind: FactItem.Kind) -> UIKeyboardType {
        switch kind {
        case .phone: .phonePad
        case .email: .emailAddress
        case .link: .URL
        case .number: .numbersAndPunctuation
        default: .default
        }
    }

    private static func capitalization(for kind: FactItem.Kind) -> TextInputAutocapitalization {
        switch kind {
        case .link, .email, .wifi, .code: .never
        default: .sentences
        }
    }
}

/// Выбор значка поля: «Автоматически» — по подписи и виду
struct FactSymbolPicker: View {
    let selection: String?
    let automatic: String
    let accent: Color
    let onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        onPick(nil)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            tile(automatic, selected: selection == nil)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Автоматически")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                Text("По подписи и виду поля")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .cardStyle(cornerRadius: 14)
                    }
                    .buttonStyle(.plain)

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(FactSymbols.itemChoices, id: \.self) { name in
                            Button {
                                onPick(name)
                                dismiss()
                            } label: {
                                tile(name, selected: selection == name)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(name)
                        }
                    }
                    .padding(14)
                    .cardStyle(cornerRadius: 14)
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Значок поля")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func tile(_ name: String, selected: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 18))
            .foregroundStyle(selected ? .white : .primary.opacity(0.7))
            .frame(width: 44, height: 44)
            .background(
                selected ? accent : Theme.well,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }
}
