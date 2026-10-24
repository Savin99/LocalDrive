import SwiftUI

// Геометрия страницы-документа. В референсе медиа шире текста примерно на 6pt —
// эта разница заметна глазу, поэтому вынесена в отдельные константы.
enum FeedPage {
    /// Отступ страницы от краёв экрана
    static let sideInset: CGFloat = 14
    /// Поле текста внутри страницы
    static let textInset: CGFloat = 20
    /// Поле медиа внутри страницы — на 6pt уже, фото выходят шире текста
    static let mediaInset: CGFloat = 14
    /// Вертикальный ритм между блоками (он же зона попадания линии вставки)
    static let blockGap: CGFloat = 14
    /// Зазор между фото в ряду
    static let mediaGap: CGFloat = 4
    /// Радиус миниатюры в ряду
    static let mediaRadius: CGFloat = 4
    static let pageRadius: CGFloat = 18

    static let rowMaxHeight: CGFloat = 320
    static let rowMinHeight: CGFloat = 56
    /// Одиночное фото или видео не растягивается на всю высоту экрана
    static let singleMaxHeight: CGFloat = 300
}
