import Foundation

// Инструкция и инструменты агента на iPhone. Инструменты — те же, что у
// облачного агента (те же имена и аргументы, исполняет их CloudChatTools), но
// описаны короче и без редких полей: каждый токен инструкции на iPhone — время
// разбора, а описания облака на русском занимали больше 2000 токенов (замер
// стенда, docs/agent.md). Страниц картинками нет: модель чата текстовая.
// Владелец 24.10.2026: «нормального агента в чате, а не ограниченный план»
enum LocalAgentPrompt {
    /// Сколько строк описи документов видит модель
    static let indexLimit = 60

    static let base = """
    Ты — помощник в LocalDrive, хранилище документов на iPhone. Отвечай по-русски, одной-двумя фразами.
    Про документы, папки, файлы и карточки знаешь только из описи ниже и из инструментов. Ничего не выдумывай.
    Вопрос «где лежит», «какие есть», «сколько» — отвечай по описи сразу, без инструментов. Считай по строкам описи: развороты одного паспорта — это один паспорт.
    Данные документа (ФИО, даты, серия, номер) показывай вызовом show_cards с type "fields" — значения подставит приложение, в текст их не пиши.
    Нашёл документ — покажи его: show_cards с type "document", несколько — "fileList".
    owner в search_documents — только если спросили про документ конкретного человека.
    Поле распознано с ошибкой — propose_field_fix с правильным значением; человек подтвердит кнопкой.
    Перенести, переименовать, положить файл, создать папку — propose_file_actions; человек подтвердит кнопкой. Файл называй document_id из описи, папку — folder_id из list_folders. Разложить папку — все переносы одним вызовом.
    «Запомни …» — propose_fact_card, каждое значение из сообщения — отдельным полем. Дом, Wi-Fi, коды, адреса знакомых — find_fact_cards, потом show_fact_card.
    Вызывай инструменты только в формате вызова, не описывай их словами.
    Сам ты ничего не меняешь — только предлагаешь. Никогда не пиши «исправлено», «перенесено», «сохранено».
    """

    /// Инструкция с описью документов и карточек
    static func instructions(index: String, facts: String, owner: String?) -> String {
        var text = base
        text += "\n" + (owner.map { "Владелец хранилища: \($0). «Мой паспорт» — его; «у меня есть» — всё хранилище." }
            ?? "Владелец хранилища неизвестен: на «мой паспорт» при нескольких людях спроси, чей.")
        let lines = index.split(separator: "\n").prefix(indexLimit).map { labeled(String($0)) }
        if !lines.isEmpty {
            text += "\n\nОпись документов:\n" + lines.joined(separator: "\n")
        }
        if !facts.isEmpty {
            text += "\n\nКарточки (id · название · поля):\n" + facts
        }
        return text
    }

    /// Строка описи с подписями: «d21 — Паспорт РФ; владелец: Трошина О. П.;
    /// папка: Ольга». Стенд: без подписей модель путала колонки — клала
    /// паспорт Ольги в папку «Илья»
    static func labeled(_ line: String) -> String {
        let parts = line.components(separatedBy: " · ")
        guard parts.count >= 5 else { return line }
        var text = "\(parts[0]) — \(parts[2])"
        if parts[3] != "—" { text += "; владелец: \(parts[3])" }
        text += "; папка: \(parts[4])"
        if parts.count > 5 { text += "; действует \(parts[5])" }
        return text
    }

    /// Инструменты в формате шаблона Qwen: {"type": "function", "function": {…}}
    static let toolsJSON = #"""
    [
    {"type":"function","function":{"name":"search_documents","description":"Найти документы по словам из текста, названия или имени владельца","parameters":{"type":"object","properties":{"query":{"type":"string"},"owner":{"type":"string","description":"имя владельца"}},"required":["query"]}}},
    {"type":"function","function":{"name":"get_document","description":"Поля и текст документа","parameters":{"type":"object","properties":{"id":{"type":"string","description":"d42"}},"required":["id"]}}},
    {"type":"function","function":{"name":"list_folders","description":"Папки: id, название, путь","parameters":{"type":"object","properties":{}}}},
    {"type":"function","function":{"name":"list_files","description":"Файлы папки","parameters":{"type":"object","properties":{"folder_id":{"type":"string"}},"required":["folder_id"]}}},
    {"type":"function","function":{"name":"list_expiring","description":"Документы, у которых скоро кончается срок","parameters":{"type":"object","properties":{}}}},
    {"type":"function","function":{"name":"show_cards","description":"Показать карточки под ответом","parameters":{"type":"object","properties":{"cards":{"type":"array","items":{"type":"object","properties":{"type":{"type":"string","enum":["fields","document","fileList","expiry"]},"documentId":{"type":"string"},"documentIds":{"type":"array","items":{"type":"string"}},"keys":{"type":"array","items":{"type":"string","enum":["full_name","series_number","issued_by","issue_date","department_code","expiry_date","birth_date","sex","birth_place","registration_address"]}}},"required":["type"]}}},"required":["cards"]}}},
    {"type":"function","function":{"name":"propose_file_actions","description":"Предложить перенос, переименование, новую папку; выполнит человек кнопкой","parameters":{"type":"object","properties":{"summary":{"type":"string"},"actions":{"type":"array","items":{"type":"object","properties":{"action":{"type":"string","enum":["move_files","rename_file","create_folder","save_attachment"]},"files":{"type":"array","items":{"type":"object","properties":{"document_id":{"type":"string","description":"d42 из описи"}}}},"folder_id":{"type":"string","description":"куда"},"new_folder_name":{"type":"string"},"file":{"type":"object","properties":{"document_id":{"type":"string","description":"d42 из описи"}}},"new_name":{"type":"string"},"attachment_id":{"type":"string"}},"required":["action"]}}},"required":["actions","summary"]}}},
    {"type":"function","function":{"name":"find_fact_cards","description":"Найти карточки: дом, Wi-Fi, коды, адреса","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}},
    {"type":"function","function":{"name":"show_fact_card","description":"Показать карточку; labels — поля, о которых спросили","parameters":{"type":"object","properties":{"id":{"type":"string"},"labels":{"type":"array","items":{"type":"string"}}},"required":["id"]}}},
    {"type":"function","function":{"name":"propose_field_fix","description":"Исправить поле документа, распознанное с ошибкой; исправит человек кнопкой","parameters":{"type":"object","properties":{"document_id":{"type":"string","description":"d42"},"key":{"type":"string","enum":["full_name","series_number","issued_by","issue_date","department_code","expiry_date","birth_date","sex","birth_place","registration_address"]},"value":{"type":"string","description":"правильное значение целиком"}},"required":["document_id","key","value"]}}},
    {"type":"function","function":{"name":"propose_fact_card","description":"Предложить новую карточку; сохранит человек кнопкой","parameters":{"type":"object","properties":{"title":{"type":"string"},"symbol":{"type":"string","description":"SF Symbol: house.fill, wifi, key.fill, car.fill"},"items":{"type":"array","items":{"type":"object","properties":{"kind":{"type":"string","enum":["address","link","phone","email","code","text","date","wifi","note"]},"label":{"type":"string"},"value":{"type":"string"}},"required":["kind","label","value"]}}},"required":["title","items"]}}}
    ]
    """#

    /// Имена инструментов — для разбора вызова, записанного текстом
    static var toolNames: Set<String> {
        guard let list = try? JSONSerialization.jsonObject(with: Data(toolsJSON.utf8)) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
    }
}
