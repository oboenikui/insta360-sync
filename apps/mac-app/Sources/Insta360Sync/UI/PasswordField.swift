import AppKit
import SwiftUI

/// Form 内の SwiftUI SecureField がレイアウトを壊すため、AppKit で完結したパスワード入力欄。
struct PasswordField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        PasswordFieldRepresentable(text: $text, placeholder: title)
            .frame(height: 21)
            .accessibilityLabel(title)
    }
}

private struct PasswordFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> PasswordFieldBox {
        let box = PasswordFieldBox()
        box.placeholderString = placeholder
        box.stringValue = text
        box.onTextChange = { context.coordinator.text.wrappedValue = $0 }
        return box
    }

    func updateNSView(_ box: PasswordFieldBox, context: Context) {
        context.coordinator.text = $text
        box.onTextChange = { context.coordinator.text.wrappedValue = $0 }
        if box.stringValue != text {
            box.stringValue = text
        }
        if box.placeholderString != placeholder {
            box.placeholderString = placeholder
        }
    }

    final class Coordinator {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }
    }
}

private final class PasswordFieldBox: NSView, NSTextFieldDelegate {
    var onTextChange: ((String) -> Void)?

    private let secureField = TrailingInsetSecureTextField(string: "")
    private let plainField = TrailingInsetPlainTextField(string: "")
    private let toggleButton = NSButton()
    private var isVisible = false

    var stringValue: String {
        get { activeField.stringValue }
        set {
            guard secureField.stringValue != newValue || plainField.stringValue != newValue else { return }
            secureField.stringValue = newValue
            plainField.stringValue = newValue
        }
    }

    var placeholderString: String {
        get { secureField.placeholderString ?? "" }
        set {
            secureField.placeholderString = newValue
            plainField.placeholderString = newValue
        }
    }

    private var activeField: NSTextField {
        isVisible ? plainField : secureField
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 21)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        configureField(secureField)
        configureField(plainField)
        plainField.isHidden = true

        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.bezelStyle = .inline
        toggleButton.isBordered = false
        toggleButton.imagePosition = .imageOnly
        toggleButton.target = self
        toggleButton.action = #selector(toggleVisibility)
        toggleButton.setContentHuggingPriority(.required, for: .horizontal)
        toggleButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateToggleAppearance()

        addSubview(secureField)
        addSubview(plainField)
        addSubview(toggleButton)

        for field in [secureField as NSView, plainField as NSView] {
            field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor),
                field.trailingAnchor.constraint(equalTo: trailingAnchor),
                field.topAnchor.constraint(equalTo: topAnchor),
                field.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            toggleButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            toggleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 16),
            toggleButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func configureField(_ field: NSTextField) {
        field.delegate = self
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.alignment = .left
        field.cell?.isScrollable = true
        field.isEditable = true
        field.isSelectable = true
        field.lineBreakMode = .byClipping
    }

    private func updateToggleAppearance() {
        let name = isVisible ? "eye.slash" : "eye"
        toggleButton.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        toggleButton.toolTip = isVisible ? "パスワードを隠す" : "パスワードを表示"
        toggleButton.contentTintColor = .secondaryLabelColor
    }

    @objc private func toggleVisibility() {
        let current = activeField.stringValue
        let wasFirstResponder = window?.firstResponder === activeField
            || (window?.firstResponder as? NSText)?.delegate as AnyObject? === activeField

        isVisible.toggle()
        secureField.isHidden = isVisible
        plainField.isHidden = !isVisible
        secureField.stringValue = current
        plainField.stringValue = current
        updateToggleAppearance()

        if wasFirstResponder {
            window?.makeFirstResponder(activeField)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        let value = activeField.stringValue
        secureField.stringValue = value
        plainField.stringValue = value
        onTextChange?(value)
    }
}

private final class TrailingInsetSecureTextField: NSSecureTextField {
    override class var cellClass: AnyClass? {
        get { TrailingInsetSecureTextFieldCell.self }
        set {}
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = TrailingInsetSecureTextFieldCell(textCell: "")
    }

    convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class TrailingInsetPlainTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { TrailingInsetPlainTextFieldCell.self }
        set {}
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = TrailingInsetPlainTextFieldCell(textCell: "")
    }

    convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class TrailingInsetSecureTextFieldCell: NSSecureTextFieldCell {
    private let trailingInset: CGFloat = 26

    override init(textCell string: String) {
        super.init(textCell: string)
        echosBullets = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        insetDrawingRect(super.drawingRect(forBounds: rect), by: trailingInset)
    }
}

private final class TrailingInsetPlainTextFieldCell: NSTextFieldCell {
    private let trailingInset: CGFloat = 26

    override init(textCell string: String) {
        super.init(textCell: string)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        insetDrawingRect(super.drawingRect(forBounds: rect), by: trailingInset)
    }
}

private func insetDrawingRect(_ rect: NSRect, by trailingInset: CGFloat) -> NSRect {
    var drawingRect = rect
    drawingRect.size.width = max(0, drawingRect.size.width - trailingInset)
    return drawingRect
}
