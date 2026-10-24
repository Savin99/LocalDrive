import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Штрих по корню «Файлов» целиком, от касания до отпускания. Что это было,
/// решается только в конце: секретный знак открывает скрытые папки, прямой
/// свайп вправо листает к чату, остальное — прокрутка и нажатия — идёт своим
/// чередом. Пока палец рисует, ничего не двигается и следа нет: по экрану не
/// видно, знак это или неудачный свайп.
///
/// Распознаватель UIKit, а не DragGesture (docs/navigation.md, «Что
/// выяснено»): он работает вместе с прокруткой, а начавшись после ~10 pt
/// движения, отменяет нажатие под пальцем — знак, начатый на карточке папки,
/// папку не открывает
struct FilesStrokeGesture: UIGestureRecognizerRepresentable {
    /// Полоса у левого края принадлежит листанию за пальцем (PagerPan)
    let edgeWidth: CGFloat
    /// Корень «Файлов» на экране, страницы стоят
    let isActive: () -> Bool
    let onEnd: (FilesStroke) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(isActive: isActive, edgeWidth: edgeWidth)
    }

    func makeUIGestureRecognizer(context: Context) -> StrokeRecognizer {
        let recognizer = StrokeRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: StrokeRecognizer, context: Context) {
        context.coordinator.isActive = isActive
    }

    func handleUIGestureRecognizerAction(_ recognizer: StrokeRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        onEnd(FilesStroke(
            points: recognizer.points,
            velocity: recognizer.velocity(in: nil),
            screen: recognizer.view?.window?.bounds.size ?? .zero,
            startedOnHorizontalScroll: context.coordinator.startedOnHorizontalScroll
        ))
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isActive: () -> Bool
        private let edgeWidth: CGFloat
        private(set) var startedOnHorizontalScroll = false

        /// Палец столько простоял на месте — это долгое нажатие (меню папки),
        /// а не штрих
        private static let holdLimit: TimeInterval = 0.45

        init(isActive: @escaping () -> Bool, edgeWidth: CGFloat) {
            self.isActive = isActive
            self.edgeWidth = edgeWidth
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard isActive(), touch.location(in: nil).x >= edgeWidth else { return false }
            // Лента «Недавнее» листается вбок сама — там свайп не уводит к чату
            startedOnHorizontalScroll = Self.isInsideHorizontalScroll(touch.view)
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Время по меткам самих касаний, а не по часам: занятый главный
            // поток не должен превращать быстрый штрих в долгое нажатие
            guard let stroke = gestureRecognizer as? StrokeRecognizer else { return true }
            return stroke.holdBeforeMoving < Self.holdLimit
        }

        /// Прокрутка папок и ленты работает вместе со штрихом
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer
        }

        private static func isInsideHorizontalScroll(_ view: UIView?) -> Bool {
            var current = view
            while let view = current {
                if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 {
                    return true
                }
                current = view.superview
            }
            return false
        }
    }
}

/// Пан, который помнит весь путь пальца в координатах окна, включая
/// промежуточные точки между кадрами.
///
/// Нажатие кнопки папки начинается раньше, чем штрих (палец ещё не сдвинулся):
/// в симуляторе распознаватель жестов SwiftUI под пальцем уже в состоянии
/// «идёт», когда штрих только начинается. Поэтому штрих не может быть отменён
/// другими, а сам, начавшись, прерывает идущие нажатия под пальцем — иначе
/// знак, начатый и законченный на одной карточке, открыл бы папку
final class StrokeRecognizer: UIPanGestureRecognizer {
    private(set) var points: [CGPoint] = []
    /// Сколько палец стоял на месте, прежде чем сдвинуться на ~10 pt
    private(set) var holdBeforeMoving: TimeInterval = 0
    private var touchDownTime: TimeInterval?
    private var hasCancelledPresses = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if points.isEmpty, let touch = touches.first {
            points.append(touch.location(in: nil))
            touchDownTime = touch.timestamp
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        record(touches, event: event)
        super.touchesMoved(touches, with: event)
        if state == .began, !hasCancelledPresses, let touch = touches.first {
            hasCancelledPresses = true
            cancelPresses(under: touch)
        }
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        record(touches, event: event)
        super.touchesEnded(touches, with: event)
    }

    override func reset() {
        super.reset()
        points.removeAll(keepingCapacity: true)
        holdBeforeMoving = 0
        touchDownTime = nil
        hasCancelledPresses = false
    }

    /// Выключить и включить — штатный способ UIKit прервать распознаватель.
    /// Только уже идущие нажатия внутри страницы: прокрутку (паны и служебные
    /// распознаватели UIScrollView) и системные жесты окна не трогаем
    private func cancelPresses(under touch: UITouch) {
        guard let root = view else { return }
        for other in touch.gestureRecognizers ?? [] where other !== self && !(other is UIPanGestureRecognizer) {
            guard other.isEnabled, other.state == .began || other.state == .changed,
                  let owner = other.view, owner.isDescendant(of: root), !(owner is UIScrollView) else { continue }
            other.isEnabled = false
            other.isEnabled = true
        }
    }

    private func record(_ touches: Set<UITouch>, event: UIEvent) {
        guard let touch = touches.first else { return }
        let samples = event.coalescedTouches(for: touch) ?? [touch]
        for sample in samples {
            let point = sample.location(in: nil)
            if let start = points.first, let down = touchDownTime,
               hypot(point.x - start.x, point.y - start.y) < 10 {
                holdBeforeMoving = sample.timestamp - down
            }
            points.append(point)
        }
    }
}

/// Законченный штрих по «Файлам» в координатах окна
struct FilesStroke {
    let points: [CGPoint]
    let velocity: CGPoint
    let screen: CGSize
    let startedOnHorizontalScroll: Bool

    /// Порог листания — как у свайпа за пальцем в MainView: больше трети
    /// ширины экрана или взмах быстрее 600 pt/с
    static let pageFraction: CGFloat = 0.3
    static let flingVelocity: CGFloat = 600

    /// Свайп вправо, который возвращает к чату: явно горизонтальный (вбок
    /// вдвое больше, чем по вертикали — как у листания за пальцем) и почти
    /// прямой. Знак так не выглядит: у него прогиб больше
    /// StrokeMatcher.lineDeviation
    var returnsToChat: Bool {
        guard !startedOnHorizontalScroll, screen.width > 0,
              let first = points.first, let last = points.last else { return false }
        let dx = last.x - first.x
        let dy = last.y - first.y
        guard dx > 0, dx > 2 * abs(dy),
              StrokeMatcher.deviation(points) <= StrokeMatcher.lineDeviation else { return false }
        return dx > screen.width * Self.pageFraction || velocity.x > Self.flingVelocity
    }
}
