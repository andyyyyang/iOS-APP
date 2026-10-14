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

    /// 2.3 以前的分頁筆記本（A4 比例 1 : 1.414），只用來把舊筆記本轉成連續畫布（`migratedFromPagedNotebook`）。
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

/// 手寫筆記的畫布（2.4 起）：寬度固定（邏輯座標，iPad 與 iPhone 上筆跡位置一致），往下無限延伸，紙張連續、不分頁。
/// 匯出給 Obsidian 與手寫辨識時，依筆跡之間的空白切成數段圖片，不會把一行字切成兩半。
enum CanvasLayout {
    static let width: CGFloat = 820
    /// 畫布往下延伸的單位，也是每段匯出圖片的最大高度。
    static let segmentHeight: CGFloat = 1160
    /// 最低的筆跡下面至少保留的書寫空間。
    static let writingRoom: CGFloat = 580
    /// 最後一段圖片在最低的筆跡下面留的空白。
    static let exportPadding: CGFloat = 48

    /// 畫布需要的高度：至少 `minimum`，最低的筆跡下方留一段空白可以繼續寫，以 `segmentHeight` 為單位加長。
    static func height(for drawing: PKDrawing, minimum: CGFloat) -> CGFloat {
        let bottom = drawing.strokes.isEmpty ? 0 : drawing.bounds.maxY
        let needed = max(minimum, bottom + writingRoom, segmentHeight)
        return ceil(needed / segmentHeight) * segmentHeight
    }

    /// 匯出（與手寫辨識）的分段：由上而下，每段最高 `segmentHeight`，盡量切在沒有筆跡經過的位置；
    /// 最後一段到最低的筆跡下方一點為止。空白畫布是一段完整高度的空白紙。
    static func bands(for drawing: PKDrawing) -> [CGRect] {
        let spans = drawing.strokes.map(\.renderBounds).filter { !$0.isNull && !$0.isInfinite }
        guard let bottom = spans.map(\.maxY).max() else {
            return [CGRect(x: 0, y: 0, width: width, height: segmentHeight)]
        }
        let end = bottom + exportPadding
        var bands: [CGRect] = []
        var top: CGFloat = 0
        while end - top > segmentHeight {
            var cut = top + segmentHeight
            // 往上找沒有筆跡經過的位置（最多往上三分之一段）；找不到就照原位置切
            var candidate = cut
            while candidate > top + segmentHeight * 2 / 3 {
                if !spans.contains(where: { $0.minY < candidate && $0.maxY > candidate }) {
                    cut = candidate
                    break
                }
                candidate -= 8
            }
            bands.append(CGRect(x: 0, y: top, width: width, height: cut - top))
            top = cut
        }
        bands.append(CGRect(x: 0, y: top, width: width, height: end - top))
        return bands
    }
}

/// AI 整理的結果（標題、摘要、重點、待辦、標籤）。
struct NoteInsights: Codable, Equatable {
    var title: String
    var summary: String
    var keyPoints: [String]
    var actionItems: [String]
    var tags: [String]
}

// MARK: - 畫布

extension PKDrawing {
    /// 2.3 以前的筆記本是 A4 分頁（`PageLayout.notebook`：頁邊與頁距 28）。把每頁的筆跡移到連續畫布上，
    /// 每頁的左上角對齊畫布上第 n 段的開頭（`CanvasLayout.segmentHeight` 與舊版頁高相同），相對位置不變。
    func migratedFromPagedNotebook(pageCount: Int) -> PKDrawing {
        let old = PageLayout.notebook
        return PKDrawing(strokes: strokes.map { stroke in
            var stroke = stroke
            let page = old.pageIndex(atY: stroke.renderBounds.midY, pageCount: max(pageCount, 1))
            let rect = old.pageRect(page)
            let shift = CGAffineTransform(translationX: -rect.minX, y: CGFloat(page) * CanvasLayout.segmentHeight - rect.minY)
            stroke.transform = stroke.transform.concatenating(shift)
            return stroke
        })
    }

    /// 某個範圍內是否有筆跡。
    func hasStrokes(in rect: CGRect) -> Bool {
        strokes.contains { $0.renderBounds.intersects(rect) }
    }
}
