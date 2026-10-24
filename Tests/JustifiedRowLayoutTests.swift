import XCTest
@testable import LocalDrive

// Раскладка ряда — чистая функция, поэтому проверяется без UI
final class JustifiedRowLayoutTests: XCTestCase {
    private let width: CGFloat = 384

    func testRowFillsFullWidth() {
        let metrics = JustifiedRowMetrics.compute(width: width, aspects: [0.75, 0.75, 0.75])
        let total = metrics.widths.reduce(0, +) + FeedPage.mediaGap * 2

        XCTAssertEqual(total, width, accuracy: 0.01)
        XCTAssertEqual(metrics.leadingInset, 0)
    }

    // Высота выводится из пропорций: три портрета 3:4 дают ~168pt, как в референсе
    func testHeightFollowsAspectRatios() {
        let metrics = JustifiedRowMetrics.compute(width: width, aspects: [0.75, 0.75, 0.75])
        let expected = (width - FeedPage.mediaGap * 2) / (0.75 * 3)

        XCTAssertEqual(metrics.height, expected, accuracy: 0.01)
        XCTAssertGreaterThan(metrics.height, 160)
        XCTAssertLessThan(metrics.height, 180)
    }

    func testWiderPhotoGetsMoreRoom() {
        let metrics = JustifiedRowMetrics.compute(width: width, aspects: [0.5, 1.5])

        XCTAssertEqual(metrics.widths.count, 2)
        XCTAssertEqual(metrics.widths[1] / metrics.widths[0], 3, accuracy: 0.01)
    }

    // Семь фото в одном ряду — легальная композиция, ряд просто становится ниже
    func testLongRowStaysWithinBounds() {
        let metrics = JustifiedRowMetrics.compute(width: width, aspects: Array(repeating: 0.75, count: 7))

        XCTAssertGreaterThanOrEqual(metrics.height, FeedPage.rowMinHeight)
        XCTAssertEqual(metrics.widths.count, 7)
        let total = metrics.widths.reduce(0, +) + FeedPage.mediaGap * 6
        XCTAssertEqual(total, width, accuracy: 0.01)
    }

    // Одиночный портрет не растягивается на всю высоту экрана, а центрируется —
    // так в референсе лежит вертикальное видео
    func testSingleTallItemIsCappedAndCentred() {
        let metrics = JustifiedRowMetrics.compute(width: width, aspects: [0.5])

        XCTAssertEqual(metrics.height, FeedPage.singleMaxHeight)
        XCTAssertEqual(metrics.widths[0], FeedPage.singleMaxHeight * 0.5, accuracy: 0.01)
        XCTAssertEqual(metrics.leadingInset, (width - metrics.widths[0]) / 2, accuracy: 0.01)
    }

    func testSingleWideItemFillsWidth() {
        let metrics = JustifiedRowMetrics.compute(width: width, aspects: [1.5])

        XCTAssertEqual(metrics.widths[0], width, accuracy: 0.01)
        XCTAssertEqual(metrics.leadingInset, 0, accuracy: 0.01)
        XCTAssertEqual(metrics.height, width / 1.5, accuracy: 0.01)
    }

    func testSeamsSitOnEveryJoint() {
        let metrics = JustifiedRowMetrics.compute(width: width, aspects: [1, 1, 1])
        let seams = metrics.seams

        XCTAssertEqual(seams.count, 4)
        XCTAssertEqual(seams.first, 0)
        XCTAssertEqual(seams.last!, width, accuracy: 0.01)
        XCTAssertTrue(zip(seams, seams.dropFirst()).allSatisfy { $0 < $1 })
    }

    func testEmptyRowHasNoHeight() {
        let metrics = JustifiedRowMetrics.compute(width: width, aspects: [])

        XCTAssertEqual(metrics.height, 0)
        XCTAssertTrue(metrics.widths.isEmpty)
    }
}
