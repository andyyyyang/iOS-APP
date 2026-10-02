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
    /// 沒有逐行信心度的紀錄（例如舊版即時掃描擷取的文字）此時為 nil。
    var averageConfidence: Double?
    @Attribute(.externalStorage) var thumbnailData: Data?

    // 智慧掃描與同步（新增欄位皆為選用，舊資料可直接升級）
    /// 上傳到伺服器使用的 id。
    var remoteID: UUID?
    var templateID: String?
    /// 依樣板產生的 JSON 文字（保留欄位順序）。
    var jsonText: String?
    var classificationJSON: String?
    /// 最後一次成功上傳的時間；內容修改後設為 nil 表示需要重新上傳。
    var syncedAt: Date?

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

    /// 寫入智慧掃描結果。
    func apply(_ outcome: SmartScanOutcome) {
        templateID = outcome.template.id
        classificationJSON = outcome.classification.jsonValue.compactString
        if let data = outcome.data {
            jsonText = data.prettyPrinted()
        }
        syncedAt = nil
    }

    var dataValue: JSONValue? {
        jsonText.flatMap { try? JSONValue.parse($0) }
    }

    var classificationValue: JSONValue? {
        classificationJSON.flatMap { try? JSONValue.parse($0) }
    }

    var classificationConfidence: Double? {
        if case .number(let value)? = classificationValue?["confidence"] { return value }
        return nil
    }

    var title: String {
        if let data = dataValue {
            for key in ["title", "store", "name", "company"] {
                if let value = data[key]?.stringValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                    return value
                }
            }
        }
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
