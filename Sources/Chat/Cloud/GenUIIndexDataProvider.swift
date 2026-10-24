import Foundation

/// Данные приложения для блоков интерфейса с `source` — из индекса на iPhone
/// (docs/genui.md, «Источники данных»). Только папки, доступные для поиска:
/// суперскрытых для модели нет. Колонок с номерами нет вовсе, длинные цифры в
/// названиях закрыты, поле серии и номера — маской «•••• ••••56». Считается
/// при каждой отрисовке: документ из папки, которую скрыли, пропадает и из
/// старого ответа
struct GenUIIndexDataProvider: GenUIDataProvider {
    let search: SearchService
    var today: @Sendable () -> Date = { Date() }

    func rows(for source: GenUIDataSource) async throws -> GenUIRows {
        await compute(source)
    }

    /// Не больше строк — интерфейс всё равно показывает первые
    static let maxRows = 500

    // MARK: - Каталог

    /// Документ, как его видят источники
    struct Entry {
        let id: Int64
        let title: String
        let kind: String
        let type: DocumentType
        let category: String
        let folderID: UUID
        let folder: String
        let owner: String
        let ownerFull: String
        let documentDate: GenUIDay?
        let validUntil: GenUIDay?
        let pages: Int
        let amounts: [DocumentMetadata.Amount]
        let fields: [DocumentField]
    }

    @MainActor
    private func catalog(_ source: GenUIDataSource) async -> [Entry] {
        let folders = Dictionary(uniqueKeysWithValues: search.searchableFolders.map { ($0.id, $0) })
        let types = (source.types ?? []).compactMap(DocumentType.init(rawValue:))
        let stored = await search.documents(ofTypes: types.isEmpty ? DocumentType.allCases : types)
        let ids = stored.map(\.id)
        let fields = await search.fields(for: ids)
        let metadata = await search.metadata(for: ids)
        var found: Set<Int64>?
        if let query = source.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            found = Set(await search.search(query, limit: Self.maxRows).compactMap(\.documentID))
        }
        let ownerWords = source.owner.map { SearchText.tokens(in: $0).map(\.word) } ?? []
        let categories = Set(source.categories ?? [])
        let now = today()

        return stored.sorted { $0.id < $1.id }.compactMap { document in
            guard let folder = folders[document.folderID] else { return nil }
            if let folderID = source.folderID, folderID != folder.id { return nil }
            if let found, !found.contains(document.id) { return nil }
            let documentFields = fields[document.id] ?? []
            let values = Dictionary(documentFields.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            let owner = values[FieldKey.fullName] ?? ""
            if !ownerWords.isEmpty, !ChatRouter.nameMatches(ownerWords, owner: owner) { return nil }
            let meta = metadata[document.id]
            let category = meta?.category ?? (document.type.isPersonal ? DocumentCategory.identity.rawValue : DocumentCategory.other.rawValue)
            if !categories.isEmpty, !categories.contains(category) { return nil }
            let validity = DocumentValidity.of(type: document.type, fields: values, validUntil: meta?.validUntil.nilIfEmpty, today: now)
            return Entry(
                id: document.id,
                title: Self.withoutNumbers(meta?.title.nilIfEmpty ?? SearchText.title(fromFileName: document.fileName)),
                kind: meta?.kind.nilIfEmpty ?? document.type.title(country: values[FieldKey.country]),
                type: document.type,
                category: category,
                folderID: folder.id,
                folder: folder.name,
                owner: owner.isEmpty ? "" : ChatRouter.shortName(owner),
                ownerFull: owner,
                documentDate: DocumentReadingMerge.date(meta?.documentDate).map { GenUIDay(date: $0, calendar: Self.calendar) },
                validUntil: validity.date.map { GenUIDay(date: $0, calendar: Self.calendar) },
                pages: document.pageCount,
                amounts: meta?.amounts ?? [],
                fields: documentFields
            )
        }
    }

    // MARK: - Источники

    @MainActor
    private func compute(_ source: GenUIDataSource) async -> GenUIRows {
        switch source.kind {
        case .documents: await documents(source)
        case .documentStats: await stats(source)
        case .expiring: await expiring(source)
        case .amounts: await amounts(source)
        case .fields: await fields(source)
        }
    }

    @MainActor
    private func documents(_ source: GenUIDataSource) async -> GenUIRows {
        let allowed = GenUIDataSourceSpec.documentColumns
        let columns = (source.columns ?? []).filter(allowed.contains)
        let shown = columns.isEmpty ? allowed : columns
        let rows: [[String: GenUIScalar]] = await catalog(source).prefix(Self.maxRows).map { entry in
            var row: [String: GenUIScalar] = [:]
            for column in shown { row[column] = Self.value(column, of: entry) }
            return row
        }
        return GenUIRows(columns: shown, rows: rows)
    }

    /// Сводка: число документов или сумма по группам. Без валюты сумма
    /// складывается только у самой частой валюты — рубли с долларами не
    /// складываются
    @MainActor
    private func stats(_ source: GenUIDataSource) async -> GenUIRows {
        let entries = await catalog(source)
        let grouping = source.groupBy ?? "category"
        var totals: [String: Double] = [:]
        if source.metric == "amount_sum" {
            let currency = source.currency?.uppercased() ?? Self.commonCurrency(entries.flatMap(\.amounts))
            for entry in entries {
                for amount in entry.amounts where amount.currency.uppercased() == currency {
                    guard let value = Self.number(amount.value) else { continue }
                    totals[Self.group(grouping, of: entry), default: 0] += value
                }
            }
        } else {
            for entry in entries { totals[Self.group(grouping, of: entry), default: 0] += 1 }
        }
        // Месяцы и годы — по порядку времени, остальное — по убыванию
        let keys = ["month", "year"].contains(grouping)
            ? totals.keys.sorted()
            : totals.keys.sorted { totals[$0]! != totals[$1]! ? totals[$0]! > totals[$1]! : $0 < $1 }
        return GenUIRows(columns: ["key", "value"], rows: keys.prefix(Self.maxRows).map { ["key": .string($0), "value": .number(totals[$0]!)] })
    }

    /// Сроки: уже истёкшие и те, что истекают в ближайшие `within_days` дней
    /// (по умолчанию — год)
    @MainActor
    private func expiring(_ source: GenUIDataSource) async -> GenUIRows {
        let todayDay = GenUIDay(date: today(), calendar: Self.calendar)
        let horizon = todayDay.adding(.day, max(0, source.withinDays ?? 365)) ?? todayDay
        let entries = await catalog(source).filter { entry in
            guard let until = entry.validUntil else { return false }
            return until <= horizon
        }.sorted { $0.validUntil! < $1.validUntil! }
        let columns = ["id", "title", "type", "owner", "valid_until", "days_left"]
        let rows: [[String: GenUIScalar]] = entries.prefix(Self.maxRows).map { entry in
            let days = Self.calendar.dateComponents([.day], from: todayDay.date, to: entry.validUntil!.date).day ?? 0
            return [
                "id": .string(ChatCard.encodeID(entry.id)), "title": .string(entry.title), "type": .string(entry.type.rawValue),
                "owner": .string(entry.owner), "valid_until": .date(entry.validUntil!), "days_left": .number(Double(days)),
            ]
        }
        return GenUIRows(columns: columns, rows: rows)
    }

    /// Суммы из метаданных: чеки, договоры, полисы. Дата — дата документа
    @MainActor
    private func amounts(_ source: GenUIDataSource) async -> GenUIRows {
        let currency = source.currency?.uppercased()
        var rows: [(GenUIDay?, [String: GenUIScalar])] = []
        for entry in await catalog(source) {
            if let from = source.from, let date = entry.documentDate, date < from { continue }
            if let to = source.to, let date = entry.documentDate, date > to { continue }
            if (source.from != nil || source.to != nil) && entry.documentDate == nil { continue }
            for amount in entry.amounts {
                guard let value = Self.number(amount.value) else { continue }
                if let currency, amount.currency.uppercased() != currency { continue }
                rows.append((entry.documentDate, [
                    "date": entry.documentDate.map(GenUIScalar.date) ?? .null,
                    "label": .string(Self.withoutNumbers(amount.label.nilIfEmpty ?? entry.title)),
                    "value": .number(value),
                    "currency": .string(amount.currency.uppercased()),
                    "document_id": .string(ChatCard.encodeID(entry.id)),
                ]))
            }
        }
        let sorted = rows.sorted { lhs, rhs in
            switch (lhs.0, rhs.0) {
            case let (left?, right?): left < right
            case (nil, _?): false
            case (_?, nil): true
            case (nil, nil): false
            }
        }
        return GenUIRows(columns: ["date", "label", "value", "currency", "document_id"], rows: sorted.prefix(Self.maxRows).map(\.1))
    }

    /// Поля документа. Серия и номер — маской, как в карточке до Face ID
    @MainActor
    private func fields(_ source: GenUIDataSource) async -> GenUIRows {
        guard let id = source.documentID,
              let entry = await catalog(GenUIDataSource(kind: .fields)).first(where: { $0.id == id }) else {
            return GenUIRows(columns: ["key", "title", "value"], rows: [])
        }
        let keys = (source.keys ?? []).isEmpty ? FieldKey.order : source.keys!
        let rows: [[String: GenUIScalar]] = keys.compactMap { key in
            guard let field = entry.fields.first(where: { $0.key == key }) else { return nil }
            let value = FieldKey.isSensitive(key) ? FieldMask.masked(field.value) : field.value
            return ["key": .string(key), "title": .string(FieldKey.title(key)), "value": .string(value)]
        }
        return GenUIRows(columns: ["key", "title", "value"], rows: rows)
    }

    // MARK: - Значения

    private static func value(_ column: String, of entry: Entry) -> GenUIScalar {
        switch column {
        case "id": .string(ChatCard.encodeID(entry.id))
        case "title": .string(entry.title)
        case "kind": .string(entry.kind)
        case "type": .string(entry.type.rawValue)
        case "category": .string(categoryTitle(entry.category))
        case "folder": .string(entry.folder)
        case "owner": .string(entry.owner)
        case "document_date": entry.documentDate.map(GenUIScalar.date) ?? .null
        case "valid_until": entry.validUntil.map(GenUIScalar.date) ?? .null
        case "pages": .number(Double(entry.pages))
        default: .null
        }
    }

    private static func group(_ grouping: String, of entry: Entry) -> String {
        switch grouping {
        case "type": entry.type.rawValue
        case "kind": entry.kind
        case "folder": entry.folder
        case "owner": entry.owner.nilIfEmpty ?? "Без владельца"
        case "month": entry.documentDate.map { String(format: "%04d-%02d", $0.year, $0.month) } ?? "Без даты"
        case "year": entry.documentDate.map { String($0.year) } ?? "Без даты"
        default: categoryTitle(entry.category)
        }
    }

    private static func categoryTitle(_ raw: String) -> String {
        DocumentCategory(rawValue: raw)?.title ?? raw
    }

    /// «120 000,50 ₽» → 120000.5
    static func number(_ text: String) -> Double? {
        let cleaned = text.filter { $0.isNumber || $0 == "," || $0 == "." || $0 == "-" }
            .replacingOccurrences(of: ",", with: ".")
        return Double(cleaned)
    }

    private static func commonCurrency(_ amounts: [DocumentMetadata.Amount]) -> String {
        let counts = Dictionary(grouping: amounts.map { $0.currency.uppercased() }, by: { $0 }).mapValues(\.count)
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? "RUB"
    }

    /// Номер договора в названии — «Договор № …»: цифры длиннее трёх закрыты
    static func withoutNumbers(_ text: String) -> String {
        text.replacingOccurrences(of: #"\d{4,}"#, with: "…", options: .regularExpression)
    }

    private static let calendar = Calendar(identifier: .gregorian)
}
