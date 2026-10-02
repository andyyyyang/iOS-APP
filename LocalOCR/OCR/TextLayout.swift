import CoreGraphics
import Foundation

/// 座標換算與閱讀順序排序（純運算，方便單元測試）。
enum TextLayout {
    /// Vision 的 boundingBox 原點在左下角，轉換成左上角原點（仍為正規化座標）。
    static func topLeftNormalizedRect(fromVision rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 圖片以 aspect-fit 方式顯示在容器中時，實際佔用的區域。
    static func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return .zero
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// 將正規化（左上角原點）矩形映射到畫面上的顯示區域。
    static func denormalize(_ rect: CGRect, into frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + rect.minX * frame.width,
            y: frame.minY + rect.minY * frame.height,
            width: rect.width * frame.width,
            height: rect.height * frame.height
        )
    }

    /// 依閱讀順序分列：由上而下分成多列，每列由左而右排序。
    /// `rect` 需使用左上角原點的座標系（正規化或畫面座標皆可）。
    static func rows<T>(_ items: [T], rect: (T) -> CGRect) -> [[T]] {
        let sorted = items.sorted { rect($0).midY < rect($1).midY }
        var rows: [[T]] = []
        var rowBounds: [CGRect] = []

        for item in sorted {
            let itemRect = rect(item)
            if let last = rows.indices.last, isSameRow(itemRect, rowBounds[last]) {
                rows[last].append(item)
                rowBounds[last] = rowBounds[last].union(itemRect)
            } else {
                rows.append([item])
                rowBounds.append(itemRect)
            }
        }

        return rows.map { row in row.sorted { rect($0).minX < rect($1).minX } }
    }

    static func readingOrder(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        rows(lines, rect: { $0.boundingBox }).flatMap { $0 }
    }

    /// 同一列的區塊以空白連接，不同列以換行連接。
    static func joinedText(_ lines: [RecognizedLine]) -> String {
        rows(lines, rect: { $0.boundingBox })
            .map { row in row.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    /// 垂直方向重疊超過較矮者高度的一半，就視為同一列。
    private static func isSameRow(_ rect: CGRect, _ row: CGRect) -> Bool {
        let overlap = min(rect.maxY, row.maxY) - max(rect.minY, row.minY)
        let minHeight = min(rect.height, row.height)
        return minHeight > 0 && overlap > minHeight * 0.5
    }
}
