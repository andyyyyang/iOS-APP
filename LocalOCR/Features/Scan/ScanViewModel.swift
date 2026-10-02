import Observation
import UIKit

@MainActor
@Observable
final class ScanViewModel {
    enum Phase: Equatable {
        case idle
        case processing(current: Int, total: Int)
        case failed(String)
    }

    var phase: Phase = .idle
    /// 辨識完成後設定，畫面會導向結果頁。
    var session: ScanSession?

    var isProcessing: Bool {
        if case .processing = phase { return true }
        return false
    }

    func process(_ images: [UIImage], source: ScanSource) async {
        guard !images.isEmpty, !isProcessing else { return }

        // 每次辨識都讀取最新設定
        let service = OCRService()
        let start = Date()
        var pages: [OCRPage] = []

        do {
            for (index, image) in images.enumerated() {
                phase = .processing(current: index + 1, total: images.count)
                pages.append(try await service.recognize(image))
            }
            phase = .idle
            session = ScanSession(source: source, pages: pages, duration: Date().timeIntervalSince(start))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 逐頁解碼並辨識（頁面以 JPEG 保存），多頁文件不會一次佔用大量記憶體。
    func process(imageData pages: [Data], source: ScanSource) async {
        guard !pages.isEmpty, !isProcessing else { return }
        let service = OCRService()
        let start = Date()
        var results: [OCRPage] = []
        do {
            for (index, data) in pages.enumerated() {
                phase = .processing(current: index + 1, total: pages.count)
                guard let image = UIImage(data: data) else { throw OCRError.invalidImage }
                results.append(try await service.recognize(image))
            }
            phase = .idle
            session = ScanSession(source: source, pages: results, duration: Date().timeIntervalSince(start))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func fail(_ message: String) {
        phase = .failed(message)
    }
}
