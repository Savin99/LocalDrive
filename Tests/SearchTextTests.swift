import XCTest
@testable import LocalDrive

final class SearchTextTests: XCTestCase {
    func testNormalizeFoldsCaseAndYo() {
        XCTAssertEqual(SearchText.normalize("Пётр ЁЛКИН"), "петр елкин")
    }

    func testRussianWordsGetSnowballStems() {
        let stems = SearchText.tokens(in: "Справку о принятии статьи").map(\.stem)
        XCTAssertEqual(stems, ["справк", "о", "принят", "стат"])
    }

    func testInflectedFormsShareStem() {
        let forms = ["справка", "справку", "справки", "справкой", "справках"]
        XCTAssertEqual(Set(forms.map(RussianStemmer.stem)), ["справк"])
        XCTAssertNotEqual(RussianStemmer.stem("статус"), RussianStemmer.stem("статья"))
    }

    /// Пары из эталонного словаря Snowball (snowball-data/russian), по одной
    /// на каждую группу окончаний. Полный словарь из 49 785 слов прогнан при
    /// разработке без единого расхождения — см. docs/search.md
    func testMatchesSnowballReference() {
        let reference = [
            "вернувшись": "вернувш", "воспламенившись": "воспламен",
            "благонамереннейший": "благонамерен", "бездыханность": "бездыхан",
            "благодарностью": "благодарн", "бессмысленный": "бессмыслен",
            "бессонная": "бессон", "блуждающий": "блужда", "марширующих": "маршир",
            "готовившийся": "готов", "брался": "брал", "боялись": "боя",
            "имейте": "им", "бережешь": "бережеш", "ассигнациями": "ассигнац",
            "благословением": "благословен", "анисья": "анис", "агрономии": "агроном",
            "адриатической": "адриатическ", "безукоризненно": "безукоризнен",
            "абонировался": "абонирова", "абонируйся": "абонир",
        ]
        for (word, stem) in reference {
            XCTAssertEqual(RussianStemmer.stem(word), stem, word)
        }
    }

    func testStemNormalizesYoAndCase() {
        XCTAssertEqual(RussianStemmer.stem("ЁЛКАМИ"), RussianStemmer.stem("елками"))
    }

    func testLatinAndNumbersAreNotStemmed() {
        XCTAssertEqual(SearchText.stem("rudn"), "rudn")
        XCTAssertEqual(SearchText.stem("770120"), "770120")
    }

    func testTokensSplitLikeUnicode61() {
        let words = SearchText.tokens(in: "Группа НПМбд-01-21, «Антиплагиат.ВУЗ»").map(\.word)
        XCTAssertEqual(words, ["группа", "нпмбд", "01", "21", "антиплагиат", "вуз"])
    }

    func testFileNameBecomesWords() {
        XCTAssertEqual(SearchText.title(fromFileName: "Справка_антиплагиат.2025.pdf"), "Справка антиплагиат 2025")
    }

    func testStopWordsAreDropped() {
        XCTAssertEqual(SearchQuery("мой паспорт").terms.map(\.word), ["паспорт"])
        XCTAssertEqual(SearchQuery("когда истекает загран").terms.map(\.word), ["истекает", "загран"])
    }

    func testQueryOfOnlyStopWordsStillSearches() {
        XCTAssertEqual(SearchQuery("мой").terms.map(\.word), ["мой"])
    }

    func testExpressionMatchesWordPrefixOrStem() {
        let expression = SearchQuery("справку").ftsExpression(matchAll: true)
        XCTAssertEqual(expression, #"(words : "справку" * OR stems : "справк")"#)
    }

    func testExpressionQuotesUserInput() throws {
        let expression = try XCTUnwrap(SearchQuery(#"ООО "Ромашка""#).ftsExpression(matchAll: true))
        XCTAssertFalse(expression.contains(#""""#), "кавычки пользователя не должны ломать синтаксис FTS5")
        XCTAssertTrue(expression.contains(#""ромашка""#))
    }

    func testFallbackExpressionUsesOr() throws {
        let expression = try XCTUnwrap(SearchQuery("справка антиплагиат").ftsExpression(matchAll: false))
        XCTAssertTrue(expression.contains(") OR ("))
    }

    func testSnippetHighlightsInflectedForm() throws {
        let text = "Настоящая справка выдана в том, что работа прошла проверку на заимствования."
        let snippet = try XCTUnwrap(SearchQuery("справку проверка").snippet(in: text))
        let highlighted = snippet.runs
            .filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(snippet[$0.range].characters) }
        XCTAssertEqual(highlighted, ["справка", "проверку"])
    }

    func testSnippetCutsLongTextAroundMatch() throws {
        let filler = String(repeating: "слово ", count: 80)
        let text = filler + "антиплагиат" + " " + filler
        let snippet = try XCTUnwrap(SearchQuery("антиплагиат").snippet(in: text))
        let plain = String(snippet.characters)
        XCTAssertTrue(plain.hasPrefix("…"))
        XCTAssertTrue(plain.hasSuffix("…"))
        XCTAssertTrue(plain.contains("антиплагиат"))
        XCTAssertLessThan(plain.count, 200)
    }

    func testNoSnippetWithoutMatch() {
        XCTAssertNil(SearchQuery("паспорт").snippet(in: "Справка о проверке"))
    }

    // MARK: - Извлечение текста

    func testDecodesTruncatedUTF8() {
        let data = Data("Справка".utf8).dropLast(1) // последняя буква разрезана пополам
        XCTAssertEqual(DocumentTextExtractor.decode(Data(data)), "Справк")
    }

    func testDecodesWindows1251() {
        let cp1251 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)
        )
        let data = try! XCTUnwrap("Справка о доходах".data(using: String.Encoding(rawValue: cp1251)))
        XCTAssertEqual(DocumentTextExtractor.decode(data), "Справка о доходах")
    }

    func testBrokenPDFTextLayerIsNotReadable() {
        XCTAssertFalse(DocumentTextExtractor.hasReadableText("ÿ\u{1}\u{2} … ¶¶ 12 34 ##"))
        XCTAssertTrue(DocumentTextExtractor.hasReadableText("Справка о проверке на антиплагиат"))
    }

    func testSplitKeepsPiecesWithinLimit() {
        let text = (1...200).map { "Строка номер \($0) с текстом" }.joined(separator: "\n")
        let pieces = SearchIndexer.split(text, limit: 500)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 500 })
        XCTAssertEqual(pieces.joined(separator: "\n"), text)
    }

    func testSplitBreaksSingleHugeLineByWords() {
        let text = Array(repeating: "антиплагиат", count: 300).joined(separator: " ")
        let pieces = SearchIndexer.split(text, limit: 400)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 400 })
        XCTAssertEqual(pieces.joined(separator: " "), text)
    }
}
