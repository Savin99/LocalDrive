import SwiftUI

/// Компонент реестра: тип блока в JSON и его нативное представление.
/// Компонент сам описывает свои свойства для схемы ответа, сам их разбирает
/// и проверяет, сам рисует. Новый тип — новый компонент и строка регистрации
protocol GenUIComponent: Sendable {
    /// Значение поля `type`
    static var type: String { get }
    /// Для модели: когда этот блок уместен — одна строка
    static var guide: String { get }
    /// Свойства блока, кроме общих `id`, `type`, `visible_if`, в порядке схемы
    static var properties: [GenUISchemaProperty] { get }

    /// Разбор и проверка свойств. nil — блок выпадает, причина — в замечаниях
    init?(_ props: GenUIProps, parser: inout GenUIParser)

    /// Вложенные блоки — для лимитов, уникальности id и поиска при перестройке
    var children: [GenUIBlock] { get }

    @MainActor func render(_ context: GenUIRenderContext, block: GenUIBlock) -> AnyView
}

extension GenUIComponent {
    var children: [GenUIBlock] { [] }
}

/// Свойства блока из JSON. `null` значит «нет»: в строгом режиме модель
/// присылает все поля схемы, а ненужные — пустыми
struct GenUIProps {
    let object: [String: JSONValue]

    init(_ object: [String: JSONValue]) {
        self.object = object
    }

    subscript(key: String) -> JSONValue? {
        guard let value = object[key], !value.isNull else { return nil }
        return value
    }
}

/// Свойство в схеме ответа
struct GenUISchemaProperty: Sendable {
    let name: String
    let node: GenUISchemaNode
    /// Необязательное: в строгой схеме — тип с `null`
    let optional: Bool

    static func required(_ name: String, _ node: GenUISchemaNode) -> GenUISchemaProperty {
        GenUISchemaProperty(name: name, node: node, optional: false)
    }

    static func optional(_ name: String, _ node: GenUISchemaNode) -> GenUISchemaProperty {
        GenUISchemaProperty(name: name, node: node, optional: true)
    }
}

/// Узел JSON Schema. Только то, что понимает строгий режим Structured Outputs:
/// без allOf, not, if/then/else и без ограничений длины строк
indirect enum GenUISchemaNode: Sendable {
    case string(enumValues: [String]? = nil, format: String? = nil, description: String? = nil)
    case number(minimum: Double? = nil, maximum: Double? = nil, description: String? = nil)
    case integer(minimum: Int? = nil, maximum: Int? = nil, description: String? = nil)
    case boolean(description: String? = nil)
    case array(GenUISchemaNode, minItems: Int? = nil, maxItems: Int? = nil, description: String? = nil)
    case object([GenUISchemaProperty], description: String? = nil)
    /// Ссылка на определение в `$defs`: блок, значение, действие, источник
    case ref(String)
    case anyOf([GenUISchemaNode], description: String? = nil)

    static var text: GenUISchemaNode { .string() }
    static var blocks: GenUISchemaNode { .array(.ref("block"), maxItems: 40) }
    static var value: GenUISchemaNode { .ref("value") }
    static var action: GenUISchemaNode { .ref("action") }
    static var source: GenUISchemaNode { .ref("source") }
    static var generate: GenUISchemaNode { .ref("generate") }
    static var cell: GenUISchemaNode { .ref("cell") }
    static var format: GenUISchemaNode { .string(enumValues: GenUIValueFormat.allCases.map(\.rawValue)) }
    static var variable: GenUISchemaNode { .string(description: "Имя переменной состояния") }

    static func choice(_ values: [String], description: String? = nil) -> GenUISchemaNode {
        .string(enumValues: values, description: description)
    }
}

/// Реестр разрешённых компонентов
struct GenUIComponentRegistry: Sendable {
    private(set) var components: [String: any GenUIComponent.Type] = [:]
    /// Порядок регистрации — порядок в схеме и в подсказке модели
    private(set) var types: [String] = []

    init() {}

    mutating func register(_ component: any GenUIComponent.Type) {
        if components[component.type] == nil { types.append(component.type) }
        components[component.type] = component
    }

    func component(_ type: String) -> (any GenUIComponent.Type)? {
        components[type]
    }

    /// Базовый набор: отображение, графики, ввод, компоновка, карточки приложения
    static let standard: GenUIComponentRegistry = {
        var registry = GenUIComponentRegistry()
        let all: [any GenUIComponent.Type] = [
            GenUITextComponent.self, GenUIHeadingComponent.self, GenUIMetricComponent.self,
            GenUIListComponent.self, GenUITableComponent.self, GenUIComparisonComponent.self,
            GenUIProgressComponent.self, GenUICalloutComponent.self, GenUIChartComponent.self,
            GenUIButtonComponent.self, GenUIToggleComponent.self, GenUICheckboxComponent.self,
            GenUISliderComponent.self, GenUITextFieldComponent.self, GenUIDatePickerComponent.self,
            GenUIPickerComponent.self, GenUIFormComponent.self,
            GenUIStackComponent.self, GenUIGridComponent.self, GenUISectionComponent.self,
            GenUITabsComponent.self, GenUIDisclosureComponent.self, GenUIDividerComponent.self,
            GenUIAppCardComponent.self,
        ]
        for component in all { registry.register(component) }
        return registry
    }()
}
