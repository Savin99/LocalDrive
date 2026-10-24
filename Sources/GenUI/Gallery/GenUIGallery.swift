#if DEBUG
import SwiftUI
import Observation

// Отладочная галерея Generative UI: семь сценариев ТЗ на поддельных данных.
// Ответы написаны в формате схемы так, как их присылает модель, — галерея
// проверяет движок, а не модель. Открывается запуском с -GenUIGallery
enum GenUIGallery {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-GenUIGallery")
    }

    struct Scenario: Identifiable {
        let id: String
        let title: String
        let question: String
        let payloads: [String]
    }

    static let scenarios: [Scenario] = [
        Scenario(id: "text", title: "1. Текстовый ответ", question: "Когда истекает загранпаспорт?", payloads: [textOnly]),
        Scenario(id: "compare", title: "2. Сравнение: график и таблица", question: "Сколько у меня документов по категориям?", payloads: [comparison]),
        Scenario(id: "calculator", title: "3. Калькулятор ипотеки", question: "Посчитай ипотеку на 3 миллиона", payloads: [calculator]),
        Scenario(id: "form", title: "4. Форма для следующего ответа", question: "Какие документы взять в поездку?", payloads: [form]),
        Scenario(id: "mixed", title: "5. Смешанный ответ", question: "Что с моими документами?", payloads: [mixed]),
        Scenario(id: "broken", title: "6. Битый JSON и неизвестный блок", question: "Покажи график", payloads: [brokenJSON, unknownComponent]),
        Scenario(id: "forbidden", title: "7. Неразрешённое действие", question: "Открой сайт", payloads: [forbiddenAction]),
    ]

    private static let statsSource = #"{"kind":"document_stats","group_by":"category","metric":"count","currency":null,"types":null,"categories":null,"folder_id":null,"owner":null}"#

    static let textOnly = #"""
    {"version":1,"mode":"text","text":"Загранпаспорт действует до **15.03.2031** — ещё больше четырёх лет. Менять пока не нужно.","state":[],"computed":[],"blocks":[]}
    """#

    static let comparison = #"""
    {"version":1,"mode":"mixed","text":"Документы по категориям — по данным приложения:","state":[],"computed":[],"blocks":[
     {"id":"total","type":"metric","visible_if":null,"label":"Всего документов","value":null,"format":"integer","unit":null,"caption":null,"trend":null,"source":\#(statsSource),"aggregate":{"op":"sum","column":"value"}},
     {"id":"by-category","type":"chart","visible_if":null,"kind":"bar","title":"По категориям","x":{"key":"key","title":"Категория","kind":"category"},"y":{"key":"value","title":"Документов","format":"integer"},"series":null,"columns":null,"rows":null,"source":\#(statsSource),"generate":null,"height":"m"},
     {"id":"by-category-table","type":"table","visible_if":null,"columns":[{"key":"key","title":"Категория","format":null,"align":null},{"key":"value","title":"Документов","format":"integer","align":"trailing"}],"rows":null,"source":\#(statsSource),"generate":null,"max_rows":null}
    ]}
    """#

    static let calculator = #"""
    {"version":1,"mode":"mixed","text":"Посчитал аннуитетный платёж. Подвигайте параметры:",
     "state":[{"name":"amount","value":3000000},{"name":"rate","value":18.5},{"name":"years","value":10}],
     "computed":[{"name":"r","expr":"rate / 1200"},{"name":"n","expr":"years * 12"},{"name":"payment","expr":"amount * r / (1 - pow(1 + r, -n))"},{"name":"overpay","expr":"payment * n - amount"}],
     "blocks":[
      {"id":"amount","type":"slider","visible_if":null,"label":"Сумма кредита","bind":"amount","min":500000,"max":20000000,"step":100000,"format":"money"},
      {"id":"rate","type":"slider","visible_if":null,"label":"Ставка, % годовых","bind":"rate","min":5,"max":30,"step":0.5,"format":"percent"},
      {"id":"years","type":"slider","visible_if":null,"label":"Срок, лет","bind":"years","min":1,"max":30,"step":1,"format":"integer"},
      {"id":"results","type":"grid","visible_if":null,"columns":2,"blocks":[
        {"id":"payment","type":"metric","visible_if":null,"label":"Платёж в месяц","value":{"expr":"payment"},"format":"money","unit":null,"caption":null,"trend":null,"source":null,"aggregate":null},
        {"id":"overpay","type":"metric","visible_if":null,"label":"Переплата","value":{"expr":"overpay"},"format":"money","unit":null,"caption":"за {{ years }} лет","trend":null,"source":null,"aggregate":null}]},
      {"id":"balance","type":"chart","visible_if":null,"kind":"area","title":"Остаток долга","x":{"key":"month","title":"Месяц","kind":"number"},"y":{"key":"balance","title":"Остаток","format":"money"},"series":null,"columns":null,"rows":null,"source":null,
       "generate":{"var":"month","from":0,"to":{"expr":"n"},"step":{"expr":"max(1, round(n / 60))"},"columns":[{"key":"balance","expr":"max(0, amount * pow(1 + r, month) - payment * (pow(1 + r, month) - 1) / r)"}]},"height":"m"},
      {"id":"schedule","type":"table","visible_if":null,"columns":[{"key":"year","title":"Год","format":"integer","align":null},{"key":"paid","title":"Выплачено","format":"money","align":"trailing"},{"key":"left","title":"Остаток","format":"money","align":"trailing"}],"rows":null,"source":null,
       "generate":{"var":"year","from":1,"to":{"expr":"years"},"step":null,"columns":[{"key":"paid","expr":"payment * 12 * year"},{"key":"left","expr":"max(0, amount * pow(1 + r, year * 12) - payment * (pow(1 + r, year * 12) - 1) / r)"}]},"max_rows":5}
     ]}
    """#

    static let form = #"""
    {"version":1,"mode":"mixed","text":"Заполните — и я соберу список документов для поездки:",
     "state":[{"name":"country","value":"Турция"},{"name":"departure","value":"2026-11-20"},{"name":"days","value":10},{"name":"children","value":false}],
     "computed":[],
     "blocks":[{"id":"trip","type":"form","visible_if":null,"blocks":[
       {"id":"country","type":"text_field","visible_if":null,"label":"Страна","bind":"country","placeholder":"Например, Турция","keyboard":"text","max_length":60},
       {"id":"departure","type":"date_picker","visible_if":null,"label":"Вылет","bind":"departure","min":"2026-10-12","max":null},
       {"id":"days","type":"slider","visible_if":null,"label":"Дней","bind":"days","min":1,"max":60,"step":1,"format":"integer"},
       {"id":"children","type":"checkbox","visible_if":null,"label":"Еду с детьми","bind":"children"},
       {"id":"children-note","type":"callout","visible_if":"children","text":"Для детей понадобится свидетельство о рождении или их загранпаспорт.","tone":"info"}],
      "submit":{"label":"Подобрать документы","action":null}}]}
    """#

    static let mixed = #"""
    {"version":1,"mode":"mixed","text":"Сводка по документам. Подвиньте горизонт, чтобы увидеть, что истекает:",
     "state":[{"name":"horizon","value":365}],"computed":[],
     "blocks":[
      {"id":"kpis","type":"grid","visible_if":null,"columns":2,"blocks":[
        {"id":"docs","type":"metric","visible_if":null,"label":"Документов","value":null,"format":"integer","unit":null,"caption":null,"trend":null,"source":{"kind":"documents","types":null,"categories":null,"folder_id":null,"owner":null,"query":null,"columns":null},"aggregate":{"op":"count","column":null}},
        {"id":"soon","type":"metric","visible_if":null,"label":"Истекают за {{ horizon }} дн.","value":null,"format":"integer","unit":null,"caption":null,"trend":null,"source":{"kind":"expiring","within_days":{"expr":"horizon"}},"aggregate":{"op":"count","column":null}}]},
      {"id":"horizon","type":"slider","visible_if":null,"label":"Горизонт, дней","bind":"horizon","min":30,"max":1825,"step":30,"format":"integer"},
      {"id":"views","type":"tabs","visible_if":null,"bind":null,"tabs":[
        {"id":"share","title":"Доли","blocks":[{"id":"pie","type":"chart","visible_if":null,"kind":"pie","title":null,"x":{"key":"key","title":"Категория","kind":"category"},"y":{"key":"value","title":"Документов","format":"integer"},"series":null,"columns":null,"rows":null,"source":\#(statsSource),"generate":null,"height":"s"}]},
        {"id":"expiring","title":"Скоро истекают","blocks":[{"id":"expiring-table","type":"table","visible_if":null,"columns":[{"key":"title","title":"Документ","format":null,"align":null},{"key":"valid_until","title":"До","format":"date","align":null},{"key":"days_left","title":"Дней","format":"integer","align":"trailing"}],"rows":null,"source":{"kind":"expiring","within_days":{"expr":"horizon"}},"generate":null,"max_rows":null}]}]},
      {"id":"note","type":"callout","visible_if":null,"text":"Загранпаспорт лучше менять заранее: запись в МФЦ бывает на месяц вперёд.","tone":"warning"},
      {"id":"how","type":"disclosure","visible_if":null,"title":"Как считается срок","expanded":false,"blocks":[{"id":"how-text","type":"text","visible_if":null,"text":"Срок — из поля «Действует до», а у паспорта РФ — по замене в 20 и 45 лет.","style":"caption"}]},
      {"id":"ask","type":"button","visible_if":null,"label":"Что взять в МФЦ?","style":"secondary","action":{"kind":"ask","text":"Какие документы взять в МФЦ для замены загранпаспорта?"}}
     ]}
    """#

    static let brokenJSON = #"{"version":1,"mode":"ui","text":"","state":[],"blocks":[{"id":"x","type":"metric","label":"Обрыв"#

    static let unknownComponent = #"""
    {"version":1,"mode":"mixed","text":"Часть ответа не прошла проверку — показываю остальное:","state":[],"computed":[],"blocks":[
     {"id":"video","type":"video_player","visible_if":null,"url":"https://example.com/a.mp4"},
     {"id":"bad","type":"metric","visible_if":null,"label":"Сломанное выражение","value":{"expr":"amount * * 2"},"format":null,"unit":null,"caption":null,"trend":null,"source":null,"aggregate":null},
     {"id":"ok","type":"text","visible_if":null,"text":"Этот блок прошёл проверку.","style":null}
    ]}
    """#

    static let forbiddenAction = #"""
    {"version":1,"mode":"mixed","text":"Сайты и скрипты из ответа не открываются. Разрешённые действия — работают:","state":[],"computed":[],"blocks":[
     {"id":"js","type":"button","visible_if":null,"label":"Выполнить скрипт","style":"primary","action":{"kind":"run_js","code":"alert(1)"}},
     {"id":"url","type":"button","visible_if":null,"label":"Открыть сайт","style":"secondary","action":{"kind":"open_url","url":"https://example.com"}},
     {"id":"ask","type":"button","visible_if":null,"label":"Спросить в чате","style":"secondary","action":{"kind":"ask","text":"Какие действия разрешены?"}}
    ]}
    """#
}

/// Поддельные данные приложения: синтетические документы, без настоящих людей
struct GenUIFakeDataProvider: GenUIDataProvider {
    var today = GenUIDay(date: Date())

    struct Document {
        let id: String
        let title: String
        let type: String
        let category: String
        let owner: String
        let validUntil: GenUIDay?
        let documentDate: GenUIDay?
    }

    static let documents: [Document] = [
        Document(id: "d1", title: "Паспорт РФ", type: "passport_ru", category: "Удостоверения", owner: "Иванов И. И.", validUntil: nil, documentDate: GenUIDay(year: 2020, month: 5, day: 14)),
        Document(id: "d2", title: "Загранпаспорт", type: "passport_intl", category: "Удостоверения", owner: "Иванов И. И.", validUntil: GenUIDay(date: Date().addingTimeInterval(200 * 86_400)), documentDate: GenUIDay(year: 2017, month: 3, day: 1)),
        Document(id: "d3", title: "Полис ОСАГО", type: "other", category: "Транспорт", owner: "Иванов И. И.", validUntil: GenUIDay(date: Date().addingTimeInterval(40 * 86_400)), documentDate: GenUIDay(year: 2025, month: 11, day: 20)),
        Document(id: "d4", title: "Водительское удостоверение", type: "driver_license", category: "Транспорт", owner: "Иванов И. И.", validUntil: GenUIDay(date: Date().addingTimeInterval(900 * 86_400)), documentDate: GenUIDay(year: 2019, month: 4, day: 2)),
        Document(id: "d5", title: "Трудовой договор", type: "other", category: "Работа", owner: "Иванов И. И.", validUntil: nil, documentDate: GenUIDay(year: 2023, month: 9, day: 1)),
        Document(id: "d6", title: "Диплом бакалавра", type: "diploma", category: "Учёба", owner: "Иванов И. И.", validUntil: nil, documentDate: GenUIDay(year: 2022, month: 7, day: 1)),
        Document(id: "d7", title: "Справка 2-НДФЛ", type: "certificate", category: "Финансы", owner: "Иванов И. И.", validUntil: nil, documentDate: GenUIDay(year: 2026, month: 2, day: 10)),
        Document(id: "d8", title: "Медицинский полис", type: "other", category: "Медицина", owner: "Иванова А. С.", validUntil: GenUIDay(date: Date().addingTimeInterval(1500 * 86_400)), documentDate: GenUIDay(year: 2021, month: 1, day: 15)),
    ]

    func rows(for source: GenUIDataSource) async throws -> GenUIRows {
        try await Task.sleep(for: .milliseconds(150))
        switch source.kind {
        case .documents:
            let documents = Self.documents.filter { source.types?.contains($0.type) ?? true }
            return GenUIRows(columns: ["id", "title", "type", "category", "owner", "valid_until"], rows: documents.map { document in
                ["id": .string(document.id), "title": .string(document.title), "type": .string(document.type),
                 "category": .string(document.category), "owner": .string(document.owner),
                 "valid_until": document.validUntil.map(GenUIScalar.date) ?? .null]
            })
        case .documentStats:
            let groups = Dictionary(grouping: Self.documents, by: \.category)
            return GenUIRows(columns: ["key", "value"], rows: groups.keys.sorted().map { key in
                ["key": .string(key), "value": .number(Double(groups[key]!.count))]
            })
        case .expiring:
            let horizon = source.withinDays ?? 365
            let rows: [[String: GenUIScalar]] = Self.documents.compactMap { document in
                guard let until = document.validUntil,
                      let days = GenUIDay.calendar.dateComponents([.day], from: today.date, to: until.date).day,
                      days >= 0, days <= horizon else { return nil }
                return ["id": .string(document.id), "title": .string(document.title), "type": .string(document.type),
                        "owner": .string(document.owner), "valid_until": .date(until), "days_left": .number(Double(days))]
            }
            return GenUIRows(columns: ["id", "title", "type", "owner", "valid_until", "days_left"], rows: rows.sorted { ($0["days_left"]?.number ?? 0) < ($1["days_left"]?.number ?? 0) })
        case .amounts:
            return GenUIRows(columns: ["date", "label", "value", "currency"], rows: [])
        case .fields:
            return GenUIRows(columns: ["key", "title", "value"], rows: [["key": .string("series_number"), "title": .string("Серия и номер"), "value": .string("•••• ••••56")]])
        }
    }
}

/// Поддельный исполнитель: записывает вызовы и честно говорит, что передал
@MainActor
@Observable
final class GenUIFakePerformer: GenUIActionPerformer {
    private(set) var calls: [String] = []

    func perform(_ action: GenUIAction, block: String, state: GenUIStateSnapshot) async -> GenUIActionOutcome {
        try? await Task.sleep(for: .milliseconds(300))
        switch action {
        case .submit:
            calls.append("submit: " + state.values.keys.sorted().joined(separator: ", "))
            return .done("Передано модели: " + state.values.keys.sorted().joined(separator: ", "))
        case .ask(let text):
            calls.append("ask")
            return .done("Вопрос отправлен: «\(text.description)»")
        default:
            calls.append(action.kind.rawValue)
            return .done("Передано приложению: \(action.kind.rawValue)")
        }
    }
}

struct GenUIGalleryView: View {
    @State private var performer = GenUIFakePerformer()

    var body: some View {
        NavigationStack {
            List(GenUIGallery.scenarios) { scenario in
                NavigationLink(scenario.title) {
                    GenUIGalleryScenarioView(scenario: scenario, performer: performer)
                }
                .accessibilityIdentifier("genui-scenario-\(scenario.id)")
            }
            .navigationTitle("Generative UI")
        }
    }
}

private struct GenUIGalleryScenarioView: View {
    let scenario: GenUIGallery.Scenario
    let performer: GenUIFakePerformer

    @State private var models: [GenUIMessageModel] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(scenario.question)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                ForEach(models) { model in
                    GenUIMessageView(model: model, environment: GenUIEnvironment(dataProvider: GenUIFakeDataProvider(), actionPerformer: performer))
                    if !model.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Проверка: \(pluralize(model.issues.count, "замечание", "замечания", "замечаний"))").font(.caption.weight(.semibold))
                            ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                                Text(issue.description).font(.caption2)
                            }
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("genui-issues")
                    }
                }
                if let last = performer.calls.last {
                    Text("Последний вызов: \(last)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("genui-log")
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(scenario.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if models.isEmpty { models = scenario.payloads.map { GenUIMessageModel(json: Data($0.utf8)) } }
        }
    }
}
#endif
