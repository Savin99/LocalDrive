import SwiftUI

/// Что нужно компоненту при отрисовке: состояние, действия, приложение
@MainActor
struct GenUIRenderContext {
    let state: GenUIState
    let runner: GenUIActionRunner
    let environment: GenUIEnvironment

    func evaluate(_ value: GenUIValue?, extra: [String: GenUIScalar] = [:]) -> GenUIScalar? {
        value.flatMap { state.evaluate($0, extra: extra) }
    }

    func text(_ template: GenUITemplate?, extra: [String: GenUIScalar] = [:]) -> String {
        template.map { state.text($0, extra: extra) } ?? ""
    }

    func perform(_ action: GenUIAction, block: String) {
        let runner = runner
        let state = state
        let performer = environment.actionPerformer
        Task { await runner.run(action, block: block, state: state, performer: performer) }
    }

    func isRunning(_ block: String) -> Bool {
        runner.running.contains(block)
    }

    func outcome(_ block: String) -> GenUIActionOutcome? {
        runner.outcomes[block]
    }
}

/// Блок: условие видимости, плавное появление, стабильная идентичность
struct GenUIBlockView: View {
    let block: GenUIBlock
    let context: GenUIRenderContext

    var body: some View {
        if isVisible {
            block.component.render(context, block: block)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }

    private var isVisible: Bool {
        guard let condition = block.visibleIf else { return true }
        return context.state.evaluate(condition)?.truthy ?? false
    }
}

/// Список блоков с общим отступом
struct GenUIBlockList: View {
    let blocks: [GenUIBlock]
    let context: GenUIRenderContext
    var spacing: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks) { block in
                GenUIBlockView(block: block, context: context)
            }
        }
    }
}

/// Ответ с интерфейсом в сообщении чата
struct GenUIMessageView: View {
    let model: GenUIMessageModel
    let environment: GenUIEnvironment
    /// Чат может показывать текст сам — тогда здесь только блоки
    var showsText = true

    var body: some View {
        let context = GenUIRenderContext(state: model.state, runner: model.runner, environment: environment)
        VStack(alignment: .leading, spacing: 12) {
            if showsText, !model.text.isEmpty {
                GenUIRichText(text: model.text)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
            }
            GenUIBlockList(blocks: model.blocks, context: context)
            if model.isEmpty {
                Label("Не получилось показать ответ", systemImage: "exclamationmark.bubble")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("genui-fallback")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Текст с простой разметкой: **жирный**, *курсив*, `код`. Ссылки отключены:
/// из ответа модели никуда не переходим
struct GenUIRichText: View {
    let text: String

    var body: some View {
        Text(Self.attributed(text))
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        for run in attributed.runs where run.link != nil {
            attributed[run.range].link = nil
        }
        return attributed
    }
}

/// Отступы, цвета графиков и тона — из дизайн-системы приложения
enum GenUIStyle {
    static func spacing(_ name: String?) -> CGFloat {
        switch name {
        case "s": 6
        case "l": 18
        default: 12
        }
    }

    /// Цвета рядов: зелёный акцент, затем цвета папок
    static let palette: [Color] = [
        Theme.accent, Theme.color("indigo"), Theme.color("orange"), Theme.color("pink"),
        Theme.color("teal"), Theme.color("purple"), Theme.color("blue"), Theme.color("graphite"),
    ]

    static func tone(_ name: String) -> (color: Color, symbol: String) {
        switch name {
        case "success": (Theme.accent, "checkmark.circle.fill")
        case "warning": (Theme.color("orange"), "exclamationmark.triangle.fill")
        case "danger": (Color.red, "xmark.octagon.fill")
        default: (Theme.color("blue"), "info.circle.fill")
        }
    }

    /// Только безопасные символы в имени значка SF Symbols
    static func symbol(_ name: String?) -> String? {
        guard let name, !name.isEmpty, name.count <= 60,
              name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." }) else { return nil }
        return name
    }
}

extension View {
    /// Карточка блока: та же, что у карточек чата
    func genUICard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(cornerRadius: 16)
    }
}

/// Строки из источника данных: загрузка при появлении и при смене параметров,
/// заглушка во время загрузки, ошибка — на месте блока, а не алертом
struct GenUISourceRows<Content: View>: View {
    let spec: GenUIDataSourceSpec
    let context: GenUIRenderContext
    @ViewBuilder let content: (GenUIRows) -> Content

    @State private var phase: Phase = .loading

    private enum Phase: Equatable {
        case loading
        case loaded(GenUIRows)
        case failed(String)
    }

    var body: some View {
        let source = spec.resolved(with: context.state)
        Group {
            switch phase {
            case .loading:
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
                    .frame(height: 64)
                    .overlay { ProgressView() }
                    .accessibilityLabel("Загружаю данные")
            case .loaded(let rows):
                content(rows)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        // Пересчёт при появлении: если папку скрыли, её данные пропадут
        .task(id: source) {
            guard let provider = context.environment.dataProvider else {
                phase = .failed("Данные приложения недоступны")
                return
            }
            do {
                let rows = try await provider.rows(for: source)
                phase = .loaded(GenUIRows(columns: rows.columns, rows: Array(rows.rows.prefix(GenUILimits.maxChartPoints))))
            } catch is CancellationError {
                return
            } catch {
                phase = .failed("Не удалось получить данные")
            }
        }
    }
}

/// Таблица или график с данными: решает, откуда строки
struct GenUIDataView<Content: View>: View {
    let literal: GenUIRows?
    let generate: GenUIGenerate?
    let source: GenUIDataSourceSpec?
    let context: GenUIRenderContext
    @ViewBuilder let content: (GenUIRows) -> Content

    var body: some View {
        if let source {
            GenUISourceRows(spec: source, context: context, content: content)
        } else if let generate {
            if let rows = generate.rows(with: context.state) {
                content(rows)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        } else {
            content(literal ?? .empty)
        }
    }
}
