import SwiftUI

// MARK: - Кнопка

struct GenUIButtonComponent: GenUIComponent {
    static let type = "button"
    static let guide = "Кнопка с действием из белого списка: спросить, открыть документ, отправить форму, перестроить блок"
    static let properties: [GenUISchemaProperty] = [
        .required("label", .string()),
        .optional("style", .choice(["primary", "secondary"])),
        .required("action", .action),
    ]

    let label: GenUITemplate
    let style: String
    let action: GenUIAction

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let label = parser.template(props, "label", required: true, maxLength: 60) else { return nil }
        guard let action = parser.action(props["action"], field: "action") else {
            parser.issue("кнопка без разрешённого действия не показывается")
            return nil
        }
        self.label = label
        self.action = action
        style = parser.choice(props, "style", ["primary", "secondary"], default: "secondary")
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        AnyView(GenUIActionButton(label: context.text(label), primary: style == "primary", action: action, blockID: block.id, context: context))
    }
}

/// Кнопка действия: пока действие идёт — индикатор и недоступна, итог — под ней
struct GenUIActionButton: View {
    let label: String
    let primary: Bool
    let action: GenUIAction
    let blockID: String
    let context: GenUIRenderContext

    var body: some View {
        let running = context.isRunning(blockID)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                context.perform(action, block: blockID)
            } label: {
                HStack(spacing: 8) {
                    if running { ProgressView().controlSize(.small).tint(primary ? Theme.background : Theme.ink) }
                    Text(label).font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .modifier(GenUICapsule(primary: primary))
            .disabled(running)
            .opacity(running ? 0.7 : 1)
            .accessibilityIdentifier("genui-\(blockID)")
            if let outcome = context.outcome(blockID) {
                switch outcome {
                case .done(let message?):
                    Label(message, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("genui-\(blockID)-outcome")
                case .done(nil):
                    EmptyView()
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.red)
                        .accessibilityIdentifier("genui-\(blockID)-outcome")
                }
            }
        }
    }
}

private struct GenUICapsule: ViewModifier {
    let primary: Bool

    func body(content: Content) -> some View {
        if primary {
            content.primaryCapsule()
        } else {
            content.secondaryCapsule()
        }
    }
}

// MARK: - Переключатели

struct GenUIToggleComponent: GenUIComponent {
    static let type = "toggle"
    static let guide = "Включить или выключить условие расчёта или фильтра"
    static let properties: [GenUISchemaProperty] = [
        .required("label", .string()),
        .required("bind", .variable),
    ]

    let label: GenUITemplate
    let bind: String

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let label = parser.template(props, "label", required: true),
              let bind = parser.bind(props, kind: .bool, default: .bool(false)) else { return nil }
        self.label = label
        self.bind = bind
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        let state = context.state
        return AnyView(
            Toggle(context.text(label), isOn: Binding(
                get: { state.value(bind)?.truthy ?? false },
                set: { state.set(bind, .bool($0)) }
            ))
            .font(.subheadline)
            .tint(Theme.accent)
            .accessibilityIdentifier("genui-\(block.id)")
        )
    }
}

struct GenUICheckboxComponent: GenUIComponent {
    static let type = "checkbox"
    static let guide = "Галочка в форме: согласие, пункт списка дел"
    static let properties: [GenUISchemaProperty] = [
        .required("label", .string()),
        .required("bind", .variable),
    ]

    let label: GenUITemplate
    let bind: String

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let label = parser.template(props, "label", required: true),
              let bind = parser.bind(props, kind: .bool, default: .bool(false)) else { return nil }
        self.label = label
        self.bind = bind
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        AnyView(GenUICheckboxView(label: context.text(label), bind: bind, state: context.state, id: block.id))
    }
}

private struct GenUICheckboxView: View {
    let label: String
    let bind: String
    let state: GenUIState
    let id: String

    var body: some View {
        let isOn = state.value(bind)?.truthy ?? false
        Button {
            state.set(bind, .bool(!isOn))
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(isOn ? Theme.accent : Color.secondary)
                Text(label).font(.subheadline).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("genui-\(id)")
    }
}

// MARK: - Ползунок

struct GenUISliderComponent: GenUIComponent {
    static let type = "slider"
    static let guide = "Числовой параметр расчёта: сумма, ставка, срок. Зависимые показатели пересчитываются сразу"
    static let properties: [GenUISchemaProperty] = [
        .required("label", .string()),
        .required("bind", .variable),
        .required("min", .number()),
        .required("max", .number()),
        .optional("step", .number()),
        .optional("format", .format),
    ]

    let label: GenUITemplate
    let bind: String
    let range: ClosedRange<Double>
    let step: Double?
    let format: GenUIValueFormat?

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let label = parser.template(props, "label", required: true),
              let low = parser.number(props, "min", required: true),
              let high = parser.number(props, "max", required: true) else { return nil }
        guard low < high else {
            parser.issue("min должен быть меньше max")
            return nil
        }
        let step = parser.number(props, "step")
        if let step, step <= 0 || step > high - low {
            parser.issue("шаг вне диапазона, без шага", field: "step")
            self.step = nil
        } else {
            self.step = step
        }
        guard let bind = parser.bind(props, kind: .number, default: .number(low)) else { return nil }
        self.label = label
        self.bind = bind
        range = low...high
        format = props["format"]?.string.flatMap(GenUIValueFormat.init(rawValue:))
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        AnyView(GenUISliderView(component: self, context: context, id: block.id))
    }
}

private struct GenUISliderView: View {
    let component: GenUISliderComponent
    let context: GenUIRenderContext
    let id: String

    var body: some View {
        let state = context.state
        let bind = component.bind
        let range = component.range
        let current = min(max(state.value(bind)?.number ?? range.lowerBound, range.lowerBound), range.upperBound)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(context.text(component.label)).font(.subheadline).foregroundStyle(Theme.ink)
                Spacer()
                Text(GenUIFormat.formatted(.number(current), as: component.format))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
            let binding = Binding<Double>(get: { current }, set: { state.set(bind, .number($0)) })
            Group {
                if let step = component.step {
                    Slider(value: binding, in: range, step: step)
                } else {
                    Slider(value: binding, in: range)
                }
            }
            .tint(Theme.accent)
            .accessibilityLabel(context.text(component.label))
            .accessibilityValue(GenUIFormat.formatted(.number(current), as: component.format))
            .accessibilityIdentifier("genui-\(id)")
        }
    }
}

// MARK: - Поле ввода

struct GenUITextFieldComponent: GenUIComponent {
    static let type = "text_field"
    static let guide = "Ввод текста или числа: имя, сумма, комментарий к форме"
    static let properties: [GenUISchemaProperty] = [
        .required("label", .string()),
        .required("bind", .variable),
        .optional("placeholder", .string()),
        .optional("keyboard", .choice(["text", "number", "decimal"])),
        .optional("max_length", .integer(minimum: 1, maximum: 2000)),
    ]

    let label: GenUITemplate
    let bind: String
    let placeholder: String?
    let keyboard: String
    let maxLength: Int

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let label = parser.template(props, "label", required: true) else { return nil }
        let keyboard = parser.choice(props, "keyboard", ["text", "number", "decimal"], default: "text")
        let numeric = keyboard != "text"
        guard let bind = parser.bind(props, kind: numeric ? .number : .string, default: numeric ? .number(0) : .string("")) else { return nil }
        self.label = label
        self.bind = bind
        self.keyboard = keyboard
        placeholder = parser.string(props, "placeholder")
        maxLength = parser.integer(props, "max_length", in: 1...2000) ?? 500
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        AnyView(GenUITextFieldView(component: self, state: context.state, label: context.text(label), id: block.id))
    }
}

private struct GenUITextFieldView: View {
    let component: GenUITextFieldComponent
    let state: GenUIState
    let label: String
    let id: String

    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            TextField(component.placeholder ?? "", text: $text)
                .keyboardType(component.keyboard == "number" ? .numberPad : (component.keyboard == "decimal" ? .decimalPad : .default))
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(label)
                .accessibilityIdentifier("genui-\(id)")
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = Self.display(state.value(component.bind), numeric: component.keyboard != "text")
        }
        // Значение поменяли извне — «Сбросить» или кнопка с set: поле следует
        .onChange(of: state.value(component.bind)) { _, new in
            let numeric = component.keyboard != "text"
            let parsed = numeric ? Double(text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")) : nil
            if numeric, let parsed, let number = new?.number, parsed == number { return }
            if !numeric, new?.string == text { return }
            text = Self.display(new, numeric: numeric)
        }
        .onChange(of: text) { _, new in
            let limited = String(new.prefix(component.maxLength))
            if limited != new { text = limited }
            if component.keyboard == "text" {
                state.set(component.bind, .string(limited))
            } else if let number = Double(limited.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")) {
                state.set(component.bind, .number(number))
            } else if limited.isEmpty {
                state.set(component.bind, .number(0))
            }
        }
    }

    static func display(_ value: GenUIScalar?, numeric: Bool) -> String {
        guard let value else { return "" }
        if numeric, let number = value.number {
            return number == number.rounded() ? String(Int(number)) : String(number).replacingOccurrences(of: ".", with: ",")
        }
        return value.string ?? GenUIFormat.display(value)
    }
}

// MARK: - Дата и выбор

struct GenUIDatePickerComponent: GenUIComponent {
    static let type = "date_picker"
    static let guide = "Выбор даты: начало периода, дата рождения для расчёта срока"
    static let properties: [GenUISchemaProperty] = [
        .required("label", .string()),
        .required("bind", .variable),
        .optional("min", .string(format: "date")),
        .optional("max", .string(format: "date")),
    ]

    let label: GenUITemplate
    let bind: String
    let low: GenUIDay?
    let high: GenUIDay?

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let label = parser.template(props, "label", required: true),
              let bind = parser.bind(props, kind: .date, default: .date(GenUIDay(date: Date()))) else { return nil }
        self.label = label
        self.bind = bind
        low = props["min"]?.string.flatMap(GenUIDay.init(iso:))
        high = props["max"]?.string.flatMap(GenUIDay.init(iso:))
        if let low, let high, high < low {
            parser.issue("max раньше min")
            return nil
        }
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        let state = context.state
        let today = GenUIDay(date: Date())
        let current = state.value(bind)?.day ?? today
        let binding = Binding<Date>(
            get: { current.localDate() },
            set: { state.set(bind, .date(GenUIDay(date: $0))) }
        )
        let lower = (low ?? GenUIDay(year: 1900, month: 1, day: 1)!).localDate()
        let upper = (high ?? GenUIDay(year: 2100, month: 12, day: 31)!).localDate()
        return AnyView(
            DatePicker(context.text(label), selection: binding, in: lower...upper, displayedComponents: .date)
                .font(.subheadline)
                .tint(Theme.accent)
                .environment(\.locale, RussianFormat.locale)
                .accessibilityIdentifier("genui-\(block.id)")
        )
    }
}

struct GenUIPickerComponent: GenUIComponent {
    static let type = "picker"
    static let guide = "Выбор одного варианта: период, категория, тип документа. segmented — до четырёх коротких"
    static let properties: [GenUISchemaProperty] = [
        .required("label", .string()),
        .required("bind", .variable),
        .required("options", .array(.object([
            .required("value", .cell),
            .required("label", .string()),
        ]), minItems: 1, maxItems: GenUILimits.maxOptions)),
        .optional("style", .choice(["menu", "segmented"])),
    ]

    struct Option: Hashable, Sendable {
        let value: GenUIScalar
        let label: String
    }

    let label: GenUITemplate
    let bind: String
    let options: [Option]
    let style: String

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let label = parser.template(props, "label", required: true) else { return nil }
        var options: [Option] = []
        for json in (props["options"]?.array ?? []).prefix(GenUILimits.maxOptions) {
            guard let object = json.object, let value = object["value"].flatMap(GenUIScalar.init(json:)), !value.isNull,
                  let title = object["label"]?.string else { continue }
            if options.contains(where: { $0.value == value }) { continue }
            options.append(Option(value: value, label: String(title.prefix(GenUILimits.maxLabelLength))))
        }
        guard let first = options.first else {
            parser.issue("у выбора нет вариантов", field: "options")
            return nil
        }
        // Тип переменной — по первому варианту; разнотипные варианты отбрасываются
        let kind = first.value.kind ?? .string
        let typed = options.filter { $0.value.kind == kind }
        if typed.count != options.count { parser.issue("варианты разных типов, лишние отброшены", field: "options") }
        guard let bind = parser.bind(props, kind: kind, default: first.value) else { return nil }
        self.label = label
        self.bind = bind
        self.options = typed
        style = parser.choice(props, "style", ["menu", "segmented"], default: typed.count <= 4 ? "segmented" : "menu")
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        let state = context.state
        let options = options
        let bind = bind
        let selection = Binding<Int>(
            get: { options.firstIndex(where: { GenUIEvaluator.equal($0.value, state.value(bind) ?? .null) }) ?? 0 },
            set: { index in if options.indices.contains(index) { state.set(bind, options[index].value) } }
        )
        let title = context.text(label)
        if style == "segmented" {
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.footnote).foregroundStyle(.secondary)
                    Picker(title, selection: selection) {
                        ForEach(options.indices, id: \.self) { index in Text(options[index].label).tag(index) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("genui-\(block.id)")
                }
            )
        }
        return AnyView(
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.ink)
                Spacer()
                Picker(title, selection: selection) {
                    ForEach(options.indices, id: \.self) { index in Text(options[index].label).tag(index) }
                }
                .pickerStyle(.menu)
                .tint(Theme.ink)
                .accessibilityIdentifier("genui-\(block.id)")
            }
        )
    }
}

// MARK: - Форма

struct GenUIFormComponent: GenUIComponent {
    static let type = "form"
    static let guide = "Форма: поля ввода и кнопка; без action отправляет значения своих полей модели — для следующего ответа"
    static let properties: [GenUISchemaProperty] = [
        .required("blocks", .blocks),
        .required("submit", .object([
            .required("label", .string()),
            .optional("action", .action),
        ])),
    ]

    let blocks: [GenUIBlock]
    let submitLabel: GenUITemplate
    let action: GenUIAction

    var children: [GenUIBlock] { blocks }

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        let blocks = parser.blocks(props)
        guard !blocks.isEmpty else {
            parser.issue("пустая форма")
            return nil
        }
        let submit = GenUIProps(props["submit"]?.object ?? [:])
        let label = parser.template(submit, "label") ?? GenUITemplate(text: "Отправить")
        // Без действия форма отправляет модели свои поля
        let fields = Set(blocks.flatMap(\.flattened).flatMap { $0.binds.keys }).sorted()
        let action = parser.action(submit["action"], field: "submit.action") ?? .submit(include: fields.isEmpty ? nil : fields, message: nil)
        self.blocks = blocks
        submitLabel = label
        self.action = action
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 14) {
                GenUIBlockList(blocks: blocks, context: context)
                GenUIActionButton(label: context.text(submitLabel), primary: true, action: action, blockID: block.id, context: context)
            }
            .genUICard()
        )
    }
}
