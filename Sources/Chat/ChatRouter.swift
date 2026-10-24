import Foundation

extension DocumentType {
    /// Документ человека: ищется по типу и имени владельца, отвечает полями
    var isPersonal: Bool {
        switch self {
        case .passportRU, .passportIntl, .snils, .inn, .driverLicense: true
        case .diploma, .certificate, .other: false
        }
    }

    /// Родительный падеж: «срок действия загранпаспорта», «паспорта РФ не нашёл»
    var genitiveTitle: String {
        switch self {
        case .passportRU: "паспорта РФ"
        case .passportIntl: "загранпаспорта"
        case .snils: "СНИЛС"
        case .inn: "ИНН"
        case .driverLicense: "водительского удостоверения"
        case .diploma: "диплома"
        case .certificate: "справки"
        case .other: "документа"
        }
    }

    /// Как сказать о документе в ответе: «паспорт РФ», «загранпаспорт»
    var spokenTitle: String {
        switch self {
        case .passportRU: "паспорт РФ"
        case .passportIntl: "загранпаспорт"
        case .snils: "СНИЛС"
        case .inn: "ИНН"
        case .driverLicense: "водительское удостоверение"
        case .diploma: "диплом"
        case .certificate: "справку"
        case .other: "документ"
        }
    }
}

extension DocumentType {
    /// Паспорт по ИКАО другой страны — не «загранпаспорт», а «Паспорт
    /// Таджикистана». `country` — код ИКАО из поля документа
    func title(country: String?) -> String {
        foreignCountry(country).map { "Паспорт \($0)" } ?? title
    }

    func spokenTitle(country: String?) -> String {
        foreignCountry(country).map { "паспорт \($0)" } ?? spokenTitle
    }

    func genitiveTitle(country: String?) -> String {
        foreignCountry(country).map { "паспорта \($0)" } ?? genitiveTitle
    }

    /// Страна в родительном падеже: «Таджикистана», неизвестная — «страны XYZ»
    private func foreignCountry(_ country: String?) -> String? {
        guard self == .passportIntl, let country, !country.isEmpty, country != "RUS" else { return nil }
        return PassportCountry.named(country)?.genitive ?? "страны \(country)"
    }
}

/// Что спросили: тип документа, нужные поля, срок, имя владельца
struct ChatIntent: Equatable {
    var types: [DocumentType] = []
    var fieldKeys: [String] = []
    var wantsExpiry = false
    var wantsList = false
    /// Слова, оставшиеся после типа и полей, — у личных документов это имя
    var nameWords: [String] = []
    /// Страна паспорта из запроса: «паспорт Таджикистана» — коды ИКАО
    var countries: Set<String> = []
    /// «Иностранный паспорт»: паспорт любой страны, кроме России
    var foreignOnly = false
    /// «Адрес», «где прописан»: страница паспорта «Место жительства»
    var wantsAddress = false
    /// «Все данные», «для копирования», «реквизиты»: все поля документа
    var wantsAllFields = false
    /// «Фото паспорта», «скинь скан», «дошли файл»: нужен сам файл, а не поля
    var wantsFile = false
    /// «Этого человека», «у него», «её»: о документе, о котором только что шла
    /// речь, или о том, что только что добавили
    var refersBack = false

    init(_ text: String) {
        let tokens = SearchText.tokens(in: text)
        let words = tokens.map(\.word)
        var consumed = Set<String>()
        // Понятия задаются точными основами Snowball или целыми словами, а не
        // началом слова: иначе фамилия «Сериков» стала бы «серией», а
        // «Дипломатов» — дипломом. Основы проверены прогоном словоформ
        func take(stems: Set<String> = [], words exact: Set<String> = [], prefixes: [String] = []) -> Bool {
            let hits = tokens.filter { token in
                stems.contains(token.stem) || exact.contains(token.word)
                    || prefixes.contains { token.word.hasPrefix($0) }
            }.map(\.word)
            consumed.formUnion(hits)
            return !hits.isEmpty
        }
        func has(stems: Set<String> = [], words exact: Set<String> = []) -> Bool {
            tokens.contains { stems.contains($0.stem) || exact.contains($0.word) }
        }

        // Тип документа. «Загран…» — безопасный префикс: с него не начинаются фамилии
        let travel = take(prefixes: ["загран", "заграничн", "международн"])
        let passport = take(stems: ["паспорт", "паспортн"])
        let russian = take(stems: ["рф", "российск", "внутрен", "гражданск"])
        let foreign = take(prefixes: ["иностран"])
        // Страна — только рядом со словом «паспорт»: «договор с Таджикистаном»
        // остаётся поиском по тексту
        if passport || foreign || travel {
            for token in tokens {
                guard let code = PassportCountry.code(forWord: token.word) else { continue }
                countries.insert(code)
                consumed.insert(token.word)
            }
        }
        if travel {
            types.append(.passportIntl)
        } else if foreign || (passport && !countries.isEmpty) {
            types.append(.passportIntl)
            foreignOnly = countries.isEmpty
        } else if passport {
            types.append(contentsOf: russian ? [.passportRU] : [.passportRU, .passportIntl])
        }
        if take(words: ["снилс"]) { types.append(.snils) }
        if take(words: ["инн"]) { types.append(.inn) }
        if take(stems: ["водительск"], words: ["права"]) { types.append(.driverLicense) }
        if take(stems: ["дипл", "диплом", "дипломн"]) { types.append(.diploma) }

        // Поля
        if take(stems: ["сер", "номер"]) { fieldKeys.append(FieldKey.seriesNumber) }
        let askedWho = has(words: ["кем"]) || has(stems: ["орга", "орган"])
        if askedWho {
            _ = take(stems: ["выда", "орга", "орган"], words: ["кем"])
            fieldKeys.append(FieldKey.issuedBy)
        }
        if has(stems: ["подразделен"]) {
            _ = take(stems: ["подразделен", "код"])
            fieldKeys.append(FieldKey.departmentCode)
        }
        // «День рождения» — тоже дата: «день» иначе остался бы словом имени, и
        // «какой день рождения у Ольги» уходил в поиск по тексту (сборка 16)
        if has(stems: ["рожден"], words: ["родился", "родилась", "днюха", "днюху", "др"]) {
            fieldKeys.append(has(stems: ["мест"]) ? FieldKey.birthPlace : FieldKey.birthDate)
            _ = take(stems: ["рожден", "мест", "дат"], words: ["родился", "родилась", "день", "дня", "днём", "днем", "днюха", "днюху", "др"])
        }
        // «Сколько лет Ольге», «возраст Ильи» — это дата рождения
        if !fieldKeys.contains(FieldKey.birthDate), has(words: ["возраст", "возраста", "возрасте"])
            || (has(words: ["сколько"]) && has(words: ["лет", "годиков"])) {
            _ = take(words: ["возраст", "возраста", "возрасте", "сколько", "лет", "годиков"])
            fieldKeys.append(FieldKey.birthDate)
        }
        if !askedWho, has(stems: ["дат"], words: ["когда"]), has(stems: ["выда", "выдач"]) {
            _ = take(stems: ["выда", "выдач", "дат"])
            fieldKeys.append(FieldKey.issueDate)
        }
        if take(words: ["фио", "фамилия", "фамилию", "имя", "отчество"]) {
            fieldKeys.append(FieldKey.fullName)
        }

        // Срок и списки. «Годен» не берём основой: она совпадает со словом «год»
        wantsExpiry = take(
            stems: ["истека", "истек", "истекл", "истечет", "истечен", "срок", "действ", "действител",
                    "действительн", "просроч", "годн", "годност"],
            words: ["годен", "замена", "замены", "замену", "заменить", "заменять", "менять", "поменять"]
        )
        // «Дай все данные для копирования»: все поля, вместе с серией и номером —
        // карточка закроет номер маской
        let dataWords: Set<String> = ["данные", "данных", "поля", "полей", "сведения", "сведений", "реквизиты", "реквизитов"]
        let copying = take(prefixes: ["копир", "скопир"])
        let everything = words.contains { ["все", "всё", "полностью", "целиком"].contains($0) }
        if copying || (everything && words.contains(where: dataWords.contains)) || take(words: ["реквизиты", "реквизитов"]) {
            wantsAllFields = true
            _ = take(words: dataWords.union(["все", "всё", "полностью", "целиком"]))
        }
        wantsFile = take(words: ["фото", "фотку", "фотографию", "фотография", "скан", "сканы", "скриншот", "файл",
                                 "файлом", "картинку", "оригинал", "pdf", "пдф"])
        wantsList = take(words: ["документы", "документов", "все", "список", "какие"])
        refersBack = take(words: Self.backReferences)
        wantsAddress = take(prefixes: ["адрес", "пропис", "регистрац", "зарегистр", "жительств", "прожива"])
            || take(words: ["живет", "живёт"])

        nameWords = words.filter { word in
            !consumed.contains(word)
                && !Self.fillerWords.contains(word)
                && !SearchQuery.stopWords.contains(word)
                && word.count > 1
                && !word.allSatisfy(\.isNumber)
        }
    }

    /// Уточнение с «а»: «а загран?» после «номер паспорта» — тот же вопрос о
    /// другом документе; «а у Ольги?» после «дата рождения Ильи» — о другом
    /// человеке. Раньше такие вопросы понимала только модель на iPhone, и
    /// ответ ждал её загрузки; теперь — правила, сразу
    func continuing(_ previous: ChatIntent, text: String) -> ChatIntent {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let elliptic = ["а ", "а,", "и ", "ещё ", "еще ", "тогда ", "теперь "].contains { lower.hasPrefix($0) }
        guard elliptic, fieldKeys.isEmpty, !wantsExpiry, !wantsAllFields, !wantsAddress else { return self }
        var merged = self
        if !types.isEmpty {
            // Другой документ — прежние поля и срок; человек тот же, если не назван
            merged.fieldKeys = previous.fieldKeys
            merged.wantsExpiry = previous.wantsExpiry
            merged.wantsAllFields = previous.wantsAllFields
            if nameWords.isEmpty { merged.nameWords = previous.nameWords }
            return merged
        }
        let asked = !previous.types.isEmpty || !previous.fieldKeys.isEmpty || previous.wantsExpiry || previous.wantsAllFields
        guard !nameWords.isEmpty, asked else { return self }
        // Другой человек — прежние вид документа, поля и срок
        merged.types = previous.types
        merged.countries = previous.countries
        merged.foreignOnly = previous.foreignOnly
        merged.fieldKeys = previous.fieldKeys
        merged.wantsExpiry = previous.wantsExpiry
        merged.wantsAllFields = previous.wantsAllFields
        merged.wantsAddress = previous.wantsAddress
        return merged
    }

    /// «Этого человека», «у него», «её»: указывают на документ, а не называют
    /// имя. Владелец на сборке 16: «какой день рождения у этого человека» — эти
    /// слова считались именем, и ответа не было
    static let backReferences: Set<String> = [
        "этого", "этой", "этому", "этим", "этот", "эта", "эту", "этих", "тот", "того", "той",
        "человека", "человек", "человеку", "него", "неё", "нее", "ему", "ей", "нём", "нем", "ней",
        "его", "её", "ее", "их", "них", "владельца", "владелец", "хозяина", "хозяйки",
    ]

    /// Слова просьбы, а не содержания: «покажи», «найди», «дай»
    static let fillerWords: Set<String> = [
        "покажи", "покажите", "показать", "найди", "найдите", "найти", "дай", "дайте",
        "открой", "открыть", "нужен", "нужна", "нужно", "нужны", "скинь", "пришли",
        "пожалуйста", "данные", "документ", "документа", "когда", "дата", "дату", "код",
        "какой", "какая", "какое", "сколько", "лет", "мне", "наш", "наша", "его", "её",
        // «Регистрацию тоже», «а ещё дату выдачи» — уточнение, не имя
        "тоже", "также", "ещё", "еще", "там", "тут", "здесь",
        // «Что есть на Ольгу», «информация по Илье» — просьба, не имя
        "есть", "имеется", "известно", "знаешь", "информация", "информацию", "информации",
        "инфа", "инфу", "скажи", "подскажи", "напомни", "посмотри",
        // «Дошли загран», «перешли скан» — просьба прислать, не имя
        "дошли", "дошлите", "дослать", "пришлите", "перешли", "перешлите", "отправь", "отправьте",
        "скиньте", "кинь", "покажите", "можешь", "можно",
    ]
}

// Ответы без модели: ключевые слова и тип документа. Этот же каталог карточек
// потом заполняет локальная модель — роутер остаётся запасным путём, пока она
// не скачана, и проверкой её ответов
@MainActor
struct ChatRouter {
    let search: SearchService
    /// Шаги ответа для экрана: что понял, кого перебирает, что открыл
    var onStep: ChatStepSink?
    /// «Карточки» — факты, которых нет в документах. nil — без них
    var facts: FactStore?

    /// Ответ и найденные по пути результаты поиска — из них рендерер берёт
    /// подсветку фрагментов
    /// `context` — документы прошлого ответа: к ним относятся уточнения без
    /// типа и имени, «а дата выдачи?», «адрес какой?»
    /// `previous` — прошлый вопрос: к нему относятся уточнения «а загран?»,
    /// «а у Ольги?»
    func reply(
        to text: String,
        preferring documentID: Int64? = nil,
        context: [Int64] = [],
        previous: String? = nil
    ) async -> (ChatReply, [Int64: SearchResult]) {
        let own = ChatIntent(text)
        let intent = previous.map { own.continuing(ChatIntent($0), text: text) } ?? own
        let inherited = intent != own
        let summary = intent.summary
        onStep?(.understand, summary.isEmpty ? "Разбираю вопрос" : "Понял: \(summary)")
        if let documentID, var reply = await chosen(documentID, intent: intent) {
            reply.isConfident = true
            return (reply, [:])
        }
        // «Дом Камилы», «домофон Камилы», «где живёт Камила» — карточка
        if let reply = factAnswer(text) { return (reply, [:]) }
        if intent.wantsAddress { return await address(intent, context: context) }
        // «А дата выдачи?» после ответа о паспорте — о том же паспорте. Слово
        // сверх поля («номер договора») значит другой документ: тогда поиск
        if intent.types.isEmpty, intent.nameWords.isEmpty, !intent.fieldKeys.isEmpty || intent.wantsExpiry || intent.wantsAllFields,
           let id = await personalDocument(in: context),
           var reply = await chosen(id, intent: intent) {
            reply.isConfident = true
            return (reply, [:])
        }
        // «Какой день рождения у этого человека?» без прошлого ответа: о том,
        // что только что добавили, иначе — как о паспорте без имени
        if intent.types.isEmpty, intent.nameWords.isEmpty, !intent.fieldKeys.isEmpty || intent.wantsAllFields || intent.wantsExpiry {
            if intent.refersBack, let id = await justAddedPersonalDocument(), var reply = await chosen(id, intent: intent) {
                reply.isConfident = true
                return (reply, [:])
            }
            var asked = intent
            asked.types = intent.wantsExpiry ? [.passportIntl, .passportRU, .driverLicense] : [.passportRU, .passportIntl]
            if var reply = await personalDocument(asked) {
                reply.isConfident = true
                return (reply, [:])
            }
        }
        if intent.types.contains(where: \.isPersonal) {
            if var reply = await personalDocument(intent) {
                // «А у Ольги?» — вид документа взят из прошлого вопроса. Точно —
                // только если нашлись поля или срок: «а другой?» не имя
                if inherited, reply.cards.contains(where: { card in
                    switch card {
                    case .fields, .expiry: true
                    default: false
                    }
                }) {
                    reply.isConfident = true
                }
                return (reply, [:])
            }
        }
        // «Дата рождения Ольги», «данные Ильи», «Ольга» — вид документа не
        // назван, но в вопросе имя человека из документов
        if intent.types.isEmpty, !intent.nameWords.isEmpty, let reply = await person(intent, text: text) {
            return (reply, [:])
        }
        if intent.types.contains(.diploma) {
            if let reply = await documentList(of: [.diploma]) { return (reply, [:]) }
        }
        // «Камила» — документов на неё нет, а карточка есть
        if let reply = factAnswer(text, force: true) { return (reply, [:]) }
        return await textSearch(text)
    }

    /// Пустой ответ объясняет, где чат ищет. Сразу после установки индекс
    /// строится в фоне, и «ничего не нашёл» без этой оговорки выглядит поломкой.
    /// О суперскрытых папках — ни слова: подсказка выдала бы их существование
    static func nothingFound(_ text: String, pending: Int) -> String {
        if pending > 0 {
            return "По запросу «\(text)» пока ничего. Я ещё распознаю документы — осталось \(pending). Спросите чуть позже."
        }
        return "Ничего не нашёл по запросу «\(text)». Ищу в тексте файлов и их названиях — в папках, где включено «Доступна для поиска». Попробуйте другое слово."
    }

    // MARK: - Личные документы

    private func personalDocument(_ intent: ChatIntent) async -> ChatReply? {
        let types = intent.types.filter(\.isPersonal)
        var candidates = await search.documents(ofTypes: types)
        guard !candidates.isEmpty else { return nil }
        var fields = await search.fields(for: candidates.map(\.id))
        func owner(_ document: StoredDocument) -> String {
            fields[document.id]?.first { $0.key == FieldKey.fullName }?.value ?? ""
        }
        func country(_ document: StoredDocument) -> String? {
            fields[document.id]?.first { $0.key == FieldKey.country }?.value
        }
        /// Разворот «кем выдан»: на нём нет ни имени, ни номера
        func isAnonymous(_ document: StoredDocument) -> Bool {
            fields[document.id]?.contains { $0.key == FieldKey.fullName || $0.key == FieldKey.seriesNumber } != true
        }

        // «Паспорт Таджикистана», «иностранный паспорт». Загранпаспорт без кода
        // страны — из индекса до версии 3, он российский
        if !intent.countries.isEmpty || intent.foreignOnly {
            candidates = candidates.filter { document in
                guard document.type == .passportIntl else { return false }
                let code = country(document) ?? "RUS"
                return intent.countries.isEmpty ? code != "RUS" : intent.countries.contains(code)
            }
            guard !candidates.isEmpty else {
                let title = intent.countries.count == 1
                    ? DocumentType.passportIntl.genitiveTitle(country: intent.countries.first)
                    : "иностранного паспорта"
                return ChatReply(text: "Не нашёл \(title).", cards: [])
            }
        }
        // Владелец известен, имя не названо — «мой паспорт», «паспорт»: его
        // документы и безымянные развороты из тех же папок
        if intent.nameWords.isEmpty, let ownerKey = search.owner.owner?.key {
            let mine = candidates.filter { Self.personKey(owner($0)) == ownerKey }
            if !mine.isEmpty {
                let folders = Set(mine.map(\.folderID))
                candidates = mine + candidates.filter { isAnonymous($0) && folders.contains($0.folderID) }
            }
        }
        let people = Set(candidates.map { Self.personKey(owner($0)) }.filter { !$0.isEmpty })
        var guessedOwner: String?

        if !intent.nameWords.isEmpty {
            onStep?(.people, "Перебираю людей: " + Self.peopleList(candidates.map(owner)))
            var named = candidates.filter { Self.nameMatches(intent.nameWords, owner: owner($0)) }
            // Имени нет среди паспортов спрошенного вида — ищем во всех паспортах:
            // «паспорт Рахимова» без слова «иностранный» находит паспорт Таджикистана
            var widened = false
            if named.isEmpty, !Set(types).isDisjoint(with: Self.passportTypes), intent.countries.isEmpty, !intent.foreignOnly {
                let known = Set(candidates.map(\.id))
                let others = await search.documents(ofTypes: Self.passportTypes).filter { !known.contains($0.id) }
                if !others.isEmpty {
                    fields.merge(await search.fields(for: others.map(\.id))) { current, _ in current }
                    candidates += others
                    named = others.filter { Self.nameMatches(intent.nameWords, owner: owner($0)) }
                    widened = true
                }
            }
            // Опечатка в имени: «сааин» вместо «савин». Близкое имя одного
            // человека — это он, но ответ об этом говорит
            var guessed: String?
            if named.isEmpty {
                let close = candidates.filter { Self.nameIsClose(intent.nameWords, owner: owner($0)) }
                if !close.isEmpty, Set(close.map { Self.personKey(owner($0)) }).count == 1 {
                    named = close
                    guessed = owner(close[0])
                }
            }
            if named.isEmpty {
                // В чипах первыми — самые похожие имена: их всего четыре
                let ranked = candidates.filter { !isAnonymous($0) }
                    .map { ($0, Self.nameSimilarity(intent.nameWords, owner: owner($0))) }
                    .sorted { $0.1 > $1.1 }
                    .map(\.0)
                let options = self.options(for: ranked, intent: intent, owner: owner, country: country, withNames: true)
                let title = types.count == 1 && !widened ? types[0].genitiveTitle : (widened ? "паспорта" : "документа")
                return ChatReply(
                    text: options.isEmpty ? "На это имя \(title) не нашёл." : "На это имя \(title) не нашёл. Есть такие:",
                    cards: options.isEmpty ? [] : [.clarify(question: nil, options: options)]
                )
            }
            // Развороты без имени из той же папки — часть того же паспорта:
            // фильтр по фамилии не должен терять страницу «кем выдан». Но только
            // если паспорт с именем в этой папке один, иначе «кем выдан»
            // досталась бы чужому
            let sole = Self.soleOwnerFolders(candidates, isAnonymous: isAnonymous)
            let anchors = Set(named.map { "\($0.type.rawValue)|\($0.folderID)" }).intersection(sole)
            let pages = candidates.filter { isAnonymous($0) && anchors.contains("\($0.type.rawValue)|\($0.folderID)") }
            candidates = named + pages
            guessedOwner = guessed
        }

        // «Паспорт» без уточнения по-русски — внутренний паспорт. Ответ сразу
        // с его данными, а загранпаспорт — чипом под ответом, а не вопросом
        // вместо ответа. Про срок, наоборот, спрашивают о загранпаспорте:
        // у паспорта РФ даты окончания в документе нет
        var alternatives: [StoredDocument] = []
        if types.contains(.passportRU), types.contains(.passportIntl) {
            let russian = candidates.filter { $0.type == .passportRU }
            let travel = candidates.filter { $0.type == .passportIntl }
            if intent.wantsExpiry, !travel.isEmpty {
                candidates = travel
            } else if !russian.isEmpty {
                candidates = russian
                alternatives = travel
            }
        }

        var reply = answer(for: candidates, intent: intent, fields: fields, owner: owner)
        if let guessedOwner {
            reply.text = "Похоже, вы про «\(Self.shortName(guessedOwner))». " + reply.text
        }
        guard !alternatives.isEmpty else { return reply }
        if let index = reply.cards.firstIndex(where: { if case .clarify = $0 { true } else { false } }),
           case .clarify(let question, let existing) = reply.cards[index] {
            // Уже спрашиваем, чей паспорт, — остальные паспорта в тот же список
            let extra = self.options(for: alternatives.filter { !isAnonymous($0) }, intent: intent, owner: owner, country: country, withNames: true)
            let merged = existing + extra.filter { option in !existing.contains { $0.documentID == option.documentID } }
            reply.cards[index] = .clarify(question: question, options: Array(merged.prefix(4)))
        } else {
            let options = self.options(for: alternatives, intent: intent, owner: owner, country: country, withNames: people.count > 1)
            reply.cards.append(.clarify(question: "Ещё есть:", options: options))
        }
        return reply
    }

    /// Удостоверение, добавленное последним, — если не больше получаса назад:
    /// «этот человек» сразу после загрузки паспорта — это он
    private func justAddedPersonalDocument() async -> Int64? {
        let documents = await search.documents(ofTypes: DocumentType.allCases.filter(\.isPersonal))
        let dated = documents.compactMap { document in search.file(for: document).map { (document.id, $0.file.addedAt) } }
        guard let newest = dated.max(by: { $0.1 < $1.1 }), Date().timeIntervalSince(newest.1) < 30 * 60 else { return nil }
        return newest.0
    }

    /// Первый личный документ из прошлого ответа
    private func personalDocument(in context: [Int64]) async -> Int64? {
        guard !context.isEmpty else { return nil }
        let documents = await search.documents(ids: context)
        return context.first { id in documents.contains { $0.id == id && $0.type.isPersonal } }
    }

    // MARK: - Человек без вида документа

    /// Виды документов по важности: главный документ человека — паспорт РФ
    static let personalPriority: [DocumentType] = [.passportRU, .passportIntl, .driverLicense, .snils, .inn, .diploma, .certificate, .other]

    /// «Дата рождения Ольги», «сколько лет Илье», «данные Ольги», «Ольга».
    /// Вид документа не назван, но слова вопроса — имя человека из документов.
    /// Владелец 24.10.2026: такой вопрос шёл в модель и думал больше 30 с,
    /// хотя всё нужное уже лежит в базе. Ответ — из полей, сразу. nil — в
    /// вопросе нет ни одного известного имени: тогда это поиск по тексту
    private func person(_ intent: ChatIntent, text: String) async -> ChatReply? {
        let words = intent.nameWords.filter { $0.count >= 3 }
        guard !words.isEmpty else { return nil }
        let documents = await search.documents(ofTypes: DocumentType.allCases)
        guard !documents.isEmpty else { return nil }
        var fields = await search.fields(for: documents.map(\.id))
        func owner(_ document: StoredDocument) -> String {
            fields[document.id]?.first { $0.key == FieldKey.fullName }?.value ?? ""
        }

        // Люди — по ключу «фамилия имя» латиницей: паспорт РФ и загранпаспорт
        // одного человека — один человек. Имя для ответа — кириллицей, если есть
        var names: [String: String] = [:]
        var owned: [String: [StoredDocument]] = [:]
        for document in documents {
            let name = owner(document)
            let key = Self.personKey(name)
            guard !key.isEmpty else { continue }
            if names[key] == nil || name.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
                names[key] = name
            }
            owned[key, default: []].append(document)
        }
        guard !names.isEmpty else { return nil }

        // Слова имени — те, что подходят хоть к одному человеку. Слово сверх
        // имени («договор Ольги») — уже не данные человека, а поиск по тексту
        let nameWords = words.filter { word in names.values.contains { Self.nameMatches([word], owner: $0) } }
        var guessed = false
        var matched = names.keys.filter { key in
            !nameWords.isEmpty && owned[key, default: []].contains { Self.nameMatches(nameWords, owner: owner($0)) }
        }
        if nameWords.count < words.count {
            guard nameWords.isEmpty else { return nil }
            // Ни одно слово не подошло — может быть, опечатка в имени
            matched = names.keys.filter { key in owned[key, default: []].contains { Self.nameIsClose(words, owner: owner($0)) } }
            guard matched.count == 1 else { return nil }
            guessed = true
        }
        guard !matched.isEmpty else { return nil }
        onStep?(.people, "Перебираю людей: " + Self.peopleList(Array(names.values)))

        // Двое с таким именем — какой из них
        guard matched.count == 1, let key = matched.first, let fullName = names[key] else {
            let main = matched.compactMap { key in Self.mainDocument(of: owned[key, default: []]) }
            func country(_ document: StoredDocument) -> String? {
                fields[document.id]?.first { $0.key == FieldKey.country }?.value
            }
            let options = self.options(for: main, intent: intent, owner: owner, country: country, withNames: true)
            return ChatReply(text: "Нашёл нескольких людей с таким именем. О ком речь?",
                             cards: [.clarify(question: nil, options: options)], isConfident: true)
        }
        let short = Self.shortName(fullName)
        let lead = guessed ? "Похоже, вы про «\(short)». " : ""
        let mine = owned[key, default: []].sorted { first, second in
            let a = Self.personalPriority.firstIndex(of: first.type) ?? .max
            let b = Self.personalPriority.firstIndex(of: second.type) ?? .max
            return a == b ? first.id < second.id : a < b
        }

        // Срок, все данные и поля удостоверений — тем же путём, что «паспорт
        // Ольги»: там развороты без имени и чип «Ещё есть»
        let personal = mine.filter(\.type.isPersonal)
        if intent.wantsExpiry {
            let expiring = personal.filter { $0.type != .passportRU }
            let types = expiring.isEmpty ? [DocumentType.passportRU] : Self.personalPriority.filter { type in expiring.contains { $0.type == type } }
            var named = intent
            named.types = types
            named.nameWords = nameWords.isEmpty ? words : nameWords
            if var reply = await personalDocument(named) {
                reply.text = lead + reply.text
                reply.isConfident = true
                return reply
            }
        }
        if intent.wantsAllFields, let main = Self.mainDocument(of: mine), var reply = await chosen(main.id, intent: intent) {
            reply.text = lead + reply.text
            reply.isConfident = true
            return reply
        }
        if !intent.fieldKeys.isEmpty {
            // Документ, где эти поля есть: паспорт РФ первым, потом остальные
            let holder = mine.first { document in
                intent.fieldKeys.contains { key in fields[document.id]?.contains { $0.key == key } == true }
            }
            if let holder, holder.type.isPersonal {
                var named = intent
                named.types = [holder.type]
                named.nameWords = nameWords.isEmpty ? words : nameWords
                if var reply = await personalDocument(named) {
                    reply.text = lead + reply.text
                    reply.isConfident = true
                    return reply
                }
            }
            if let holder {
                let keys = intent.fieldKeys.filter { key in fields[holder.id]?.contains { $0.key == key } == true }
                onStep?(.open, "Открываю: \(holder.type.title) — \(short)")
                return ChatReply(text: lead + "\(short). Нажмите на поле, чтобы скопировать:",
                                 cards: [.fields(documentID: holder.id, keys: keys)], isConfident: true)
            }
            let asked = intent.fieldKeys.map { "«\(FieldKey.title($0))»" }.joined(separator: ", ")
            return ChatReply(text: lead + "В документах \(short) поле \(asked) не распознано. Вот документы — сверьте по фото:",
                             cards: [.fileList(documentIDs: Array(mine.prefix(12).map(\.id)))], isConfident: true)
        }

        // «Скинь скан Ольги» — сами файлы, главный первым
        if intent.wantsFile {
            onStep?(.files, "Беру файлы: \(short)")
            return ChatReply(text: lead + "Файлы — \(short). Нажмите, чтобы открыть или отправить:",
                             cards: [.fileList(documentIDs: Array(mine.prefix(12).map(\.id)))], isConfident: true)
        }
        // Только имя: главный документ с полями и всё, что есть на человека
        onStep?(.files, "Собираю документы: \(short)")
        var cards: [ChatCard] = []
        if let main = Self.mainDocument(of: mine) {
            fields.merge(await search.fields(for: [main.id])) { current, _ in current }
            let keys = FieldKey.order.filter { key in fields[main.id]?.contains { $0.key == key } == true }
            if !keys.isEmpty { cards.append(.fields(documentID: main.id, keys: keys)) }
        }
        cards.append(.fileList(documentIDs: Array(mine.prefix(12).map(\.id))))
        // Карточки о человеке — «Дом Камилы» — рядом с документами
        cards += factCards(about: text)
        return ChatReply(text: lead + "\(short) — \(pluralize(mine.count, "документ", "документа", "документов")):",
                         cards: cards, isConfident: true)
    }

    /// Главный документ человека: удостоверение по важности, иначе первый
    static func mainDocument(of documents: [StoredDocument]) -> StoredDocument? {
        for type in personalPriority {
            if let document = documents.first(where: { $0.type == type }) { return document }
        }
        return documents.first
    }

    /// «Савин И. А., Трошина О. В. и ещё 2» — для шага «перебираю людей»
    static func peopleList(_ names: [String]) -> String {
        var seen = Set<String>()
        let unique = names.filter { !$0.isEmpty && seen.insert(personKey($0)).inserted }.map(shortName).sorted()
        guard !unique.isEmpty else { return "в документах нет имён" }
        let shown = unique.prefix(4).joined(separator: ", ")
        return unique.count > 4 ? "\(shown) и ещё \(unique.count - 4)" : shown
    }

    // MARK: - Адрес

    /// Адрес полем не распознаётся — штампы регистрации слишком разные. Ответ —
    /// страница «Место жительства» со штампом. Чья — по имени в вопросе или по
    /// паспорту из прошлого ответа. Если в папке паспорта нескольких людей, чья
    /// страница, по тексту не понять: тогда так и говорим
    private func address(_ intent: ChatIntent, context: [Int64]) async -> (ChatReply, [Int64: SearchResult]) {
        onStep?(.search, "Ищу страницу с пропиской")
        var people: [StoredDocument] = []
        if !intent.nameWords.isEmpty {
            let passports = await search.documents(ofTypes: Self.passportTypes)
            let fields = await search.fields(for: passports.map(\.id))
            people = passports.filter { document in
                Self.nameMatches(intent.nameWords, owner: fields[document.id]?.first { $0.key == FieldKey.fullName }?.value ?? "")
            }
        } else if !context.isEmpty {
            people = await search.documents(ids: context).filter(\.type.isPersonal)
        }
        let folders = Set(people.map(\.folderID))
        if let reply = await registrationFields(of: people) { return (reply, [:]) }

        let results = await search.search("место жительства зарегистрирован регистрации прописка адрес")
        let pages = results.filter { result in
            guard let id = result.documentID, result.snippet != nil, result.type != .passportIntl else { return false }
            return folders.isEmpty || (folders.contains(result.folder.id) && !people.contains { $0.id == id })
        }
        let hits = Dictionary(pages.compactMap { result in result.documentID.map { ($0, result) } }, uniquingKeysWith: { first, _ in first })
        guard let best = pages.first, let bestID = best.documentID else {
            return (ChatReply(
                text: "Не нашёл страницу с пропиской. Сфотографируйте разворот паспорта «Место жительства» и добавьте в папку с паспортом — тогда покажу адрес.",
                cards: []
            ), [:])
        }

        // Своя ли это страница: в папке один человек с паспортом
        var sole = false
        if folders.count == 1, let folder = folders.first {
            let passports = await search.documents(ofTypes: Self.passportTypes).filter { $0.folderID == folder }
            let fields = await search.fields(for: passports.map(\.id))
            let owners = Set(passports.compactMap { document in
                fields[document.id]?.first { $0.key == FieldKey.fullName }.map { Self.personKey($0.value) }
            })
            sole = owners.count == 1
        }
        let rest = pages.dropFirst().compactMap(\.documentID).prefix(4)
        var cards: [ChatCard] = [.snippet(documentID: bestID, page: best.page)]
        if !rest.isEmpty { cards.append(.fileList(documentIDs: Array(rest))) }
        let text = sole && rest.isEmpty
            ? "Адрес регистрации — на этой странице паспорта:"
            : "Нашёл страницы с пропиской. Чья из них — видно на фото:"
        return (ChatReply(text: text, cards: cards), hits)
    }

    /// Распознанная регистрация: у самого паспорта (страница «Место жительства»
    /// в том же файле) или у безымянной страницы из папки, где паспорт с
    /// именем один, — иначе чья она, по тексту не понять
    private func registrationFields(of people: [StoredDocument]) async -> ChatReply? {
        guard !people.isEmpty else { return nil }
        let own = await search.fields(for: people.map(\.id))
        func keys(_ fields: [DocumentField]?) -> [String] {
            FieldKey.registration.filter { key in fields?.contains { $0.key == key } == true }
        }
        if let person = people.first(where: { keys(own[$0.id]).contains(FieldKey.registrationAddress) }) {
            return ChatReply(text: "Регистрация по месту жительства:", cards: [.fields(documentID: person.id, keys: keys(own[person.id]))])
        }
        let folders = Set(people.map(\.folderID))
        let passports = await search.documents(ofTypes: [.passportRU]).filter { folders.contains($0.folderID) }
        let fields = await search.fields(for: passports.map(\.id))
        func isAnonymous(_ document: StoredDocument) -> Bool {
            fields[document.id]?.contains { $0.key == FieldKey.fullName || $0.key == FieldKey.seriesNumber } != true
        }
        let sole = Self.soleOwnerFolders(passports, isAnonymous: isAnonymous)
        guard let page = passports.first(where: { document in
            isAnonymous(document) && sole.contains("\(document.type.rawValue)|\(document.folderID)")
                && keys(fields[document.id]).contains(FieldKey.registrationAddress)
        }) else { return nil }
        return ChatReply(text: "Регистрация по месту жительства — со страницы «Место жительства»:",
                         cards: [.fields(documentID: page.id, keys: keys(fields[page.id]))])
    }

    /// Виды паспортов: имя ищется во всех сразу
    static let passportTypes: [DocumentType] = [.passportRU, .passportIntl]

    /// Папки, где у документа этого вида с именем ровно один владелец, —
    /// ключи «тип|папка». Только туда можно приложить безымянный разворот
    static func soleOwnerFolders(_ documents: [StoredDocument], isAnonymous: (StoredDocument) -> Bool) -> Set<String> {
        let named = documents.filter { !isAnonymous($0) }
        let counts = Dictionary(grouping: named, by: { "\($0.type.rawValue)|\($0.folderID)" }).mapValues(\.count)
        return Set(counts.filter { $0.value == 1 }.keys)
    }

    /// Чип указал документ: показываем его, а у паспорта РФ — вместе с
    /// безымянным разворотом «кем выдан» из той же папки
    private func chosen(_ id: Int64, intent: ChatIntent) async -> ChatReply? {
        guard let document = await search.documents(ids: [id]).first else { return nil }
        guard document.type.isPersonal else {
            return ChatReply(text: "Вот этот документ:", cards: [.document(documentID: id)])
        }
        let neighbours = await search.documents(ofTypes: [document.type])
            .filter { $0.folderID == document.folderID && $0.id != id }
        let fields = await search.fields(for: [id] + neighbours.map(\.id))
        func owner(_ document: StoredDocument) -> String {
            fields[document.id]?.first { $0.key == FieldKey.fullName }?.value ?? ""
        }
        func isAnonymous(_ page: StoredDocument) -> Bool {
            fields[page.id]?.contains { $0.key == FieldKey.fullName || $0.key == FieldKey.seriesNumber } != true
        }
        // Безымянный разворот — только если другого паспорта с именем в папке нет
        let unambiguous = isAnonymous(document) || !neighbours.contains { !isAnonymous($0) }
        let pages = unambiguous ? neighbours.filter(isAnonymous) : []
        return answer(for: [document] + pages, intent: intent, fields: fields, owner: owner)
    }

    /// Ответ по уже отобранным документам одного вида
    private func answer(
        for documents: [StoredDocument],
        intent: ChatIntent,
        fields: [Int64: [DocumentField]],
        owner: (StoredDocument) -> String
    ) -> ChatReply {
        var choices = documents
        // Паспорт РФ обычно снят двумя разворотами: на одном ФИО и MRZ, на
        // другом «кем выдан» без имени. Это один документ, а не два. Срок
        // считается по развороту с датой рождения, остальное — по обоим
        let spreads = Self.spreads(of: documents, fields: fields)
        // «Фото паспорта», «дошли скан»: сами развороты — открыть или отправить
        if intent.wantsFile, intent.fieldKeys.isEmpty, spreads.count > 1, let primary = spreads.first {
            onStep?(.open, "Беру файлы: \(primary.type.title), \(pluralize(spreads.count, "разворот", "разворота", "разворотов"))")
            return ChatReply(text: "Вот развороты — нажмите, чтобы открыть, или «Поделиться»:",
                             cards: [.fileList(documentIDs: spreads.map(\.id))], isConfident: true)
        }
        if spreads.count > 1, let primary = spreads.first {
            guard intent.wantsExpiry else {
                return spreadsReply(primary: primary, extra: Array(spreads.dropFirst()), intent: intent, fields: fields)
            }
            choices = [primary]
        }

        func country(_ document: StoredDocument) -> String? {
            fields[document.id]?.first { $0.key == FieldKey.country }?.value
        }
        guard choices.count == 1, let document = choices.first else {
            // Безымянные развороты в списке выбора бесполезны: чип без имени
            // не говорит, чей это паспорт
            let identified = choices.filter { page in
                fields[page.id]?.contains { $0.key == FieldKey.fullName || $0.key == FieldKey.seriesNumber } == true
            }
            let listed = identified.isEmpty ? choices : identified
            let multiplePeople = Set(listed.map { Self.personKey(owner($0)) }.filter { !$0.isEmpty }).count > 1
            return ChatReply(
                text: "Нашлось несколько документов. Какой нужен?",
                cards: [.clarify(question: nil, options: options(for: listed, intent: intent, owner: owner, country: country, withNames: multiplePeople))]
            )
        }

        let available = Set(fields[document.id]?.map(\.key) ?? [])
        let title = document.type.spokenTitle(country: country(document))
        let name = Self.shortName(owner(document))
        onStep?(.open, "Открываю: \(document.type.title(country: country(document)))" + (name.isEmpty ? "" : " — \(name)"))
        if intent.wantsExpiry {
            return ChatReply(
                text: "Срок действия \(document.type.genitiveTitle(country: country(document))):",
                cards: [.expiry(documentID: document.id)]
            )
        }
        if intent.wantsFile, intent.fieldKeys.isEmpty {
            return ChatReply(text: "Вот \(title) — нажмите, чтобы открыть, или «Поделиться»:",
                             cards: [.document(documentID: document.id)], isConfident: true)
        }
        if !intent.fieldKeys.isEmpty {
            let keys = intent.fieldKeys.filter(available.contains)
            guard !keys.isEmpty else {
                let names = intent.fieldKeys.map { "«\(FieldKey.title($0))»" }.joined(separator: ", ")
                // Только что загрузили — облако или модель ещё читают: это не «нет поля»
                let progress = search.progress
                let reading = progress.pending + progress.cloudPending + progress.modelPending
                let text = reading > 0
                    ? "Документ ещё распознаётся (осталось \(reading)) — поле \(names) появится через минуту. Пока — сам документ:"
                    : "В файле не распознано поле \(names). Вот сам документ — сверьте по фото:"
                return ChatReply(text: text, cards: [.document(documentID: document.id)])
            }
            return ChatReply(text: "Нажмите на поле, чтобы скопировать:", cards: [.fields(documentID: document.id, keys: keys)])
        }
        let keys = FieldKey.order.filter(available.contains)
        guard !keys.isEmpty else {
            return ChatReply(text: "Нашёл \(title), но данные с него не распознались:", cards: [.document(documentID: document.id)])
        }
        return ChatReply(
            text: "Нашёл \(title). Нажмите на поле, чтобы скопировать:",
            cards: [.fields(documentID: document.id, keys: keys), .document(documentID: document.id)]
        )
    }

    /// Развороты одного паспорта: документы одного типа из одной папки, где
    /// имя есть только у одного. Первым идёт разворот с именем
    static func spreads(of candidates: [StoredDocument], fields: [Int64: [DocumentField]]) -> [StoredDocument] {
        guard candidates.count > 1,
              Set(candidates.map(\.type)).count == 1,
              Set(candidates.map(\.folderID)).count == 1 else { return [] }
        func identity(_ document: StoredDocument) -> Bool {
            fields[document.id]?.contains { $0.key == FieldKey.fullName || $0.key == FieldKey.seriesNumber } == true
        }
        let named = candidates.filter(identity)
        guard named.count == 1, let primary = named.first else { return [] }
        return [primary] + candidates.filter { $0.id != primary.id }
    }

    private func spreadsReply(
        primary: StoredDocument,
        extra: [StoredDocument],
        intent: ChatIntent,
        fields: [Int64: [DocumentField]]
    ) -> ChatReply {
        let primaryKeys = Set(fields[primary.id]?.map(\.key) ?? [])
        let owner = fields[primary.id]?.first { $0.key == FieldKey.fullName }?.value ?? ""
        onStep?(.open, "Открываю: \(primary.type.title), \(pluralize(extra.count + 1, "разворот", "разворота", "разворотов"))" + (owner.isEmpty ? "" : " — \(Self.shortName(owner))"))
        let wanted = intent.fieldKeys.isEmpty ? FieldKey.order : intent.fieldKeys
        var cards: [ChatCard] = []
        let mainKeys = wanted.filter(primaryKeys.contains)
        if !mainKeys.isEmpty { cards.append(.fields(documentID: primary.id, keys: mainKeys)) }
        // Со второго разворота — только то, чего нет на первом: «кем выдан»
        var shown = primaryKeys
        for page in extra {
            let keys = wanted.filter { key in
                !shown.contains(key) && fields[page.id]?.contains { $0.key == key } == true
            }
            if !keys.isEmpty { cards.append(.fields(documentID: page.id, keys: keys)) }
            shown.formUnion(keys)
        }
        guard !cards.isEmpty else {
            return ChatReply(text: "Нашёл \(primary.type.spokenTitle), но нужное поле не распознано. Вот развороты:",
                             cards: [.fileList(documentIDs: [primary.id] + extra.map(\.id))])
        }
        if intent.fieldKeys.isEmpty {
            cards.append(.fileList(documentIDs: [primary.id] + extra.map(\.id)))
        }
        return ChatReply(text: "Нашёл \(primary.type.spokenTitle). Нажмите на поле, чтобы скопировать:", cards: cards)
    }

    /// Чипы уточнения. Каждый указывает свой документ напрямую, а текст чипа
    /// повторяет смысл вопроса: после «номер паспорта» чип спросит номер.
    /// Одинаковые подписи — например, два паспорта РФ одного человека в
    /// разных папках — различаются названием папки
    private func options(
        for documents: [StoredDocument],
        intent: ChatIntent,
        owner: (StoredDocument) -> String,
        country: (StoredDocument) -> String?,
        withNames: Bool
    ) -> [ClarifyOption] {
        let chosen = Array(documents.prefix(4))
        let bases = chosen.map { document -> String in
            let base = document.type == .passportIntl
                ? DocumentType.passportIntl.title(country: country(document))
                : document.type.title
            let short = withNames ? Self.shortName(owner(document)) : ""
            return short.isEmpty ? base : "\(base) · \(short)"
        }
        let folders = Dictionary(search.searchableFolders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return zip(chosen, bases).map { document, base in
            let duplicate = bases.filter { $0 == base }.count > 1
            let title = duplicate ? "\(base) · \(folders[document.folderID] ?? "")" : base
            let query = query(for: document, country: country(document), intent: intent, owner: withNames ? owner(document) : "")
            return ClarifyOption(title: title, query: query, documentID: document.id)
        }
    }

    private func query(for document: StoredDocument, country: String?, intent: ChatIntent, owner: String) -> String {
        var query: String
        if intent.wantsExpiry {
            query = "срок действия \(document.type.genitiveTitle(country: country))"
        } else if !intent.fieldKeys.isEmpty {
            query = intent.fieldKeys.map { FieldKey.title($0).lowercased() }.joined(separator: ", ")
                + " " + document.type.genitiveTitle(country: country)
        } else {
            query = document.type == .passportRU ? "паспорт РФ" : document.type.spokenTitle(country: country)
        }
        return owner.isEmpty ? query : "\(query) \(owner)"
    }

    /// Один и тот же человек в паспорте РФ записан кириллицей, в загранпаспорте —
    /// латиницей. Ключ — фамилия и имя латиницей по ИКАО: «savin ilia»
    static func personKey(_ owner: String) -> String {
        let words = owner.split(separator: " ").prefix(2).map { transliterate(String($0)) }
        return words.joined(separator: " ")
    }

    /// «Савин Илья Андреевич» → «Савин И. А.»
    static func shortName(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard let surname = parts.first else { return "" }
        let initials = parts.dropFirst().compactMap { $0.first.map { "\($0)." } }
        return ([String(surname)] + initials).joined(separator: " ")
    }

    /// Имя из запроса сравнивается по основам: «савина илья» подходит к
    /// «Савин Илья Андреевич». У загранпаспорта имя латиницей — запрос
    /// переводится в латиницу по ИКАО
    static func nameMatches(_ words: [String], owner: String) -> Bool {
        guard !owner.isEmpty else { return false }
        let ownerTokens = SearchText.tokens(in: owner)
        let isLatin = owner.unicodeScalars.contains { ("A"..."z").contains($0) }
        return words.allSatisfy { word in
            if isLatin {
                let latin = transliterate(word)
                return ownerTokens.contains { token in
                    token.word.hasPrefix(latin) || (latin.hasPrefix(token.word) && latin.count - token.word.count <= 2)
                }
            }
            let stem = SearchText.stem(word)
            return ownerTokens.contains { token in
                token.stem == stem || token.word.hasPrefix(word)
                    // «орлова» к «Орлов»: у мужской фамилии на -ов Snowball
                    // отрезает окончание «ов», и основы не совпадают
                    || (token.word.count >= 3 && word.hasPrefix(token.word) && word.count - token.word.count <= 3)
            }
        }
    }

    /// Имя с опечаткой: каждое слово запроса — не дальше одной правки от слова
    /// владельца, у длинных слов — двух. Окончание падежа не в счёт:
    /// «сааина» сравнивается с «савин» по первым пяти буквам
    static func nameIsClose(_ words: [String], owner: String) -> Bool {
        guard !owner.isEmpty, !words.isEmpty else { return false }
        let isLatin = owner.unicodeScalars.contains { ("A"..."z").contains($0) }
        let ownerWords = SearchText.tokens(in: owner).map(\.word)
        return words.allSatisfy { raw in
            let word = isLatin ? transliterate(raw) : raw
            return ownerWords.contains { candidate in
                guard word.count >= 4, candidate.count >= 3 else { return word == candidate }
                let limit = max(word.count, candidate.count) >= 7 ? 2 : 1
                if editDistance(word, candidate) <= limit { return true }
                let extra = word.count - candidate.count
                return (1...3).contains(extra) && editDistance(String(word.prefix(candidate.count)), candidate) <= limit
            }
        }
    }

    /// Насколько имя владельца похоже на слова запроса: 0…1 на слово
    static func nameSimilarity(_ words: [String], owner: String) -> Double {
        let ownerWords = SearchText.tokens(in: owner).map(\.word)
        guard !ownerWords.isEmpty else { return 0 }
        return words.reduce(0) { total, word in
            total + (ownerWords.map { candidate in
                1 - Double(editDistance(word, candidate)) / Double(max(word.count, candidate.count, 1))
            }.max() ?? 0)
        }
    }

    /// Расстояние Левенштейна
    nonisolated static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Транслитерация ИКАО 9303 для русских имён: Илья → ilia
    static func transliterate(_ word: String) -> String {
        let table: [Character: String] = [
            "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh",
            "з": "z", "и": "i", "й": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o",
            "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts",
            "ч": "ch", "ш": "sh", "щ": "shch", "ъ": "ie", "ы": "y", "ь": "", "э": "e", "ю": "iu",
            "я": "ia",
        ]
        return word.lowercased().map { table[$0] ?? String($0) }.joined()
    }

    // MARK: - Списки по типу

    /// «Дипломные документы»: документы этого типа и остальное из их папок
    private func documentList(of types: [DocumentType]) async -> ChatReply? {
        onStep?(.files, "Собираю документы: " + types.map(\.title).joined(separator: ", "))
        let typed = await search.documents(ofTypes: types)
        guard !typed.isEmpty else { return nil }
        let folderIDs = Set(typed.map(\.folderID))
        let neighbours = await search.documents(ofTypes: DocumentType.allCases)
            .filter { folderIDs.contains($0.folderID) && !typed.map(\.id).contains($0.id) }
        let ids = (typed + neighbours).prefix(12).map(\.id)
        let folders = search.searchableFolders.filter { folderIDs.contains($0.id) }
        let text = folders.count == 1
            ? "Файлы из папки «\(folders[0].name)»:"
            : "Нашёл \(pluralize(ids.count, "документ", "документа", "документов")):"
        return ChatReply(text: text, cards: [.fileList(documentIDs: Array(ids))])
    }

    // MARK: - Поиск по тексту

    private func textSearch(_ text: String) async -> (ChatReply, [Int64: SearchResult]) {
        onStep?(.search, "Ищу в тексте документов: «\(text)»")
        let results = await search.search(text)
        let indexed = results.filter { $0.documentID != nil }
        let hits = Dictionary(indexed.map { ($0.documentID!, $0) }, uniquingKeysWith: { first, _ in first })
        guard !results.isEmpty else {
            return (ChatReply(text: Self.nothingFound(text, pending: search.progress.pending), cards: []), [:])
        }
        guard !indexed.isEmpty else {
            return (ChatReply(text: "Подходящие файлы ещё распознаются — спросите через минуту.", cards: []), [:])
        }

        if let best = indexed.first, best.snippet != nil, let id = best.documentID {
            let rest = indexed.dropFirst().compactMap(\.documentID).prefix(6)
            var cards: [ChatCard] = [.snippet(documentID: id, page: best.page)]
            if !rest.isEmpty { cards.append(.fileList(documentIDs: Array(rest))) }
            let text = rest.isEmpty ? "Нашёл в тексте документа:" : "Лучшее совпадение — в тексте этого документа. Ещё подходят:"
            return (ChatReply(text: text, cards: cards), hits)
        }

        let ids = indexed.compactMap(\.documentID)
        if ids.count == 1 {
            return (ChatReply(text: "Нашёл файл:", cards: [.document(documentID: ids[0])]), hits)
        }
        let folders = Set(indexed.filter(\.matchedFolder).map(\.folder.id))
        let text = folders.count == 1 && indexed.allSatisfy(\.matchedFolder)
            ? "Файлы из папки «\(indexed[0].folder.name)»:"
            : "Нашёл \(pluralize(ids.count, "файл", "файла", "файлов")):"
        return (ChatReply(text: text, cards: [.fileList(documentIDs: Array(ids.prefix(12)))]), hits)
    }
}
