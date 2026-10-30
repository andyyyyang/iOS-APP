import CryptoKit
import Foundation
import PencilKit
import UIKit

/// 日誌筆記本：像真的筆記本一頁一頁（固定大小、有邊界），每頁屬於一天；每天第一次打開時自動加一頁今天的。
/// 筆記本本身是一個 Markdown 檔（依日期整理：摘要、重點、提到的機種、每頁圖片與手寫內容），筆跡存在附件資料夾。
struct JournalNotebook: Codable, Equatable {
    static let currentVersion = 1
    static let fileExtension = "localocr-journal"
    static let idPrefix = "jn-"

    var version = JournalNotebook.currentVersion
    var id: String
    var createdAt: Date
    var updatedAt: Date
    var paper: PaperStyle
    var pages: [JournalPage]
    /// 每天的 AI 整理（依日期）。
    var days: [String: JournalDay] = [:]

    static func newID() -> String {
        idPrefix + UUID().uuidString.prefix(8).lowercased()
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 依日期分組的頁碼（日期新的在前）。
    var pagesByDay: [JournalDayPages] {
        var order: [String] = []
        var groups: [String: [Int]] = [:]
        for (index, page) in pages.enumerated() {
            if groups[page.date] == nil { order.append(page.date) }
            groups[page.date, default: []].append(index)
        }
        return order.sorted(by: >).map { JournalDayPages(date: $0, pages: groups[$0] ?? []) }
    }

    /// 日誌的規則：最後一頁不是今天的、而且已經寫了東西，就加一頁今天的；最後一頁還是空白的就改成今天。
    /// 回傳是否有變動。
    @discardableResult
    mutating func ensurePage(for today: String) -> Bool {
        guard let last = pages.last else {
            pages.append(JournalPage(date: today))
            return true
        }
        guard last.date != today else { return false }
        if last.isBlank {
            pages[pages.count - 1].date = today
        } else {
            pages.append(JournalPage(date: today))
        }
        return true
    }
}

struct JournalPage: Codable, Equatable, Identifiable {
    var id: String
    /// 這頁屬於哪一天（yyyy-MM-dd）。
    var date: String
    /// 這頁的筆跡（座標以頁面左上角為原點）。
    var drawing: Data
    var recognizedText: String?
    /// 辨識時的筆跡（指紋）：沒改過就不必重新辨識。
    var recognizedFingerprint: String?
    /// 上次產生圖片時的筆跡（指紋）：沒改過就不必重新產生、上傳。
    var publishedFingerprint: String?
    /// 這頁寫的 #機種。
    var tags: [JournalTag] = []
    /// 手寫的「@時間」換成的提醒時間（原文 → 時間），重新辨識時沿用。
    var mentionDates: [String: Date]?

    init(id: String = UUID().uuidString.prefix(6).lowercased(), date: String, drawing: Data = PKDrawing().dataRepresentation()) {
        self.id = id
        self.date = date
        self.drawing = drawing
    }

    var pkDrawing: PKDrawing {
        get { (try? PKDrawing(data: drawing)) ?? PKDrawing() }
        set { drawing = newValue.dataRepresentation() }
    }

    var isBlank: Bool { pkDrawing.strokes.isEmpty }

    /// 筆跡的指紋（比對有沒有改過）。
    var fingerprint: String {
        SHA256.hash(data: drawing).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    var needsRecognition: Bool { !isBlank && recognizedFingerprint != fingerprint }
}

/// 頁面上寫的一個 #機種。
struct JournalTag: Codable, Equatable, Hashable {
    /// 辨識出來的文字（不含 #）。
    var text: String
    /// 在頁面上的位置（頁面座標）。
    var rect: CGRect
    /// 對到的機種主卡。
    var modelPath: String?
    var modelCode: String?
    /// 不確定時的其他可能（主卡路徑）。
    var candidates: [String] = []
    /// 使用者自己選的（重新辨識時保留）。
    var confirmed = false

    var isLinked: Bool { modelPath != nil }
}

/// 某一天的頁面（頁碼從 0 開始）。
struct JournalDayPages: Identifiable, Equatable {
    let date: String
    let pages: [Int]
    var id: String { date }
}

/// 筆記本中連到的機種（Markdown 連結用）。
struct JournalLinkedModel: Hashable {
    let code: String
    let title: String
    let path: String
}

/// 一天的 AI 整理。
struct JournalDay: Codable, Equatable {
    /// 整理時的手寫內容（指紋）：內容沒變就不必重新整理。
    var textFingerprint: String
    var summary: String
    var keyPoints: [String]
    var actionItems: [String]
}

// MARK: - 版面

/// 頁面的顯示方式：連續往下捲、一次一頁、兩頁並排（後兩種像翻書一樣左右翻頁）。
enum JournalViewMode: String, CaseIterable, Identifiable, Sendable {
    case scroll
    case single
    case spread

    static let storageKey = "journal.viewMode"

    var id: Self { self }

    var title: String {
        switch self {
        case .scroll: return "連續捲動"
        case .single: return "一頁一張"
        case .spread: return "兩頁並排"
        }
    }

    var systemImage: String {
        switch self {
        case .scroll: return "scroll"
        case .single: return "rectangle.portrait"
        case .spread: return "rectangle.split.2x1"
        }
    }

    /// 左右翻頁（一次一頁或兩頁）。
    var isPaged: Bool { self != .scroll }
}

/// 頁面大小與排列：連續捲動時頁面一頁接一頁往下，中間留一點空隙；翻頁時每一頁（或並排的兩頁）佔一格，格子左右排列。
/// 每頁的筆跡都存成頁面座標，畫布上的位置依顯示方式換算（combine / split），換顯示方式不會改到內容。
enum JournalLayout {
    static let pageSize = CGSize(width: 820, height: 1160)
    static let gap: CGFloat = 40
    static let margin: CGFloat = 28
    /// 兩頁並排時中間的書背。
    static let spine: CGFloat = 24
    /// 翻頁時最後面「新增一頁」的寬度。
    static let addPageWidth: CGFloat = 320
    /// 頁首（日期）的高度：筆跡從這下面開始比較好看，但寫在上面也可以。
    static let headerHeight: CGFloat = 72

    static var canvasWidth: CGFloat { pageSize.width + margin * 2 }

    static func pageRect(_ index: Int) -> CGRect {
        CGRect(x: margin, y: margin + CGFloat(index) * (pageSize.height + gap), width: pageSize.width, height: pageSize.height)
    }

    /// 翻頁時一格的大小（一頁或並排的兩頁，含四周留白）。
    static func slotSize(_ mode: JournalViewMode) -> CGSize {
        switch mode {
        case .scroll, .single: return CGSize(width: pageSize.width + margin * 2, height: pageSize.height + margin * 2)
        case .spread: return CGSize(width: pageSize.width * 2 + spine + margin * 2, height: pageSize.height + margin * 2)
        }
    }

    /// 第幾頁在第幾格。
    static func slot(ofPage index: Int, mode: JournalViewMode) -> Int {
        mode == .spread ? index / 2 : index
    }

    static func slotCount(pageCount: Int, mode: JournalViewMode) -> Int {
        let count = max(pageCount, 1)
        return mode == .spread ? (count + 1) / 2 : count
    }

    static func pageRect(_ index: Int, mode: JournalViewMode) -> CGRect {
        switch mode {
        case .scroll:
            return pageRect(index)
        case .single:
            return CGRect(x: CGFloat(index) * slotSize(.single).width + margin, y: margin, width: pageSize.width, height: pageSize.height)
        case .spread:
            let slot = CGFloat(index / 2)
            let side = CGFloat(index % 2)
            return CGRect(x: slot * slotSize(.spread).width + margin + side * (pageSize.width + spine), y: margin, width: pageSize.width, height: pageSize.height)
        }
    }

    /// 所有頁面佔的大小（不含最後面的「新增一頁」）。
    static func canvasSize(pageCount: Int, mode: JournalViewMode) -> CGSize {
        switch mode {
        case .scroll:
            return CGSize(width: canvasWidth, height: canvasHeight(pageCount: pageCount))
        case .single, .spread:
            let slot = slotSize(mode)
            return CGSize(width: CGFloat(slotCount(pageCount: pageCount, mode: mode)) * slot.width, height: slot.height)
        }
    }

    /// 畫布上某一點屬於第幾頁（空隙與書背算最近的一頁）。
    static func pageIndex(at point: CGPoint, pageCount: Int, mode: JournalViewMode) -> Int {
        let last = max(pageCount - 1, 0)
        switch mode {
        case .scroll:
            return pageIndex(atY: point.y, pageCount: pageCount)
        case .single:
            return min(max(Int(floor(point.x / slotSize(.single).width)), 0), last)
        case .spread:
            let width = slotSize(.spread).width
            let slot = max(Int(floor(point.x / width)), 0)
            let local = point.x - CGFloat(slot) * width - margin
            let side = local > pageSize.width + spine / 2 ? 1 : 0
            return min(slot * 2 + side, last)
        }
    }

    static func canvasHeight(pageCount: Int) -> CGFloat {
        let count = CGFloat(max(pageCount, 1))
        return margin * 2 + count * pageSize.height + (count - 1) * gap
    }

    /// 畫布上某個高度屬於第幾頁（空隙算下一頁的上方一半與上一頁）。
    static func pageIndex(atY y: CGFloat, pageCount: Int) -> Int {
        let raw = Int(floor((y - margin + gap / 2) / (pageSize.height + gap)))
        return min(max(raw, 0), max(pageCount - 1, 0))
    }

    /// 每頁的筆跡合成整本的畫布筆跡。
    static func combine(_ pages: [PKDrawing], mode: JournalViewMode = .scroll) -> PKDrawing {
        var strokes: [PKStroke] = []
        for (index, drawing) in pages.enumerated() {
            let origin = pageRect(index, mode: mode).origin
            for var stroke in drawing.strokes {
                stroke.transform = stroke.transform.concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
                strokes.append(stroke)
            }
        }
        return PKDrawing(strokes: strokes)
    }

    /// 整本的畫布筆跡分回每一頁（依每一筆的中心落在哪一頁）。
    static func split(_ drawing: PKDrawing, pageCount: Int, mode: JournalViewMode = .scroll) -> [PKDrawing] {
        var pages = Array(repeating: [PKStroke](), count: max(pageCount, 1))
        for stroke in drawing.strokes {
            let bounds = stroke.renderBounds
            let center = bounds.isNull ? CGPoint.zero : CGPoint(x: bounds.midX, y: bounds.midY)
            let index = pageIndex(at: center, pageCount: pages.count, mode: mode)
            let origin = pageRect(index, mode: mode).origin
            var moved = stroke
            moved.transform = stroke.transform.concatenating(CGAffineTransform(translationX: -origin.x, y: -origin.y))
            pages[index].append(moved)
        }
        return pages.map { PKDrawing(strokes: $0) }
    }

    // MARK: 日期

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func day(_ date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    /// 頁首顯示的日期：「2026 年 10 月 15 日 週四」。
    static func title(for day: String) -> String {
        guard let date = dayFormatter.date(from: day) else { return day }
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        let weekday = parts.weekday.map { weekdays[($0 - 1) % 7] } ?? ""
        return "\(parts.year ?? 0) 年 \(parts.month ?? 0) 月 \(parts.day ?? 0) 日　週\(weekday)"
    }

    /// Markdown 標題用的日期：「2026-10-15 週四」。
    static func heading(for day: String) -> String {
        guard let date = dayFormatter.date(from: day) else { return day }
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: date)
        return "\(day) 週\(["日", "一", "二", "三", "四", "五", "六"][(weekday - 1) % 7])"
    }
}

// MARK: - #機種

enum JournalTags {
    /// 「#代號」：手寫的 # 常被辨識成 ＃ 或 井；代號是英數字（可以有 - _ . ~），至少 3 個字。
    private static let pattern = #"[#＃井]\s?([A-Za-z0-9０-９Ａ-Ｚａ-ｚ][A-Za-z0-9０-９Ａ-Ｚａ-ｚ\-_.~]{2,31})"#

    /// 一行文字中的 #代號，與它在這行中的大約位置（0…1，依字數比例）。
    static func tags(in line: String) -> [(text: String, start: Double, end: Double)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = line as NSString
        let total = Double(max(ns.length, 1))
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).map { match in
            let code = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: ".-_~"))
            return (code, Double(match.range.location) / total, Double(NSMaxRange(match.range)) / total)
        }
    }

    /// 一頁的辨識結果找出 #機種，並依機種清單連結（夠確定才自動連結，不確定的列出可能的機種）。
    /// 沒寫 # 但完整寫出機種代號（6 個字以上、和清單中的代號完全相同）的也算。
    /// `previous`：上次的結果，使用者自己選過的機種保留。
    static func pageTags(lines: [RecognizedLine], pageSize: CGSize, models: [ModelEntry], previous: [JournalTag] = []) -> [JournalTag] {
        var results: [JournalTag] = []
        var seen = Set<String>()
        let exactCodes = Dictionary(models.map { (ModelCatalog.normalize($0.code), $0) }, uniquingKeysWith: { first, _ in first })
        for line in lines {
            let box = line.boundingBox
            func rect(_ start: Double, _ end: Double) -> CGRect {
                CGRect(x: (box.minX + box.width * start) * pageSize.width, y: box.minY * pageSize.height,
                       width: max(box.width * (end - start), 0.02) * pageSize.width, height: box.height * pageSize.height)
            }
            var found = tags(in: line.text).map { (text: $0.text, rect: rect($0.start, $0.end)) }
            // 沒有 # 的完整代號
            for word in line.text.split(whereSeparator: { $0.isWhitespace || "，,、；;：:()（）".contains($0) }) {
                let key = ModelCatalog.normalize(String(word))
                guard key.count >= 6, exactCodes[key] != nil, !found.contains(where: { ModelCatalog.normalize($0.text) == key }) else { continue }
                if let range = line.text.range(of: word) {
                    let total = Double(max(line.text.count, 1))
                    let start = Double(line.text.distance(from: line.text.startIndex, to: range.lowerBound)) / total
                    let end = Double(line.text.distance(from: line.text.startIndex, to: range.upperBound)) / total
                    found.append((String(word), rect(start, end)))
                }
            }
            for item in found {
                let key = ModelCatalog.normalize(item.text)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                if let kept = previous.first(where: { $0.confirmed && ModelCatalog.normalize($0.text) == key }) {
                    var tag = kept
                    tag.rect = item.rect
                    results.append(tag)
                    continue
                }
                let matches = ModelCatalog.match(item.text, in: models)
                let linked = ModelCatalog.confidentMatch(matches)
                results.append(JournalTag(
                    text: item.text, rect: item.rect,
                    modelPath: linked?.path, modelCode: linked?.code,
                    candidates: linked == nil ? matches.map(\.entry.path) : []
                ))
            }
        }
        return results
    }
}

// MARK: - Markdown

/// 日誌筆記本的 Markdown：屬性＋App 管理的區段（依日期，新的在前）。區段以外使用者自己寫的內容不會被改動。
enum JournalMarkdown {
    static let sectionStart = "<!-- localocr:journal:start -->"
    static let sectionEnd = "<!-- localocr:journal:end -->"

    static func newJournal(id: String, createdAt: Date) -> String {
        [
            "---",
            "type: notebook",
            "created: \(NotebookMarkdown.dateFormatter.string(from: createdAt))",
            "\(NotebookFiles.frontmatterKey): \(id)",
            "tags: [journal, handwriting]",
            "---",
            "",
            sectionStart,
            sectionEnd,
            "",
        ].joined(separator: "\n")
    }

    /// 每天一段：摘要、重點、待辦、提到的機種（連到主卡）、當天的 Daily 筆記、每頁圖片與手寫內容。
    static func managedSection(_ notebook: JournalNotebook, imageName: (JournalPage) -> String) -> String {
        var lines = [sectionStart]
        for group in notebook.pagesByDay {
            let day = group.date, indices = group.pages
            let pages = indices.map { notebook.pages[$0] }
            guard pages.contains(where: { !$0.isBlank }) else { continue }
            lines.append("## \(JournalLayout.heading(for: day))")
            lines.append("")
            if let insights = notebook.days[day] {
                if !insights.summary.isEmpty {
                    lines.append("> [!summary] 摘要")
                    lines.append(contentsOf: insights.summary.split(separator: "\n").map { "> " + $0 })
                    lines.append("")
                }
                if !insights.keyPoints.isEmpty {
                    lines.append("**重點**")
                    lines.append(contentsOf: insights.keyPoints.map { "- " + $0 })
                    lines.append("")
                }
                if !insights.actionItems.isEmpty {
                    lines.append("**待跟進**")
                    lines.append(contentsOf: insights.actionItems.map { "- " + $0 })
                    lines.append("")
                }
            }
            let models = linkedModels(in: pages)
            if !models.isEmpty {
                lines.append("**機種** " + models.map { "[[\($0.title)|\($0.code)]]" }.joined(separator: " · "))
            }
            lines.append("**日誌** [[\(day)]]")
            lines.append("")
            // 每頁先放辨識出來的文字（Obsidian 中直接讀得到、搜得到），再放手寫原稿
            for page in pages where !page.isBlank {
                if let text = page.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    lines.append(text)
                    lines.append("")
                }
                lines.append("![[\(imageName(page))]]")
                lines.append("")
            }
        }
        lines.append(sectionEnd)
        return lines.joined(separator: "\n")
    }

    /// 這些頁面連到的機種（依第一次出現的順序，不重複）。
    static func linkedModels(in pages: [JournalPage]) -> [JournalLinkedModel] {
        var seen = Set<String>()
        var results: [JournalLinkedModel] = []
        for tag in pages.flatMap(\.tags) {
            guard let path = tag.modelPath, seen.insert(path).inserted else { continue }
            let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            results.append(JournalLinkedModel(code: tag.modelCode ?? tag.text, title: title, path: path))
        }
        return results
    }

    static func replacingManagedSection(in text: String, with section: String) -> String {
        if let start = text.range(of: sectionStart), let end = text.range(of: sectionEnd, range: start.upperBound..<text.endIndex) {
            return text.replacingCharacters(in: start.lowerBound..<end.upperBound, with: section)
        }
        let trimmed = text.trimmingCharacters(in: .newlines)
        return (trimmed.isEmpty ? "" : trimmed + "\n\n") + section + "\n"
    }

    /// 某一天的手寫內容（給 AI 整理）。
    static func text(for day: String, in notebook: JournalNotebook) -> String {
        notebook.pages.filter { $0.date == day }.compactMap(\.recognizedText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
