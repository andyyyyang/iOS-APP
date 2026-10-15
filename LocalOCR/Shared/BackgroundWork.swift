import UIKit

/// 進入背景時還要做完的工作（上傳剛存檔的筆跡、產生手寫筆記的圖片）：向系統要一點背景時間，做完或時間到就結束。
@MainActor
enum BackgroundWork {
    static func run(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { token.end() }
        }
        Task { @MainActor in
            await work()
            token.end()
        }
    }

    @MainActor
    private final class Token {
        var id: UIBackgroundTaskIdentifier = .invalid

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}
