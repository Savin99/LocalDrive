import XCTest
@testable import LocalDrive

// Разбор разметки и правки от панели форматирования — чистые функции,
// поэтому проверяются без UITextView
final class FeedMarkdownTests: XCTestCase {
    private let style = FeedMarkdown.Style.standard(body: .systemFont(ofSize: 17))

    // MARK: - Готовый вид

    func testHeadingLosesHashes() {
        let rendered = FeedMarkdown.rendered("# Заголовок", style: style)

        XCTAssertEqual(rendered.text.string, "Заголовок")
        // Первый символ готового текста — это третий символ исходника
        XCTAssertEqual(rendered.sourceOffset(for: 0), 2)
    }

    func testBoldLosesAsterisks() {
        let rendered = FeedMarkdown.rendered("**жирный**", style: style)

        XCTAssertEqual(rendered.text.string, "жирный")
        XCTAssertEqual(rendered.sourceOffset(for: 0), 2)
    }

    func testBulletGetsMarker() {
        let rendered = FeedMarkdown.rendered("- пункт", style: style)

        XCTAssertEqual(rendered.text.string, "•  пункт")
        // Маркера нет в исходнике — вся его ширина указывает на начало пункта
        XCTAssertEqual(rendered.sourceOffset(for: 0), 2)
        XCTAssertEqual(rendered.sourceOffset(for: 3), 2)
    }

    func testNumberedKeepsOwnNumber() {
        XCTAssertEqual(FeedMarkdown.rendered("3. пункт", style: style).text.string, "3.  пункт")
    }

    func testNewlinesSurviveRendering() {
        let rendered = FeedMarkdown.rendered("# Дела\n- раз\n- два", style: style)

        XCTAssertEqual(rendered.text.string, "Дела\n•  раз\n•  два")
    }

    // Подчёркивания внутри слова курсивом не считаются
    func testSnakeCaseStaysPlain() {
        XCTAssertEqual(FeedMarkdown.rendered("файл_с_именем", style: style).text.string, "файл_с_именем")
    }

    func testItalicLosesUnderscores() {
        XCTAssertEqual(FeedMarkdown.rendered("_курсив_", style: style).text.string, "курсив")
    }

    // В фокусе служебные символы остаются на месте
    func testStyledSourceKeepsSyntax() {
        let styled = FeedMarkdown.styledSource("## Дела\n**жирный**", style: style)

        XCTAssertEqual(styled.string, "## Дела\n**жирный**")
    }

    func testHeadingIsBigger() {
        let rendered = FeedMarkdown.rendered("# Заголовок", style: style)
        let font = rendered.text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont

        XCTAssertNotNil(font)
        XCTAssertGreaterThan(font?.pointSize ?? 0, style.body.pointSize)
    }

    // MARK: - Жирный и курсив

    func testBoldWrapsSelection() {
        let edit = FeedMarkdownEditing.toggleEmphasis("**", in: "текст", selection: NSRange(location: 0, length: 5))

        XCTAssertEqual(edit.text, "**текст**")
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 5))
    }

    func testBoldUnwrapsSelection() {
        let edit = FeedMarkdownEditing.toggleEmphasis("**", in: "**текст**", selection: NSRange(location: 2, length: 5))

        XCTAssertEqual(edit.text, "текст")
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: 5))
    }

    func testBoldUnwrapsWhenMarkersAreSelected() {
        let edit = FeedMarkdownEditing.toggleEmphasis("**", in: "**текст**", selection: NSRange(location: 0, length: 9))

        XCTAssertEqual(edit.text, "текст")
    }

    // Без выделения жирным становится слово под кареткой
    func testBoldTakesWordUnderCaret() {
        let edit = FeedMarkdownEditing.toggleEmphasis("**", in: "слово", selection: NSRange(location: 2, length: 0))

        XCTAssertEqual(edit.text, "**слово**")
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 5))
    }

    // Каретка на пустом месте — ставим пару маркеров и оставляем её между ними
    func testBoldOnEmptyTextLeavesCaretInside() {
        let edit = FeedMarkdownEditing.toggleEmphasis("**", in: "", selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(edit.text, "****")
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 0))
    }

    // Курсив не должен отщипывать половину от жирного
    func testItalicIgnoresBoldMarkers() {
        let edit = FeedMarkdownEditing.toggleEmphasis("*", in: "**текст**", selection: NSRange(location: 2, length: 5))

        XCTAssertEqual(edit.text, "***текст***")
    }

    // MARK: - Заголовки и списки

    func testHeadingAdded() {
        let edit = FeedMarkdownEditing.toggleLinePrefix(.heading(1), in: "Текст", selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(edit.text, "# Текст")
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 0))
    }

    func testSameHeadingRemoved() {
        let edit = FeedMarkdownEditing.toggleLinePrefix(.heading(1), in: "# Текст", selection: NSRange(location: 2, length: 0))

        XCTAssertEqual(edit.text, "Текст")
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: 0))
    }

    func testHeadingLevelReplaced() {
        let edit = FeedMarkdownEditing.toggleLinePrefix(.heading(2), in: "# Текст", selection: NSRange(location: 2, length: 0))

        XCTAssertEqual(edit.text, "## Текст")
        XCTAssertEqual(edit.selection, NSRange(location: 3, length: 0))
    }

    func testBulletReplacesHeading() {
        let edit = FeedMarkdownEditing.toggleLinePrefix(.bullet, in: "## Дела", selection: NSRange(location: 4, length: 0))

        XCTAssertEqual(edit.text, "- Дела")
    }

    func testBulletAppliesToEverySelectedLine() {
        let edit = FeedMarkdownEditing.toggleLinePrefix(.bullet, in: "раз\nдва", selection: NSRange(location: 0, length: 7))

        XCTAssertEqual(edit.text, "- раз\n- два")
    }

    // Если префикс уже у всех строк — снимаем со всех
    func testBulletRemovedFromEveryLine() {
        let edit = FeedMarkdownEditing.toggleLinePrefix(.bullet, in: "- раз\n- два", selection: NSRange(location: 0, length: 11))

        XCTAssertEqual(edit.text, "раз\nдва")
    }

    func testNumberedAppliedToSecondLineOnly() {
        let edit = FeedMarkdownEditing.toggleLinePrefix(.numbered, in: "раз\nдва", selection: NSRange(location: 5, length: 0))

        XCTAssertEqual(edit.text, "раз\n1. два")
    }
}
