import SwiftUI
import UIKit

/// 鍵盤版面診斷（設定 › 筆記 › 版面中開啟）：顯示鍵盤出現前後，視窗在螢幕上的位置、App 畫面在視窗中的位置與安全區域。
/// 鍵盤打開時截圖，就知道是整個視窗被系統移動（台前調度、視窗化 App），還是 App 的畫面在視窗裡被推動。
struct KeyboardDiagnosticsOverlay: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardDiagnosticsLabel {
        KeyboardDiagnosticsLabel()
    }

    func updateUIView(_ uiView: KeyboardDiagnosticsLabel, context: Context) {}
}

final class KeyboardDiagnosticsLabel: UILabel {
    static let key = "debug.keyboardDiagnostics"

    /// 鍵盤沒有出現時最後一次的狀態（和現在比較）。
    private var withoutKeyboard = "（尚未記錄）"
    private var keyboardFrame: CGRect?
    private var tokens: [NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 0
        font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        textColor = .white
        backgroundColor = UIColor.black.withAlphaComponent(0.78)
        layer.cornerRadius = 8
        layer.masksToBounds = true
        isUserInteractionEnabled = false
        let center = NotificationCenter.default
        let events: [(Notification.Name, String)] = [
            (UIResponder.keyboardWillShowNotification, "鍵盤將出現"),
            (UIResponder.keyboardDidShowNotification, "鍵盤已出現"),
            (UIResponder.keyboardWillHideNotification, "鍵盤將收起"),
            (UIResponder.keyboardDidHideNotification, "鍵盤已收起"),
            (UIResponder.keyboardDidChangeFrameNotification, "鍵盤位置變了"),
        ]
        for (name, title) in events {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.keyboardFrame = name == UIResponder.keyboardDidHideNotification ? nil : frame
                    // 版面調整完才量
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        self.refresh(title)
                    }
                }
            })
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refresh("開始")
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: 8, dy: 6))
    }

    private func refresh(_ event: String) {
        guard let window else { return }
        let state = Self.describe(window: window, marker: self)
        let keyboard = keyboardFrame.map(Self.format) ?? "沒有"
        if keyboardFrame == nil || (keyboardFrame?.height ?? 0) < 1 {
            withoutKeyboard = state
        }
        text = [
            "鍵盤診斷 · \(event)",
            "鍵盤（螢幕座標）\(keyboard)",
            "── 沒有鍵盤時 ──",
            withoutKeyboard,
            "── 現在 ──",
            state,
        ].joined(separator: "\n")
    }

    private static func describe(window: UIWindow, marker: UIView) -> String {
        let screen = window.screen.coordinateSpace
        let windowOnScreen = window.convert(window.bounds, to: screen)
        let root = window.rootViewController?.view
        let rootFrame = root.map { $0.convert($0.bounds, to: window) } ?? .zero
        let markerFrame = marker.convert(marker.bounds, to: window)
        let insets = root?.safeAreaInsets ?? .zero
        let scene = window.windowScene
        let mode = scene.map { $0.screen.bounds.size == window.bounds.size ? "全螢幕" : "視窗" } ?? "-"
        return [
            "視窗在螢幕 \(format(windowOnScreen)) \(mode)",
            "視窗 bounds 原點 \(Int(window.bounds.minX)),\(Int(window.bounds.minY))",
            "App 畫面在視窗 \(format(rootFrame))",
            "這個標籤在視窗 y=\(Int(markerFrame.minY))",
            "安全區域 上\(Int(insets.top)) 下\(Int(insets.bottom))",
        ].joined(separator: "\n")
    }

    private static func format(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height)))"
    }
}
