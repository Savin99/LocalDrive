import SwiftUI
import UIKit

/// Куда поставить каретку при передаче фокуса блоку
struct FeedFocus: Equatable {
    var id: UUID
    /// nil — в конец текста
    var caret: Int?

    init(_ id: UUID, caret: Int? = nil) {
        self.id = id
        self.caret = caret
    }
}

// Текстовый блок редактируется прямо на странице.
//
// Вне фокуса вью показывает разметку в готовом виде, в фокусе — исходник со
// служебными символами и панелью форматирования над клавиатурой. Тап
// переводится из отрендеренного текста в исходник по карте смещений, иначе
// каретка вставала бы мимо на каждой строке с разметкой.
//
// UITextView намеренно держится нередактируемым и невыделяемым, пока блок не в
// фокусе: иначе его собственные распознаватели съедают долгое нажатие, и блок
// становится невозможно перетащить. Каретку по тапу ставим сами — так тап
// попадает ровно в тот символ, по которому нажали.
struct FeedTextBlockEditor: UIViewRepresentable {
    let blockID: UUID
    @Binding var text: String
    let isFocused: Bool
    let isEnabled: Bool
    let placeholder: String
    let caret: Int?

    var onFocus: (Int?) -> Void
    var onBlur: () -> Void
    /// Enter: текст режется по каретке, хвост уходит в новый блок ниже
    var onSplit: (String, String) -> Void
    /// Backspace в самом начале: блок склеивается с предыдущим
    var onMergeBackward: (String) -> Void

    func makeUIView(context: Context) -> FeedTextView {
        let view = FeedTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.isEditable = false
        view.isSelectable = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.tintColor = .tintColor
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)

        view.accessibilityIdentifier = "feedTextBlock"

        let formatBar = FeedFormatBar()
        formatBar.onAction = { [weak coordinator = context.coordinator] action in
            coordinator?.apply(action)
        }
        view.inputAccessoryView = formatBar

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        context.coordinator.textView = view
        return view
    }

    func updateUIView(_ view: FeedTextView, context: Context) {
        context.coordinator.parent = self
        view.placeholder = placeholder

        // Пока блок в фокусе, текст живёт в UITextView — перезапись оттуда
        // сбрасывала бы каретку на каждое нажатие
        if !view.isFirstResponder, context.coordinator.needsRender(of: text, in: view) {
            context.coordinator.applyRendered(source: text, to: view)
        }

        if isFocused {
            if !view.isFirstResponder {
                view.isEditable = true
                view.isSelectable = true
                context.coordinator.beginExternalFocus(on: view)
            }
            context.coordinator.applyCaret(caret)
        } else if view.isFirstResponder {
            view.resignFirstResponder()
        }

        if !isEnabled, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FeedTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? 20
        return CGSize(width: width, height: max(fitted.height, lineHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: FeedTextBlockEditor
        weak var textView: FeedTextView?
        private var appliedCaret: Int??
        /// becomeFirstResponder синхронно вызывает textViewDidBeginEditing;
        /// на программном фокусе тот не должен сбрасывать заданную каретку
        private var isTakingFocusProgrammatically = false

        /// Исходник, который сейчас показан в готовом виде.
        /// nil — во вью лежит исходник, то есть блок правится.
        private var renderedSource: String?
        private var renderedCategory: UIContentSizeCategory?
        private var renderedLayout: FeedMarkdown.Rendered?

        init(parent: FeedTextBlockEditor) {
            self.parent = parent
        }

        // MARK: - Разметка

        private func style(for view: UIView) -> FeedMarkdown.Style {
            .standard(body: .preferredFont(forTextStyle: .body, compatibleWith: view.traitCollection))
        }

        func needsRender(of source: String, in view: FeedTextView) -> Bool {
            renderedSource != source
                || renderedCategory != view.traitCollection.preferredContentSizeCategory
        }

        /// Готовый вид: служебные символы убраны
        func applyRendered(source: String, to view: FeedTextView) {
            let rendered = FeedMarkdown.rendered(source, style: style(for: view))
            view.attributedText = rendered.text
            view.refreshPlaceholder()
            view.invalidateIntrinsicContentSize()

            renderedSource = source
            renderedCategory = view.traitCollection.preferredContentSizeCategory
            renderedLayout = rendered
        }

        /// Исходник для правки: символы разметки видны, оформление применено
        private func applyEditingSource(_ source: String, to view: FeedTextView, selection: NSRange?) {
            let style = style(for: view)
            view.attributedText = FeedMarkdown.styledSource(source, style: style)
            view.typingAttributes = [.font: style.body, .foregroundColor: style.textColor]
            if let selection {
                let length = (source as NSString).length
                view.selectedRange = NSRange(
                    location: min(selection.location, length),
                    length: min(selection.length, max(0, length - min(selection.location, length)))
                )
            }
            view.refreshPlaceholder()
            view.invalidateIntrinsicContentSize()

            renderedSource = nil
            renderedLayout = nil
        }

        /// Перекраска на ходу: набранный `**жирный**` виден сразу.
        /// Длина текста не меняется, поэтому выделение переносится один в один.
        private func restyleWhileEditing(_ view: FeedTextView) {
            // Во время набора через IME подменять attributedText нельзя —
            // рассыплется незакреплённый ввод
            guard view.markedTextRange == nil else { return }
            applyEditingSource(view.text ?? "", to: view, selection: view.selectedRange)
        }

        // MARK: - Панель форматирования

        func apply(_ action: FeedFormatAction) {
            guard let view = textView, view.isFirstResponder else { return }

            if action == .dismissKeyboard {
                view.resignFirstResponder()
                return
            }

            let source = view.text ?? ""
            let selection = view.selectedRange

            let edit: FeedMarkdownEditing.Edit = switch action {
            case .bold:
                FeedMarkdownEditing.toggleEmphasis("**", in: source, selection: selection)
            case .italic:
                FeedMarkdownEditing.toggleEmphasis("*", in: source, selection: selection)
            case .heading(let level):
                FeedMarkdownEditing.toggleLinePrefix(.heading(level), in: source, selection: selection)
            case .bullet:
                FeedMarkdownEditing.toggleLinePrefix(.bullet, in: source, selection: selection)
            case .numbered:
                FeedMarkdownEditing.toggleLinePrefix(.numbered, in: source, selection: selection)
            case .dismissKeyboard:
                FeedMarkdownEditing.Edit(text: source, selection: selection)
            }

            applyEditingSource(edit.text, to: view, selection: edit.selection)
            appliedCaret = .some(edit.selection.location)
            parent.text = edit.text
        }

        // MARK: - Фокус и каретка

        /// Фокус пришёл извне (Enter в соседнем блоке, Backspace, меню).
        /// Свежесозданный UITextView ещё не в окне и первым ответчиком не станет,
        /// поэтому попытка повторяется на следующем цикле; каретку тоже ставим
        /// повторно — UIKit после becomeFirstResponder уводит её в конец текста.
        func beginExternalFocus(on view: FeedTextView) {
            appliedCaret = nil
            view.isEditable = true
            view.isSelectable = true

            if let shown = renderedSource {
                applyEditingSource(shown, to: view, selection: nil)
            }

            isTakingFocusProgrammatically = true
            let became = view.becomeFirstResponder()
            isTakingFocusProgrammatically = false

            let requested = parent.caret
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.parent.isFocused else { return }
                if became {
                    self.forceCaret(requested)
                } else if !view.isFirstResponder {
                    self.beginExternalFocus(on: view)
                }
            }
        }

        private func forceCaret(_ caret: Int?) {
            guard let view = textView, view.isFirstResponder else { return }
            appliedCaret = .some(caret)
            let target = caret.map { min(max(0, $0), (view.text as NSString).length) }
            let position = target
                .flatMap { view.position(from: view.beginningOfDocument, offset: $0) }
                ?? view.endOfDocument
            view.selectedTextRange = view.textRange(from: position, to: position)
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard parent.isEnabled, let view = textView else { return }
            let point = recognizer.location(in: view)
            let showsRendered = renderedSource != nil

            // Смещение считается по тому, что сейчас на экране: у готового вида
            // это отрендеренный текст, и его надо перевести в исходник
            var offset: Int?
            if let position = view.closestPosition(to: point) {
                let hit = view.offset(from: view.beginningOfDocument, to: position)
                offset = showsRendered ? (renderedLayout?.sourceOffset(for: hit) ?? hit) : hit
            }

            view.isEditable = true
            view.isSelectable = true
            if let shown = renderedSource {
                applyEditingSource(shown, to: view, selection: nil)
            }

            appliedCaret = .some(offset)
            isTakingFocusProgrammatically = true
            view.becomeFirstResponder()
            isTakingFocusProgrammatically = false
            if let offset, let position = view.position(from: view.beginningOfDocument, offset: offset) {
                view.selectedTextRange = view.textRange(from: position, to: position)
            }
            parent.onFocus(offset)
        }

        func applyCaret(_ caret: Int?) {
            // Каждое значение применяется один раз, иначе каретка возвращалась бы
            // на исходное место при каждой перерисовке
            if let applied = appliedCaret, applied == caret { return }
            forceCaret(caret)
        }

        // MARK: - UITextViewDelegate

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            let current = textView.text as NSString

            if text == "\n" {
                let prefix = current.substring(to: range.location)
                let suffix = current.substring(from: min(current.length, range.location + range.length))
                // Вью остаётся первым ответчиком ещё цикл; без этого его
                // textViewDidEndEditing вернул бы в модель неразрезанную строку
                textView.text = prefix
                appliedCaret = .some(prefix.utf16.count)
                parent.onSplit(prefix, suffix)
                return false
            }

            if text.isEmpty, range.length == 0, range.location == 0 {
                parent.onMergeBackward(current as String)
                return false
            }

            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            if let view = textView as? FeedTextView {
                restyleWhileEditing(view)
            }
            (textView as? FeedTextView)?.refreshPlaceholder()
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            // Блок уже помечен активным — фокус пришёл извне (Enter, Backspace,
            // меню). Это единственный надёжный момент поставить каретку: раньше
            // becomeFirstResponder может не сработать, вью ещё не в окне.
            if parent.isFocused {
                let requested = parent.caret
                DispatchQueue.main.async { [weak self] in self?.forceCaret(requested) }
                return
            }
            guard !isTakingFocusProgrammatically else { return }
            appliedCaret = nil
            parent.onFocus(nil)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            appliedCaret = nil
            textView.isEditable = false
            textView.isSelectable = false
            parent.text = textView.text

            // Модель обновится следующим циклом, поэтому рендерим
            // от того, что лежит во вью
            if let view = textView as? FeedTextView {
                applyRendered(source: textView.text ?? "", to: view)
            }
            parent.onBlur()
        }
    }
}

// UITextView без плейсхолдера — рисуем его сами
final class FeedTextView: UITextView {
    var placeholder: String = "" {
        didSet { refreshPlaceholder() }
    }

    private let placeholderLabel = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .tertiaryLabel
        placeholderLabel.numberOfLines = 1
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var text: String! {
        didSet { refreshPlaceholder() }
    }

    func refreshPlaceholder() {
        placeholderLabel.text = placeholder
        placeholderLabel.isHidden = !(text ?? "").isEmpty || placeholder.isEmpty
    }
}
