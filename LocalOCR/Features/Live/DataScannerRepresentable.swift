import SwiftUI
import VisionKit

/// 讓 SwiftUI 端可以向相機要一張照片。
final class LiveScannerBridge {
    fileprivate weak var scanner: DataScannerViewController?

    /// 以相機目前的畫面拍一張高解析度照片。
    @MainActor
    func capturePhoto() async throws -> UIImage {
        guard let scanner else { throw OCRError.invalidImage }
        return try await scanner.capturePhoto()
    }
}

/// 以 VisionKit 的 DataScannerViewController 當作相機（iOS 17 支援的裝置皆可使用）。
/// 只用來拍照：關閉文字標示與點選，畫面就是單純的相機預覽，文字辨識在拍完後才做。
struct DataScannerRepresentable: UIViewControllerRepresentable {
    let languages: [String]
    let bridge: LiveScannerBridge

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text(languages: languages)],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: false
        )
        bridge.scanner = scanner
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Void) {
        scanner.stopScanning()
    }
}
