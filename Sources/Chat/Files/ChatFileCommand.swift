import Foundation

/// «Положи в папку Семья», «перенеси паспорт Ольги в Документы», «сохрани это
/// в Паспорта» — просьба разложить файлы, понятая без облака и без модели.
/// Владелец 24.10.2026: «закинул документ — попросил “положи”, и он предложил
/// папку; чтобы с ним можно было пообщаться». Чат по-прежнему только
/// предлагает: в хранилище ничего не меняется до «Выполнить»
struct ChatFileCommand: Equatable {
    /// Куда: «Семья», «папку для работы» — как написал человек, с регистром
    var destination: String
    /// Что: «паспорт Ольги», «его», «эти файлы»; пусто — то, о чём шла речь
    var subject: String
    /// Сказано «в папку …»: название тогда в именительном — «в папку Работа».
    /// Без этого слова — в винительном: «в работу», «в новую»
    var namedFolder: Bool

    /// Глаголы просьбы. Только повелительное и неопределённая форма: «я
    /// положил паспорт в сейф» — рассказ, а не просьба
    static let verbs = [
        "положи", "положить", "сохрани", "сохранить", "перенеси", "перенести", "переложи", "переложить",
        "перемести", "переместить", "закинь", "закинуть", "кинь", "убери", "убрать", "помести", "поместить",
        "добавь", "добавить", "клади", "засунь",
    ]

    /// Слова, которыми называют то, о чём шла речь: «положи его», «эти файлы»
    static let pronouns: Set<String> = [
        "его", "её", "ее", "их", "это", "этот", "эту", "эти", "этих", "то", "тот", "те", "всё", "все", "оба", "обе",
        "файл", "файлы", "файла", "документ", "документы", "фото", "фотку", "фотки", "скан", "сканы",
        "вложение", "вложения", "туда", "сюда", "пожалуйста", "давай", "ладно", "хорошо", "ок", "да",
    ]

    init?(_ text: String) {
        let pattern = "(?i)(?:^|[^\\p{L}])(" + Self.verbs.joined(separator: "|") + ")(?![\\p{L}])(.*)[\\s,]+(?:в|во)\\s+(?:папку|папке|раздел|папка)?\\s*(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let subjectRange = Range(match.range(at: 2), in: text),
              let destinationRange = Range(match.range(at: 3), in: text) else { return nil }
        let destination = String(text[destinationRange])
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;:«»\"'“”").union(.whitespacesAndNewlines))
            .replacingOccurrences(of: #"\s+пожалуйста$"#, with: "", options: [.regularExpression, .caseInsensitive])
        guard !destination.isEmpty, destination.count <= 60 else { return nil }
        self.destination = destination
        namedFolder = match.range(at: 3).location > 0
            && text[..<destinationRange.lowerBound].lowercased().range(of: #"(папку|папке|папка|раздел)\s*[«"]?$"#, options: .regularExpression) != nil
        subject = String(text[subjectRange]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// Предмет — «то, о чём шла речь»: пусто или одни местоимения
    var refersToContext: Bool {
        SearchText.tokens(in: subject).allSatisfy { Self.pronouns.contains($0.word) || SearchQuery.stopWords.contains($0.word) }
    }

    /// Папка назначения: существующая, доступная для поиска, — по точному
    /// названию или по основам слов («в семью» → «Семья»). Иначе — новая папка
    /// с этим названием. Суперскрытые не находятся никогда: чат не должен
    /// выдавать, что они есть
    @MainActor
    func target(in store: VaultStore) -> FolderTarget {
        let folders = store.folders.filter(store.isIndexable)
        if let exact = folders.first(where: { $0.name.compare(destination, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return .existing(exact.id)
        }
        let wanted = SearchText.tokens(in: destination).map(\.stem).filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return .new(name: Self.folderName(destination)) }
        var best: (folder: VaultFolder, score: Int)?
        for folder in folders {
            let stems = Set(SearchText.tokens(in: folder.name).map(\.stem))
            let score = wanted.filter { stem in stems.contains(stem) || stems.contains { $0.hasPrefix(stem) || stem.hasPrefix($0) && $0.count >= 3 } }.count
            if score == wanted.count, score > (best?.score ?? 0) { best = (folder, score) }
        }
        return best.map { .existing($0.folder.id) } ?? .new(name: Self.folderName(namedFolder ? destination : Self.nominative(destination)))
    }

    /// Новая папка — с заглавной буквы: «семья» → «Семья»
    static func folderName(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    /// «в работу» → «работа», «в новую семью» → «новая семья»: окончания
    /// винительного падежа женского рода. Остальное как есть — «в Документы»
    static func nominative(_ phrase: String) -> String {
        phrase.split(separator: " ").map { word -> String in
            let lower = word.lowercased()
            guard lower.count >= 3, lower.unicodeScalars.allSatisfy({ (0x0400...0x04FF).contains($0.value) }) else { return String(word) }
            if lower.hasSuffix("ую") { return String(word.dropLast(2)) + "ая" }
            if lower.hasSuffix("юю") { return String(word.dropLast(2)) + "яя" }
            if lower.hasSuffix("у") { return String(word.dropLast()) + "а" }
            if lower.hasSuffix("ю") { return String(word.dropLast()) + "я" }
            return String(word)
        }.joined(separator: " ")
    }
}
