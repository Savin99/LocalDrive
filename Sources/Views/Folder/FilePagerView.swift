import AVKit
import PDFKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// Полноэкранный просмотр: свайп идёт по всей цепочке вложений подряд —
// фото, видео и документы в порядке страницы.
//
// Пейджер свой, а не QLPreviewController, из-за его панели: на каждой смене
// файла QuickLook переанимирует свой навигационный бар — «Готово» сжимается в
// точку и уезжает, кнопка списка исчезает. При быстром листании это выглядит
// сломанным. Отдать ему только пейджинг нельзя: без нашего
// UINavigationController он не листает вообще.
//
// Фото, видео, PDF и текст рисуем сами: встроенный QLPreviewController
// показывает содержимое без своей хромы, но его скролл съедает горизонтальный
// жест, и со страницы документа было бы не свайпнуть. Он остался запасным
// вариантом для остальных форматов, а листать всегда можно стрелками в панели.
struct FilePagerView: View {
    let files: [VaultFile]
    let initialFile: VaultFile
    /// Страница PDF, с которой открыть первый файл: поиск нашёл текст на ней
    var initialPage: Int?
    let onClose: () -> Void

    @State private var index: Int
    @State private var controlsHidden = false

    init(
        files: [VaultFile],
        initialFile: VaultFile,
        initialPage: Int? = nil,
        onClose: @escaping () -> Void
    ) {
        self.files = files.contains(initialFile) ? files : [initialFile] + files
        self.initialFile = initialFile
        self.initialPage = initialPage
        self.onClose = onClose
        _index = State(initialValue: self.files.firstIndex(of: initialFile) ?? 0)
    }

    private var current: VaultFile? {
        files.indices.contains(index) ? files[index] : nil
    }

    private var showsDocument: Bool {
        guard let current else { return false }
        return !current.isPlayable && !current.type.conforms(to: .image)
    }

    var body: some View {
        ZStack {
            // Документ читается на светлом, фото и видео — на чёрном
            (showsDocument ? Color(.systemBackground) : .black)
                .ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(files.enumerated()), id: \.element.id) { offset, file in
                    page(for: file)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if !controlsHidden {
                controls
                    .transition(.opacity)
            }
        }
        .statusBarHidden()
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { controlsHidden.toggle() }
        }
    }

    @ViewBuilder
    private func page(for file: VaultFile) -> some View {
        if file.isPlayable {
            VideoPlayer(player: AVPlayer(url: file.url))
                .ignoresSafeArea()
        } else if file.type.conforms(to: .image) {
            ZoomableImage(url: file.url)
        } else if file.type.conforms(to: .pdf) {
            PDFPageView(url: file.url, page: file == initialFile ? initialPage : nil)
        } else if file.type.conforms(to: .text) {
            TextFileView(url: file.url)
        } else {
            DocumentPage(url: file.url)
        }
    }

    // Стрелки нужны не для красоты: на странице документа QuickLook
    // забирает горизонтальный жест себе, и свайпом оттуда не уйти
    private func step(by offset: Int, symbol: String, label: String) -> some View {
        let target = index + offset
        return Button {
            withAnimation(.snappy(duration: 0.25)) { index = target }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(!files.indices.contains(target))
        .opacity(files.indices.contains(target) ? 1 : 0.3)
        .accessibilityLabel(label)
    }

    private var controls: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть")
            }
            .padding(.horizontal, 16)

            Spacer()

            HStack(spacing: 14) {
                step(by: -1, symbol: "chevron.left", label: "Предыдущий файл")

                Text("\(index + 1) / \(files.count)")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(.white)
                    .monospacedDigit()

                if let current {
                    Divider()
                        .frame(height: 18)
                        .overlay(.white.opacity(0.3))

                    Text(current.name)
                        .font(.system(.subheadline))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150)

                    Divider()
                        .frame(height: 18)
                        .overlay(.white.opacity(0.3))

                    ShareLink(item: current.url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }

                step(by: 1, symbol: "chevron.right", label: "Следующий файл")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.black.opacity(0.45), in: Capsule())
        }
        .padding(.vertical, 12)
    }
}

// PDF рисуем PDFKit-ом: он листает страницы по вертикали и не мешает
// горизонтальному свайпу пейджера
private struct PDFPageView: UIViewRepresentable {
    let url: URL
    /// Номер страницы с единицы
    var page: Int?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.backgroundColor = .systemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard view.document?.documentURL != url else { return }
        let document = PDFDocument(url: url)
        view.document = document
        guard let page, page > 1, let target = document?.page(at: page - 1) else { return }
        // До первой раскладки PDFView ещё не знает размеров страниц и
        // переход на страницу теряется — откладываем на следующий цикл
        DispatchQueue.main.async {
            view.go(to: target)
        }
    }
}

// Текстовый файл — обычный нередактируемый UITextView с вертикальным скроллом
private struct TextFileView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.backgroundColor = .systemBackground
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 24, left: 16, bottom: 24, right: 16)
        view.alwaysBounceHorizontal = false
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text.isEmpty else { return }
        view.text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            ?? "Не удалось прочитать файл"
    }
}

// Одна страница документа. QLPreviewController без своего
// UINavigationController рисует только содержимое — ни панели, ни кнопок,
// зато остаются его зум и прокрутка страниц.
private struct DocumentPage: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        return preview
    }

    func updateUIViewController(_ preview: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        preview.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// Зум щипком и двойным тапом, пан в пределах увеличенного кадра
private struct ZoomableImage: View {
    let url: URL

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            AsyncImageFile(url: url)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scale = max(1, committedScale * value.magnification)
                        }
                        .onEnded { _ in
                            committedScale = scale
                            if scale <= 1 { reset() }
                        }
                )
                // Пан включается только на увеличенном кадре: иначе его
                // распознаватель забирает горизонтальный жест у пейджера
                // и цепочка перестаёт листаться свайпом
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: committedOffset.width + value.translation.width,
                                height: committedOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in committedOffset = offset },
                    isEnabled: scale > 1
                )
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) {
                        if scale > 1 {
                            reset()
                        } else {
                            scale = 2
                            committedScale = 2
                        }
                    }
                }
        }
    }

    private func reset() {
        scale = 1
        committedScale = 1
        offset = .zero
        committedOffset = .zero
    }
}

// Полноразмерное изображение с диска — миниатюры QuickLook здесь мало
private struct AsyncImageFile: View {
    let url: URL

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .task(id: url) {
            image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path)
            }.value
        }
    }
}
