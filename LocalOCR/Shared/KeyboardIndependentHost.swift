import SwiftUI
import UIKit

/// 鍵盤不算進安全區域的容器：內容放在另一個 UIHostingController，安全區域只有狀態列與底部指示條
/// （safeAreaRegions = .container），鍵盤出現時內容完全不會被推動或縮小。
/// 環境不會跨過 UIHostingController，內容需要的環境物件要在傳進來之前加上。
struct KeyboardIndependentHost<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = .container
        host.view.backgroundColor = .clear
        return host
    }

    func updateUIViewController(_ host: UIHostingController<Content>, context: Context) {
        host.rootView = content
    }
}
