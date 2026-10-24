import UIKit

enum FeedFormatAction: Equatable {
    case bold
    case italic
    case heading(Int)
    case bullet
    case numbered
    case dismissKeyboard
}

// Панель над клавиатурой: пока блок в фокусе, отсюда ставится жирный,
// курсив, заголовок и списки. Кнопки работают и по выделению,
// и по строке под кареткой — за это отвечает FeedMarkdownEditing.
//
// Ряд прокручивается: восемь кнопок в строку не влезают на узком экране,
// а на крупном системном шрифте не влезли бы и на широком.
final class FeedFormatBar: UIInputView {
    var onAction: ((FeedFormatAction) -> Void)?

    private let scroll = UIScrollView()
    private let row = UIStackView()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        autoresizingMask = .flexibleWidth
        allowsSelfSizing = true

        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        row.axis = .horizontal
        row.spacing = 2
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        addButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func addButtons() {
        row.addArrangedSubview(
            button(symbol: "bold", label: "Жирный", identifier: "feedFormatBold", action: .bold)
        )
        row.addArrangedSubview(
            button(symbol: "italic", label: "Курсив", identifier: "feedFormatItalic", action: .italic)
        )

        for level in 1...3 {
            row.addArrangedSubview(
                button(
                    title: "H\(level)",
                    label: "Заголовок \(level)",
                    identifier: "feedFormatHeading\(level)",
                    action: .heading(level)
                )
            )
        }

        row.addArrangedSubview(
            button(symbol: "list.bullet", label: "Список", identifier: "feedFormatBullet", action: .bullet)
        )
        row.addArrangedSubview(
            button(
                symbol: "list.number",
                label: "Нумерованный список",
                identifier: "feedFormatNumbered",
                action: .numbered
            )
        )
        row.addArrangedSubview(
            button(
                symbol: "keyboard.chevron.compact.down",
                label: "Скрыть клавиатуру",
                identifier: "feedFormatDone",
                action: .dismissKeyboard
            )
        )
    }

    private func button(
        symbol: String,
        label: String,
        identifier: String,
        action: FeedFormatAction
    ) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        return button(configuration: configuration, label: label, identifier: identifier, action: action)
    }

    private func button(
        title: String,
        label: String,
        identifier: String,
        action: FeedFormatAction
    ) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString(
            title,
            attributes: AttributeContainer([.font: UIFont.preferredFont(forTextStyle: .subheadline)])
        )
        return button(configuration: configuration, label: label, identifier: identifier, action: action)
    }

    private func button(
        configuration: UIButton.Configuration,
        label: String,
        identifier: String,
        action: FeedFormatAction
    ) -> UIButton {
        var configuration = configuration
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)

        let button = UIButton(
            configuration: configuration,
            primaryAction: UIAction { [weak self] _ in self?.onAction?(action) }
        )
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.widthAnchor.constraint(greaterThanOrEqualTo: button.heightAnchor).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }
}
