import CoreGraphics
import Foundation
import Vision

/// Распознанная строка вместе с её местом на странице
struct RecognizedLine: Hashable, Sendable {
    let text: String
    let confidence: Float
    /// Нормализованная рамка Vision: 0…1, начало координат внизу слева
    let box: CGRect
}

enum TextRecognizer {
    static let languages = [Locale.Language(identifier: "ru-RU"), Locale.Language(identifier: "en-US")]

    static func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        var request = RecognizeTextRequest()
        // Русский есть только у точного уровня: у .fast шесть латинских языков
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        // По умолчанию Vision отбрасывает текст ниже 1/32 высоты кадра. На
        // странице A4 это портило кегль 10 pt и мельче: верно читалась треть
        // строк. С нулём — все строки, 0,2 с на страницу (docs/search.md)
        request.minimumTextHeightFraction = 0

        let observations = try await request.perform(on: image)
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(
                text: candidate.string,
                confidence: candidate.confidence,
                box: observation.boundingBox.cgRect
            )
        }
    }

    /// Текст в порядке чтения: визуальные строки сверху вниз, внутри строки —
    /// слева направо. В анкетах подпись и значение стоят на одной высоте,
    /// и так они оказываются рядом
    static func readingOrder(_ lines: [RecognizedLine]) -> String {
        // Строку задаёт её первая рамка, а не объединение: высокий повёрнутый
        // номер на поле паспорта иначе растянул бы строку на полстраницы
        var rows: [(anchor: CGRect, items: [RecognizedLine])] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let index = rows.indices.last, sameRow(rows[index].anchor, line.box) {
                rows[index].items.append(line)
            } else {
                rows.append((line.box, [line]))
            }
        }
        return rows
            .map { row in row.items.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    private static func sameRow(_ anchor: CGRect, _ line: CGRect) -> Bool {
        abs(anchor.midY - line.midY) < min(anchor.height, line.height) * 0.5
    }
}
