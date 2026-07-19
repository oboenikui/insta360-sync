import AppKit
import SwiftUI

/// Form 内の SwiftUI TextField がラベル付き・右寄せになるのを避けるための入力欄。
struct BorderedTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        BorderedTextFieldRepresentable(text: $text, placeholder: title)
            .frame(height: 21)
            .accessibilityLabel(title)
    }
}

private struct BorderedTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
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
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
        field.alignment = .left
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
