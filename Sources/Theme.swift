import SwiftUI

extension Color {
    /// Цвет, меняющийся вместе с системной темой
    init(light: UInt32, dark: UInt32) {
        self = Color(UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    fileprivate convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// Дизайн-система «Стекло» (референсы владельца 19.11.2026, docs/design.md):
// почти чёрный фон с точечной сеткой, стекло на элементах управления,
// монохромный текст и кнопки; цвет — у папок и их свечения, фиолетовый
// акцент — скупо: переключатели и выбранное. Прежняя — в духе ChatGPT (12.10.2026)
enum Theme {
    static let background = Color(light: 0xF2F2F5, dark: 0x0A0A0C)
    static let card = Color(light: 0xFFFFFF, dark: 0x151517)
    /// Фиолетовый — переключатели, выбранное, главное действие меню
    static let accent = Color(light: 0x5B4FE0, dark: 0x8F85FF)

    /// Текст и главные кнопки: почти чёрный днём, почти белый вечером
    static let ink = Color(light: 0x0B0B0D, dark: 0xF4F4F6)
    /// Серая поверхность: чипы, подложки значков
    static let surface = Color(light: 0xE8E8ED, dark: 0x1E1E22)
    /// Пузырь вопроса: днём чёрный с белым текстом, вечером — графит
    static let bubble = Color(light: 0x111113, dark: 0x232327)
    static let bubbleInk = Color(light: 0xFFFFFF, dark: 0xF4F4F6)
    /// Рамка карточек и полей
    static let border = Color(light: 0xE0E0E6, dark: 0x2A2A30)
    /// Фон бокового меню
    static let sidebar = Color(light: 0xF9F9F9, dark: 0x171717)

    /// Обводка миниатюр и разделители — в тёмной теме светлая, а не чёрная
    static let hairline = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.09)

    /// Подложка под иконку или превью
    static let well = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.05)

    struct FolderColor: Identifiable {
        let name: String
        let light: UInt32
        let dark: UInt32

        var id: String { name }
        var color: Color { Color(light: light, dark: dark) }
    }

    // В тёмной теме оттенки чуть светлее, иначе теряются на тёмном фоне
    static let palette: [FolderColor] = [
        .init(name: "indigo", light: 0x4F6BF0, dark: 0x7A8DF8),
        .init(name: "blue", light: 0x3D9BF0, dark: 0x63B2F5),
        .init(name: "teal", light: 0x2EB5A8, dark: 0x45CFC1),
        .init(name: "green", light: 0x57B369, dark: 0x71CE83),
        .init(name: "orange", light: 0xF09C3D, dark: 0xF5B45F),
        .init(name: "pink", light: 0xF06B9B, dark: 0xF589B2),
        .init(name: "purple", light: 0x9B6BF0, dark: 0xB189F5),
        .init(name: "graphite", light: 0x6B7280, dark: 0x9AA1AC),
    ]

    static func color(_ name: String) -> Color {
        palette.first(where: { $0.name == name })?.color ?? accent
    }

    // Иконки на выбор для папок
    static let folderIcons: [String] = [
        "folder.fill", "doc.text.fill", "photo.fill", "creditcard.fill",
        "key.fill", "heart.fill", "briefcase.fill", "house.fill",
        "car.fill", "airplane", "graduationcap.fill", "banknote.fill",
        "shield.fill", "star.fill", "gift.fill", "pawprint.fill",
    ]
}

extension View {
    // Единый стиль карточки: плоская подложка и тонкая рамка, как у карточек
    // ChatGPT. Тень — едва заметная: на белом фоне карточку держит рамка
    func cardStyle(cornerRadius: CGFloat = 20) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    /// Рамка и лёгкая тень для карточек, которые сами обрезают содержимое
    /// по скруглению — превью у них доходит до края
    func cardBorder(cornerRadius: CGFloat) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    /// Главная кнопка: заливка цветом текста, надпись — цветом фона.
    /// В светлой теме чёрная кнопка с белым текстом, в тёмной — наоборот
    func primaryCapsule() -> some View {
        foregroundStyle(Theme.background)
            .background(Theme.ink, in: Capsule())
    }

    /// Второстепенная кнопка: прозрачная капсула с тонкой рамкой
    func secondaryCapsule() -> some View {
        foregroundStyle(Theme.ink)
            .background(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Capsule())
    }
}

// Русские формы множественного числа: pluralize(3, "файл", "файла", "файлов")
func pluralize(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
    let n = abs(count) % 100
    let n1 = n % 10
    if n > 10 && n < 20 { return "\(count) \(many)" }
    if n1 == 1 { return "\(count) \(one)" }
    if n1 >= 2 && n1 <= 4 { return "\(count) \(few)" }
    return "\(count) \(many)"
}
