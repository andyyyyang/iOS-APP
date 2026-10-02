import Foundation
import UIKit

/// 單一文字區塊的辨識結果。
/// `boundingBox` 為正規化座標（0~1），原點在圖片左上角。
struct RecognizedLine: Identifiable, Equatable {
    let id: UUID
    let text: String
    let confidence: Float
    let boundingBox: CGRect

    init(id: UUID = UUID(), text: String, confidence: Float, boundingBox: CGRect) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// 一張圖片（一頁）的辨識結果，`image` 為實際送進 Vision 的圖片（已轉正方向）。
struct OCRPage: Identifiable {
    let id = UUID()
    let image: UIImage
    let lines: [RecognizedLine]

    /// 依閱讀順序排列的文字區塊。
    var orderedLines: [RecognizedLine] { TextLayout.readingOrder(lines) }

    var text: String { TextLayout.joinedText(lines) }
}

enum ScanSource: String, CaseIterable {
    case photoLibrary
    case camera
    case documentScanner
    case pasteboard
    case liveScanner

    var displayName: String {
        switch self {
        case .photoLibrary: return "相簿"
        case .camera: return "相機"
        case .documentScanner: return "文件掃描"
        case .pasteboard: return "剪貼簿"
        case .liveScanner: return "即時掃描"
        }
    }

    var systemImage: String {
        switch self {
        case .photoLibrary: return "photo.on.rectangle"
        case .camera: return "camera"
        case .documentScanner: return "doc.viewfinder"
        case .pasteboard: return "doc.on.clipboard"
        case .liveScanner: return "camera.viewfinder"
        }
    }
}

/// 一次辨識作業（可能包含多頁）。
struct ScanSession: Identifiable, Hashable {
    let id = UUID()
    let createdAt = Date()
    let source: ScanSource
    let pages: [OCRPage]
    let duration: TimeInterval

    var allLines: [RecognizedLine] { pages.flatMap(\.lines) }

    var fullText: String {
        pages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var averageConfidence: Double {
        let lines = allLines
        guard !lines.isEmpty else { return 0 }
        return lines.reduce(0) { $0 + Double($1.confidence) } / Double(lines.count)
    }

    static func == (lhs: ScanSession, rhs: ScanSession) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
