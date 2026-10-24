import CoreGraphics
import Foundation

/// Сравнение штрихов пальцем в духе распознавателя $1 (Wobbrock, Wilson, Li,
/// 2007): штрих пересэмплируется в 64 точки через равные расстояния,
/// масштабируется по большей стороне (пропорции сохраняются) и сдвигается
/// центром масс в начало координат. Расстояние — среднее расхождение точек
/// с одинаковыми номерами.
///
/// В отличие от $1 поворот не выравнивается: Z, повёрнутая на 90°, — это N.
/// Направление тоже важно: Z, нарисованная с конца, — другой знак
enum StrokeMatcher {
    static let pointCount = 64

    /// Порог совпадения в долях большей стороны знака. Подобран на
    /// синтетических штрихах (Tests/SecretSymbolTests.swift и замер в
    /// docs/navigation.md): Z с наклоном до 12°, дрожью и разными пропорциями
    /// дают до ~0,17, повторы своего знака — до ~0,09, а ближайшие чужие
    /// формы (дуга, «7», N, S, зеркальная Z) — от 0,22
    static let threshold: CGFloat = 0.18

    /// Штрихи, которые почти прямая линия: прогиб меньше этой доли длины.
    /// Такие никогда не знак — это свайп или прокрутка
    static let lineDeviation: CGFloat = 0.2

    /// Нормализованный штрих: 64 точки, большая сторона — 1, центр масс — 0.
    /// nil — если штрих вырожден (точка или меньше двух точек)
    static func normalize(_ points: [CGPoint]) -> [CGPoint]? {
        guard points.count >= 2 else { return nil }
        let resampled = resample(points, count: pointCount)
        guard let bounds = boundingBox(resampled) else { return nil }
        let side = max(bounds.width, bounds.height)
        guard side > 0 else { return nil }
        let scaled = resampled.map { CGPoint(x: $0.x / side, y: $0.y / side) }
        let centroid = centroid(of: scaled)
        return scaled.map { CGPoint(x: $0.x - centroid.x, y: $0.y - centroid.y) }
    }

    /// Среднее расстояние между точками с одинаковыми номерами
    static func distance(_ lhs: [CGPoint], _ rhs: [CGPoint]) -> CGFloat {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
        let total = zip(lhs, rhs).reduce(CGFloat.zero) { sum, pair in
            sum + hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y)
        }
        return total / CGFloat(lhs.count)
    }

    /// Наибольшее отклонение штриха от прямой «начало — конец» в долях её
    /// длины. Прямой свайп — около 0, Z — 0,35–0,5, замкнутый круг — ∞.
    /// Мелкая дрожь пальца на него почти не влияет, в отличие от длины пути
    static func deviation(_ points: [CGPoint]) -> CGFloat {
        guard let first = points.first, let last = points.last else { return 0 }
        let chord = hypot(last.x - first.x, last.y - first.y)
        guard chord >= 1 else { return .infinity }
        let farthest = points.reduce(CGFloat.zero) { result, point in
            // Расстояние до прямой через начало и конец
            let cross = (last.x - first.x) * (first.y - point.y) - (first.x - point.x) * (last.y - first.y)
            return max(result, abs(cross) / chord)
        }
        return farthest / chord
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func centroid(of points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// Точки через равные расстояния вдоль пути — как шаг 1 у $1
    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        let length = zip(points, points.dropFirst()).reduce(CGFloat.zero) { sum, pair in
            sum + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
        }
        guard length > 0 else { return Array(repeating: points[0], count: count) }

        let step = length / CGFloat(count - 1)
        var result = [points[0]]
        result.reserveCapacity(count)
        var travelled: CGFloat = 0
        var previous = points[0]
        var index = 1
        while index < points.count {
            let current = points[index]
            let segment = hypot(current.x - previous.x, current.y - previous.y)
            if segment > 0, travelled + segment >= step {
                let t = (step - travelled) / segment
                let point = CGPoint(
                    x: previous.x + t * (current.x - previous.x),
                    y: previous.y + t * (current.y - previous.y)
                )
                result.append(point)
                // Новая точка становится началом оставшегося отрезка
                previous = point
                travelled = 0
            } else {
                travelled += segment
                previous = current
                index += 1
            }
        }
        // Из-за округления последней точки может не хватить
        while result.count < count { result.append(points[points.count - 1]) }
        return Array(result.prefix(count))
    }
}

/// Секретный знак скрытых папок: несколько образцов одного штриха,
/// уже нормализованных. Штрих засчитывается, если он близок хотя бы к одному
struct SecretSymbol: Codable, Equatable {
    let samples: [[CGPoint]]

    /// Сколько раз рисуют свой знак при создании
    static let sampleCount = 3
    /// Меньше этого (в pt по большей стороне) — случайное касание, а не знак
    static let minimumSide: CGFloat = 80
    /// Свой знак при создании должен заметно отличаться от прямой
    static let minimumDeviation: CGFloat = 0.3

    /// Встроенная Z: сверху слева направо, по диагонали вниз влево, внизу
    /// слева направо. Пропорции разные — масштаб общий для обеих осей,
    /// и широкая Z от квадратной иначе отличалась бы сильнее, чем от N
    static let defaultZ = SecretSymbol(samples: [0.75, 1.0, 1.35, 1.8, 2.4].compactMap { aspect in
        StrokeMatcher.normalize([
            CGPoint(x: 0, y: 0), CGPoint(x: aspect, y: 0),
            CGPoint(x: 0, y: 1), CGPoint(x: aspect, y: 1),
        ])
    })

    init(samples: [[CGPoint]]) {
        self.samples = samples
    }

    /// Знак из сырых штрихов. nil — если какой-то штрих вырожден
    init?(strokes: [[CGPoint]]) {
        let normalized = strokes.compactMap(StrokeMatcher.normalize)
        guard !normalized.isEmpty, normalized.count == strokes.count else { return nil }
        samples = normalized
    }

    /// Расстояние до ближайшего образца, ∞ — если штрих вырожден
    func distance(to stroke: [CGPoint]) -> CGFloat {
        guard let candidate = StrokeMatcher.normalize(stroke) else { return .infinity }
        return samples.map { StrokeMatcher.distance(candidate, $0) }.min() ?? .infinity
    }

    /// Совпадает ли форма штриха, без оглядки на размер и место
    func matchesShape(_ stroke: [CGPoint]) -> Bool {
        StrokeMatcher.deviation(stroke) > StrokeMatcher.lineDeviation
            && distance(to: stroke) <= StrokeMatcher.threshold
    }

    /// Штрих по «Файлам»: крупный, нарисован не у самого края экрана
    /// и совпадает по форме. Прямой свайп и прокрутка знаком не бывают
    func matches(stroke: [CGPoint], in screen: CGSize) -> Bool {
        guard stroke.count >= 5, screen.width > 0, screen.height > 0,
              let bounds = StrokeMatcher.boundingBox(stroke),
              max(bounds.width, bounds.height) >= Self.minimumSide else { return false }
        // У краёв — шапка, строка состояния и полоска «домой»
        let center = CGPoint(x: bounds.midX / screen.width, y: bounds.midY / screen.height)
        guard (0.15...0.85).contains(center.x), (0.15...0.85).contains(center.y) else { return false }
        return matchesShape(stroke)
    }

    // MARK: - Создание своего знака

    enum SampleIssue: Equatable {
        /// Меньше minimumSide
        case tooSmall
        /// Почти прямая: так выглядит обычный свайп
        case tooSimple
        /// Не совпал с уже нарисованными образцами
        case mismatch
    }

    /// Проверка очередного образца при создании знака: годится сам по себе
    /// и совпадает со всеми прежними
    static func check(sample: [CGPoint], against previous: [[CGPoint]]) -> SampleIssue? {
        guard let bounds = StrokeMatcher.boundingBox(sample),
              max(bounds.width, bounds.height) >= minimumSide else { return .tooSmall }
        guard StrokeMatcher.deviation(sample) >= minimumDeviation,
              let normalized = StrokeMatcher.normalize(sample) else { return .tooSimple }
        for other in previous {
            guard let reference = StrokeMatcher.normalize(other),
                  StrokeMatcher.distance(normalized, reference) <= StrokeMatcher.threshold else { return .mismatch }
        }
        return nil
    }
}
