import SwiftUI

struct PasswordField: View {
    let title: String
    @Binding var text: String
    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isVisible {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)

            Button {
                isVisible.toggle()
            } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(isVisible ? "パスワードを隠す" : "パスワードを表示")
        }
    }
}
