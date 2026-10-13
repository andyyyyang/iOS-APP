import Foundation
import PencilKit
import SwiftUI

/// 紙張樣式。
enum PaperStyle: String, CaseIterable, Identifiable, Codable {
    case blank
    case lined
    case grid
    case dotted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return "空白"
        case .lined: return "橫線"
        case .grid: return "方格"
        case .dotted: return "點陣"
        }
    }

    var systemImage: String {
        switch self {
        case .blank: return "doc"
        case .lined: return "line.3.horizontal"
        case .grid: return "squareshape.split.3x3"
        case .dotted: return "circle.grid.3x3"
        }
    }
}

/// 筆記本封面顏色。
enum NotebookColor: String, CaseIterable, Identifiable, Codable {
    case blue
    case indigo
    case teal
    case green
    case orange
    case pink
    case graphite

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: return .blue
        case .indigo: return .indigo
        case .teal: return .teal
        case .green: return .green
        case .orange: return .orange
        case .pink: return .pink
        case .graphite: return .gray
        }
    }
}

/// 頁面配置（邏輯座標，與裝置尺寸無關，iPad 與 iPhone 上的筆跡位置一致）。
/// 所有頁面由上而下排在同一張畫布上，頁面之間留一段間隔。
struct PageLayout: Equatable {
    var pageSize: CGSize
    var margin: CGFloat
    var pageGap: CGFloat

    /// 筆記本：A4 比例（1 : 1.414）。
    static let notebook = PageLayout(pageSize: CGSize(width: 820, height: 1160), margin: 28, pageGap: 28)

    /// 筆記中的手寫區塊。
    static func inkBlock(height: CGFloat) -> PageLayout {
        PageLayout(pageSize: CGSize(width: 820, height: height), margin: 16, pageGap: 0)
    }

    var canvasWidth: CGFloat { pageSize.width + margin * 2 }

    func canvasHeight(pageCount: Int) -> CGFloat {
        let count = CGFloat(max(pageCount, 1))
        return margin * 2 + count * pageSize.height + (count - 1) * pageGap
    }

    func pageRect(_ index: Int) -> CGRect {
        CGRect(
            x: margin,
            y: margin + CGFloat(index) * (pageSize.height + pageGap),
            width: pageSize.width,
            height: pageSize.height
        )
    }

    /// 某個 y 座標落在第幾頁（落在頁間空白時歸到上一頁）。
    func pageIndex(atY y: CGFloat, pageCount: Int) -> Int {
        let index = Int(floor((y - margin + pageGap / 2) / (pageSize.height + pageGap)))
        return min(max(index, 0), max(pageCount - 1, 0))
    }
}

/// 筆記本的頁面配置。
enum NotebookLayout {
    static var pageSize: CGSize { PageLayout.notebook.pageSize }
    static var margin: CGFloat { PageLayout.notebook.margin }
    static var pageGap: CGFloat { PageLayout.notebook.pageGap }
    static var canvasWidth: CGFloat { PageLayout.notebook.canvasWidth }

    static func canvasHeight(pageCount: Int) -> CGFloat { PageLayout.notebook.canvasHeight(pageCount: pageCount) }
    static func pageRect(_ index: Int) -> CGRect { PageLayout.notebook.pageRect(index) }
    static func pageIndex(atY y: CGFloat, pageCount: Int) -> Int { PageLayout.notebook.pageIndex(atY: y, pageCount: pageCount) }
}

/// AI 整理的結果（標題、摘要、重點、待辦、標籤）。
struct NoteInsights: Codable, Equatable {
    var title: String
    var summary: String
    var keyPoints: [String]
    var actionItems: [String]
    var tags: [String]
}

// MARK: - 頁面編輯（插入、刪除時移動筆跡）

extension PKDrawing {
    private static var pageStride: CGFloat { NotebookLayout.pageSize.height + NotebookLayout.pageGap }

    /// 刪除第 `index` 頁的筆跡，並把後面頁面的筆跡往上移一頁。
    func removingPage(_ index: Int, pageCount: Int) -> PKDrawing {
        var strokes: [PKStroke] = []
        for var stroke in self.strokes {
            let page = NotebookLayout.pageIndex(atY: stroke.renderBounds.midY, pageCount: pageCount)
            if page == index { continue }
            if page > index {
                stroke.transform = stroke.transform.concatenating(CGAffineTransform(translationX: 0, y: -Self.pageStride))
            }
            strokes.append(stroke)
        }
        return PKDrawing(strokes: strokes)
    }

    /// 在第 `index` 頁之前插入空白頁：該頁與後面頁面的筆跡往下移一頁。
    func insertingPage(at index: Int, pageCount: Int) -> PKDrawing {
        PKDrawing(strokes: strokes.map { stroke in
            var stroke = stroke
            let page = NotebookLayout.pageIndex(atY: stroke.renderBounds.midY, pageCount: pageCount)
            if page >= index {
                stroke.transform = stroke.transform.concatenating(CGAffineTransform(translationX: 0, y: Self.pageStride))
            }
            return stroke
        })
    }

    /// 某一頁是否有筆跡。
    func hasStrokes(onPage index: Int, pageCount: Int) -> Bool {
        strokes.contains { NotebookLayout.pageIndex(atY: $0.renderBounds.midY, pageCount: pageCount) == index }
    }
}
