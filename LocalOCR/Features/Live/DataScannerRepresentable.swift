import SwiftUI
import VisionKit

/// 保存掃描器目前畫面中辨識到的文字，讓 SwiftUI 端可以隨時「擷取全部」。
final class LiveScannerBridge {
    fileprivate var currentItems: [RecognizedItem] = []

    /// 目前畫面中的文字，依閱讀順序排列。
    func currentTexts() -> [String] {
        let texts: [(text: String, rect: CGRect)] = currentItems.compactMap { item in
            guard case .text(let text) = item else { return nil }
            return (text: text.transcript, rect: Self.boundingRect(of: text.bounds))
        }
        return TextLayout.rows(texts, rect: { $0.rect })
            .flatMap { $0 }
            .map { $0.text }
    }

    private static func boundingRect(of bounds: RecognizedItem.Bounds) -> CGRect {
        let points = [bounds.topLeft, bounds.topRight, bounds.bottomLeft, bounds.bottomRight]
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
    }
}

/// 包裝 VisionKit 的 DataScannerViewController（即時相機文字辨識，iOS 16+、A12 以上晶片）。
struct DataScannerRepresentable: UIViewControllerRepresentable {
    let languages: [String]
    let bridge: LiveScannerBridge
    var onTapText: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text(languages: languages)],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.parent = self
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: DataScannerRepresentable

        init(parent: DataScannerRepresentable) {
            self.parent = parent
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .text(let text) = item {
                parent.onTapText(text.transcript)
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            parent.bridge.currentItems = allItems
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            parent.bridge.currentItems = allItems
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didRemove removedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            parent.bridge.currentItems = allItems
        }
    }
}
