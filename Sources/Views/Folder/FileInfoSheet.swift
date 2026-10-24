import PDFKit
import SwiftUI

// Сведения о файле: что это, сколько весит, когда появился и находит ли его
// чат. Значений полей документа здесь нет и не будет — только факт индекса
struct FileInfoSheet: View {
    @Environment(VaultStore.self) private var store
    @Environment(SearchService.self) private var search
    @Environment(\.dismiss) private var dismiss

    let file: VaultFile
    let folder: VaultFolder

    @State private var pageCount: Int?
    @State private var isIndexed: Bool?
    /// Второе чтение моделью — только у удостоверений, без значений полей
    @State private var modelState: ModelReadState?
    @State private var cloudState: CloudReadState?
    /// О чём документ — от облачного распознавания. Без идентификаторов и сумм
    @State private var metadata: DocumentMetadata?

    @ScaledMetric(relativeTo: .title) private var thumbnailSide: CGFloat = 72

    /// Папку могли переименовать или убрать из поиска, пока открыт экран
    private var currentFolder: VaultFolder { store.folder(by: folder.id) ?? folder }
    private var accent: Color { Theme.color(currentFolder.color) }

    private var isMedia: Bool {
        file.type.conforms(to: .image) || file.type.conforms(to: .movie) || file.type.conforms(to: .video)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                }

                Section {
                    LabeledContent("Тип", value: kindTitle)
                    LabeledContent("Размер", value: RussianFormat.size(file.size, exact: true))
                    if let pageCount {
                        LabeledContent("Страниц", value: "\(pageCount)")
                    }
                }
                .listRowBackground(Theme.card)

                // Найдёт ли файл чат — выше дат: ради этого сведения и открывают
                Section {
                    // Путь целиком: одноимённые папки бывают в разных местах
                    LabeledContent("Папка", value: store.path(of: currentFolder))
                    LabeledContent("Поиск в чате", value: searchState.value)
                        .accessibilityIdentifier("fileInfoSearch")
                    if let metadata {
                        if !metadata.title.isEmpty {
                            LabeledContent("Название", value: metadata.title)
                                .accessibilityIdentifier("fileInfoTitle")
                        }
                        if !metadata.kind.isEmpty {
                            LabeledContent("Вид", value: metadata.kind)
                        }
                        LabeledContent("Категория", value: DocumentCategory(rawValue: metadata.category)?.title ?? DocumentCategory.other.title)
                        if !metadata.documentDate.isEmpty {
                            LabeledContent("Дата документа", value: metadata.documentDate)
                        }
                        if !metadata.validUntil.isEmpty {
                            LabeledContent("Действует до", value: metadata.validUntil)
                        }
                        if !metadata.summary.isEmpty {
                            Text(metadata.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("fileInfoSummary")
                        }
                    }
                    if let cloudState {
                        LabeledContent("Облако", value: Self.title(cloudState))
                            .accessibilityIdentifier("fileInfoCloud")
                    } else if let modelState {
                        LabeledContent("Модель для документов", value: Self.title(modelState))
                            .accessibilityIdentifier("fileInfoModel")
                    }
                } footer: {
                    Text(searchState.footer)
                }
                .listRowBackground(Theme.card)

                Section {
                    LabeledContent("Добавлен", value: RussianFormat.dateTime(file.addedAt))
                    if let contentDate {
                        LabeledContent(isMedia ? "Снято" : "Изменён", value: RussianFormat.dateTime(contentDate))
                    }
                }
                .listRowBackground(Theme.card)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Сведения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .tint(Theme.ink)
        // Во весь рост: на половине экрана строка о поиске уходила за край
        .presentationDetents([.large])
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            FileThumbnail(
                file: file,
                accent: accent,
                size: CGSize(width: thumbnailSide, height: thumbnailSide),
                cornerRadius: 18
            )
            Text(file.name)
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
    }

    // MARK: - Значения

    private var kindTitle: String {
        let type = file.type
        let kind = if type.conforms(to: .pdf) {
            "PDF-документ"
        } else if type.conforms(to: .image) {
            "Изображение"
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            "Видео"
        } else if type.conforms(to: .audio) {
            "Аудио"
        } else if type.conforms(to: .spreadsheet) {
            "Таблица"
        } else if type.conforms(to: .presentation) {
            "Презентация"
        } else if type.conforms(to: .archive) {
            "Архив"
        } else if type.conforms(to: .sourceCode) {
            "Исходный код"
        } else if type.conforms(to: .text) {
            "Текст"
        } else {
            "Документ"
        }
        guard let badge = file.extensionBadge, !type.conforms(to: .pdf) else { return kind }
        return "\(kind), \(badge)"
    }

    /// Дата съёмки из метаданных или дата изменения документа. Если она
    /// совпадает с датой добавления, второй строкой она ничего не скажет
    private var contentDate: Date? {
        let date = store.contentDates(in: folder)[file.name] ?? file.contentDate
        return abs(date.timeIntervalSince(file.addedAt)) < 60 ? nil : date
    }

    /// Скрытость и «вне поиска» наследуются от папок выше — сведения называют,
    /// у какой папки искать переключатель
    private var searchState: (value: String, footer: String) {
        let lineage = store.lineage(of: currentFolder)
        if store.isHidden(currentFolder) {
            return ("Нет", "Суперскрытые папки в поиск не попадают никогда — и всё, что внутри них.")
        }
        if !currentFolder.searchable {
            return ("Выключен", "В этой папке выключено «Доступна для поиска» — включить можно в настройках папки.")
        }
        if let off = lineage.last(where: { !$0.searchable }) {
            return ("Выключен", "У папки «\(off.name)» выключено «Доступна для поиска» — это действует и на всё внутри неё.")
        }
        switch isIndexed {
        case true?:
            return ("Находит", "Файл в индексе: чат находит его по тексту и названию.")
        case false? where search.progress.isIndexing:
            return ("В очереди", "Файлы ещё распознаются — осталось \(search.progress.pending).")
        case false?:
            return ("Ещё нет", "Новые файлы распознаются в фоне, пока приложение открыто.")
        case nil:
            return ("Проверяю…", " ")
        }
    }

    private func load() async {
        if file.type.conforms(to: .pdf) {
            let url = file.url
            pageCount = await Task.detached(priority: .utility) {
                PDFDocument(url: url)?.pageCount
            }.value
        }
        guard store.isIndexable(currentFolder) else { return }
        let key = FileKey(folderID: folder.id, name: file.name)
        isIndexed = await search.indexedFiles().contains(key)
        modelState = await search.modelState(for: file, in: currentFolder)
        cloudState = await search.cloudState(for: file, in: currentFolder)
        metadata = await search.metadata(for: file, in: currentFolder)
    }

    static func title(_ state: CloudReadState) -> String {
        switch state {
        case .read: "Распознан в облаке"
        case .notNeeded: "Не нужно: текст файла точный"
        case .failed: "Облако не распознало"
        case .waiting: "Ждёт облака"
        }
    }

    static func title(_ state: ModelReadState) -> String {
        switch state {
        case .read: "Прочитан моделью"
        case .notNeeded: "Не понадобилась"
        case .failed: "Не прочитала"
        case .waiting: "Ждёт модели"
        }
    }
}
