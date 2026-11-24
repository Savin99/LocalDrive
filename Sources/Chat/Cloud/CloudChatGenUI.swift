import Foundation

/// Ответ облачного чата интерфейсом (Generative UI, docs/genui.md): модель
/// сама выбирает формат — текст, интерфейс или смесь — и присылает финальный
/// ответ JSON по схеме `GenUIJSONSchema`. Инструменты при этом работают как
/// раньше: строгий `text.format` и вызовы функций в одном запросе — Responses
/// API (Structured Outputs: «function calling … or text.format»)
enum CloudChatGenUI {
    /// OpenAI — да. Gemini 3 по документации тоже совмещает структурированный
    /// ответ с вызовом функций, но на настоящем Gemini это не проверено —
    /// там ответ пока текстом
    static func isEnabled(for provider: CloudProvider) -> Bool {
        provider == .openAI
    }

    static let schemaName = "genui_answer"

    /// Заглушка в теле запроса: CloudJSON порядок ключей не хранит, а ответ
    /// идёт в порядке ключей схемы (text — раньше blocks). Схема вставляется
    /// готовой строкой вместо заглушки
    static let schemaPlaceholder = "__GENUI_SCHEMA__"

    /// text.format строгого ответа — с заглушкой вместо схемы
    static var textFormat: CloudJSON {
        ["type": "json_schema", "name": .string(schemaName), "strict": true, "schema": .string(schemaPlaceholder)]
    }

    /// Тело запроса с настоящей схемой на месте заглушки
    static func body(_ body: CloudJSON) -> Data {
        let text = String(data: body.data, encoding: .utf8) ?? "{}"
        return Data(text.replacingOccurrences(of: "\"\(schemaPlaceholder)\"", with: GenUIJSONSchema.openAIStrictString).utf8)
    }

    /// Системная инструкция: чистый AGENT.md + техническая справка по формату JSON-ответа.
    /// Без жёстких скриптов и шаблонов — агент сам выбирает формат и глубину ответа.
    static var system: String {
        """
        \(AgentIdentity.instructions)

        \(instructions)
        """
    }

    /// Технический контракт формата ответа (JSON-схема Generative UI).
    static var instructions: String {
        """
        Формат ответа — JSON по схеме ответа (version 1). Свободно выбирай то, что лучше подходит задаче: обычный текст (mode "text", blocks пустой), интерфейс (mode "ui") или текст с блоками (mode "mixed"). В text поддерживается простая разметка (**жирный**, списки, абзацы).
        Возможности блоков:
        - app_card — карточка документа из хранилища (id "d…" из описи): kind "fields" для полей документа (включай series_number и department_code, если просят реквизиты или все данные — карточка сама закроет их маской), kind "document" для показа самого файла/скана, kind "expiry" для срока.
        - Интерактивные виджеты: chart, table, metric, list, callout, form, slider, button (например, варианты с действием ask при неоднозначном вопросе). Для графиков, таблиц и метрик по хранилищу бери данные через source (documents, document_stats, amounts, expiring), а для калькуляторов — state + computed + slider/metric/chart.
        - «Карточки» (Wi-Fi, коды, адреса) — не документы, работай с ними через find_fact_cards, show_fact_card и propose_fact_card.
        - sources — id документов ("d…"), на которые опирается ответ (до 3), чтобы человек мог открыть источник в одно касание; пусто, если ответ не из документов.
        - followups — до 2–3 коротких уместных продолжений от лица пользователя (или пусто, если нечего предложить).
        \(GenUIJSONSchema.promptCatalog())
        """
    }

    /// Просьба перестроить один блок: его JSON и значения состояния. Ответ —
    /// документ, где в blocks один этот блок с тем же id
    static func regenerateRequest(block: JSONValue, instruction: String?, state: GenUIStateSnapshot) -> String {
        let json = (try? JSONEncoder().encode(block)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var lines = [
            "Перестрой блок интерфейса из прошлого ответа с учётом текущих значений.",
            "Блок: \(json)",
            "Значения: \(state.summary.isEmpty ? "нет" : state.summary)",
        ]
        if let instruction, !instruction.isEmpty { lines.append("Что изменить: \(instruction)") }
        lines.append("Ответь документом, где в blocks ровно один блок с тем же id; text — пусто.")
        return lines.joined(separator: "\n")
    }
}
