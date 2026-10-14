import SwiftUI

/// 畫面底部短暫顯示的提示訊息，設定為 nil 即隱藏。
private struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Midnight.text)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .glass(cornerRadius: 22)
                        .overlay(Capsule().strokeBorder(Midnight.gradient, lineWidth: 1).opacity(0.4))
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(1.5))
                            self.message = nil
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: message)
    }
}

extension View {
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}
