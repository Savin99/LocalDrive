import Charts
import SwiftUI

struct GenUIChartComponent: GenUIComponent {
    static let type = "chart"
    static let guide = "График: динамика (line, area), сравнение величин (bar), доли (pie), распределение (histogram). Данные приложения — через source, расчёт — через generate"
    static let properties: [GenUISchemaProperty] = [
        .required("kind", .choice(Kind.allCases.map(\.rawValue))),
        .optional("title", .string()),
        .required("x", .object([
            .required("key", .string()),
            .optional("title", .string()),
            .required("kind", .choice(["number", "date", "category"])),
        ])),
        .required("y", .object([
            .required("key", .string()),
            .optional("title", .string()),
            .optional("format", .format),
        ])),
        .optional("series", .string(description: "Колонка, по которой ряды различаются цветом")),
        .optional("columns", .array(.string(), maxItems: GenUILimits.maxTableColumns, description: "Ключи значений в строках rows")),
        .optional("rows", .array(.array(.cell), maxItems: GenUILimits.maxChartPoints)),
        .optional("source", .source),
        .optional("generate", .generate),
        .optional("height", .choice(["s", "m", "l"])),
    ]

    enum Kind: String, CaseIterable, Sendable {
        case line, bar, area, point, pie, histogram
    }

    let kind: Kind
    let title: GenUITemplate?
    let xKey: String
    let xTitle: String?
    let xKind: String
    let yKey: String
    let yTitle: String?
    let yFormat: GenUIValueFormat?
    let series: String?
    let literal: GenUIRows?
    let source: GenUIDataSourceSpec?
    let generate: GenUIGenerate?
    let height: CGFloat

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let kindName = props["kind"]?.string, let kind = Kind(rawValue: kindName) else {
            parser.issue("неизвестный вид графика", field: "kind")
            return nil
        }
        guard let x = props["x"]?.object, let xKey = x["key"]?.string,
              let y = props["y"]?.object, let yKey = y["key"]?.string else {
            parser.issue("у графика нет x.key или y.key")
            return nil
        }
        self.kind = kind
        title = parser.template(props, "title")
        self.xKey = xKey
        xTitle = x["title"]?.string
        xKind = ["number", "date", "category"].contains(x["kind"]?.string ?? "") ? x["kind"]!.string! : "category"
        self.yKey = yKey
        yTitle = y["title"]?.string
        yFormat = y["format"]?.string.flatMap(GenUIValueFormat.init(rawValue:))
        series = props["series"]?.string
        source = parser.source(props["source"], field: "source")
        generate = source == nil ? parser.generate(props["generate"], field: "generate") : nil
        let columns = parser.strings(props, "columns", max: GenUILimits.maxTableColumns) ?? [xKey, yKey] + (props["series"]?.string.map { [$0] } ?? [])
        literal = parser.cells(props["rows"], columns: columns, limit: GenUILimits.maxChartPoints, field: "rows")
            .map { GenUIRows(columns: columns, values: $0) }
        height = switch props["height"]?.string {
        case "s": 150
        case "l": 300
        default: 210
        }
        guard source != nil || generate != nil || literal != nil else {
            parser.issue("у графика нет rows, source или generate")
            return nil
        }
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 10) {
                if let title {
                    Text(context.text(title)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                }
                GenUIDataView(literal: literal, generate: generate, source: source, context: context) { rows in
                    GenUIChartView(component: self, rows: rows)
                }
            }
            .genUICard()
            .accessibilityIdentifier("genui-\(block.id)")
        )
    }
}

/// Точка графика: значение X одного из трёх видов, Y, ряд
private struct GenUIChartPoint: Identifiable {
    let id: Int
    let number: Double?
    let date: Date?
    let category: String?
    let y: Double
    let series: String?
}

private struct GenUIChartView: View {
    let component: GenUIChartComponent
    let rows: GenUIRows

    var body: some View {
        let points = self.points
        if points.isEmpty {
            Text("Нет данных для графика").font(.footnote).foregroundStyle(.secondary)
        } else {
            let horizontal = Self.isHorizontal(component, points)
            // Легенда нужна, только когда рядов больше одного; у круговой — всегда
            let series = Set(points.map { $0.series ?? "" }).count
            chart(points, horizontal: horizontal)
                .chartForegroundStyleScale(range: GenUIStyle.palette)
                .chartLegend(series > 1 || component.kind == .pie ? .visible : .hidden)
                .frame(height: horizontal ? max(component.height, CGFloat(points.count) * 30 + 30) : component.height)
                .accessibilityElement()
                .accessibilityLabel(summary(points))
        }
    }

    /// Столбцы по категориям с длинными подписями — горизонтальные: на
    /// iPhone «Удостоверения» под узким столбцом обрезались бы
    static func isHorizontal(_ component: GenUIChartComponent, _ points: [GenUIChartPoint]) -> Bool {
        component.kind == .bar && component.xKind == "category"
            && (points.count > 4 || points.contains { ($0.category?.count ?? 0) > 9 })
    }

    /// Подпись деления оси значений. У целых величин дробные деления пустые:
    /// иначе «1,5 документа» округлилось бы в повтор «2, 2»
    private func axisLabel(_ number: Double) -> String {
        if component.yFormat == .integer, number != number.rounded() { return "" }
        return GenUIFormat.formatted(.number(number), as: component.yFormat == .money ? .number : component.yFormat)
    }

    private var points: [GenUIChartPoint] {
        rows.rows.enumerated().compactMap { index, row in
            guard let y = row[component.yKey]?.number, y.isFinite else { return nil }
            let x = row[component.xKey]
            let series = component.series.flatMap { row[$0] }.map { GenUIFormat.display($0) }
            switch component.xKind {
            case "number":
                guard let number = x?.number else { return nil }
                return GenUIChartPoint(id: index, number: number, date: nil, category: nil, y: y, series: series)
            case "date":
                guard let day = x?.day else { return nil }
                return GenUIChartPoint(id: index, number: nil, date: day.localDate(), category: nil, y: y, series: series)
            default:
                return GenUIChartPoint(id: index, number: nil, date: nil, category: GenUIFormat.display(x), y: y, series: series)
            }
        }
    }

    private var yLabel: String { component.yTitle ?? component.yKey }
    private var xLabel: String { component.xTitle ?? component.xKey }

    @ViewBuilder
    private func chart(_ points: [GenUIChartPoint], horizontal: Bool) -> some View {
        switch component.kind {
        case .pie:
            Chart(points) { point in
                SectorMark(angle: .value(yLabel, point.y), innerRadius: .ratio(0.55), angularInset: 1.5)
                    .foregroundStyle(by: .value(xLabel, point.category ?? point.series ?? ""))
            }
        case .histogram:
            let bins = Self.bins(points.map(\.y))
            Chart(bins) { bin in
                BarMark(x: .value(yLabel, bin.label), y: .value("Количество", bin.count))
                    .foregroundStyle(Theme.accent)
            }
        default:
            if horizontal {
                Chart(points) { point in
                    BarMark(x: .value(yLabel, point.y), y: .value(xLabel, point.category ?? ""))
                        .foregroundStyle(by: .value("Ряд", point.series ?? yLabel))
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { Text(value.as(Double.self).map(axisLabel) ?? "") }
                    }
                }
            } else {
                Chart(points) { point in
                    mark(point)
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { Text(value.as(Double.self).map(axisLabel) ?? "") }
                    }
                }
            }
        }
    }

    @ChartContentBuilder
    private func mark(_ point: GenUIChartPoint) -> some ChartContent {
        let series = point.series ?? yLabel
        if let number = point.number {
            switch component.kind {
            case .bar: BarMark(x: .value(xLabel, number), y: .value(yLabel, point.y)).foregroundStyle(by: .value("Ряд", series))
            case .area: AreaMark(x: .value(xLabel, number), y: .value(yLabel, point.y)).foregroundStyle(by: .value("Ряд", series))
            case .point: PointMark(x: .value(xLabel, number), y: .value(yLabel, point.y)).foregroundStyle(by: .value("Ряд", series))
            default: LineMark(x: .value(xLabel, number), y: .value(yLabel, point.y)).foregroundStyle(by: .value("Ряд", series))
            }
        } else if let date = point.date {
            switch component.kind {
            case .bar: BarMark(x: .value(xLabel, date, unit: .day), y: .value(yLabel, point.y)).foregroundStyle(by: .value("Ряд", series))
            case .area: AreaMark(x: .value(xLabel, date), y: .value(yLabel, point.y)).foregroundStyle(by: .value("Ряд", series))
            case .point: PointMark(x: .value(xLabel, date), y: .value(yLabel, point.y)).foregroundStyle(by: .value("Ряд", series))
            default: LineMark(x: .value(xLabel, date), y: .value(yLabel, point.y)).foregroundStyle(by: .value("Ряд", series))
            }
        } else {
            let category = point.category ?? ""
            switch component.kind {
            case .area: AreaMark(x: .value(xLabel, category), y: .value(yLabel, point.y)).foregroundStyle(by: .value("Ряд", series))
            case .point: PointMark(x: .value(xLabel, category), y: .value(yLabel, point.y)).foregroundStyle(by: .value("Ряд", series))
            case .line: LineMark(x: .value(xLabel, category), y: .value(yLabel, point.y)).foregroundStyle(by: .value("Ряд", series))
            default: BarMark(x: .value(xLabel, category), y: .value(yLabel, point.y)).foregroundStyle(by: .value("Ряд", series))
            }
        }
    }

    /// Для VoiceOver: вид, сколько значений, от и до
    private func summary(_ points: [GenUIChartPoint]) -> String {
        let values = points.map(\.y)
        let low = values.min().map { GenUIFormat.formatted(.number($0), as: component.yFormat) } ?? "—"
        let high = values.max().map { GenUIFormat.formatted(.number($0), as: component.yFormat) } ?? "—"
        let kind = switch component.kind {
        case .line: "Линейный график"
        case .bar: "Столбчатая диаграмма"
        case .area: "График с областью"
        case .point: "Точечный график"
        case .pie: "Круговая диаграмма"
        case .histogram: "Гистограмма"
        }
        return "\(kind) «\(yLabel)»: \(pluralize(points.count, "значение", "значения", "значений")), от \(low) до \(high)"
    }

    struct Bin: Identifiable {
        let id: Int
        let label: String
        let count: Int
    }

    /// Десять корзин между минимумом и максимумом
    static func bins(_ values: [Double]) -> [Bin] {
        guard let low = values.min(), let high = values.max() else { return [] }
        guard high > low else { return [Bin(id: 0, label: GenUIFormat.number(low), count: values.count)] }
        let count = 10
        let width = (high - low) / Double(count)
        var counts = Array(repeating: 0, count: count)
        for value in values {
            counts[min(count - 1, Int((value - low) / width))] += 1
        }
        return counts.enumerated().map { index, value in
            Bin(id: index, label: GenUIFormat.number(low + width * Double(index), digits: 0), count: value)
        }
    }
}
