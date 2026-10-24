import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Второе чтение удостоверения: модель «текст + картинка» смотрит на фото
/// документа. В приложении это локальная модель (Chat/LLM), в тестах — подделка
protocol DocumentReading: Sendable {
    /// Ревизия модели: документ, который она уже прочитала, второй раз не читается
    var revision: String { get }
    func read(_ image: PageImage, kind: DocumentType) async throws -> DocumentReadout
}

/// Кадр страницы для модели. CGImage неизменяем, поэтому его можно передавать
/// между потоками
struct PageImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// Модель сейчас работать не может: не хватает памяти, симулятор. Индекс не
/// пытается снова, пока приложение не вернётся на экран
struct DocumentReaderUnavailable: Error, Sendable, Equatable {
    let reason: String
}

/// Ответ модели не уложился в грамматику или не разобрался: значений нет.
/// Документ отмечается прочитанным, второй раз эта модель его не читает
struct DocumentReaderIncomplete: Error, Sendable, Equatable {}

/// Чем кончилось второе чтение документа — для «Сведений» о файле
enum ModelReadState: Equatable, Sendable {
    /// Модель прочитала фото
    case read
    /// Правила подтвердили всё нужное — модель не понадобилась
    case notNeeded
    /// Модель пробовала, но значений не дала: нет кадра, неполный ответ
    case failed
    /// Ждёт своей очереди
    case waiting
}

/// Чем кончилось облачное распознавание файла — для «Сведений»
enum CloudReadState: Equatable, Sendable {
    case read
    /// Отправлять нечего: у PDF есть текстовый слой, файл не фото
    case notNeeded
    case failed
    case waiting
}

/// Что модель прочитала на фото — как напечатано. Пустое поле — nil
struct DocumentReadout: Equatable, Sendable, Decodable {
    var type: String?
    var surname: String?
    var givenName: String?
    var patronymic: String?
    var birthDate: String?
    var issueDate: String?
    var expiryDate: String?
    var number: String?
    var departmentCode: String?
    var issuedBy: String?
    var birthPlace: String?
    var sex: String?
    var country: String?
    /// Действующий штамп «Зарегистрирован» на этой странице — адрес, дата, орган
    var registrationAddress: String?
    var registrationDate: String?
    var registrationIssuer: String?
    /// Последний штамп «Снят с регистрационного учёта» на этой странице: по нему
    /// из штампов всех страниц выбирается действующий
    var deregistrationDate: String?

    private enum CodingKeys: String, CodingKey {
        case type, surname, patronymic, number, sex, country
        case givenName = "given_name"
        case birthDate = "birth_date"
        case issueDate = "issue_date"
        case expiryDate = "expiry_date"
        case departmentCode = "department_code"
        case issuedBy = "issued_by"
        case birthPlace = "birth_place"
        case registrationAddress = "registration_address"
        case registrationDate = "registration_date"
        case registrationIssuer = "registration_issuer"
        case deregistrationDate = "deregistration_date"
    }

    init(
        type: String? = nil, surname: String? = nil, givenName: String? = nil, patronymic: String? = nil,
        birthDate: String? = nil, issueDate: String? = nil, expiryDate: String? = nil, number: String? = nil,
        departmentCode: String? = nil, issuedBy: String? = nil, birthPlace: String? = nil, sex: String? = nil,
        country: String? = nil, registrationAddress: String? = nil, registrationDate: String? = nil,
        registrationIssuer: String? = nil, deregistrationDate: String? = nil
    ) {
        self.type = type
        self.surname = surname
        self.givenName = givenName
        self.patronymic = patronymic
        self.birthDate = birthDate
        self.issueDate = issueDate
        self.expiryDate = expiryDate
        self.number = number
        self.departmentCode = departmentCode
        self.issuedBy = issuedBy
        self.birthPlace = birthPlace
        self.sex = sex
        self.country = country
        self.registrationAddress = registrationAddress
        self.registrationDate = registrationDate
        self.registrationIssuer = registrationIssuer
        self.deregistrationDate = deregistrationDate
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) -> String? {
            let text = (try? container.decodeIfPresent(String.self, forKey: key))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        self.init(
            type: value(.type), surname: value(.surname), givenName: value(.givenName), patronymic: value(.patronymic),
            birthDate: value(.birthDate), issueDate: value(.issueDate), expiryDate: value(.expiryDate),
            number: value(.number), departmentCode: value(.departmentCode), issuedBy: value(.issuedBy),
            birthPlace: value(.birthPlace), sex: value(.sex), country: value(.country),
            registrationAddress: value(.registrationAddress), registrationDate: value(.registrationDate),
            registrationIssuer: value(.registrationIssuer), deregistrationDate: value(.deregistrationDate)
        )
    }
}

/// Кадр для модели: фото с учётом поворота из EXIF, у PDF — первая страница.
/// Длинная сторона — 1024 px: на стенде так же точно, как 1280, и быстрее
enum DocumentPageImage {
    static let maxSide = 1024

    @Sendable static func load(_ url: URL) -> PageImage? {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true { return pdfPage(url) }
        guard type?.conforms(to: .image) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map(PageImage.init)
    }

    private static func pdfPage(_ url: URL) -> PageImage? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // Повёрнутая страница меняет стороны местами — thumbnail учитывает поворот сам
        let rotated = page.rotation % 180 != 0
        let width = rotated ? bounds.height : bounds.width
        let height = rotated ? bounds.width : bounds.height
        let scale = CGFloat(maxSide) / max(width, height)
        let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        return autoreleasepool {
            page.thumbnail(of: size, for: .mediaBox).cgImage.map(PageImage.init)
        }
    }
}
