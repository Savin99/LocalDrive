import SwiftUI

// MARK: - Стопка и сетка

struct GenUIStackComponent: GenUIComponent {
    static let type = "stack"
    static let guide = "Группа блоков друг под другом или в ряд; ряд на узком экране складывается в столбик"
    static let properties: [GenUISchemaProperty] = [
        .optional("axis", .choice(["vertical", "horizontal"])),
        .optional("spacing", .choice(["s", "m", "l"])),
        .required("blocks", .blocks),
    ]

    let horizontal: Bool
    let spacing: CGFloat
    let blocks: [GenUIBlock]

    var children: [GenUIBlock] { blocks }

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        horizontal = parser.choice(props, "axis", ["vertical", "horizontal"], default: "vertical") == "horizontal"
        spacing = GenUIStyle.spacing(props["spacing"]?.string)
        blocks = parser.blocks(props)
        guard !blocks.isEmpty else { return nil }
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        guard horizontal else {
            return AnyView(GenUIBlockList(blocks: blocks, context: context, spacing: spacing))
        }
        return AnyView(
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(blocks) { GenUIBlockView(block: $0, context: context) }
                }
                GenUIBlockList(blocks: blocks, context: context, spacing: spacing)
            }
        )
    }
}

struct GenUIGridComponent: GenUIComponent {
    static let type = "grid"
    static let guide = "Сетка из 1–4 колонок: показатели, карточки. На узком экране колонок меньше"
    static let properties: [GenUISchemaProperty] = [
        .required("columns", .integer(minimum: 1, maximum: 4)),
        .required("blocks", .blocks),
    ]

    let columns: Int
    let blocks: [GenUIBlock]

    var children: [GenUIBlock] { blocks }

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        columns = parser.integer(props, "columns", in: 1...4) ?? 2
        blocks = parser.blocks(props)
        guard !blocks.isEmpty else { return nil }
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        AnyView(GenUIGridView(columns: columns, blocks: blocks, context: context))
    }
}

private struct GenUIGridView: View {
    let columns: Int
    let blocks: [GenUIBlock]
    let context: GenUIRenderContext

    @State private var width: CGFloat = 360

    var body: some View {
        // Колонка не уже 140 pt: на iPhone четыре колонки складываются в две
        let fitting = max(1, min(columns, Int(width / 140)))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: fitting), alignment: .leading, spacing: 10) {
            ForEach(blocks) { GenUIBlockView(block: $0, context: context) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// MARK: - Раздел

struct GenUISectionComponent: GenUIComponent {
    static let type = "section"
    static let guide = "Раздел с заголовком; style card — в карточке"
    static let properties: [GenUISchemaProperty] = [
        .optional("title", .string()),
        .optional("subtitle", .string()),
        .optional("style", .choice(["plain", "card"])),
        .required("blocks", .blocks),
    ]

    let title: GenUITemplate?
    let subtitle: GenUITemplate?
    let card: Bool
    let blocks: [GenUIBlock]

    var children: [GenUIBlock] { blocks }

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        title = parser.template(props, "title")
        subtitle = parser.template(props, "subtitle")
        card = parser.choice(props, "style", ["plain", "card"], default: "plain") == "card"
        blocks = parser.blocks(props)
        guard !blocks.isEmpty else { return nil }
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        let content = VStack(alignment: .leading, spacing: 10) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title { Text(context.text(title)).font(.headline).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader) }
                    if let subtitle { Text(context.text(subtitle)).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            GenUIBlockList(blocks: blocks, context: context)
        }
        return card ? AnyView(content.genUICard()) : AnyView(content)
    }
}

// MARK: - Вкладки и раскрываемый раздел

struct GenUITabsComponent: GenUIComponent {
    static let type = "tabs"
    static let guide = "Вкладки: разные представления одних данных — график и таблица, по категориям и списком"
    static let properties: [GenUISchemaProperty] = [
        .optional("bind", .variable),
        .required("tabs", .array(.object([
            .required("id", .string()),
            .required("title", .string()),
            .required("blocks", .blocks),
        ]), minItems: 2, maxItems: GenUILimits.maxTabs)),
    ]

    struct Tab: Hashable, Sendable {
        let id: String
        let title: String
        let blocks: [GenUIBlock]
    }

    let bind: String?
    let tabs: [Tab]

    var children: [GenUIBlock] { tabs.flatMap(\.blocks) }

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        var tabs: [Tab] = []
        for json in (props["tabs"]?.array ?? []).prefix(GenUILimits.maxTabs) {
            guard let object = json.object, let id = object["id"]?.string, GenUIParser.isValidID(id),
                  !tabs.contains(where: { $0.id == id }) else {
                parser.issue("вкладка без id или с повтором", field: "tabs")
                continue
            }
            let tab = GenUIProps(object)
            let title = String((tab["title"]?.string ?? id).prefix(40))
            tabs.append(Tab(id: id, title: title, blocks: parser.blocks(tab)))
        }
        guard tabs.count >= 2 else {
            parser.issue("вкладок меньше двух")
            return nil
        }
        self.tabs = tabs
        if props["bind"] != nil {
            bind = parser.bind(props, kind: .string, default: .string(tabs[0].id))
        } else {
            bind = nil
        }
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        AnyView(GenUITabsView(component: self, context: context, id: block.id))
    }
}

private struct GenUITabsView: View {
    let component: GenUITabsComponent
    let context: GenUIRenderContext
    let id: String

    var body: some View {
        let state = context.state
        let key = "tab:\(id)"
        let selected: String = {
            if let bind = component.bind { return state.value(bind)?.string ?? component.tabs[0].id }
            return state.interfaceValue(key)?.string ?? component.tabs[0].id
        }()
        let current = component.tabs.first { $0.id == selected } ?? component.tabs[0]
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(component.tabs, id: \.id) { tab in
                        Button {
                            if let bind = component.bind {
                                state.set(bind, .string(tab.id))
                            } else {
                                state.setInterface(key, .string(tab.id))
                            }
                        } label: {
                            Text(tab.title)
                                .font(.subheadline.weight(tab.id == current.id ? .semibold : .regular))
                                .foregroundStyle(tab.id == current.id ? Theme.ink : Color.secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(tab.id == current.id ? Theme.surface : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(tab.id == current.id ? .isSelected : [])
                        .accessibilityIdentifier("genui-\(id)-tab-\(tab.id)")
                    }
                }
            }
            GenUIBlockList(blocks: current.blocks, context: context)
                .id(current.id)
                .transition(.opacity)
        }
        .animation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.18), value: current.id)
    }
}

struct GenUIDisclosureComponent: GenUIComponent {
    static let type = "disclosure"
    static let guide = "Раскрываемый раздел: подробности, расчёт по шагам, исходные данные"
    static let properties: [GenUISchemaProperty] = [
        .required("title", .string()),
        .optional("expanded", .boolean()),
        .required("blocks", .blocks),
    ]

    let title: GenUITemplate
    let expanded: Bool
    let blocks: [GenUIBlock]

    var children: [GenUIBlock] { blocks }

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let title = parser.template(props, "title", required: true) else { return nil }
        self.title = title
        expanded = parser.bool(props, "expanded") ?? false
        blocks = parser.blocks(props)
        guard !blocks.isEmpty else { return nil }
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        let state = context.state
        let key = "open:\(block.id)"
        let initiallyExpanded = expanded
        let isExpanded = Binding<Bool>(
            get: { state.interfaceValue(key)?.truthy ?? initiallyExpanded },
            set: { state.setInterface(key, .bool($0)) }
        )
        return AnyView(
            DisclosureGroup(isExpanded: isExpanded) {
                GenUIBlockList(blocks: blocks, context: context)
                    .padding(.top, 10)
            } label: {
                Text(context.text(title)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            }
            .tint(Theme.ink)
            .genUICard()
            .accessibilityIdentifier("genui-\(block.id)")
        )
    }
}

// MARK: - Карточка приложения

struct GenUIAppCardComponent: GenUIComponent {
    static let type = "app_card"
    static let guide = "Карточка из каталога чата: поля документа, документ, файлы, фрагмент, срок. Значения берутся из базы"
    static let properties: [GenUISchemaProperty] = [
        .required("card", .object([
            .required("kind", .choice(["fields", "document", "file_list", "snippet", "expiry"])),
            .optional("document_id", .string()),
            .optional("document_ids", .array(.string(), maxItems: 12)),
            .optional("keys", .array(.string(), maxItems: 12)),
            .optional("page", .integer(minimum: 1, maximum: 10_000)),
        ])),
    ]

    /// Карточки каталога. Обычно одна; модель просит и несколько разом —
    /// «сроки» по списку document_ids: тогда по карточке на документ
    let cards: [ChatCard]

    init?(_ props: GenUIProps, parser: inout GenUIParser) {
        guard let object = props["card"]?.object else {
            parser.issue("нет card", field: "card")
            return nil
        }
        let card = GenUIProps(object)
        // Документы — из document_id и document_ids, без повторов, по порядку
        var ids: [Int64] = []
        for id in [GenUIDocumentID.parse(card["document_id"])].compactMap({ $0 })
            + (card["document_ids"]?.array ?? []).compactMap({ GenUIDocumentID.parse($0) }) where !ids.contains(id) {
            ids.append(id)
        }
        guard let first = ids.first else {
            parser.issue("нет документа", field: "card.document_id")
            return nil
        }
        switch card["kind"]?.string {
        case "fields":
            // keys: null — «все поля»: так модель просит «все данные паспорта».
            // Живая проверка 19.11.2026: такие карточки отбрасывались, на
            // экране было «Не нашёл, что ответить»
            let keys = (card["keys"]?.isNull ?? true) ? [] : (parser.strings(card, "keys", max: 12) ?? [])
            let wanted = keys.isEmpty ? FieldKey.order : keys
            cards = ids.prefix(4).map { .fields(documentID: $0, keys: wanted) }
        case "document":
            cards = ids.count == 1 ? [.document(documentID: first)] : [.fileList(documentIDs: Array(ids.prefix(12)))]
        case "file_list":
            cards = [.fileList(documentIDs: Array(ids.prefix(12)))]
        case "snippet":
            cards = [.snippet(documentID: first, page: card["page"]?.number.map { Int($0) })]
        case "expiry":
            cards = ids.prefix(6).map { .expiry(documentID: $0) }
        default:
            parser.issue("неизвестная карточка", field: "card.kind")
            return nil
        }
    }

    func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView {
        if let appCard = context.environment.appCard {
            return AnyView(
                VStack(spacing: 10) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { _, card in appCard(card) }
                }
            )
        }
        return AnyView(
            Label("Карточка документа", systemImage: "doc.text")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .genUICard()
        )
    }
}
