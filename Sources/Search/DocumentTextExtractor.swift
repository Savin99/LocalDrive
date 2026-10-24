import Foundation
import ImageIO
import PDFKit
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

/// Текст одной страницы документа
struct ExtractedPage: Sendable {
    let number: Int
    let text: String
    /// Строки OCR с рамками; пусто, если текст взят из текстового слоя
    let lines: [RecognizedLine]
}

struct ExtractedText: Sendable {
    var pages: [ExtractedPage] = []
    var pageCount = 0

    static let empty = ExtractedText()
}

// Достаёт текст из файла хранилища. Работает с диском и Vision, поэтому
// вызывается только вне главного потока
enum DocumentTextExtractor {
    /// Текстовый слой дешёвый — читаем его почти целиком
    static let maxPDFPages = 300
    /// OCR страницы стоит десятые доли секунды; больше двадцати страниц
    /// сканов в одном файле — скорее книга, чем документ
    static let maxRecognizedPages = 20
    static let maxTextBytes = 2 * 1024 * 1024
    /// Длинная сторона кадра для OCR: фото с камеры в 48 Мп не нужно целиком
    static let maxImageSide = 4096
    /// Страница PDF рендерится так, чтобы кегль 8 pt был выше 20 пикселей
    static let pdfRenderSide: CGFloat = 2400

    static func extract(from url: URL) async throws -> ExtractedText {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .pdf) { return try await pdf(at: url) }
        if type.conforms(to: .image) { return try await image(at: url) }
        if type.conforms(to: .rtf) { return rtf(at: url) }
        if type.conforms(to: .html) { return plainText(at: url, strippingTags: true) }
        if type.conforms(to: .text) { return plainText(at: url, strippingTags: false) }
        if type.conforms(to: .compositeContent) { return try await quickLookPreview(of: url) }
        // Видео, аудио, архивы — только по имени
        return .empty
    }

    // MARK: - PDF

    private static func pdf(at url: URL) async throws -> ExtractedText {
        guard let document = PDFDocument(url: url) else { return .empty }
        var result = ExtractedText(pageCount: document.pageCount)
        var recognized = 0

        for index in 0..<min(document.pageCount, maxPDFPages) {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let layer = page.string ?? ""
            if hasReadableText(layer) {
                result.pages.append(ExtractedPage(number: index + 1, text: layer, lines: []))
                continue
            }
            // Скан без текстового слоя или слой из мусорных символов
            guard recognized < maxRecognizedPages, let image = render(page) else { continue }
            recognized += 1
            let lines = try await TextRecognizer.recognize(image)
            let text = TextRecognizer.readingOrder(lines)
            if !text.isEmpty {
                result.pages.append(ExtractedPage(number: index + 1, text: text, lines: lines))
            }
        }
        return result
    }

    /// Слой с битой кодировкой шрифта выглядит как набор знаков без букв
    static func hasReadableText(_ text: String) -> Bool {
        var letters = 0
        var visible = 0
        for character in text where !character.isWhitespace {
            visible += 1
            if character.isLetter { letters += 1 }
        }
        return letters >= 20 && Double(letters) / Double(max(visible, 1)) > 0.5
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // Повёрнутая страница меняет стороны местами — thumbnail учитывает поворот сам
        let rotated = page.rotation % 180 != 0
        let width = rotated ? bounds.height : bounds.width
        let height = rotated ? bounds.width : bounds.height
        let scale = pdfRenderSide / max(width, height)
        let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        return autoreleasepool {
            page.thumbnail(of: size, for: .mediaBox).cgImage
        }
    }

    // MARK: - Фото

    private static func image(at url: URL) async throws -> ExtractedText {
        guard let image = downsampledImage(at: url) else { return .empty }
        let lines = try await TextRecognizer.recognize(image)
        let text = TextRecognizer.readingOrder(lines)
        guard !text.isEmpty else { return ExtractedText(pageCount: 1) }
        return ExtractedText(pages: [ExtractedPage(number: 1, text: text, lines: lines)], pageCount: 1)
    }

    /// Кадр с учётом EXIF-ориентации и не больше `maxImageSide` по длинной
    /// стороне: Vision ждёт текст в правильной ориентации
    static func downsampledImage(at url: URL) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageSide,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    // MARK: - Текст

    private static func plainText(at url: URL, strippingTags: Bool) -> ExtractedText {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .empty }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxTextBytes), !data.isEmpty,
              var text = decode(data) else { return .empty }
        if strippingTags {
            text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        return single(text)
    }

    /// UTF-8, затем UTF-16 по метке порядка байтов, затем Windows-1251 —
    /// русские текстовые файлы из Windows до сих пор встречаются в нём
    static func decode(_ data: Data) -> String? {
        // Чтение обрезано по maxTextBytes и могло разрезать последнюю букву
        // посередине — такой хвост в 1–3 байта не повод считать файл не UTF-8
        for cut in 0...3 where data.count > cut {
            if let text = String(data: data.dropLast(cut), encoding: .utf8) { return text }
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        let cp1251 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)
        )
        return String(data: data, encoding: String.Encoding(rawValue: cp1251))
    }

    private static func rtf(at url: URL) -> ExtractedText {
        guard let text = try? NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ).string else { return .empty }
        return single(text)
    }

    private static func single(_ text: String) -> ExtractedText {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ExtractedText(pageCount: 1) }
        return ExtractedText(pages: [ExtractedPage(number: 1, text: trimmed, lines: [])], pageCount: 1)
    }

    // MARK: - Офисные документы

    /// Своего разбора docx и Pages на iOS нет, зато QuickLook умеет рисовать
    /// их первую страницу. Её и распознаём
    private static func quickLookPreview(of url: URL) async throws -> ExtractedText {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 1700, height: 2200),
            scale: 1,
            representationTypes: .thumbnail
        )
        guard let preview = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return .empty }
        let lines = try await TextRecognizer.recognize(preview.cgImage)
        let text = TextRecognizer.readingOrder(lines)
        guard !text.isEmpty else { return .empty }
        return ExtractedText(pages: [ExtractedPage(number: 1, text: text, lines: lines)], pageCount: 1)
    }
}
