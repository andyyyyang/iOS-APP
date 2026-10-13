import Foundation
import PencilKit
import SwiftData
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

/// 筆記本的頁面配置（邏輯座標，與裝置尺寸無關，iPad 與 iPhone 上的筆跡位置一致）。
/// 所有頁面由上而下排在同一張畫布上，頁面之間留一段間隔。
enum NotebookLayout {
    /// A4 比例（1 : 1.414）。
    static let pageSize = CGSize(width: 820, height: 1160)
    static let margin: CGFloat = 28
    static let pageGap: CGFloat = 28

    static var canvasWidth: CGFloat { pageSize.width + margin * 2 }

    static func canvasHeight(pageCount: Int) -> CGFloat {
        let count = CGFloat(max(pageCount, 1))
        return margin * 2 + count * pageSize.height + (count - 1) * pageGap
    }

    static func pageRect(_ index: Int) -> CGRect {
        CGRect(
            x: margin,
            y: margin + CGFloat(index) * (pageSize.height + pageGap),
            width: pageSize.width,
            height: pageSize.height
        )
    }

    /// 某個 y 座標落在第幾頁（落在頁間空白時歸到上一頁）。
    static func pageIndex(atY y: CGFloat, pageCount: Int) -> Int {
        let index = Int(floor((y - margin + pageGap / 2) / (pageSize.height + pageGap)))
        return min(max(index, 0), max(pageCount - 1, 0))
    }
}

/// AI 整理的結果（標題、摘要、重點、待辦、標籤）。以 JSON 存在筆記本上，所有系統版本都能顯示。
struct NoteInsights: Codable, Equatable {
    var title: String
    var summary: String
    var keyPoints: [String]
    var actionItems: [String]
    var tags: [String]
}

/// 手寫筆記本：所有頁面的筆跡存成一份 PKDrawing（`drawingData`），以 `pageCount` 決定頁數。
@Model
final class Notebook {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var paperRaw: String
    var colorRaw: String
    var pageCount: Int
    @Attribute(.externalStorage) var drawingData: Data
    /// 第一頁的縮圖（封面）。
    @Attribute(.externalStorage) var coverData: Data?

    // Apple Intelligence
    /// 手寫辨識出的文字，各頁以空白行分隔。
    var recognizedText: String?
    var insightsJSON: String?

    // Obsidian vault 同步
    /// 筆記在 vault 中的 Markdown 路徑。
    var vaultPath: String?
    /// 上次寫入 Markdown 時伺服器回傳的 ETag，用來偵測在 Obsidian 中被修改。
    var vaultETag: String?
    var syncedAt: Date?

    init(title: String, paper: PaperStyle = .lined, color: NotebookColor = .blue) {
        id = UUID()
        self.title = title
        createdAt = .now
        updatedAt = .now
        paperRaw = paper.rawValue
        colorRaw = color.rawValue
        pageCount = 1
        drawingData = PKDrawing().dataRepresentation()
    }

    var paper: PaperStyle {
        get { PaperStyle(rawValue: paperRaw) ?? .lined }
        set { paperRaw = newValue.rawValue }
    }

    var color: NotebookColor {
        get { NotebookColor(rawValue: colorRaw) ?? .blue }
        set { colorRaw = newValue.rawValue }
    }

    var drawing: PKDrawing {
        get { (try? PKDrawing(data: drawingData)) ?? PKDrawing() }
        set { drawingData = newValue.dataRepresentation() }
    }

    var insights: NoteInsights? {
        get { insightsJSON.flatMap { try? JSONDecoder().decode(NoteInsights.self, from: Data($0.utf8)) } }
        set { insightsJSON = newValue.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) } }
    }

    var cover: UIImage? { coverData.flatMap(UIImage.init(data:)) }

    /// 修改後尚未寫入 vault。
    var needsSync: Bool {
        guard let syncedAt else { return true }
        return updatedAt > syncedAt
    }

    /// 檔名用的短代碼，例如 nb-1a2b3c4d。
    var shortID: String { "nb-" + id.uuidString.prefix(8).lowercased() }

    func touch() {
        updatedAt = .now
    }
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
