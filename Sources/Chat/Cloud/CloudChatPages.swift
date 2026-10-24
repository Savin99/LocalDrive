import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Страницы документа картинками для инструмента view_document: модель
/// «заходит посмотреть» скан — штамп регистрации, отметку о браке, детей.
/// Фото — одна страница, PDF — указанные страницы. Длинная сторона — 1600 px,
/// JPEG 0,85, не больше четырёх страниц за вызов
enum CloudChatPages {
    static let maxSide = 1600
    static let maxPages = 4

    struct Pages {
        let images: [(number: Int, jpeg: Data)]
        let total: Int
    }

    /// `pages` — номера с 1. nil — первые страницы. nil в ответе — файл не картинка и не PDF
    static func load(_ url: URL, pages: [Int]?) -> Pages? {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true { return pdf(url, pages: pages) }
        guard type?.conforms(to: .image) == true, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let jpeg = CloudPageImages.jpeg(image) else { return Pages(images: [], total: 1) }
        return Pages(images: [(1, jpeg)], total: 1)
    }

    private static func pdf(_ url: URL, pages requested: [Int]?) -> Pages {
        guard let document = PDFDocument(url: url) else { return Pages(images: [], total: 0) }
        let total = document.pageCount
        let wanted = (requested?.isEmpty == false ? requested! : Array(1...max(1, min(total, maxPages))))
            .filter { (1...max(1, total)).contains($0) }
            .prefix(maxPages)
        var images: [(Int, Data)] = []
        for number in wanted {
            guard let page = document.page(at: number - 1) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let rotated = page.rotation % 180 != 0
            let width = rotated ? bounds.height : bounds.width
            let height = rotated ? bounds.width : bounds.height
            let scale = CGFloat(maxSide) / max(width, height)
            let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
            let jpeg: Data? = autoreleasepool { page.thumbnail(of: size, for: .mediaBox).cgImage.flatMap(CloudPageImages.jpeg) }
            if let jpeg { images.append((number, jpeg)) }
        }
        return Pages(images: images, total: total)
    }
}
