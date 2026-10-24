import Foundation

/// Поток ответа модели в сообщение с интерфейсом: текст растёт, состояние и
/// блоки появляются, как только их JSON закрыт. Номера документов закрываются
/// маской в разобранных значениях — в сыром JSON маска сломала бы числа
@MainActor
final class GenUIStreamFeed {
    let model: GenUIMessageModel
    private var parser = GenUIStreamParser()
    private let mask: @MainActor (String) -> String

    init(model: GenUIMessageModel? = nil, mask: @escaping @MainActor (String) -> String = { $0 }) {
        self.model = model ?? GenUIMessageModel()
        self.mask = mask
    }

    /// Пришло ли хоть что-то: ответ, кончившийся одними карточками,
    /// интерфейса не показывает
    var hasContent: Bool { parser.receivedBytes > 0 }

    /// Новый кусок ответа
    func feed(_ delta: String) {
        for event in parser.feed(delta) {
            switch event {
            case .text(let text): model.setPartialText(mask(text))
            case .state(let json): model.setState(json)
            case .computed(let json): model.setComputed(json)
            case .block(let json): model.append(Self.masked(json, with: mask))
            }
        }
        // Не JSON — простой текст: показывается по мере прихода, как раньше
        if parser.isNotJSON { model.setPartialText(mask(parser.raw)) }
    }

    /// Ответ закончился. Закрытый JSON проверяется целиком, как ответ без
    /// потока. Не JSON — простой текст. Оборванный — остаётся, что пришло
    func finish() {
        if let data = parser.complete, let json = try? JSONValue(data) {
            let validation = GenUIValidator.document(from: Self.masked(json, with: mask), registry: model.registry)
            model.finish(validation.document, issues: validation.issues)
        } else if parser.isNotJSON {
            model.finish(GenUIDocument(mode: .text, text: mask(parser.raw.trimmingCharacters(in: .whitespacesAndNewlines))))
        } else if parser.receivedBytes == 0 {
            model.finish(GenUIDocument(mode: .text, text: ""))
        } else {
            model.fail("ответ оборвался")
        }
    }

    /// Ответ остановлен человеком или сроком: остаётся то, что пришло
    func stop(_ reason: String) {
        model.fail(reason)
    }

    /// Строки — через маску. Число, в котором маска нашла номер документа,
    /// становится строкой с маской
    static func masked(_ json: JSONValue, with mask: @MainActor (String) -> String) -> JSONValue {
        switch json {
        case .string(let text):
            return .string(mask(text))
        case .number(let value):
            let text = value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
            let masked = mask(text)
            return masked == text ? json : .string(masked)
        case .array(let items):
            return .array(items.map { masked($0, with: mask) })
        case .object(let object):
            return .object(object.mapValues { masked($0, with: mask) })
        case .null, .bool:
            return json
        }
    }
}
