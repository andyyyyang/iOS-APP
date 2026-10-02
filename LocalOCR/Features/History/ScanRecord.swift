import Foundation
import SwiftData
import UIKit

/// 儲存在本機（SwiftData）的辨識紀錄。
@Model
final class ScanRecord {
    var createdAt: Date
    var text: String
    var source: String
    var pageCount: Int
    var lineCount: Int
    /// 即時掃描沒有信心度資訊，此時為 nil。
    var averageConfidence: Double?
    @Attribute(.externalStorage) var thumbnailData: Data?

    init(
        createdAt: Date = .now,
        text: String,
        source: String,
        pageCount: Int,
        lineCount: Int,
        averageConfidence: Double?,
        thumbnailData: Data?
    ) {
        self.createdAt = createdAt
        self.text = text
        self.source = source
        self.pageCount = pageCount
        self.lineCount = lineCount
        self.averageConfidence = averageConfidence
        self.thumbnailData = thumbnailData
    }

    static func make(from session: ScanSession, text: String) -> ScanRecord {
        ScanRecord(
            createdAt: session.createdAt,
            text: text,
            source: session.source.rawValue,
            pageCount: session.pages.count,
            lineCount: session.allLines.count,
            averageConfidence: session.averageConfidence,
            thumbnailData: session.pages.first.flatMap { ImagePreprocessor.thumbnailJPEGData($0.image) }
        )
    }

    var title: String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return firstLine ?? "（沒有文字）"
    }

    var sourceDisplayName: String {
        ScanSource(rawValue: source)?.displayName ?? source
    }

    var sourceSystemImage: String {
        ScanSource(rawValue: source)?.systemImage ?? "doc.text"
    }

    var thumbnail: UIImage? {
        thumbnailData.flatMap { UIImage(data: $0) }
    }
}
