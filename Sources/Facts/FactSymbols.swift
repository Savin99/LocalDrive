import UIKit

// Значки карточек и полей. Агент может выбрать значок сам; если не выбрал или
// выбрал несуществующий — значок подбирается по подписи («Домофон» → звонок),
// затем по виду поля. Все имена здесь проверены тестом на iOS 26:
// `UIImage(systemName:)` их находит
enum FactSymbols {
    /// Значок поля: выбранный → по подписи → по виду
    static func symbol(for item: FactItem) -> String {
        if let chosen = item.symbol, isAvailable(chosen) { return chosen }
        return defaultSymbol(kind: item.kind, label: item.label)
    }

    /// Значок без выбора агента: по подписи, иначе по виду
    static func defaultSymbol(kind: FactItem.Kind, label: String) -> String {
        labelSymbol(label) ?? kindSymbol(kind)
    }

    /// Значок карточки: выбранный, если такой есть в системе
    static func symbol(for card: FactCard) -> String {
        isAvailable(card.symbol) ? card.symbol : FactCard.defaultSymbol
    }

    static func kindSymbol(_ kind: FactItem.Kind) -> String {
        switch kind {
        case .address: "mappin.and.ellipse"
        case .link: "link"
        case .phone: "phone.fill"
        case .email: "envelope.fill"
        case .code: "number.square.fill"
        case .text: "text.alignleft"
        case .date: "calendar"
        case .number: "number"
        case .wifi: "wifi"
        case .note: "note.text"
        }
    }

    /// Значок по подписи: первое правило, слово которого есть в подписи.
    /// Порядок важен: «Код домофона» — это домофон, а не просто код
    static func labelSymbol(_ label: String) -> String? {
        let words = SearchText.tokens(in: label).map(\.word)
        guard !words.isEmpty else { return nil }
        for rule in labelRules where rule.keywords.contains(where: { keyword in
            words.contains { matches($0, keyword: keyword) }
        }) {
            return rule.symbol
        }
        return nil
    }

    /// Короткие ключи («кв», «wi») — только целым словом, длинные — началом
    /// слова: «этаж» подходит к «этаже», «домофон» — к «домофона»
    private static func matches(_ word: String, keyword: String) -> Bool {
        word == keyword || (keyword.count >= 4 && word.hasPrefix(keyword))
    }

    struct LabelRule: Sendable {
        let keywords: [String]
        let symbol: String
    }

    static let labelRules: [LabelRule] = [
        .init(keywords: ["домофон", "интерком", "intercom", "звонок"], symbol: "bell.and.waves.left.and.right.fill"),
        .init(keywords: ["wifi", "wi", "вайфай", "вай", "роутер", "интернет"], symbol: "wifi"),
        .init(keywords: ["подъезд", "парадная", "вход"], symbol: "door.left.hand.open"),
        .init(keywords: ["квартира", "кв", "апартаменты", "комната"], symbol: "door.left.hand.closed"),
        .init(keywords: ["этаж"], symbol: "stairs"),
        .init(keywords: ["ворота", "калитка", "шлагбаум", "гараж"], symbol: "door.garage.closed"),
        .init(keywords: ["парковка", "паркинг", "машиноместо"], symbol: "parkingsign.circle.fill"),
        .init(keywords: ["машина", "авто", "автомобиль", "госномер"], symbol: "car.fill"),
        .init(keywords: ["пароль", "password", "пин", "pin"], symbol: "lock.fill"),
        .init(keywords: ["ключ", "ключи"], symbol: "key.fill"),
        // Связь раньше адреса: «Городской телефон» — телефон, а не место
        .init(keywords: ["телефон", "тел", "мобильный", "phone"], symbol: "phone.fill"),
        .init(keywords: ["email", "mail", "почта", "имейл", "емейл"], symbol: "envelope.fill"),
        .init(keywords: ["ссылка", "сайт", "url", "link"], symbol: "link"),
        .init(keywords: ["метро", "станция"], symbol: "tram.fill"),
        .init(keywords: ["дом"], symbol: "house.fill"),
        .init(keywords: ["адрес", "улица", "город", "место"], symbol: "mappin.and.ellipse"),
        .init(keywords: ["рождения", "рожд"], symbol: "gift.fill"),
        .init(keywords: ["дата", "срок", "день"], symbol: "calendar"),
        .init(keywords: ["время", "часы", "график"], symbol: "clock.fill"),
        .init(keywords: ["врач", "доктор", "клиника", "больница"], symbol: "stethoscope"),
        .init(keywords: ["карта", "счет", "банк", "реквизиты"], symbol: "creditcard.fill"),
        .init(keywords: ["имя", "контакт", "консьерж", "охрана"], symbol: "person.fill"),
        .init(keywords: ["питомец", "собака", "кошка"], symbol: "pawprint.fill"),
        .init(keywords: ["заметка", "примечание", "комментарий"], symbol: "note.text"),
        .init(keywords: ["код", "шифр", "комбинация"], symbol: "number.square.fill"),
    ]

    /// Значок справа в строке: что сделает касание
    static func actionGlyph(for action: FactItemAction) -> String {
        switch action {
        case .openMaps: "mappin"
        case .openLink: "arrow.up.right"
        case .call: "phone.fill"
        case .mail: "envelope.fill"
        case .copy: "doc.on.doc"
        }
    }

    // Значки карточки на выбор: дом, люди, машина, связь, работа, здоровье, поездки
    static let cardChoices: [String] = [
        "house.fill", "building.2.fill", "door.left.hand.closed", "key.fill",
        "lock.fill", "person.fill", "person.2.fill", "figure.2.and.child.holdinghands",
        "heart.fill", "gift.fill", "car.fill", "parkingsign.circle.fill",
        "fuelpump.fill", "wifi", "tv.fill", "briefcase.fill",
        "building.columns.fill", "graduationcap.fill", "cross.case.fill", "stethoscope",
        "pills.fill", "airplane", "suitcase.fill", "bed.double.fill",
        "fork.knife", "cart.fill", "creditcard.fill", "pawprint.fill",
        "leaf.fill", "dumbbell.fill", "star.fill", FactCard.defaultSymbol,
    ]

    /// Значки поля на выбор: по видам и подписям, без повторов
    static let itemChoices: [String] = {
        var seen = Set<String>()
        let all = FactItem.Kind.allCases.map(kindSymbol) + labelRules.map(\.symbol)
        return all.filter { seen.insert($0).inserted }
    }()

    /// Все имена, которые этот файл может вернуть, — для теста существования
    static var allNames: Set<String> {
        Set(cardChoices + itemChoices + FactItem.Kind.allCases.map(kindSymbol))
            .union(FactItemAction.allCases.map(actionGlyph))
    }

    /// Есть ли такой значок в системе: агент может выдумать имя
    static func isAvailable(_ name: String) -> Bool {
        !name.isEmpty && UIImage(systemName: name) != nil
    }
}
