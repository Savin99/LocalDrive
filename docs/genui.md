# Generative UI: интерфейс внутри ответа модели

ТЗ владельца от 12.10.2026: Gemini 3.8 Flash сама выбирает формат ответа:
текст, интерфейс или их смесь. Интерфейс она описывает декларативным JSON, а
приложение рисует его своими нативными компонентами. Модель выбирает
структуру, приложение отвечает за вид. Кода в ответе нет: только блоки из
реестра, выражения маленького языка без побочных эффектов и действия из белого
списка.

Это расширение каталога карточек из спецификации чата (`fields`, `document`,
`expiry`, …), а не замена ему: эти карточки становятся блоком `app_card`.

## Что проверено в документации (12.10.2026)

- Structured Outputs можно сочетать с вызовом функций в одном запросе — «only
  to Gemini 3 series models» (ai.google.dev/gemini-api/docs/structured-output).
  Значит, отдельный запрос «оформить ответ» не нужен: модель вызывает
  инструменты, а финальный ответ приходит JSON по схеме.
- Потоковые куски структурированного ответа — «valid partial JSON strings that
  can be concatenated». Пример на странице — через Interactions API; работает ли
  так же `streamGenerateContent`, проверяет модельная часть.
- В схеме есть `anyOf` и `$ref` (в том числе рекурсивный), `enum`, `minimum` и
  `maximum`, `minItems` и `maxItems`, `additionalProperties`. Слишком большие
  или глубокие схемы сервер может отклонить — схема компактная.

## Слои и файлы

| Слой | Где | Кто |
| --- | --- | --- |
| Схема: типы, лимиты, проверка, экспорт JSON Schema | `Sources/GenUI/Schema/` | отрисовка |
| Выражения: разбор и вычисление с лимитом шагов | `Sources/GenUI/Expressions/` | отрисовка |
| Состояние, действия, источники данных (протоколы) | `Sources/GenUI/Runtime/` | отрисовка |
| Реестр и нативные компоненты | `Sources/GenUI/Components/` | отрисовка |
| Потоковый разбор ответа | `Sources/GenUI/Streaming/` | модель |
| Промпт, схема ответа, цикл с инструментами, источники данных из индекса, действия приложения | `Sources/Chat/Cloud/` | модель |
| Сообщение чата с интерфейсом | `ChatSession`, `ChatView` | модель |

## Интерфейсы (готовы, собираются)

Всё в `Sources/GenUI/`. Модельная часть использует только это:

```swift
// Схема ответа для response_format (строгий режим OpenAI). Вставлять строкой
// как есть: словарь потерял бы порядок ключей, а text должен прийти раньше blocks
GenUIJSONSchema.openAIStrictString      // String; .openAIStrict — GenUIOrderedJSON
GenUIJSONSchema.gemini                   // та же схема
GenUIJSONSchema.promptCatalog()          // String для системной инструкции: блоки, поля, когда уместны

// Проверка
GenUIValidator.document(from: Data) -> GenUIValidation        // .document, .issues; не бросает
GenUIValidator.document(from: JSONValue) -> GenUIValidation
GenUIValidator.block(from: JSONValue, usedIDs:, blockLimit:) -> (block: GenUIBlock?, issues: [GenUIIssue])

// Сообщение с интерфейсом: поток наполняет, чат показывает
@MainActor @Observable final class GenUIMessageModel: Identifiable {
    init()                                        // пустое, phase = .streaming
    convenience init(document: GenUIDocument, issues: [GenUIIssue] = [])
    convenience init(json: Data)                  // разбор и проверка
    func setPartialText(_ text: String)           // текст, пока растёт
    func setState(_ json: JSONValue)              // закрытый массив state
    func setComputed(_ json: JSONValue)           // закрытый массив computed
    @discardableResult func append(_ json: JSONValue) -> Bool   // закрытый элемент blocks
    func finish(_ document: GenUIDocument, issues: [GenUIIssue] = [])
    func finish(json: Data)
    func fail(_ reason: String)                   // остаётся то, что пришло
    @discardableResult func replace(blockID: String, with json: JSONValue) -> Bool  // после regenerate
    func revalidate()                             // повторная проверка при открытии из истории
    var document: GenUIDocument                   // .json — для истории и для модели
    var mode, text, blocks, issues, phase, state: GenUIState, runner: GenUIActionRunner
}
struct GenUIMessageView: View { init(model:, environment:, showsText: Bool = true) }

// Что даёт приложение
struct GenUIEnvironment {
    var dataProvider: (any GenUIDataProvider)?
    var actionPerformer: (any GenUIActionPerformer)?
    var appCard: (@MainActor (ChatCard) -> AnyView)?   // карточка каталога чата
}
protocol GenUIDataProvider: Sendable {
    func rows(for source: GenUIDataSource) async throws -> GenUIRows
}
@MainActor protocol GenUIActionPerformer: AnyObject {
    func perform(_ action: GenUIAction, block: String, state: GenUIStateSnapshot) async -> GenUIActionOutcome
}
// GenUIAction: .submit(include:message:), .regenerate(blockID:instruction:), .ask(text:),
//   .openDocument, .showFields, .copyField, .openFolder, .remind, .proposeFileActions(arguments: JSONValue)
//   (.set и .reset выполняет движок). .needsConfirmation — remind и propose_file_actions.
// GenUIActionOutcome: .done(String?) — текст под кнопкой, .failed(String)
// GenUIStateSnapshot: .values, .json, .summary — значения формы для следующего сообщения модели
// GenUIDataSource: kind (documents, document_stats, expiring, amounts, fields) и вычисленные
//   параметры; GenUIRows(columns:, rows: [[String: GenUIScalar]])
```

Отладочная галерея: запуск с аргументом `-GenUIGallery` открывает семь
сценариев ТЗ на поддельных данных.

## Ответ модели — схема версии 1

Формат рассчитан на строгий режим Structured Outputs у OpenAI (проверено
координатором 12.10.2026 на developers.openai.com): корень — объект; каждое
свойство обязательно, необязательное приходит как `null`; у каждого объекта
`additionalProperties: false`, поэтому свободных словарей нет — переменные,
строки таблиц и колонки рядов идут массивами. Ключи в ответе идут в порядке
схемы. Та же схема подходит и Gemini. Разбор терпим: `null` везде значит «нет»,
а словари вместо массивов тоже понимаются.

```json
{
  "version": 1,
  "mode": "text | ui | mixed",
  "text": "Короткий текст; в mixed — подводка к интерфейсу",
  "state": [ { "name": "amount", "value": 3000000 }, { "name": "start", "value": "2026-10-12" } ],
  "computed": [ { "name": "payment", "expr": "amount * r / (1 - pow(1 + r, -n))" } ],
  "blocks": [ { "id": "b1", "type": "metric", "visible_if": null, "…": "…" } ]
}
```

Порядок: `version`, `mode`, `text`, `state`, `computed`, `blocks`. Текст в потоке
приходит первым, блоки — последними, по одному.

- `text` — без интерфейса: `blocks` пуст, `text` обязателен.
- `ui` — только блоки, `text` — одна строка-подпись или пусто.
- `mixed` — текст и блоки.
- `state` — начальные значения переменных: число, строка, логическое; дата —
  строкой «ГГГГ-ММ-ДД».
- `computed` — именованные выражения над состоянием и друг другом: «платёж»,
  «переплата». В выражениях — как переменные. Циклы дают «—».

### Общие поля блока

- `id` — уникален в ответе, `[a-z0-9_-]{1,40}`.
- `type` — тип из реестра.
- `visible_if` — выражение. Блок виден, пока оно истинно.

### Значения

- Литерал: число, строка, логическое значение, дата строкой `ГГГГ-ММ-ДД`.
- Выражение — объект `{ "expr": "…" }`.
- В строках поддерживается подстановка `{{ выражение }}`.

### Типы блоков (базовый набор)

У каждого блока все свойства схемы присутствуют; необязательные — `null`.

Отображение:
- `text {text, style: body|caption|callout|null}`
- `heading {text, level: 1|2|3|null}`
- `metric {label, value|null, format|null, unit|null, caption|null, trend: up|down|flat|null, source|null, aggregate: {op: count|sum|avg|min|max, column|null}|null}`
- `list {items: [{text, secondary|null, icon|null, action|null}]}`
- `table {columns: [{key, title, format|null, align: leading|center|trailing|null}], rows: [[ячейка]]|null, source|null, generate|null, max_rows|null}` — строка `rows` — массив значений в порядке `columns`
- `comparison {items: [{title, values: [{label, value}]}]}` — 2–4 колонки
- `progress {label, value, max|null, format|null}`
- `callout {text, tone: info|success|warning|danger|null}`

Визуализация:
- `chart {kind: line|bar|area|point|pie|histogram, title|null, x: {key, title|null, kind: number|date|category}, y: {key, title|null, format|null}, series|null, columns: [ключ]|null, rows: [[ячейка]]|null, source|null, generate|null, height: s|m|l|null}` — Swift Charts

Ввод и действия:
- `button {label, style: primary|secondary|null, action}`
- `toggle {label, bind}`, `checkbox {label, bind}`
- `slider {label, bind, min, max, step|null, format|null}`
- `text_field {label, bind, placeholder|null, keyboard: text|number|decimal|null, max_length|null}`
- `date_picker {label, bind, min|null, max|null}`
- `picker {label, bind, options: [{value, label}], style: menu|segmented|null}`
- `form {blocks, submit: {label, action|null}}` — без `action` форма отправляет модели значения своих полей

Компоновка:
- `stack {axis: vertical|horizontal|null, spacing: s|m|l|null, blocks}`
- `grid {columns: 1–4, blocks}` — на узком экране складывается в одну колонку
- `section {title|null, subtitle|null, style: plain|card|null, blocks}`
- `tabs {bind|null, tabs: [{id, title, blocks}]}`
- `disclosure {title, expanded|null, blocks}`
- `divider {}`

Приложение:
- `app_card {card: {kind: fields|document|file_list|snippet|expiry, document_id|null, document_ids|null, keys|null, page|null}}` —
  карточка из существующего каталога чата; значения, как и раньше, из базы.

Ряд для таблицы или графика: `generate {var, from, to, step|null, columns: [{key, expr}]}`.
Ячейка — число, строка, логическое или `null`. Значение свойства — число,
строка, логическое или `{"expr": "…"}`.

Новый тип добавляется регистрацией компонента в реестре: из реестра собираются
и схема ответа, и подсказка модели — движок не правится.

### Состояние и выражения

- `state` — массив `{name, value}`; `computed` — массив `{name, expr}`.
- `bind` у полей ввода указывает на переменную. Переменная без начального
  значения получает значение по типу поля.
- Выражения:
  - операторы `+ - * / % ^`, сравнения, `&& || !`, `?:`;
  - переменные состояния; в `generate` — переменная ряда и `prev.<колонка>` (предыдущая строка);
  - функции:
    - математика: `round(x, d)`, `floor`, `ceil`, `abs`, `min`, `max`, `pow`, `sqrt`, `log`, `exp`, `clamp(x, lo, hi)`, `if(c, a, b)`;
    - даты: `today()`, `add_days(d, n)`, `add_months`, `add_years`, `days_between(a, b)`, `years_between(a, b)`;
    - формат: `format_date(d)`, `format_number(x, d)`, `format_money(x, "RUB")`, `percent(x)`.
- Чистые функции, лимит длины и шагов вычисления. Ошибка вычисления — «—» в
  значении, а не падение.
- `generate {var, from, to, step|null, columns: [{key, expr}]}` строит ряд
  для таблицы или графика: калькуляторы, графики платежей. Не больше 500
  точек. На первой строке `prev.<колонка>` = 0.

### Действия (белый список)

Каждое действие — объект с полем `kind` и своим набором полей.

| Действие | Что делает | Подтверждение |
| --- | --- | --- |
| `set {var, value}`, `reset {vars\|null}` | локальное состояние | — |
| `submit {include\|null, message\|null}` | новое сообщение модели со значениями формы | — |
| `regenerate {block_id, instruction\|null}` | модель перестраивает этот блок с текущим состоянием | — |
| `ask {text}` | отправить вопрос в чат, как чип | — |
| `open_document {document_id}` | открыть файл | — |
| `show_fields {document_id, keys}` | карточка полей из базы | — |
| `copy_field {document_id, key}` | копировать поле, номер — целиком, без Face ID (24.10.2026) | — |
| `open_folder {folder_id}` | перейти в папку | — |
| `remind {document_id}` | напоминание о сроке | да |
| `propose_file_actions {summary, actions: [{kind: save_attachment\|move_files\|rename_file\|create_folder, …}]}` | карточка-предложение файловых действий | выполняет только кнопка «Принять» |

Ссылок, HTML, скриптов, произвольных URL и системных действий нет.
Неизвестное действие при проверке отбрасывается вместе с кнопкой.

### Источники данных — только настоящие данные

Таблицы, графики и показатели о данных приложения берут значения через
`source` — объект с полем `kind`. Приложение вычисляет их из индекса на iPhone при отрисовке, только по
папкам, доступным для поиска. Номера документов — маской. Литералы в `rows`
допустимы только для чисел, которые ввёл человек, и для расчётов.

- `documents {types|null, categories|null, folder_id|null, owner|null, query|null, columns|null}` —
  колонки: `id`, `title`, `kind`, `type`, `category`, `folder`, `owner`,
  `document_date`, `valid_until`, `pages`.
- `document_stats {group_by: category|type|kind|folder|owner|month|year, metric: count|amount_sum, currency|null, types|null, categories|null, folder_id|null, owner|null}` — строки `key`, `value`
- `expiring {within_days|null}` — `within_days` может быть выражением
- `amounts {categories|null, from|null, to|null, currency|null}` — суммы из метаданных (чеки, договоры):
  дата, подпись, сумма, валюта, документ.
- `fields {document_id, keys}` — строки `key`, `title`, `value`

### Лимиты

80 блоков, вложенность 6, 30 переменных, 200 строк таблицы, 500 точек графика,
4000 знаков текста в блоке, 300 знаков выражения, 50 вариантов выбора.

### Проверка и деградация

1. Ответ сначала разбирается, потом проверяется: типы, лимиты, уникальность
   `id`, разбор выражений, `bind` на объявленные переменные, действия из списка.
2. Неверный блок выпадает, остальные показываются.
3. Если не осталось ни одного блока, показывается `text`. Если нет и его —
   «Не получилось показать ответ», а в журнал уходит причина без содержимого.
4. Сохранённая в сессии схема проверяется заново при каждом открытии, а
   источники данных пересчитываются. Документ из папки, которую скрыли,
   из старого ответа пропадает.

### Поток

- Ответ разбирается по мере прихода.
- `text` показывается частично, по мере роста строки.
- `state` применяется, когда объект закрыт.
- Каждый элемент `blocks` проверяется и показывается, только когда его JSON
  закрыт.
- Остановка генерации — кнопкой вместо «Отправить».
- Битый JSON — блоки, разобранные до сбоя, плюс текст.

## Проверка

Сценарии ТЗ:
1. Простой вопрос — только текст.
2. Сравнение с графиком и таблицей.
3. Калькулятор с ползунками.
4. Форма, значения которой идут в следующий ответ.
5. Смесь текста и нескольких виджетов.
6. Битый JSON и неизвестный компонент.
7. Неразрешённое действие.

Юнит-тесты на записанных ответах проверяют разбор, проверку, отрисовку,
состояние и действия. Живая проверка (`GenUILiveEvalTests`) гоняет те же семь
запросов в настоящий OpenAI: модель сама выбирает формат и строит интерфейс.
Ключ — только из окружения, в репозиторий не попадает:

```bash
TEST_RUNNER_OPENAI_API_KEY=… TEST_RUNNER_OPENAI_MODEL=gpt-6-luna \
  xcodebuild test -scheme LocalDrive -destination '…' -only-testing:LocalDriveTests/GenUILiveEvalTests
```

xcodebuild передаёт в тест переменные с приставкой `TEST_RUNNER_`. Без ключа
тест пропускается. Хранилище синтетическое: паспорт, загранпаспорт, договор,
два чека; их метаданные заполняет заглушка распознавания — в облако уходят
только вопросы чата, 7 запросов. Отчёт — вложение `genui-live-eval.md`:
режим, блоки, совпал ли формат с ожиданием ТЗ, замечания проверки, первый
токен и время. Падает тест, только если ответ не разобрался, был ошибкой
или в нём есть номер синтетического паспорта; выбор формата — в отчёте.

## Движок отрисовки: как проверен и что не сделано

Тесты движка — на ответах в формате схемы, без модели:
- `GenUIExpressionTests` — приоритеты, ленивые `if` и `&&`, деление на ноль,
  даты с краями месяца, русские форматы, ошибки разбора и лимиты;
- `GenUISchemaTests`:
  - деградация по блокам: неизвестный компонент, битое выражение, запрещённое
    действие, повтор и неверный `id`, глубина, число блоков, диапазоны;
  - привязки и приведение типов, режим по содержимому, `null` и словари;
  - экспорт схемы: обход всей схемы по правилам строгого режима OpenAI и
    порядок ключей;
- `GenUIRuntimeTests` — пересчёт `computed` при движении ползунка, `generate` с
  `prev.` и лимитом точек, цикл и цепочка в `computed` (кэш), поток с
  сохранением правок человека, перестройка вложенного блока, локальные и
  переданные действия, параметры источника от состояния;
- `GenUIGalleryUITests` — настоящими жестами в галерее: ползунок пересчитывает
  платёж, вкладки, отправка формы доходит до исполнителя, битый ответ даёт
  заглушку, запрещённых кнопок нет.

Не сделано или не проверено:
- Живой прогон на настоящем OpenAI ещё не сделан: у стенда нет ключа.
  Модельная часть проверена заглушкой сети.
- Ответ интерфейсом включён только для OpenAI. Gemini 3 по документации
  совмещает структурированный ответ с вызовом функций, но на настоящем Gemini
  это не проверено — там ответ по-прежнему текстом и карточками.
- `open_folder` не переходит в папку: из чата перехода в «Файлы» пока нет.
  Документы папки показываются карточкой под ответом.
- Карточка `app_card` после правки поля не перечитывается сама — до нового
  ответа.
- Из истории ответ открывается заново только в пределах сессии: переписка по
  решению владельца на диск не пишется.
- Графики — базовые: одна ось Y, без масштабирования и выбора точки пальцем.
- Поле ввода с числовой клавиатурой понимает целые и дробные числа, но не
  выражения вида «3 млн».

## Модельная часть (12–13.10.2026)

- **Запрос.** У OpenAI финальный ответ — строгий `text.format {type:
  "json_schema", name: "genui_answer", strict: true, schema}`. Схема —
  `GenUIJSONSchema.openAIStrictString`, вставляется в тело готовой строкой
  вместо заглушки (`CloudChatGenUI.body`): `CloudJSON` порядок ключей не
  хранит, а ответ идёт в порядке ключей схемы — text раньше blocks.
  Инструменты работают как раньше, кроме `show_cards`: карточки документов в
  ответе интерфейсом — блоки `app_card`, значения подставляет база.
- **Инструкция** (`CloudChatGenUI.system`): правила чата без строк про
  `show_cards`, выбор формата (простой вопрос — mode text, сравнение — chart и
  table, расчёт — slider и computed, параметры — form, документы — app_card и
  source), запрет выдумывать числа о документах и писать номера, каталог
  блоков `GenUIJSONSchema.promptCatalog()`. Опись документов — как у чата
  текстом: нужный документ сразу блоком app_card, без поиска.
- **Поток** (`Sources/GenUI/Streaming/`). `GenUIStreamParser` разбирает JSON по
  байтам и не полагается на порядок ключей: `text` — по мере роста строки,
  с escape и `\uXXXX` на границах кусков; `state` и `computed` — когда массив
  закрыт; каждый элемент `blocks` — когда закрыт его объект; скобки внутри
  строк границу не ломают. `GenUIStreamFeed` кладёт это в
  `GenUIMessageModel`; в конце закрытый JSON проверяется целиком
  `GenUIValidator`, оборванный — остаётся, что пришло (`fail`), не JSON —
  ответ простым текстом.
- **Маска номеров** — по разобранным значениям, а не по сырому JSON: маска
  сломала бы число в JSON. Число, в котором нашёлся номер документа,
  становится строкой «••••».
- **Сессия.** События `answerDelta` — сырые куски JSON. Новый раунд после
  вызова инструмента — новый ответ. Ход, кончившийся одними карточками
  (`propose_file_actions`), интерфейса не показывает. «Стоп» и сроки
  оставляют пришедшие блоки; если облако не ответило, отвечают правила и
  интерфейс убирается.
- **Источники данных** (`GenUIIndexDataProvider`) — из индекса при каждой
  отрисовке, только папки, доступные для поиска: `documents` (фильтры types,
  categories, folder_id, owner, query; колонки из списка схемы, остальные
  отбрасываются), `document_stats` (count или amount_sum; без валюты — самая
  частая валюта: рубли с долларами не складываются), `expiring` (истёкшие и
  истекающие за within_days, по умолчанию год; days_left), `amounts` (суммы
  из метаданных по дате документа), `fields` (серия и номер — маской). В
  названиях цифры длиннее трёх закрыты.
- **Действия** (`GenUIChatPerformer`): `ask` и `submit` — сообщение в чат
  (форма — подписью и значениями «days: 10»); `open_document` — просмотр;
  `show_fields` — карточка под ответом; `copy_field` — номер целиком;
  `open_folder` — документы папки карточкой; `remind` — с подтверждением
  диалогом; `propose_file_actions` — карточка предложения FileProposalBuilder,
  выполняет только «Принять»; `regenerate` — модель перестраивает блок по
  его JSON и значениям состояния, ход в историю не попадает.
- **Экран.** `MessageRow` показывает `GenUIMessageView`: блоки появляются по
  мере прихода, `app_card` — карточкой каталога (`GenUIAppCardView`).

Тесты: `GenUIStreamParserTests`, `GenUIStreamFeedTests`, `GenUIChatTests`
(форма запроса, поток в сообщение с блоком до конца ответа, действия,
источники на синтетическом индексе), `GenUILiveEvalTests` — с ключом.

## Живая проверка на настоящем OpenAI — 13.10.2026

Строгие ожидания (`GenUILiveEvalTests`), по 3 прогона на сценарий; вопросы — из
галереи, каждый честно допускает ожидаемый формат:

| Сценарий | Ожидание | До: сборка 13 | После: Luna | Sol, 1 прогон |
| --- | --- | --- | --- | --- |
| text — «Когда истекает загранпаспорт?» | mode text, без блоков | 0/3 (app_card) | 3/3, 1,9 с | 1/1, 3,7 с |
| compare — «Сколько у меня документов по категориям?» | chart и table, оба с source | 0/3 (нет chart) | 3/3, 2,8 с | 1/1, 7,0 с |
| calculator — «Посчитай ипотеку на 3 миллиона» | ≥ 2 поля, результат из объявленных переменных, ряд generate | 0/3 | 3/3, 3,4 с | 1/1, 13,6 с |
| form — «Какие документы взять в поездку?» | form с полями ввода | 0/3 (list) | 3/3, 2,8 с | 1/1, 15,6 с |
| mixed — «Что с моими документами?» | текст и ≥ 2 разных виджета | 0/3 (нет текста) | 3/3, 5,2 с | 1/1, 9,9 с |
| broken — «Покажи график» | разобран | 3/3 | 3/3, 2,0 с | 1/1, 8,7 с |
| forbidden — «Открой сайт» | разобран, текст объясняет | 3/3 | 3/3, 2,2 с | 1/1, 3,3 с |
| Устойчиво (≥ 2 из 3) | | **2 из 7** | **7 из 7** | 7 из 7 |

Время — среднее «всего» на ответ. Цена прогона из 24 запросов на Luna —
около $0,10, 7 запросов на Sol — около $0,29.

Что помогло:
- **Правила выбора формата и пример на каждое** (`CloudChatGenUI.instructions`):
  факт — текстом; показать документ — app_card; сравнение — chart и table с
  одним source; расчёт — калькулятор из пяти обязательных частей (state,
  computed, slider, metric из computed, ряд generate); не хватает данных —
  form; обзор — текст и два разных виджета. Прежняя строка «нужный документ —
  сразу app_card» заставляла отвечать карточкой на вопрос о дате.
- **Срок в описи** — «· до 15.03.2031», только записанный в документе (у
  паспорта РФ срок выводится из даты рождения — его нет): на «когда
  истекает» модель отвечает текстом сразу.
- **Luna думает на уровне low** для вопросов, просящих интерфейс
  (`CloudChatReasoning.wantsInterface`: сколько, категории, график, сводка,
  подбор, кредит, поездка…); вопрос о факте — none. Время осталось 2–5 с.
- Калькулятор без `computed` — частая ошибка: metric ссылается на `payment`,
  а формулы нет, на экране «—». Проверка требует, чтобы переменные
  выражения были объявлены.

Кэш префикса не срабатывает: 0–1 попадание на 24 запроса — и с инструкцией в
сообщении developer с явной отметкой `prompt_cache_breakpoint`, и в обычном
режиме обслуживания вместо быстрого (3 одинаковых запроса — 0). Причину
показал бы инструмент диагностики кэша, но он сравнивает сохранённые ответы,
а у нас `store: false`. Префикс — около 19 тыс. токенов: попадание сделало
бы ответ дешевле в 10 раз по входу и быстрее на первом токене.

