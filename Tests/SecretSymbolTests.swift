import CoreGraphics
import XCTest
@testable import LocalDrive

// Секретный знак скрытых папок и свайп «Файлы → чат» на синтетических
// штрихах: дрожь пальца, наклон, разные размеры, места и пропорции.
// Генератор детерминированный — прогоны одинаковые

/// SplitMix64: воспроизводимые «случайные» штрихи
private struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Формы в единичных координатах экрана (y вниз) и рисование их «пальцем»
private enum Shapes {
    static func z(aspect: CGFloat = 1.3) -> [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: aspect, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: aspect, y: 1)]
    }

    /// Z, повёрнутая на 90° по часовой, — по сути N
    static let n = [CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 0)]
    static let mirroredZ = [CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    static let seven = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0.2, y: 1)]
    static let l = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
    static let v = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 1), CGPoint(x: 1, y: 0)]
    static let rightLine = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)]
    static let verticalLine = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1)]
    static let diagonal = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]

    static var s: [CGPoint] {
        let top = stride(from: 0.1, through: 1.5, by: 0.05).map { a -> CGPoint in
            let angle = CGFloat(a) * .pi
            return CGPoint(x: 0.5 + 0.5 * cos(angle), y: 0.25 - 0.25 * sin(angle))
        }
        let bottom = stride(from: 0.5, through: -0.9, by: -0.05).map { a -> CGPoint in
            let angle = CGFloat(a) * .pi
            return CGPoint(x: 0.5 + 0.5 * cos(angle), y: 0.75 - 0.25 * sin(angle))
        }
        return top + bottom
    }

    static var circle: [CGPoint] {
        stride(from: 0.0, through: 2.0, by: 0.04).map { t in
            CGPoint(x: cos(CGFloat(t) * .pi), y: sin(CGFloat(t) * .pi))
        }
    }

    /// Петля «альфа» — пример своего знака
    static var alpha: [CGPoint] {
        stride(from: 0.0, through: 1.0, by: 0.01).map { value in
            let t = CGFloat(value)
            return CGPoint(x: cos(2 * .pi * t + .pi) * (1 - 0.2 * t) + 0.8 * t, y: 0.6 * sin(2 * .pi * t))
        }
    }

    static var star: [CGPoint] {
        (0...5).map { index in
            let angle = -CGFloat.pi / 2 + CGFloat(index) * 4 * .pi / 5
            return CGPoint(x: cos(angle), y: sin(angle))
        }
    }

    /// Прокрутка большим пальцем: почти вертикаль с лёгким прогибом
    static var scrollArc: [CGPoint] {
        stride(from: 0.0, through: 1.0, by: 0.025).map { t in
            CGPoint(x: 0.1 * sin(CGFloat(t) * .pi), y: CGFloat(t))
        }
    }

    /// Нарисовать форму пальцем: большая сторона `size` pt, центр рамки
    /// в `center`, наклон, плавная дрожь (доля размера), мелкий шум и
    /// неравномерная частота точек, как у быстрого и медленного движения
    static func draw(
        _ shape: [CGPoint],
        size: CGFloat,
        center: CGPoint,
        tilt degrees: CGFloat = 0,
        wobble: CGFloat = 0,
        noise: CGFloat = 0,
        using random: inout SeededRandom
    ) -> [CGPoint] {
        // Гуще точки по отрезкам
        var dense: [CGPoint] = []
        for (from, to) in zip(shape, shape.dropFirst()) {
            for step in 0..<20 {
                let t = CGFloat(step) / 20
                dense.append(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            }
        }
        dense.append(shape[shape.count - 1])

        let bounds = StrokeMatcher.boundingBox(dense)!
        let scale = size / max(bounds.width, bounds.height)
        let angle = degrees * .pi / 180
        let controls = (0..<6).map { _ in
            CGPoint(
                x: CGFloat.random(in: -1...1, using: &random) * wobble * size,
                y: CGFloat.random(in: -1...1, using: &random) * wobble * size
            )
        }

        var points = dense.enumerated().map { index, point -> CGPoint in
            let x = (point.x - bounds.midX) * scale
            let y = (point.y - bounds.midY) * scale
            // Плавная дрожь: линейно между шестью опорными смещениями
            let position = CGFloat(index) / CGFloat(max(dense.count - 1, 1)) * 5
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, 5)
            let fraction = position - CGFloat(lower)
            let offset = CGPoint(
                x: controls[lower].x * (1 - fraction) + controls[upper].x * fraction,
                y: controls[lower].y * (1 - fraction) + controls[upper].y * fraction
            )
            return CGPoint(
                x: center.x + x * cos(angle) - y * sin(angle) + offset.x
                    + CGFloat.random(in: -1...1, using: &random) * noise * size,
                y: center.y + x * sin(angle) + y * cos(angle) + offset.y
                    + CGFloat.random(in: -1...1, using: &random) * noise * size
            )
        }
        // Часть точек теряется: палец двигался быстро
        let keep = CGFloat.random(in: 0.3...1, using: &random)
        points = points.enumerated().compactMap { index, point in
            index == 0 || index == points.count - 1 || CGFloat.random(in: 0...1, using: &random) < keep ? point : nil
        }
        return points
    }
}

final class SecretSymbolTests: XCTestCase {
    private let screen = CGSize(width: 390, height: 844)
    private var center: CGPoint { CGPoint(x: screen.width / 2, y: screen.height / 2) }

    /// Естественная Z: пропорции, наклон, дрожь, размер и место — разные
    private func naturalZ(_ random: inout SeededRandom) -> [CGPoint] {
        let aspect = CGFloat.random(in: 0.75...2.0, using: &random)
        let corners = Shapes.z(aspect: aspect).map { point in
            CGPoint(
                x: point.x + CGFloat.random(in: -0.08...0.08, using: &random) * aspect,
                y: point.y + CGFloat.random(in: -0.08...0.08, using: &random)
            )
        }
        return Shapes.draw(
            corners,
            size: .random(in: 130...320, using: &random),
            center: CGPoint(
                x: center.x + .random(in: -40...40, using: &random),
                y: center.y + .random(in: -150...150, using: &random)
            ),
            tilt: .random(in: -10...10, using: &random),
            wobble: 0.02,
            noise: 0.004,
            using: &random
        )
    }

    // MARK: - Встроенная Z (перенесено из ZGestureRecognizerTests)

    func testRecognizesCenteredZSwipe() {
        let points = [
            CGPoint(x: 80, y: 270), CGPoint(x: 130, y: 268),
            CGPoint(x: 190, y: 272), CGPoint(x: 250, y: 269), CGPoint(x: 310, y: 272),
            CGPoint(x: 265, y: 300), CGPoint(x: 220, y: 330),
            CGPoint(x: 170, y: 360), CGPoint(x: 120, y: 390), CGPoint(x: 82, y: 410),
            CGPoint(x: 145, y: 412), CGPoint(x: 220, y: 408), CGPoint(x: 310, y: 411),
        ]

        XCTAssertTrue(SecretSymbol.defaultZ.matches(stroke: points, in: screen))
    }

    func testRejectsOrdinaryVerticalScroll() {
        let points = stride(from: 250.0, through: 500.0, by: 25.0).map {
            CGPoint(x: 195, y: $0)
        }

        XCTAssertFalse(SecretSymbol.defaultZ.matches(stroke: points, in: screen))
    }

    func testRejectsZDrawnAtTopEdge() {
        let points = [
            CGPoint(x: 40, y: 20), CGPoint(x: 110, y: 20), CGPoint(x: 190, y: 20),
            CGPoint(x: 270, y: 20), CGPoint(x: 210, y: 60), CGPoint(x: 150, y: 100),
            CGPoint(x: 80, y: 140), CGPoint(x: 150, y: 140), CGPoint(x: 220, y: 140),
            CGPoint(x: 300, y: 140),
        ]

        XCTAssertFalse(SecretSymbol.defaultZ.matches(stroke: points, in: screen))
    }

    // MARK: - Встроенная Z на синтетических штрихах

    func testAcceptsNaturalRedrawsOfZ() {
        var random = SeededRandom(seed: 1)
        var worst: CGFloat = 0
        for _ in 0..<300 {
            let stroke = naturalZ(&random)
            worst = max(worst, SecretSymbol.defaultZ.distance(to: stroke))
            XCTAssertTrue(SecretSymbol.defaultZ.matches(stroke: stroke, in: screen))
        }
        // Запас до порога: естественная Z не ходит по краю
        XCTAssertLessThan(worst, StrokeMatcher.threshold)
    }

    func testRejectsOtherShapesAndPlainGestures() {
        var random = SeededRandom(seed: 2)
        let others: [(String, [CGPoint])] = [
            ("N", Shapes.n), ("S", Shapes.s), ("зеркальная Z", Shapes.mirroredZ),
            ("Z с конца", Shapes.z().reversed()), ("7", Shapes.seven), ("L", Shapes.l),
            ("V", Shapes.v), ("круг", Shapes.circle), ("свайп вправо", Shapes.rightLine),
            ("вертикаль", Shapes.verticalLine), ("диагональ", Shapes.diagonal),
            ("прокрутка дугой", Shapes.scrollArc),
        ]
        for (name, shape) in others {
            for _ in 0..<40 {
                let stroke = Shapes.draw(
                    shape,
                    size: .random(in: 130...320, using: &random),
                    center: center,
                    tilt: .random(in: -10...10, using: &random),
                    wobble: 0.02,
                    noise: 0.004,
                    using: &random
                )
                XCTAssertFalse(SecretSymbol.defaultZ.matches(stroke: stroke, in: screen), "\(name) принят за Z")
            }
        }
    }

    func testIsNotRotationInvariant() {
        var random = SeededRandom(seed: 3)
        let tilted = Shapes.draw(Shapes.z(aspect: 1.2), size: 220, center: center, tilt: 10, using: &random)
        let rotated = Shapes.draw(Shapes.z(aspect: 1.2), size: 220, center: center, tilt: 90, using: &random)
        XCTAssertTrue(SecretSymbol.defaultZ.matches(stroke: tilted, in: screen), "наклон 10° — та же Z")
        XCTAssertFalse(SecretSymbol.defaultZ.matches(stroke: rotated, in: screen), "Z на боку — это N")
    }

    func testSizeAndPlacement() {
        var random = SeededRandom(seed: 4)
        let small = Shapes.draw(Shapes.z(), size: 60, center: center, using: &random)
        let corner = Shapes.draw(Shapes.z(), size: 150, center: CGPoint(x: 70, y: 80), using: &random)
        XCTAssertFalse(SecretSymbol.defaultZ.matches(stroke: small, in: screen), "мелкий штрих — случайность")
        XCTAssertFalse(SecretSymbol.defaultZ.matches(stroke: corner, in: screen), "у края — шапка и строка состояния")
        for (size, x, y) in [(130.0, 150.0, 300.0), (300.0, 200.0, 420.0), (200.0, 240.0, 600.0)] {
            let stroke = Shapes.draw(Shapes.z(), size: size, center: CGPoint(x: x, y: y), using: &random)
            XCTAssertTrue(SecretSymbol.defaultZ.matches(stroke: stroke, in: screen), "Z \(size) pt в (\(x), \(y))")
        }
    }

    // MARK: - Свой знак

    private func userSamples(_ shape: [CGPoint], _ random: inout SeededRandom) -> [[CGPoint]] {
        (0..<SecretSymbol.sampleCount).map { _ in
            Shapes.draw(
                shape,
                size: .random(in: 200...300, using: &random),
                center: CGPoint(x: 195, y: 380),
                tilt: .random(in: -6...6, using: &random),
                wobble: 0.015,
                noise: 0.003,
                using: &random
            )
        }
    }

    func testOwnSymbolAcceptsRedrawsAndRejectsEverythingElse() throws {
        for (name, shape) in [("альфа", Shapes.alpha), ("звезда", Shapes.star)] {
            var random = SeededRandom(seed: 5)
            let samples = userSamples(shape, &random)
            for index in samples.indices {
                XCTAssertNil(SecretSymbol.check(sample: samples[index], against: Array(samples[..<index])), name)
            }
            let symbol = try XCTUnwrap(SecretSymbol(strokes: samples))

            for _ in 0..<100 {
                let redraw = Shapes.draw(
                    shape,
                    size: .random(in: 120...320, using: &random),
                    center: CGPoint(
                        x: center.x + .random(in: -40...40, using: &random),
                        y: center.y + .random(in: -150...150, using: &random)
                    ),
                    tilt: .random(in: -6...6, using: &random),
                    wobble: 0.015,
                    noise: 0.003,
                    using: &random
                )
                XCTAssertTrue(symbol.matches(stroke: redraw, in: screen), "\(name): повтор не узнан")
            }

            let others: [[CGPoint]] = [
                Shapes.z(), Shapes.n, Shapes.s, Shapes.circle, Shapes.rightLine,
                Shapes.verticalLine, Shapes.scrollArc, shape.reversed(),
                name == "альфа" ? Shapes.star : Shapes.alpha,
            ]
            for other in others {
                let stroke = Shapes.draw(other, size: 220, center: center, wobble: 0.02, using: &random)
                XCTAssertFalse(symbol.matches(stroke: stroke, in: screen), "\(name): чужой штрих принят")
            }
            // Свой знак заменяет Z
            XCTAssertFalse(symbol.matches(stroke: naturalZ(&random), in: screen))
        }
    }

    func testSampleChecksWhenCreatingSymbol() {
        var random = SeededRandom(seed: 6)
        let z = Shapes.draw(Shapes.z(), size: 220, center: center, using: &random)
        let n = Shapes.draw(Shapes.n, size: 220, center: center, using: &random)
        let tiny = Shapes.draw(Shapes.z(), size: 50, center: center, using: &random)
        let line = Shapes.draw(Shapes.rightLine, size: 250, center: center, wobble: 0.01, using: &random)
        let arc = Shapes.draw(Shapes.scrollArc, size: 250, center: center, using: &random)

        XCTAssertNil(SecretSymbol.check(sample: z, against: []))
        XCTAssertEqual(SecretSymbol.check(sample: tiny, against: []), .tooSmall)
        XCTAssertEqual(SecretSymbol.check(sample: line, against: []), .tooSimple)
        XCTAssertEqual(SecretSymbol.check(sample: arc, against: []), .tooSimple)
        XCTAssertEqual(SecretSymbol.check(sample: n, against: [z]), .mismatch)
    }

    func testNormalizationIgnoresSizeAndPositionButKeepsDirection() throws {
        let stroke = Shapes.z().map { CGPoint(x: $0.x * 100 + 20, y: $0.y * 100 + 40) }
        let bigger = Shapes.z().map { CGPoint(x: $0.x * 300 + 90, y: $0.y * 300 + 200) }
        let a = try XCTUnwrap(StrokeMatcher.normalize(stroke))
        let b = try XCTUnwrap(StrokeMatcher.normalize(bigger))
        let reversed = try XCTUnwrap(StrokeMatcher.normalize(stroke.reversed()))

        XCTAssertEqual(a.count, StrokeMatcher.pointCount)
        XCTAssertLessThan(StrokeMatcher.distance(a, b), 0.001)
        XCTAssertGreaterThan(StrokeMatcher.distance(a, reversed), 0.5)
        XCTAssertNil(StrokeMatcher.normalize([CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)]))
    }

    // MARK: - Свайп «Файлы → чат»

    private func stroke(_ points: [CGPoint], velocity: CGFloat = 300, onStrip: Bool = false) -> FilesStroke {
        FilesStroke(
            points: points,
            velocity: CGPoint(x: velocity, y: 0),
            screen: screen,
            startedOnHorizontalScroll: onStrip
        )
    }

    private func line(from start: CGPoint, by delta: CGVector, bow: CGFloat = 0) -> [CGPoint] {
        (0...40).map { index in
            let t = CGFloat(index) / 40
            return CGPoint(x: start.x + delta.dx * t, y: start.y + delta.dy * t - bow * sin(t * .pi))
        }
    }

    func testRightSwipeFromMiddleReturnsToChat() {
        let start = CGPoint(x: 120, y: 420)
        XCTAssertTrue(stroke(line(from: start, by: CGVector(dx: 200, dy: 10))).returnsToChat, "дальше трети ширины")
        XCTAssertTrue(stroke(line(from: start, by: CGVector(dx: 220, dy: -30), bow: 25)).returnsToChat, "дуга большого пальца")
        XCTAssertTrue(stroke(line(from: start, by: CGVector(dx: 70, dy: 4)), velocity: 900).returnsToChat, "быстрый взмах")
        XCTAssertFalse(stroke(line(from: start, by: CGVector(dx: 70, dy: 4)), velocity: 300).returnsToChat, "короткий и медленный")
    }

    func testOtherStrokesDoNotTurnThePage() {
        let start = CGPoint(x: 200, y: 420)
        var random = SeededRandom(seed: 7)
        XCTAssertFalse(stroke(line(from: start, by: CGVector(dx: -200, dy: 0)), velocity: -900).returnsToChat, "влево")
        XCTAssertFalse(stroke(line(from: start, by: CGVector(dx: 10, dy: -300)), velocity: 50).returnsToChat, "прокрутка")
        XCTAssertFalse(stroke(line(from: start, by: CGVector(dx: 150, dy: 150)), velocity: 700).returnsToChat, "диагональ")
        XCTAssertFalse(stroke(line(from: start, by: CGVector(dx: 200, dy: 0)), velocity: 900, onStrip: true).returnsToChat, "лента «Недавнее»")
        for _ in 0..<50 {
            XCTAssertFalse(stroke(naturalZ(&random), velocity: 900).returnsToChat, "Z увела к чату")
        }
    }

    /// Свайп и знак не путаются: прямой свайп никогда не знак, даже свой
    func testSwipesNeverMatchSymbols() throws {
        var random = SeededRandom(seed: 8)
        let own = try XCTUnwrap(SecretSymbol(strokes: userSamples(Shapes.alpha, &random)))
        for _ in 0..<100 {
            let swipe = Shapes.draw(
                Shapes.rightLine,
                size: .random(in: 120...330, using: &random),
                center: CGPoint(x: 200, y: .random(in: 250...600, using: &random)),
                tilt: .random(in: -12...12, using: &random),
                wobble: 0.03,
                noise: 0.004,
                using: &random
            )
            XCTAssertFalse(SecretSymbol.defaultZ.matches(stroke: swipe, in: screen))
            XCTAssertFalse(own.matches(stroke: swipe, in: screen))
        }
    }
}

// MARK: - Пароль и хранение

final class PasswordHashTests: XCTestCase {
    func testVerifiesOnlyTheRightPassword() throws {
        let record = try XCTUnwrap(PasswordHash.make(password: "Тайна-42", rounds: 1_000))
        XCTAssertTrue(record.verify("Тайна-42"))
        XCTAssertFalse(record.verify("тайна-42"))
        XCTAssertFalse(record.verify("Тайна-4"))
        XCTAssertFalse(record.verify(""))
    }

    func testSaltIsRandomAndRoundsAreStrong() throws {
        let first = try XCTUnwrap(PasswordHash.make(password: "secret", rounds: 1_000))
        let second = try XCTUnwrap(PasswordHash.make(password: "secret", rounds: 1_000))
        XCTAssertNotEqual(first.salt, second.salt)
        XCTAssertNotEqual(first.hash, second.hash)
        XCTAssertEqual(first.salt.count, 16)
        XCTAssertEqual(first.hash.count, 32)

        XCTAssertGreaterThanOrEqual(PasswordHash.defaultRounds, 100_000)
        let strong = try XCTUnwrap(PasswordHash.make(password: "secret"))
        XCTAssertEqual(strong.rounds, PasswordHash.defaultRounds)
        XCTAssertTrue(strong.verify("secret"))
    }

    /// Известный вектор PBKDF2-HMAC-SHA256 (RFC 7914, раздел 11)
    func testMatchesReferenceVector() throws {
        let derived = try XCTUnwrap(PasswordHash.derive(password: "passwd", salt: Data("salt".utf8), rounds: 1))
        XCTAssertEqual(
            derived.map { String(format: "%02x", $0) }.joined(),
            "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc"
        )
    }

    func testComposedAndDecomposedLettersAreTheSamePassword() throws {
        let record = try XCTUnwrap(PasswordHash.make(password: "\u{0451}лка", rounds: 1_000))
        XCTAssertTrue(record.verify("\u{0435}\u{0308}лка"))
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(PasswordHash.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(PasswordHash.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(PasswordHash.constantTimeEquals(Data([1, 2, 3]), Data([1, 2])))
    }
}

@MainActor
final class HiddenFoldersTests: XCTestCase {
    private var directory: URL!
    private var symbolStore: SecretStore!
    private var passwordStore: SecretStore!
    private let screen = CGSize(width: 390, height: 844)

    override func setUp() async throws {
        let id = UUID().uuidString
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HiddenFoldersTests-\(id)")
        symbolStore = SecretStore(service: "com.ilyaqa.localdrive.tests.symbol.\(id)", fileName: "symbol.dat", directory: directory)
        passwordStore = SecretStore(service: "com.ilyaqa.localdrive.tests.password.\(id)", fileName: "password.dat", directory: directory)
    }

    override func tearDown() async throws {
        symbolStore.delete()
        passwordStore.delete()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFolders() -> HiddenFolders {
        HiddenFolders(symbolStore: symbolStore, passwordStore: passwordStore, rounds: 1_000)
    }

    private var zStroke: [CGPoint] {
        var random = SeededRandom(seed: 10)
        return Shapes.draw(Shapes.z(aspect: 1.2), size: 220, center: CGPoint(x: 195, y: 400), wobble: 0.01, using: &random)
    }

    private func ownSymbol() throws -> (symbol: SecretSymbol, stroke: [CGPoint]) {
        var random = SeededRandom(seed: 9)
        let samples = (0..<3).map { _ in
            Shapes.draw(Shapes.alpha, size: 240, center: CGPoint(x: 195, y: 400), wobble: 0.01, using: &random)
        }
        return (try XCTUnwrap(SecretSymbol(strokes: samples)), samples[0])
    }

    func testRevealsWithDefaultZAndHidesAgain() {
        let folders = makeFolders()
        XCTAssertFalse(folders.isRevealed)
        XCTAssertFalse(folders.hasCustomSymbol)
        XCTAssertFalse(folders.hasPassword)

        XCTAssertTrue(folders.revealIfRecognized(zStroke, in: screen))
        XCTAssertTrue(folders.isRevealed)
        XCTAssertEqual(folders.revealCount, 1)
        XCTAssertFalse(folders.revealIfRecognized(zStroke, in: screen), "уже открыты")

        folders.hide()
        XCTAssertFalse(folders.isRevealed)
        XCTAssertFalse(makeFolders().isRevealed, "после перезапуска папки спрятаны")
    }

    func testFirstOwnSymbolRequiresNewPassword() async throws {
        let folders = makeFolders()
        let own = try ownSymbol()

        let shortPasswordSaved = await folders.saveSymbol(own.symbol, password: "abc")
        XCTAssertFalse(shortPasswordSaved)
        XCTAssertFalse(folders.hasCustomSymbol)

        let saved = await folders.saveSymbol(own.symbol, password: "секрет")
        XCTAssertTrue(saved)
        XCTAssertTrue(folders.hasCustomSymbol)
        XCTAssertTrue(folders.hasPassword)
        XCTAssertFalse(folders.revealIfRecognized(zStroke, in: screen), "Z больше не открывает")
        XCTAssertTrue(folders.revealIfRecognized(own.stroke, in: screen))

        // Пароль не лежит в хранилище открытым текстом
        let stored = try XCTUnwrap(passwordStore.load())
        XCTAssertNil(stored.range(of: Data("секрет".utf8)))
    }

    func testChangingSymbolAndResetNeedCurrentPassword() async throws {
        let folders = makeFolders()
        let own = try ownSymbol()
        _ = await folders.saveSymbol(own.symbol, password: "секрет")

        let wrongSave = await folders.saveSymbol(SecretSymbol.defaultZ, password: "чужой")
        XCTAssertFalse(wrongSave)
        XCTAssertTrue(folders.revealIfRecognized(own.stroke, in: screen), "знак не сменился без пароля")
        folders.hide()

        let wrongReset = await folders.resetSymbol(password: "чужой")
        XCTAssertFalse(wrongReset)
        XCTAssertTrue(folders.hasCustomSymbol)

        let reset = await folders.resetSymbol(password: "секрет")
        XCTAssertTrue(reset)
        XCTAssertFalse(folders.hasCustomSymbol)
        XCTAssertTrue(folders.hasPassword, "пароль остаётся")
        XCTAssertTrue(folders.revealIfRecognized(zStroke, in: screen))
    }

    func testRevealAndChangePassword() async throws {
        let folders = makeFolders()
        let own = try ownSymbol()
        _ = await folders.saveSymbol(own.symbol, password: "секрет")

        let wrong = await folders.reveal(password: "чужой")
        XCTAssertFalse(wrong)
        XCTAssertFalse(folders.isRevealed)

        let right = await folders.reveal(password: "секрет")
        XCTAssertTrue(right)
        XCTAssertTrue(folders.isRevealed)
        let again = await folders.reveal(password: "секрет")
        XCTAssertTrue(again)
        XCTAssertEqual(folders.revealCount, 2, "повторное открытие снова ведёт к «Файлам»")

        let changedWithWrongOld = await folders.changePassword(current: "чужой", new: "новый пароль")
        XCTAssertFalse(changedWithWrongOld)
        let changed = await folders.changePassword(current: "секрет", new: "новый пароль")
        XCTAssertTrue(changed)
        let oldAfterChange = await folders.verify("секрет")
        XCTAssertFalse(oldAfterChange)
        let newAfterChange = await folders.verify("новый пароль")
        XCTAssertTrue(newAfterChange)
    }

    func testSymbolAndPasswordSurviveRelaunch() async throws {
        let own = try ownSymbol()
        let first = makeFolders()
        _ = await first.saveSymbol(own.symbol, password: "секрет")

        let relaunched = makeFolders()
        XCTAssertTrue(relaunched.hasCustomSymbol)
        XCTAssertTrue(relaunched.hasPassword)
        XCTAssertFalse(relaunched.isRevealed)
        XCTAssertTrue(relaunched.revealIfRecognized(own.stroke, in: screen))
    }

    func testSecretStoreRoundTrip() {
        XCTAssertNil(symbolStore.load())
        XCTAssertTrue(symbolStore.save(Data([1, 2, 3])))
        XCTAssertEqual(symbolStore.load(), Data([1, 2, 3]))
        symbolStore.delete()
        XCTAssertNil(symbolStore.load())
    }
}
