import SwiftUI

/// 畫面底部短暫顯示的提示訊息，設定為 nil 即隱藏。
private struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.onPrimary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(DS.primary, in: Capsule())
                        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
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
