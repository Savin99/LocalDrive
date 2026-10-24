import SwiftUI

// MARK: - Текст и заголовок

struct GenUITextComponent: GenUIComponent {
    static let type = "text"
    static let guide = "Абзац текста; caption — мелкая подпись, callout — выделенный абзац"
    static let properties: [GenUISchemaProperty] = [
        .required("text", .string(description: "Текст; можно {{ выражение }} и **жирный**")),
        .optional("style", .choice(["body", "caption", "callout"])),
    ]

    let text: GenUITemplate
    let style: String

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let text = parser.template(props, "text", required: true, maxLength: GenUILimits.maxTextLength) else { return nil }
        self.text = text
        style = parser.choice(props, "style", ["body", "caption", "callout"], default: "body")
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        AnyView(GenUITextView(component: self, context: context, id: block.id))
    }
}

private struct GenUITextView: View {
    let component: GenUITextComponent
    let context: GenUIRenderContext
    let id: String

    var body: some View {
        GenUIRichText(text: context.text(component.text))
            .font(font)
            .foregroundStyle(component.style == "caption" ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.ink))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("genui-\(id)")
    }

    private var font: Font {
        switch component.style {
        case "caption": .footnote
        case "callout": .callout.weight(.medium)
        default: .body
        }
    }
}

struct GenUIHeadingComponent: GenUIComponent {
    static let type = "heading"
    static let guide = "Заголовок раздела ответа"
    static let properties: [GenUISchemaProperty] = [
        .required("text", .string()),
        .optional("level", .integer(minimum: 1, maximum: 3)),
    ]

    let text: GenUITemplate
    let level: Int

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let text = parser.template(props, "text", required: true) else { return nil }
        self.text = text
        level = parser.integer(props, "level", in: 1...3) ?? 2
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        let font: Font = switch level {
        case 1: .title3.weight(.bold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
        return AnyView(
            Text(context.text(text))
                .font(font)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("genui-\(block.id)")
        )
    }
}

// MARK: - Показатель

struct GenUIMetricComponent: GenUIComponent {
    static let type = "metric"
    static let guide = "Ключевое число: платёж, итог, сколько документов. Значение — выражение или сводка по source"
    static let properties: [GenUISchemaProperty] = [
        .required("label", .string()),
        .optional("value", .value),
        .optional("format", .format),
        .optional("unit", .string()),
        .optional("caption", .string()),
        .optional("trend", .choice(["up", "down", "flat"])),
        .optional("source", .source),
        .optional("aggregate", .object([
            .required("op", .choice(["count", "sum", "avg", "min", "max"])),
            .optional("column", .string()),
        ])),
    ]

    struct Aggregate: Hashable, Sendable {
        let op: String
        let column: String?
    }

    let label: GenUITemplate
    let value: GenUIValue?
    let format: GenUIValueFormat?
    let unit: String?
    let caption: GenUITemplate?
    let trend: String?
    let source: GenUIDataSourceSpec?
    let aggregate: Aggregate?

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let label = parser.template(props, "label", required: true) else { return nil }
        self.label = label
        value = parser.value(props, "value")
        format = props["format"]?.string.flatMap(GenUIValueFormat.init(rawValue:))
        unit = parser.string(props, "unit", maxLength: 20)
        caption = parser.template(props, "caption")
        trend = props["trend"].map { _ in parser.choice(props, "trend", ["up", "down", "flat"], default: "flat") }
        source = parser.source(props["source"], field: "source")
        if let object = props["aggregate"]?.object {
            let aggregateProps = GenUIProps(object)
            aggregate = Aggregate(
                op: parser.choice(aggregateProps, "op", ["count", "sum", "avg", "min", "max"], default: "count"),
                column: aggregateProps["column"]?.string
            )
        } else {
            aggregate = nil
        }
        guard value != nil || source != nil else {
            parser.issue("у показателя нет value и source")
            return nil
        }
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        AnyView(GenUIMetricView(component: self, context: context, id: block.id))
    }

    /// Сводка строк источника: count, sum, avg, min, max по колонке
    static func aggregate(_ rows: GenUIRows, _ aggregate: Aggregate?) -> GenUIScalar? {
        let op = aggregate?.op ?? "count"
        guard op != "count" else { return .number(Double(rows.rows.count)) }
        let column = aggregate?.column ?? "value"
        let numbers = rows.rows.compactMap { $0[column]?.number }
        guard !numbers.isEmpty else { return nil }
        switch op {
        case "sum": return .number(numbers.reduce(0, +))
        case "avg": return .number(numbers.reduce(0, +) / Double(numbers.count))
        case "min": return numbers.min().map(GenUIScalar.number)
        default: return numbers.max().map(GenUIScalar.number)
        }
    }
}

private struct GenUIMetricView: View {
    let component: GenUIMetricComponent
    let context: GenUIRenderContext
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(context.text(component.label))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let source = component.source {
                GenUISourceRows(spec: source, context: context) { rows in
                    valueLine(GenUIMetricComponent.aggregate(rows, component.aggregate))
                }
            } else {
                valueLine(context.evaluate(component.value))
            }
            if let caption = component.caption {
                Text(context.text(caption))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .genUICard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("genui-\(id)")
    }

    private func valueLine(_ value: GenUIScalar?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(GenUIFormat.formatted(value, as: component.format))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .accessibilityIdentifier("genui-\(id)-value")
            if let unit = component.unit {
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
            }
            if let trend = component.trend {
                Image(systemName: trend == "up" ? "arrow.up.right" : (trend == "down" ? "arrow.down.right" : "arrow.right"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(trend == "up" ? Theme.accent : (trend == "down" ? Color.red : Color.secondary))
                    .accessibilityLabel(trend == "up" ? "растёт" : (trend == "down" ? "падает" : "без изменений"))
            }
        }
    }
}

// MARK: - Список

struct GenUIListComponent: GenUIComponent {
    static let type = "list"
    static let guide = "Короткий перечень: шаги, документы, варианты; у пункта может быть действие"
    static let properties: [GenUISchemaProperty] = [
        .required("items", .array(.object([
            .required("text", .string()),
            .optional("secondary", .string()),
            .optional("icon", .string(description: "Имя значка SF Symbols")),
            .optional("action", .action),
        ]), minItems: 1, maxItems: GenUILimits.maxListItems)),
    ]

    struct Item: Hashable, Sendable {
        let text: GenUITemplate
        let secondary: GenUITemplate?
        let icon: String?
        let action: GenUIAction?
    }

    let items: [Item]

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let raw = props["items"]?.array, !raw.isEmpty else {
            parser.issue("у списка нет пунктов", field: "items")
            return nil
        }
        var items: [Item] = []
        for (index, json) in raw.prefix(GenUILimits.maxListItems).enumerated() {
            guard let object = json.object else { continue }
            let item = GenUIProps(object)
            guard let text = parser.template(item, "text", required: true) else { continue }
            items.append(Item(
                text: text,
                secondary: parser.template(item, "secondary"),
                icon: GenUIStyle.symbol(item["icon"]?.string),
                action: parser.action(item["action"], field: "items[\(index)].action")
            ))
        }
        guard !items.isEmpty else { return nil }
        self.items = items
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider().padding(.leading, item.icon == nil ? 0 : 30) }
                    row(item, index: index, context: context, block: block)
                }
            }
            .genUICard()
            .accessibilityIdentifier("genui-\(block.id)")
        )
    }

    @MainActor @ViewBuilder
    private func row(_ item: Item, index: Int, context: GenUIRenderContext, block: GenUIBlock) -> some View {
        let content = HStack(alignment: .top, spacing: 10) {
            if let icon = item.icon {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(context.text(item.text)).font(.subheadline).foregroundStyle(Theme.ink)
                if let secondary = item.secondary {
                    Text(context.text(secondary)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if item.action != nil {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        if let action = item.action {
            Button { context.perform(action, block: "\(block.id)#\(index)") } label: { content }
                .buttonStyle(.plain)
                .disabled(context.isRunning("\(block.id)#\(index)"))
        } else {
            content
        }
    }
}

// MARK: - Таблица

struct GenUITableComponent: GenUIComponent {
    static let type = "table"
    static let guide = "Таблица: сравнение, перечень с колонками, расчёт по месяцам. Данные приложения — через source"
    static let properties: [GenUISchemaProperty] = [
        .required("columns", .array(.object([
            .required("key", .string()),
            .required("title", .string()),
            .optional("format", .format),
            .optional("align", .choice(["leading", "center", "trailing"])),
        ]), minItems: 1, maxItems: GenUILimits.maxTableColumns)),
        .optional("rows", .array(.array(.cell), maxItems: GenUILimits.maxTableRows, description: "Строки — значения в порядке columns")),
        .optional("source", .source),
        .optional("generate", .generate),
        .optional("max_rows", .integer(minimum: 1, maximum: GenUILimits.maxTableRows)),
    ]

    struct Column: Hashable, Sendable {
        let key: String
        let title: String
        let format: GenUIValueFormat?
        let align: String

        var alignment: HorizontalAlignment {
            switch align {
            case "trailing": .trailing
            case "center": .center
            default: .leading
            }
        }
    }

    let columns: [Column]
    let literal: GenUIRows?
    let source: GenUIDataSourceSpec?
    let generate: GenUIGenerate?
    let maxRows: Int

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        let columns = Self.columns(props, parser: &parser)
        guard !columns.isEmpty else { return nil }
        self.columns = columns
        source = parser.source(props["source"], field: "source")
        generate = source == nil ? parser.generate(props["generate"], field: "generate") : nil
        let cells = parser.cells(props["rows"], columns: columns.map(\.key), limit: GenUILimits.maxTableRows, field: "rows")
        literal = cells.map { GenUIRows(columns: columns.map(\.key), values: $0) }
        maxRows = parser.integer(props, "max_rows", in: 1...GenUILimits.maxTableRows) ?? 20
        guard source != nil || generate != nil || literal != nil else {
            parser.issue("у таблицы нет rows, source или generate")
            return nil
        }
    }

    static func columns(_ props: GenUIProps, parser: inout GenUIParser) -> [Column] {
        guard let raw = props["columns"]?.array, !raw.isEmpty else {
            parser.issue("нет колонок", field: "columns")
            return []
        }
        if raw.count > GenUILimits.maxTableColumns { parser.issue("колонок больше \(GenUILimits.maxTableColumns)", field: "columns") }
        return raw.prefix(GenUILimits.maxTableColumns).compactMap { json in
            guard let object = json.object, let key = object["key"]?.string, !key.isEmpty else { return nil }
            let column = GenUIProps(object)
            return Column(
                key: key,
                title: column["title"]?.string ?? key,
                format: column["format"]?.string.flatMap(GenUIValueFormat.init(rawValue:)),
                align: column["align"]?.string ?? "leading"
            )
        }
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        AnyView(
            GenUIDataView(literal: literal, generate: generate, source: source, context: context) { rows in
                GenUITableView(columns: columns, rows: rows, maxRows: maxRows, blockID: block.id, state: context.state)
            }
            .accessibilityIdentifier("genui-\(block.id)")
        )
    }
}

private struct GenUITableView: View {
    let columns: [GenUITableComponent.Column]
    let rows: GenUIRows
    let maxRows: Int
    let blockID: String
    let state: GenUIState

    var body: some View {
        let expanded = state.interfaceValue("more:\(blockID)")?.truthy ?? false
        let visible = expanded ? rows.rows : Array(rows.rows.prefix(maxRows))
        VStack(alignment: .leading, spacing: 10) {
            if rows.rows.isEmpty {
                Text("Нет данных").font(.footnote).foregroundStyle(.secondary)
            } else if columns.count > 3 {
                ScrollView(.horizontal, showsIndicators: false) { grid(visible) }
            } else {
                grid(visible)
            }
            if rows.rows.count > maxRows {
                Button(expanded ? "Свернуть" : "Показать все · \(rows.rows.count)") {
                    state.setInterface("more:\(blockID)", .bool(!expanded))
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.ink)
            }
        }
        .genUICard()
    }

    private func grid(_ visible: [[String: GenUIScalar]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                ForEach(columns, id: \.key) { column in
                    Text(column.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(column.alignment)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(visible.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(columns, id: \.key) { column in
                        Text(GenUIFormat.formatted(row[column.key], as: column.format))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                    }
                }
            }
        }
    }
}

// MARK: - Сравнение, прогресс, выноска, разделитель

struct GenUIComparisonComponent: GenUIComponent {
    static let type = "comparison"
    static let guide = "Два–четыре варианта рядом: тарифы, документы, сценарии расчёта"
    static let properties: [GenUISchemaProperty] = [
        .required("items", .array(.object([
            .required("title", .string()),
            .required("values", .array(.object([
                .required("label", .string()),
                .required("value", .value),
            ]), minItems: 1, maxItems: 12)),
        ]), minItems: 2, maxItems: 4)),
    ]

    struct Item: Hashable, Sendable {
        let title: GenUITemplate
        let values: [(label: GenUITemplate, value: GenUIValue)]

        static func == (lhs: Item, rhs: Item) -> Bool { lhs.title == rhs.title && lhs.values.count == rhs.values.count }
        func hash(into hasher: inout Hasher) { hasher.combine(title) }
    }

    let items: [Item]

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        var items: [Item] = []
        for json in (props["items"]?.array ?? []).prefix(4) {
            guard let object = json.object else { continue }
            let item = GenUIProps(object)
            guard let title = parser.template(item, "title", required: true) else { continue }
            var values: [(label: GenUITemplate, value: GenUIValue)] = []
            for entry in (item["values"]?.array ?? []).prefix(12) {
                guard let entryObject = entry.object else { continue }
                let entryProps = GenUIProps(entryObject)
                guard let label = parser.template(entryProps, "label", required: true),
                      let value = parser.value(entryProps, "value", required: true) else { continue }
                values.append((label, value))
            }
            items.append(Item(title: title, values: values))
        }
        guard items.count >= 2 else {
            parser.issue("для сравнения нужно 2–4 варианта", field: "items")
            return nil
        }
        self.items = items
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        let columns = items.map { item in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.text(item.title)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                ForEach(Array(item.values.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.text(entry.label)).font(.caption).foregroundStyle(.secondary)
                        Text(GenUIFormat.display(context.evaluate(entry.value)))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .genUICard()
        }
        return AnyView(
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) { ForEach(columns.indices, id: \.self) { columns[$0].frame(minWidth: 130) } }
                VStack(spacing: 10) { ForEach(columns.indices, id: \.self) { columns[$0] } }
            }
            .accessibilityIdentifier("genui-\(block.id)")
        )
    }
}

struct GenUIProgressComponent: GenUIComponent {
    static let type = "progress"
    static let guide = "Насколько выполнено: прочитано документов, накоплено от цели. max по умолчанию 1"
    static let properties: [GenUISchemaProperty] = [
        .required("label", .string()),
        .required("value", .value),
        .optional("max", .value),
        .optional("format", .format),
    ]

    let label: GenUITemplate
    let value: GenUIValue
    let max: GenUIValue?
    let format: GenUIValueFormat?

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let label = parser.template(props, "label", required: true),
              let value = parser.value(props, "value", required: true) else { return nil }
        self.label = label
        self.value = value
        max = parser.value(props, "max")
        format = props["format"]?.string.flatMap(GenUIValueFormat.init(rawValue:))
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        let current = context.evaluate(value)?.number ?? 0
        let total = context.evaluate(max)?.number ?? 1
        let fraction = total > 0 ? Swift.min(Swift.max(current / total, 0), 1) : 0
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(context.text(label)).font(.subheadline).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(format == nil ? GenUIFormat.percent(fraction * 100, digits: 0) : GenUIFormat.formatted(.number(current), as: format))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: fraction).tint(Theme.accent)
            }
            .genUICard()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("genui-\(block.id)")
        )
    }
}

struct GenUICalloutComponent: GenUIComponent {
    static let type = "callout"
    static let guide = "Важное замечание: предупреждение о сроке, честное ограничение данных, успех"
    static let properties: [GenUISchemaProperty] = [
        .required("text", .string()),
        .optional("tone", .choice(["info", "success", "warning", "danger"])),
    ]

    let text: GenUITemplate
    let tone: String

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let text = parser.template(props, "text", required: true, maxLength: 1000) else { return nil }
        self.text = text
        tone = parser.choice(props, "tone", ["info", "success", "warning", "danger"], default: "info")
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        let style = GenUIStyle.tone(tone)
        return AnyView(
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.symbol).foregroundStyle(style.color)
                GenUIRichText(text: context.text(text))
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("genui-\(block.id)")
        )
    }
}

struct GenUIDividerComponent: GenUIComponent {
    static let type = "divider"
    static let guide = "Разделитель между частями ответа"
    static let properties: [GenUISchemaProperty] = []

    init?(_ props: GenUIProps, parser: inout GenUIParser) {}

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        AnyView(Divider().overlay(Theme.hairline))
    }
}
