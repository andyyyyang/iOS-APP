import SwiftUI
import VisionKit

/// 用相機掃描託運單：條碼直接帶入；印刷的單號（文字）點一下帶入。
struct TrackingNumberScanner: UIViewControllerRepresentable {
    var onFound: (String) -> Void
    var onCancel: () -> Void

    static var isSupported: Bool { DataScannerViewController.isSupported }

    func makeUIViewController(context: Context) -> UINavigationController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(), .text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        scanner.navigationItem.title = "掃描託運單條碼或單號"
        scanner.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { _ in context.coordinator.parent.onCancel() }
        )
        return UINavigationController(rootViewController: scanner)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.parent = self
        if let scanner = controller.viewControllers.first as? DataScannerViewController, !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ controller: UINavigationController, coordinator: Coordinator) {
        (controller.viewControllers.first as? DataScannerViewController)?.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: TrackingNumberScanner
        private var didFind = false

        init(parent: TrackingNumberScanner) {
            self.parent = parent
        }

        private func finish(_ value: String) {
            guard !didFind else { return }
            didFind = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            parent.onFound(LogisticsLogic.normalize(value))
        }

        /// 條碼一出現就帶入（託運單上的條碼就是單號）。
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue, LogisticsLogic.looksLikeTrackingNumber(payload) {
                    finish(payload)
                    return
                }
            }
        }

        /// 文字要點一下才帶入（畫面上的字很多）。
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            switch item {
            case .barcode(let barcode):
                if let payload = barcode.payloadStringValue { finish(payload) }
            case .text(let text):
                if let token = Self.trackingNumber(in: text.transcript) { finish(token) }
            @unknown default:
                break
            }
        }

        /// 一段文字中像單號的部分（整段，或其中最長的一段英數字）。
        nonisolated static func trackingNumber(in transcript: String) -> String? {
            if LogisticsLogic.looksLikeTrackingNumber(transcript) { return transcript }
            // 只以英數字切開（中文字也算 alphanumerics，「單號909556582781」要切得開）
            let ascii = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
            let tokens = transcript.components(separatedBy: ascii.inverted).filter(LogisticsLogic.looksLikeTrackingNumber)
            return tokens.max { $0.count < $1.count }
        }
    }
}
