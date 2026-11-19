#if DEBUG
import UIKit

// Отладочное хранилище для скриншотов и ручной проверки: семья Савиных,
// страницы документов нарисованы приложением — у папок есть превью, у поиска и
// чата — текст. Запуск с -DemoVault, только в отладочной сборке и только в
// пустое хранилище. Ключ облака для чата — из окружения OPENAI_API_KEY
// (simctl launch: SIMCTL_CHILD_OPENAI_API_KEY), в связку ключей не пишется
enum DemoVault {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-DemoVault")
    }

    /// Значение аргумента запуска: «-OpenFolder Паспорта» → «Паспорта»
    static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Страница при запуске: «-StartPage files»
    static var startPage: MainPage? {
        switch argument("-StartPage") {
        case "files": .files
        case "cards": .cards
        case "chat": .chat
        default: nil
        }
    }

    @MainActor
    static func seedIfNeeded(store: VaultStore, search: SearchService) {
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            search.cloud.useSessionKey(key)
            search.cloud.setChatEnabled(true)
        }
        guard isRequested, store.folders.isEmpty else { return }
        for folder in folders {
            guard let created = store.createFolder(name: folder.name, icon: folder.icon, color: folder.color) else { continue }
            for page in folder.pages {
                guard let data = render(page)?.jpegData(compressionQuality: 0.85) else { continue }
                _ = store.importData(data, preferredName: page.file, to: created)
            }
        }
        search.reconcile()
    }

    private struct Page {
        let file: String
        let title: String
        let lines: [String]
        var tint: UIColor = .white
        var photo = false
    }

    private struct Folder {
        let name: String
        let icon: String
        let color: String
        let pages: [Page]
    }

    private static let passportTint = UIColor(red: 0.98, green: 0.93, blue: 0.93, alpha: 1)

    private static let folders: [Folder] = [
        Folder(name: "Паспорта", icon: "person.text.rectangle.fill", color: "indigo", pages: [
            Page(file: "паспорт Ильи.jpg", title: "ПАСПОРТ ГРАЖДАНИНА РФ",
                 lines: ["Фамилия САВИН", "Имя ИЛЬЯ", "Отчество АНДРЕЕВИЧ", "Дата рождения 01.01.1990", "Место рождения ГОР. ТВЕРЬ",
                         "Выдан 15.02.2010 ОТДЕЛОМ УФМС РОССИИ ПО ТВЕРСКОЙ ОБЛ.", "Код подразделения 690-001"],
                 tint: passportTint, photo: true),
            Page(file: "паспорт Ольги.jpg", title: "ПАСПОРТ ГРАЖДАНИНА РФ",
                 lines: ["Фамилия ТРОШИНА", "Имя ОЛЬГА", "Отчество ПЕТРОВНА", "Дата рождения 02.02.1992", "Место рождения ГОР. МОСКВА",
                         "Выдан 10.03.2012 ОТДЕЛЕНИЕМ ПО РАЙОНУ АРБАТ", "Код подразделения 770-001"],
                 tint: passportTint, photo: true),
            Page(file: "загран Ильи.jpg", title: "ЗАГРАНИЧНЫЙ ПАСПОРТ",
                 lines: ["SAVIN / САВИН", "ILIA / ИЛЬЯ", "Дата рождения 01.01.1990", "Дата выдачи 15.03.2021", "Дата окончания срока 15.03.2031"],
                 tint: UIColor(red: 0.92, green: 0.95, blue: 0.99, alpha: 1), photo: true),
        ]),
        Folder(name: "Семья", icon: "heart.fill", color: "pink", pages: [
            Page(file: "свидетельство о браке.jpg", title: "СВИДЕТЕЛЬСТВО О ЗАКЛЮЧЕНИИ БРАКА",
                 lines: ["Савин Илья Андреевич", "и Трошина Ольга Петровна", "заключили брак 12.06.2015", "Запись акта № 120"]),
            Page(file: "свидетельство о рождении Камилы.jpg", title: "СВИДЕТЕЛЬСТВО О РОЖДЕНИИ",
                 lines: ["Савина Камила Ильинична", "Дата рождения 14.05.2018", "Место рождения г. Москва", "Отец Савин Илья Андреевич",
                         "Мать Трошина Ольга Петровна"]),
        ]),
        Folder(name: "Машина", icon: "car.fill", color: "blue", pages: [
            Page(file: "ОСАГО.jpg", title: "ПОЛИС ОСАГО",
                 lines: ["Страховщик СПАО «Ингосстрах»", "Транспортное средство Kia Rio", "Срок страхования", "с 06.01.2026 по 05.01.2027",
                         "Страховая премия 8 900 руб."]),
            Page(file: "права Ильи.jpg", title: "ВОДИТЕЛЬСКОЕ УДОСТОВЕРЕНИЕ",
                 lines: ["САВИН ИЛЬЯ АНДРЕЕВИЧ", "01.01.1990", "Выдано 10.07.2019", "Действительно до 10.07.2029", "Категории B, B1"],
                 tint: UIColor(red: 0.93, green: 0.97, blue: 0.94, alpha: 1), photo: true),
        ]),
        Folder(name: "Квартира", icon: "house.fill", color: "orange", pages: [
            Page(file: "договор аренды.jpg", title: "ДОГОВОР АРЕНДЫ ЖИЛОГО ПОМЕЩЕНИЯ",
                 lines: ["г. Москва, ул. Лесная, д. 7, кв. 45", "Арендодатель Петров Алексей Викторович", "Арендатор Савин Илья Андреевич",
                         "Арендная плата 65 000 руб. в месяц", "Срок аренды с 01.09.2026 по 31.08.2027"]),
        ]),
        Folder(name: "Работа", icon: "briefcase.fill", color: "graphite", pages: [
            Page(file: "справка с работы.jpg", title: "СПРАВКА",
                 lines: ["Дана Савину Илье Андреевичу", "в том, что он работает в ООО «Ромашка»", "в должности ведущего инженера",
                         "с 01.02.2024 по настоящее время"]),
            Page(file: "трудовой договор.jpg", title: "ТРУДОВОЙ ДОГОВОР",
                 lines: ["ООО «Ромашка» и Савин Илья Андреевич", "Должность: ведущий инженер", "Оклад 120 000 руб.", "Дата начала работы 01.02.2024"]),
        ]),
        Folder(name: "Медицина", icon: "shield.fill", color: "green", pages: [
            Page(file: "полис ДМС Ольги.jpg", title: "ПОЛИС ДМС",
                 lines: ["АО «АльфаСтрахование»", "Застрахованный Трошина Ольга Петровна", "Срок действия с 01.01.2026 по 31.12.2026"]),
        ]),
        Folder(name: "Чеки", icon: "banknote.fill", color: "teal", pages: [
            Page(file: "чек аптека.jpg", title: "КАССОВЫЙ ЧЕК", lines: ["Аптека «Здоровье»", "05.09.2026", "ИТОГО 2 350,00"]),
            Page(file: "чек техника.jpg", title: "КАССОВЫЙ ЧЕК", lines: ["Магазин техники", "20.09.2026", "ИТОГО 18 990,00"]),
            Page(file: "чек продукты.jpg", title: "КАССОВЫЙ ЧЕК", lines: ["Супермаркет", "03.10.2026", "ИТОГО 4 560,00"]),
        ]),
        Folder(name: "Входящие", icon: "tray.fill", color: "purple", pages: [
            Page(file: "скан 001.jpg", title: "СПРАВКА",
                 lines: ["Дана Савиной Камиле Ильиничне", "в том, что она обучается во 2 классе", "ГБОУ «Школа № 1234» г. Москвы"]),
        ]),
    ]

    /// Страница документа: заголовок, строки текста, у удостоверений — место фото
    private static func render(_ page: Page) -> UIImage? {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            page.tint.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 58, weight: .bold), .foregroundColor: UIColor.black]
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 46, weight: .regular), .foregroundColor: UIColor.darkGray]
            NSAttributedString(string: page.title, attributes: title)
                .draw(in: CGRect(x: 90, y: 110, width: size.width - 180, height: 160))
            var y: CGFloat = 330
            let left: CGFloat = page.photo ? 470 : 90
            if page.photo {
                UIColor(white: 0.82, alpha: 1).setFill()
                context.fill(CGRect(x: 90, y: 330, width: 320, height: 420))
            }
            for line in page.lines {
                NSAttributedString(string: line, attributes: body).draw(in: CGRect(x: left, y: y, width: size.width - left - 90, height: 120))
                y += 110
            }
            UIColor(white: 0.85, alpha: 1).setFill()
            for row in 0..<5 {
                context.fill(CGRect(x: 90, y: max(y, 900) + CGFloat(row) * 70, width: size.width - 180 - CGFloat(row % 2) * 240, height: 22))
            }
        }
    }
}
#endif
