import UIKit

// MARK: - 即時預覽的 Markdown（像 Obsidian 的 Live Preview）
//
// 筆記只有一種模式：文字永遠可以編輯，同時直接顯示排版後的樣子。
// 游標所在的那一行顯示原始語法（# 、** 、[[ ]] …），其他行把語法藏起來；
// 待辦方框、清單圓點、引用直線、程式碼與 callout 的底色、分隔線、表格框線與內嵌圖片由 LiveMarkdownLayoutManager 畫出來。
// 檔案內容完全不變（仍是 Markdown），這裡只改顯示的屬性。

extension NSAttributedString.Key {
    /// 待辦方框（值：是否完成），畫在「[ ]」的位置。
    static let mdCheckbox = NSAttributedString.Key("localocr.md.checkbox")
    /// 清單符號，畫成圓點。
    static let mdBullet = NSAttributedString.Key("localocr.md.bullet")
    /// 引用左邊的直線。
    static let mdQuote = NSAttributedString.Key("localocr.md.quote")
    /// 區塊的圓角底色（程式碼、callout、屬性）：值是 UIColor。
    static let mdBlockBackground = NSAttributedString.Key("localocr.md.blockBackground")
    /// 分隔線。
    static let mdRule = NSAttributedString.Key("localocr.md.rule")
    /// 整行畫成內嵌圖片：值是 MarkdownImageInfo。
    static let mdImage = NSAttributedString.Key("localocr.md.image")
    /// 整個表格畫成格線表（值：MarkdownTableInfo），放在表格第一行。
    static let mdTable = NSAttributedString.Key("localocr.md.table")
    /// ```dataviewjs 區塊的執行畫面位置（值：DataviewBlockInfo），放在區塊第一行；畫面由 NoteTextView 疊上去。
    static let mdDataview = NSAttributedString.Key("localocr.md.dataview")
    /// 連結（值：網址或路徑字串），點一下開啟。
    static let mdLink = NSAttributedString.Key("localocr.md.link")
    /// [[連結]]（值：連結目標，可能含 #標題）。
    static let mdWikiLink = NSAttributedString.Key("localocr.md.wikiLink")
}

/// 內嵌圖片的名稱與顯示大小。
final class MarkdownImageInfo: NSObject {
    let name: String
    let size: CGSize

    init(name: String, size: CGSize) {
        self.name = name
        self.size = size
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MarkdownImageInfo else { return false }
        return other.name == name && other.size == size
    }

    override var hash: Int { name.hashValue }
}

/// ```dataviewjs 區塊：程式碼與保留的高度（含上方一列）。
final class DataviewBlockInfo: NSObject {
    /// 還不知道內容多高時的高度。
    static let defaultContentHeight: CGFloat = 160
    /// 上方一列（DataviewJS 標籤與按鈕）。
    static let headerHeight: CGFloat = 34
    /// 各區塊上次的內容高度（重新打開筆記時不跳動）。
    @MainActor static var heights: [String: CGFloat] = [:]

    let code: String
    let key: String
    let height: CGFloat

    init(code: String, height: CGFloat) {
        self.code = code
        self.key = Self.key(for: code)
        self.height = height
    }

    static func key(for code: String) -> String {
        "\((code as NSString).length):\(code.hashValue)"
    }
}

/// 畫成格線表的 Markdown 表格：每格已套好行內樣式（粗體、連結、程式碼…），欄寬依內容與文字欄寬分配，放不下的儲存格自動換行。
/// 欄位太多、連縮小字級都放不下時（手機上的寬表格），每一列改成一張卡片：第一欄當標題，其他欄是「欄名　內容」。
final class MarkdownTableInfo: NSObject {
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 7
    /// 同一張表（內容、欄寬、字級都一樣）不用每打一個字就重新量。
    static let cache = NSCache<NSString, MarkdownTableInfo>()

    /// 一段畫在表格裡的文字與位置（相對於表格左上角）。
    struct Piece {
        let text: NSAttributedString
        let frame: CGRect
    }

    let cells: [[NSAttributedString]]
    let hasHeader: Bool
    /// 每一列畫成卡片（寬表格）。
    let stacked: Bool
    let columnWidths: [CGFloat]
    /// 格線表每一列的高度；卡片模式是每張卡片的高度。
    let rowHeights: [CGFloat]
    let cards: [CGRect]
    let pieces: [Piece]
    let size: CGSize

    init(cells: [[NSAttributedString]], hasHeader: Bool, width available: CGFloat) {
        let grid = MarkdownTableInfo.grid(cells, width: available)
        if hasHeader, cells.count > 1, !grid.fits {
            let stack = MarkdownTableInfo.stack(cells, width: available)
            self.cells = cells
            stacked = true
            columnWidths = []
            rowHeights = stack.heights
            cards = stack.cards
            pieces = stack.pieces
            size = stack.size
        } else {
            self.cells = grid.cells
            stacked = false
            columnWidths = grid.widths
            rowHeights = grid.heights
            cards = []
            pieces = grid.pieces
            size = CGSize(width: grid.widths.reduce(0, +), height: grid.heights.reduce(0, +))
        }
        self.hasHeader = hasHeader
    }

    /// 格線表：窄的欄位用原本的寬度，剩下的空間分給寬的欄位；`fits` 表示縮小字級後最小欄寬放得下。
    private static func grid(_ input: [[NSAttributedString]], width available: CGFloat) -> (cells: [[NSAttributedString]], widths: [CGFloat], heights: [CGFloat], pieces: [Piece], fits: Bool) {
        var cells = input
        let columns = cells.map(\.count).max() ?? 0
        let padding = horizontalPadding * 2
        func natural(_ cells: [[NSAttributedString]]) -> [CGFloat] {
            (0..<columns).map { column in
                cells.map { row in column < row.count ? ceil(measure(row[column], width: .greatestFiniteMagnitude).width) + padding : padding }.max() ?? padding
            }.map { max($0, 44) }
        }
        var naturalWidths = natural(cells)
        var minimumWidths = naturalWidths.map { min($0, 96) }
        var fits = true
        // 欄位很多、連最小寬度都放不下時，整張表的字縮小一點
        let minimumTotal = minimumWidths.reduce(0, +)
        if minimumTotal > available, available > 0 {
            let scale = max(0.78, available / minimumTotal)
            cells = cells.map { $0.map { restyled($0, scale: scale, keepsAlignment: true) } }
            naturalWidths = natural(cells)
            minimumWidths = naturalWidths.map { min($0, 96 * scale) }
            fits = minimumWidths.reduce(0, +) <= available + 0.5
        }
        var widths = naturalWidths
        if widths.reduce(0, +) > available {
            var remaining = available
            var open = Array(0..<columns)
            while !open.isEmpty {
                let fair = remaining / CGFloat(open.count)
                let narrow = open.filter { naturalWidths[$0] <= fair }
                if narrow.isEmpty { break }
                for column in narrow {
                    widths[column] = naturalWidths[column]
                    remaining -= naturalWidths[column]
                }
                open.removeAll { narrow.contains($0) }
            }
            if !open.isEmpty {
                let fair = remaining / CGFloat(open.count)
                for column in open { widths[column] = floor(max(fair, minimumWidths[column])) }
            }
            // 還是太寬：全部等比縮到文字欄寬，儲存格多換幾行
            let total = widths.reduce(0, +)
            if total > available, available > 0 {
                widths = widths.map { floor($0 * available / total) }
            }
        }
        var heights: [CGFloat] = []
        var pieces: [Piece] = []
        var y: CGFloat = 0
        for row in cells {
            var height: CGFloat = 0
            for (column, cell) in row.enumerated() where column < widths.count {
                height = max(height, ceil(measure(cell, width: widths[column] - padding).height))
            }
            height = max(height + verticalPadding * 2, 30)
            var x: CGFloat = 0
            for (column, width) in widths.enumerated() {
                if column < row.count, row[column].length > 0 {
                    pieces.append(Piece(text: row[column], frame: CGRect(x: x + horizontalPadding, y: y + verticalPadding, width: width - padding, height: height - verticalPadding * 2)))
                }
                x += width
            }
            heights.append(height)
            y += height
        }
        return (cells, widths, heights, pieces, fits)
    }

    /// 卡片：第一欄是粗體標題，其他欄左邊是欄名（淡色小字）、右邊是內容，各自換行。
    private static func stack(_ cells: [[NSAttributedString]], width available: CGFloat) -> (heights: [CGFloat], cards: [CGRect], pieces: [Piece], size: CGSize) {
        let inset: CGFloat = 12
        let gap: CGFloat = 10
        let inner = max(available - inset * 2, 60)
        let labels = cells[0].map { restyled($0, scale: 0.86, color: LiveMarkdown.Theme.secondary) }
        let widest = labels.dropFirst().map { ceil(measure($0, width: .greatestFiniteMagnitude).width) }.max() ?? 0
        let labelWidth = min(max(widest, 44), floor(inner * 0.36))
        var heights: [CGFloat] = []
        var cards: [CGRect] = []
        var pieces: [Piece] = []
        var y: CGFloat = 0
        for row in cells.dropFirst() {
            var cursor = y + 10
            if let first = row.first, first.length > 0 {
                let title = restyled(first, bold: true)
                let height = ceil(measure(title, width: inner).height)
                pieces.append(Piece(text: title, frame: CGRect(x: inset, y: cursor, width: inner, height: height)))
                cursor += height + 6
            }
            for column in row.indices.dropFirst() where row[column].length > 0 {
                let value = restyled(row[column])
                if column < labels.count, labels[column].length > 0 {
                    let valueWidth = inner - labelWidth - gap
                    let labelHeight = ceil(measure(labels[column], width: labelWidth).height)
                    let valueHeight = ceil(measure(value, width: valueWidth).height)
                    pieces.append(Piece(text: labels[column], frame: CGRect(x: inset, y: cursor + 1, width: labelWidth, height: labelHeight)))
                    pieces.append(Piece(text: value, frame: CGRect(x: inset + labelWidth + gap, y: cursor, width: valueWidth, height: valueHeight)))
                    cursor += max(labelHeight + 1, valueHeight) + 4
                } else {
                    let height = ceil(measure(value, width: inner).height)
                    pieces.append(Piece(text: value, frame: CGRect(x: inset, y: cursor, width: inner, height: height)))
                    cursor += height + 4
                }
            }
            let height = cursor - y + 6
            cards.append(CGRect(x: 0, y: y, width: available, height: height))
            heights.append(height)
            y += height + 8
        }
        return (heights, cards, pieces, CGSize(width: available, height: max(y - 8, 0)))
    }

    static func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        guard text.length > 0 else { return CGSize(width: 0, height: LiveMarkdown.Theme.bodyFont.lineHeight) }
        return text.boundingRect(with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
    }

    /// 改字級、粗細或顏色（藏起來的語法不動），卡片裡的文字一律靠左。
    private static func restyled(_ text: NSAttributedString, scale: CGFloat = 1, color: UIColor? = nil, bold: Bool = false, keepsAlignment: Bool = false) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        let all = NSRange(location: 0, length: copy.length)
        copy.enumerateAttributes(in: all) { attributes, range, _ in
            guard let font = attributes[.font] as? UIFont, font.pointSize > 1 else { return }
            var result = scale == 1 ? font : font.withSize(font.pointSize * scale)
            if bold { result = result.withTraits(.traitBold) }
            copy.addAttribute(.font, value: result, range: range)
            if let color { copy.addAttribute(.foregroundColor, value: color, range: range) }
        }
        if !keepsAlignment, all.length > 0 {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            copy.addAttribute(.paragraphStyle, value: style, range: all)
        }
        return copy
    }

    /// 表格裡某一點（相對於表格左上角）的連結：點 [[連結]] 或網址時開啟，不進入編輯。
    func link(at point: CGPoint) -> MarkdownTapTarget? {
        for piece in pieces where piece.frame.insetBy(dx: -4, dy: -4).contains(point) {
            let local = CGPoint(x: point.x - piece.frame.minX, y: point.y - piece.frame.minY)
            if let target = Self.link(in: piece.text, width: piece.frame.width, at: local) { return target }
        }
        return nil
    }

    private static func link(in text: NSAttributedString, width: CGFloat, at local: CGPoint) -> MarkdownTapTarget? {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var result: MarkdownTapTarget?
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, stop in
            var target: MarkdownTapTarget?
            if let wiki = attributes[.mdWikiLink] as? String {
                target = .wikiLink(wiki)
            } else if let url = attributes[.mdLink] as? String {
                target = .link(url)
            }
            guard let target else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            if layout.boundingRect(forGlyphRange: glyphs, in: container).insetBy(dx: -4, dy: -4).contains(local) {
                result = target
                stop.pointee = true
            }
        }
        return result
    }

    /// 畫在文字欄中：格線表（圓角外框、標題列底色、格線）或卡片，再畫上文字。
    func draw(in frame: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let theme = LiveMarkdown.Theme.self
        if stacked {
            for card in cards {
                let path = UIBezierPath(roundedRect: card.offsetBy(dx: frame.minX, dy: frame.minY).insetBy(dx: 0.5, dy: 0.5), cornerRadius: 10)
                theme.tableBackground.setFill()
                path.fill()
                theme.line.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        } else {
            let outline = UIBezierPath(roundedRect: frame, cornerRadius: 8)
            context.saveGState()
            outline.addClip()
            theme.tableBackground.setFill()
            UIRectFill(frame)
            if hasHeader, let first = rowHeights.first {
                theme.tableHeader.setFill()
                UIRectFill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: first))
            }
            theme.line.setFill()
            var y = frame.minY
            for (row, height) in rowHeights.enumerated() {
                if row > 0 {
                    UIRectFill(CGRect(x: frame.minX, y: y - 0.5, width: frame.width, height: row == 1 && hasHeader ? 1 : 0.5))
                }
                y += height
            }
            var x = frame.minX
            for width in columnWidths.dropLast() {
                x += width
                UIRectFill(CGRect(x: x - 0.25, y: frame.minY, width: 0.5, height: frame.height))
            }
            context.restoreGState()
            theme.line.setStroke()
            outline.lineWidth = 1
            outline.stroke()
        }
        for piece in pieces {
            piece.text.draw(with: piece.frame.offsetBy(dx: frame.minX, dy: frame.minY), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }
}

enum LiveMarkdown {
    struct Options {
        /// 游標或選取範圍；nil 表示沒有在編輯（全部以排版後的樣子顯示）。
        var selection: NSRange?
        /// 文字欄寬：決定圖片與表格的大小。
        var width: CGFloat
        /// 已載入的內嵌圖片（依名稱）。
        var images: [String: UIImage] = [:]
        /// [[連結]] 的目標是否存在（不存在的連結顏色較淡，點了會建立新筆記）。
        var resolvesLink: (String) -> Bool = { _ in true }
        /// ```dataviewjs 區塊執行後的內容高度（依 DataviewBlockInfo.key）。
        var dataviewHeights: [String: CGFloat] = [:]
        /// 執行 ```dataviewjs 區塊（編輯器有疊上執行畫面時才開啟）。
        var rendersDataview = false
    }

    // MARK: 樣式

    enum Theme {
        static var bodyFont: UIFont { UIFont.preferredFont(forTextStyle: .body) }
        static var monoFont: UIFont { UIFont.monospacedSystemFont(ofSize: bodyFont.pointSize * 0.88, weight: .regular) }
        static let hiddenFont = UIFont.systemFont(ofSize: 0.01)

        static func headingFont(level: Int) -> UIFont {
            let (size, weight, style): (CGFloat, UIFont.Weight, UIFont.TextStyle) = switch level {
            case 1: (28, .bold, .title1)
            case 2: (23, .bold, .title2)
            case 3: (20, .semibold, .title3)
            default: (17, .semibold, .headline)
            }
            return UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
        }

        static let text = UIColor.label
        static let secondary = UIColor.secondaryLabel
        static let marker = UIColor.tertiaryLabel
        /// 連結與標籤。
        static let accent = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x9DAEFF) : UIColor(hex: 0x3D5BD9) }
        /// 還不存在的 [[連結]]。
        static let unresolved = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x9DAEFF, alpha: 0.55) : UIColor(hex: 0x3D5BD9, alpha: 0.5) }
        /// 游標與勾選完成的方框（黑色；深色模式為白色）。
        static let ink = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xF2F2F4) : UIColor(hex: 0x111113) }
        static let highlight = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x5A4A12) : UIColor(hex: 0xFCF0C8) }
        static let codeBackground = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x2C2C30) : UIColor(hex: 0xF0F0F3) }
        static let tableHeader = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x26262A) : UIColor(hex: 0xF4F4F6) }
        static let tableBackground = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x1F1F22) : UIColor(hex: 0xFFFFFF) }
        static let line = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x3A3A40) : UIColor(hex: 0xDCDCE2) }

        static func calloutColor(_ kind: String) -> UIColor {
            let (dark, light): (UInt32, UInt32) = switch kind {
            case "tip", "hint", "important", "success", "check", "done": (0x1F3A26, 0xD7F3DA)
            case "warning", "caution", "attention", "question", "help", "faq", "todo": (0x3D3418, 0xFCF0C8)
            case "danger", "error", "bug", "failure", "fail", "missing": (0x432532, 0xFBE0E9)
            case "example", "quote", "cite", "abstract", "summary", "tldr": (0x33284A, 0xECE2FC)
            default: (0x1E3440, 0xDDF1FB)
            }
            return UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
        }

        static func paragraphStyle(_ configure: (NSMutableParagraphStyle) -> Void = { _ in }) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            style.paragraphSpacing = 2
            configure(style)
            return style
        }

        static var bodyAttributes: [NSAttributedString.Key: Any] {
            [.font: bodyFont, .foregroundColor: text, .paragraphStyle: paragraphStyle()]
        }

        static let hidden: [NSAttributedString.Key: Any] = [.font: hiddenFont, .foregroundColor: UIColor.clear]
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff"]
    /// 內嵌圖片最高的顯示高度。
    static let maxImageHeight: CGFloat = 640

    // MARK: 套用

    /// 依 Markdown 語法設定整段文字的顯示屬性，回傳還沒載入的內嵌圖片名稱。
    @discardableResult
    static func apply(to storage: NSTextStorage, options: Options) -> Set<String> {
        let text = storage.string as NSString
        var context = Context(storage: storage, text: text, options: options)
        storage.beginEditing()
        storage.setAttributes(Theme.bodyAttributes, range: NSRange(location: 0, length: text.length))
        if text.length > 0 {
            context.styleBlocks()
        }
        storage.endEditing()
        return context.missingImages
    }

    /// `![[名稱|寬度]]`、`![說明](網址)` 單獨一行時的內嵌目標與指定寬度。
    static func embed(in line: String) -> (target: String, width: CGFloat?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("![["), trimmed.hasSuffix("]]"), trimmed.count > 5 {
            let inner = String(trimmed.dropFirst(3).dropLast(2))
            guard !inner.contains("]]") else { return nil }
            let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
            let size = parts.count > 1 ? parts[1].split(separator: "x").first.flatMap { Double($0) }.map { CGFloat($0) } : nil
            return (parts[0].trimmingCharacters(in: .whitespaces), size)
        }
        if trimmed.hasPrefix("!["), trimmed.hasSuffix(")"), let open = trimmed.range(of: "](") {
            var target = String(trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)])
            if let space = target.firstIndex(of: " ") { target = String(target[..<space]) }
            return (target.removingPercentEncoding ?? target, nil)
        }
        return nil
    }

    /// 內嵌目標是不是圖片（依副檔名；網址也算）。
    static func isImage(_ target: String) -> Bool {
        let path = target.split(separator: "#").first.map(String.init) ?? target
        if imageExtensions.contains((path as NSString).pathExtension.lowercased()) { return true }
        return path.hasPrefix("http://") || path.hasPrefix("https://")
    }

    /// 圖片在文字欄中的顯示大小（不放大；太高時等比縮小）。
    static func displaySize(for image: UIImage, width: CGFloat, requestedWidth: CGFloat?) -> CGSize {
        let natural = image.size
        guard natural.width > 0, natural.height > 0, width > 0 else { return CGSize(width: max(width, 1), height: 1) }
        var displayWidth = min(requestedWidth ?? natural.width, width)
        var height = displayWidth * natural.height / natural.width
        if height > maxImageHeight {
            height = maxImageHeight
            displayWidth = height * natural.width / natural.height
        }
        return CGSize(width: floor(displayWidth), height: floor(height))
    }

    /// [[目標#標題|別名]] 中的筆記名稱（不含 #標題、^區塊、|別名）。
    static func linkName(_ target: String) -> String {
        let name = target.split(separator: "|", maxSplits: 1).first.map(String.init) ?? target
        let withoutAnchor = name.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        return withoutAnchor.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 實作

    private struct Context {
        let storage: NSTextStorage
        let text: NSString
        let options: Options
        var missingImages = Set<String>()
        /// 每一行的範圍（不含換行）。
        let lines: [NSRange]

        init(storage: NSTextStorage, text: NSString, options: Options) {
            self.storage = storage
            self.text = text
            self.options = options
            var lines: [NSRange] = []
            var location = 0
            while location < text.length {
                var start = 0, end = 0, contentsEnd = 0
                text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
                lines.append(NSRange(location: start, length: contentsEnd - start))
                location = end
            }
            if text.length > 0, text.character(at: text.length - 1) == 0x0A {
                lines.append(NSRange(location: text.length, length: 0))
            }
            self.lines = lines
        }

        func string(_ range: NSRange) -> String { text.substring(with: range) }

        func trimmed(_ index: Int) -> String {
            string(lines[index]).trimmingCharacters(in: .whitespaces)
        }

        /// 游標或選取範圍在這一行（游標在行尾也算）。
        func isActive(_ line: NSRange) -> Bool {
            guard let selection = options.selection else { return false }
            if selection.length == 0 {
                return selection.location >= line.location && selection.location <= NSMaxRange(line)
            }
            return selection.location <= NSMaxRange(line) && NSMaxRange(selection) >= line.location
        }

        func isActive(lines indices: ClosedRange<Int>) -> Bool {
            indices.contains { isActive(lines[$0]) }
        }

        /// 包含換行的整段（段落樣式要套用到整段）。
        func paragraph(_ line: NSRange) -> NSRange {
            guard line.location < text.length else { return line }
            return text.paragraphRange(for: line)
        }

        func setParagraphStyle(_ style: NSParagraphStyle, lines indices: ClosedRange<Int>) {
            let start = paragraph(lines[indices.lowerBound])
            let end = paragraph(lines[indices.upperBound])
            let range = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
            guard range.length > 0 else { return }
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }

        func hide(_ range: NSRange, dimInstead: Bool, font: UIFont? = nil) {
            guard range.length > 0 else { return }
            if dimInstead {
                storage.addAttribute(.foregroundColor, value: Theme.marker, range: range)
                if let font { storage.addAttribute(.font, value: font, range: range) }
            } else {
                storage.addAttributes(Theme.hidden, range: range)
            }
        }

        func width(of range: NSRange) -> CGFloat {
            guard range.length > 0 else { return 0 }
            return ceil(storage.attributedSubstring(from: range).size().width)
        }

        // MARK: 區塊

        mutating func styleBlocks() {
            var index = 0
            // YAML 屬性
            if lines.count > 1, trimmed(0) == "---", let end = (1..<lines.count).first(where: { trimmed($0) == "---" }) {
                styleFrontmatter(0...end)
                index = end + 1
            }
            while index < lines.count {
                let line = lines[index]
                let value = trimmed(index)
                if value.hasPrefix("```") || value.hasPrefix("~~~") {
                    let fence = String(value.prefix(3))
                    var end = index + 1
                    while end < lines.count, !trimmed(end).hasPrefix(fence) { end += 1 }
                    let last = min(end, lines.count - 1)
                    let language = value.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                    // 有結尾的 ```dataviewjs：沒在編輯時換成執行畫面
                    if language == "dataviewjs", options.rendersDataview, end < lines.count, last > index, !isActive(lines: index...last) {
                        styleDataview(index...last)
                    } else {
                        styleCode(index...last)
                    }
                    index = last + 1
                    continue
                }
                if value.hasPrefix("$$") {
                    var end = index
                    if !(value.count >= 5 && value.hasSuffix("$$")) {
                        end = index + 1
                        while end < lines.count, !trimmed(end).hasSuffix("$$") { end += 1 }
                        end = min(end, lines.count - 1)
                    }
                    styleMathBlock(index...end)
                    index = end + 1
                    continue
                }
                if startsTable(index) {
                    var end = index
                    while end + 1 < lines.count, isTableRow(end + 1) { end += 1 }
                    styleTable(index...end)
                    index = end + 1
                    continue
                }
                if value.hasPrefix(">") {
                    var end = index
                    while end + 1 < lines.count, trimmed(end + 1).hasPrefix(">") { end += 1 }
                    styleQuote(index...end)
                    index = end + 1
                    continue
                }
                if value.hasPrefix("<!--"), value.hasSuffix("-->") {
                    hide(line, dimInstead: isActive(line), font: Theme.monoFont)
                    index += 1
                    continue
                }
                if styleHeading(line) {
                    index += 1
                    continue
                }
                if value.count >= 3, ["-", "*", "_"].contains(where: { mark in value.allSatisfy { $0 == Character(mark) || $0 == " " } && value.filter { $0 == Character(mark) }.count >= 3 }) {
                    styleRule(line)
                    index += 1
                    continue
                }
                if let embed = LiveMarkdown.embed(in: string(line)) {
                    styleEmbed(line, target: embed.target, requestedWidth: embed.width)
                    index += 1
                    continue
                }
                if styleListItem(line) {
                    index += 1
                    continue
                }
                // 下一行是 === 或 ---：這一行是標題（Setext）
                if !value.isEmpty, index + 1 < lines.count, let level = setextLevel(index + 1) {
                    styleSetextHeading(line, underline: lines[index + 1], level: level)
                    index += 2
                    continue
                }
                styleInline(line, active: isActive(line))
                index += 1
            }
        }

        /// 表格開頭：「|」開頭的行，或含有「|」且下一行是有「|」的分隔列（GFM 不寫外框的表格）。
        func startsTable(_ index: Int) -> Bool {
            let value = trimmed(index)
            if value.hasPrefix("|") { return true }
            guard !pipes(in: lines[index]).isEmpty, index + 1 < lines.count, isTableSeparator(index + 1) else { return false }
            return trimmed(index + 1).contains("|")
        }

        func isTableSeparator(_ index: Int) -> Bool {
            let value = trimmed(index)
            return value.contains("-") && Patterns.tableSeparator.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
        }

        /// 表格的一列：開頭是「|」，或含有「|」（沒有開頭直線的寫法）。
        func isTableRow(_ index: Int) -> Bool {
            let value = trimmed(index)
            return !value.isEmpty && (value.hasPrefix("|") || !pipes(in: lines[index]).isEmpty)
        }

        func setextLevel(_ index: Int) -> Int? {
            let value = trimmed(index)
            guard value.count >= 2 else { return nil }
            if value.allSatisfy({ $0 == "=" }) { return 1 }
            if value.allSatisfy({ $0 == "-" }) { return 2 }
            return nil
        }

        func styleSetextHeading(_ line: NSRange, underline: NSRange, level: Int) {
            let active = isActive(line) || isActive(underline)
            let font = Theme.headingFont(level: level)
            storage.addAttribute(.font, value: font, range: line)
            styleInline(line, active: active, baseFont: font)
            hide(underline, dimInstead: active)
            let first = index(of: line)
            setParagraphStyle(Theme.paragraphStyle {
                $0.paragraphSpacingBefore = level == 1 ? 14 : 10
                $0.paragraphSpacing = 0
            }, lines: first...first)
            if !active {
                setParagraphStyle(Theme.paragraphStyle {
                    $0.minimumLineHeight = 0
                    $0.maximumLineHeight = 4
                    $0.lineSpacing = 0
                    $0.paragraphSpacing = 4
                }, lines: (first + 1)...(first + 1))
                storage.addAttributes(Theme.hidden, range: paragraph(underline))
            }
        }

        func styleFrontmatter(_ indices: ClosedRange<Int>) {
            let start = lines[indices.lowerBound].location
            let end = NSMaxRange(lines[indices.upperBound])
            let range = NSRange(location: start, length: end - start)
            storage.addAttributes([
                .font: UIFont.monospacedSystemFont(ofSize: Theme.bodyFont.pointSize * 0.78, weight: .regular),
                .foregroundColor: Theme.secondary,
                .mdBlockBackground: Theme.codeBackground,
            ], range: range)
            setParagraphStyle(Theme.paragraphStyle {
                $0.firstLineHeadIndent = 12
                $0.headIndent = 12
                $0.tailIndent = -12
                $0.lineSpacing = 2
            }, lines: indices)
        }

        func styleCode(_ indices: ClosedRange<Int>) {
            let active = isActive(lines: indices)
            let start = lines[indices.lowerBound].location
            let end = NSMaxRange(lines[indices.upperBound])
            storage.addAttributes([
                .font: Theme.monoFont,
                .foregroundColor: Theme.text,
                .mdBlockBackground: Theme.codeBackground,
            ], range: NSRange(location: start, length: end - start))
            // ``` 圍欄：編輯中顯示，其他時候藏起來
            hide(lines[indices.lowerBound], dimInstead: active, font: Theme.monoFont)
            let closing = indices.upperBound
            if closing > indices.lowerBound, trimmed(closing).hasPrefix(String(trimmed(indices.lowerBound).prefix(3))) {
                hide(lines[closing], dimInstead: active, font: Theme.monoFont)
            }
            setParagraphStyle(Theme.paragraphStyle {
                $0.firstLineHeadIndent = 12
                $0.headIndent = 12
                $0.tailIndent = -12
                $0.lineSpacing = 2
            }, lines: indices)
        }

        /// $$ 數學區塊：置中的斜體等寬字與底色，$$ 編輯中顯示、其他時候藏起來。
        func styleMathBlock(_ indices: ClosedRange<Int>) {
            let active = isActive(lines: indices)
            let start = lines[indices.lowerBound].location
            let end = NSMaxRange(lines[indices.upperBound])
            storage.addAttributes([
                .font: Theme.monoFont.withTraits(.traitItalic),
                .foregroundColor: Theme.text,
                .mdBlockBackground: Theme.codeBackground,
            ], range: NSRange(location: start, length: end - start))
            for index in Set([indices.lowerBound, indices.upperBound]) {
                let line = lines[index]
                let value = string(line) as NSString
                let leading = value.range(of: "$$")
                let trailing = value.range(of: "$$", options: .backwards)
                if leading.location != NSNotFound {
                    hide(NSRange(location: line.location + leading.location, length: 2), dimInstead: active, font: Theme.monoFont)
                }
                if trailing.location != NSNotFound, trailing.location >= leading.location + 2 {
                    hide(NSRange(location: line.location + trailing.location, length: 2), dimInstead: active, font: Theme.monoFont)
                }
            }
            setParagraphStyle(Theme.paragraphStyle {
                $0.alignment = .center
                $0.lineSpacing = 2
            }, lines: indices)
        }

        mutating func styleQuote(_ indices: ClosedRange<Int>) {
            let first = string(lines[indices.lowerBound])
            let markerPattern = Patterns.quoteMarker
            let calloutPattern = Patterns.callout
            let firstMarker = markerPattern.firstMatch(in: first, range: NSRange(location: 0, length: (first as NSString).length))?.range.length ?? 0
            let firstContent = (first as NSString).substring(from: firstMarker)
            let callout = calloutPattern.firstMatch(in: firstContent, range: NSRange(location: 0, length: (firstContent as NSString).length))
            let block = NSRange(location: lines[indices.lowerBound].location, length: NSMaxRange(lines[indices.upperBound]) - lines[indices.lowerBound].location)

            if let callout {
                let kind = (firstContent as NSString).substring(with: callout.range(at: 1)).lowercased()
                storage.addAttribute(.mdBlockBackground, value: Theme.calloutColor(kind), range: block)
            } else {
                storage.addAttributes([.foregroundColor: Theme.secondary, .mdQuote: true], range: block)
            }
            setParagraphStyle(Theme.paragraphStyle {
                $0.firstLineHeadIndent = 14
                $0.headIndent = 14
                $0.tailIndent = callout == nil ? 0 : -12
            }, lines: indices)

            for index in indices {
                let line = lines[index]
                let value = string(line) as NSString
                let markerLength = markerPattern.firstMatch(in: value as String, range: NSRange(location: 0, length: value.length))?.range.length ?? 0
                let active = isActive(line)
                hide(NSRange(location: line.location, length: markerLength), dimInstead: active)
                var contentStart = line.location + markerLength
                if index == indices.lowerBound, let callout {
                    // > [!note] 標題：標題用粗體；沒有標題時顯示類型名稱
                    let kindRange = NSRange(location: contentStart + callout.range(at: 1).location, length: callout.range(at: 1).length)
                    let tokenEnd = contentStart + callout.range.length
                    let titleRange = NSRange(location: tokenEnd, length: NSMaxRange(line) - tokenEnd)
                    let boldFont = Theme.bodyFont.withTraits(.traitBold)
                    if titleRange.length > 0 {
                        hide(NSRange(location: contentStart, length: callout.range.length), dimInstead: active)
                        storage.addAttribute(.font, value: boldFont, range: titleRange)
                    } else if !active {
                        hide(NSRange(location: contentStart, length: kindRange.location - contentStart), dimInstead: false)
                        hide(NSRange(location: NSMaxRange(kindRange), length: tokenEnd - NSMaxRange(kindRange)), dimInstead: false)
                        storage.addAttributes([.font: boldFont, .foregroundColor: Theme.text], range: kindRange)
                    } else {
                        storage.addAttribute(.foregroundColor, value: Theme.marker, range: NSRange(location: contentStart, length: callout.range.length))
                    }
                    contentStart = tokenEnd
                }
                styleInline(NSRange(location: contentStart, length: NSMaxRange(line) - contentStart), active: active)
            }
        }

        func styleHeading(_ line: NSRange) -> Bool {
            let value = string(line)
            let hashes = value.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes), value.dropFirst(hashes).first == " " else { return false }
            let spaces = value.dropFirst(hashes).prefix { $0 == " " }.count
            let font = Theme.headingFont(level: hashes)
            storage.addAttribute(.font, value: font, range: line)
            let active = isActive(line)
            hide(NSRange(location: line.location, length: hashes + spaces), dimInstead: active, font: font)
            setParagraphStyle(Theme.paragraphStyle {
                $0.paragraphSpacingBefore = hashes <= 2 ? 12 : 8
                $0.paragraphSpacing = 4
            }, lines: index(of: line)...index(of: line))
            // 結尾的 ## 也是語法（# 標題 #）
            var contentLength = line.length - hashes - spaces
            if let closing = Patterns.closingHashes.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)),
               closing.range.location >= hashes + spaces {
                hide(NSRange(location: line.location + closing.range.location, length: closing.range.length), dimInstead: active, font: font)
                contentLength = closing.range.location - hashes - spaces
            }
            styleInline(NSRange(location: line.location + hashes + spaces, length: contentLength), active: active, baseFont: font)
            return true
        }

        func index(of line: NSRange) -> Int {
            lines.firstIndex { $0.location == line.location } ?? 0
        }

        func styleRule(_ line: NSRange) {
            if isActive(line) {
                storage.addAttribute(.foregroundColor, value: Theme.marker, range: line)
                return
            }
            hide(line, dimInstead: false)
            storage.addAttribute(.mdRule, value: true, range: line)
            setParagraphStyle(Theme.paragraphStyle {
                $0.minimumLineHeight = 22
                $0.maximumLineHeight = 22
            }, lines: index(of: line)...index(of: line))
        }

        mutating func styleEmbed(_ line: NSRange, target: String, requestedWidth: CGFloat?) {
            let active = isActive(line)
            guard LiveMarkdown.isImage(target) else {
                styleInline(line, active: active)
                return
            }
            guard !active, line.length > 0 else {
                styleInline(line, active: active)
                return
            }
            guard let image = options.images[target] else {
                missingImages.insert(target)
                styleInline(line, active: false)
                return
            }
            let size = LiveMarkdown.displaySize(for: image, width: options.width, requestedWidth: requestedWidth)
            hide(line, dimInstead: false)
            storage.addAttribute(.mdImage, value: MarkdownImageInfo(name: target, size: size), range: line)
            setParagraphStyle(Theme.paragraphStyle {
                $0.minimumLineHeight = size.height
                $0.maximumLineHeight = size.height
                $0.paragraphSpacingBefore = 6
                $0.paragraphSpacing = 8
                $0.lineSpacing = 0
            }, lines: index(of: line)...index(of: line))
        }

        /// 清單、編號與待辦：方框與圓點用畫的，換行後的文字對齊在符號後面。
        func styleListItem(_ line: NSRange) -> Bool {
            let value = string(line)
            let pattern = Patterns.listItem
            guard let match = pattern.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) else { return false }
            let marker = NSRange(location: line.location + match.range(at: 2).location, length: match.range(at: 2).length)
            let prefixEnd = line.location + match.range.length
            let content = NSRange(location: prefixEnd, length: NSMaxRange(line) - prefixEnd)
            let active = isActive(line)
            // 游標在符號上時顯示原本的文字，方便刪改
            let markerActive: Bool = {
                guard let selection = options.selection else { return false }
                return selection.location >= line.location && selection.location <= prefixEnd && selection.length == 0
            }()
            let markerText = (value as NSString).substring(with: match.range(at: 2))
            let isTask = match.range(at: 4).location != NSNotFound
            if isTask {
                let done = (value as NSString).substring(with: match.range(at: 5)).lowercased() == "x"
                let box = NSRange(location: line.location + match.range(at: 4).location, length: 3)
                if markerActive {
                    storage.addAttribute(.foregroundColor, value: Theme.marker, range: NSRange(location: marker.location, length: prefixEnd - marker.location))
                } else {
                    hide(NSRange(location: marker.location, length: box.location - marker.location), dimInstead: false)
                    storage.addAttributes([.foregroundColor: UIColor.clear, .mdCheckbox: done], range: box)
                }
                if done {
                    storage.addAttributes([.foregroundColor: Theme.secondary, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: content)
                }
            } else if ["-", "*", "+"].contains(markerText), !markerActive {
                storage.addAttributes([.foregroundColor: UIColor.clear, .mdBullet: true], range: marker)
            } else {
                storage.addAttribute(.foregroundColor, value: Theme.secondary, range: marker)
            }
            styleInline(content, active: active)
            let indent = width(of: NSRange(location: line.location, length: prefixEnd - line.location))
            setParagraphStyle(Theme.paragraphStyle {
                $0.headIndent = indent
            }, lines: index(of: line)...index(of: line))
            return true
        }

        // MARK: 表格

        func styleTable(_ indices: ClosedRange<Int>) {
            let active = isActive(lines: indices)
            func raw() {
                for index in indices {
                    storage.addAttribute(.font, value: Theme.monoFont, range: lines[index])
                    for pipe in pipes(in: lines[index]) {
                        storage.addAttribute(.foregroundColor, value: Theme.marker, range: NSRange(location: pipe, length: 1))
                    }
                }
            }
            // 游標在表格裡時顯示原始文字，方便編輯；其他時候畫成格線表
            guard !active, indices.count >= 2, let info = tableInfo(indices) else {
                raw()
                return
            }
            reserve(indices, height: info.size.height, key: .mdTable, value: info)
        }

        /// 把整段文字藏起來，在第一行保留 `height` 的空間（由版面管理或疊上去的畫面畫出內容）。
        func reserve(_ indices: ClosedRange<Int>, height: CGFloat, key: NSAttributedString.Key, value: Any) {
            let first = indices.lowerBound
            let start = lines[first].location
            let end = NSMaxRange(paragraph(lines[indices.upperBound]))
            storage.addAttributes(Theme.hidden, range: NSRange(location: start, length: end - start))
            storage.addAttribute(key, value: value, range: lines[first].length > 0 ? lines[first] : NSRange(location: start, length: min(1, end - start)))
            setParagraphStyle(Theme.paragraphStyle {
                $0.minimumLineHeight = height
                $0.maximumLineHeight = height
                $0.lineSpacing = 0
                $0.paragraphSpacingBefore = 6
                $0.paragraphSpacing = 10
            }, lines: first...first)
            if indices.count > 1 {
                setParagraphStyle(Theme.paragraphStyle {
                    $0.minimumLineHeight = 0
                    $0.maximumLineHeight = 0.1
                    $0.lineSpacing = 0
                    $0.paragraphSpacing = 0
                    $0.paragraphSpacingBefore = 0
                }, lines: (first + 1)...indices.upperBound)
            }
        }

        /// ```dataviewjs 區塊：保留執行畫面的高度（內容高度＋上方一列）。
        func styleDataview(_ indices: ClosedRange<Int>) {
            let code = ((indices.lowerBound + 1)..<indices.upperBound).map { string(lines[$0]) }.joined(separator: "\n")
            let key = DataviewBlockInfo.key(for: code)
            let height = (options.dataviewHeights[key] ?? DataviewBlockInfo.defaultContentHeight) + DataviewBlockInfo.headerHeight
            reserve(indices, height: height, key: .mdDataview, value: DataviewBlockInfo(code: code, height: height))
        }

        /// 表格的儲存格：每格套好行內樣式，欄位對齊依分隔列（:--- 靠左、:---: 置中、---: 靠右）。
        func tableInfo(_ indices: ClosedRange<Int>) -> MarkdownTableInfo? {
            let start = lines[indices.lowerBound].location
            let source = text.substring(with: NSRange(location: start, length: NSMaxRange(lines[indices.upperBound]) - start))
            let width = max(options.width - 2, 120)
            // 有 [[連結]] 的表格不快取：連結的筆記可能剛建立（顏色要跟著變）
            let key: NSString? = source.contains("[[") ? nil : "\(Int(width))|\(Theme.bodyFont.pointSize)|\(source)" as NSString
            if let key, let cached = MarkdownTableInfo.cache.object(forKey: key) { return cached }
            let separatorIndex = indices.lowerBound + 1
            let hasHeader = isTableSeparator(separatorIndex)
            var alignments: [NSTextAlignment] = []
            if hasHeader {
                alignments = cells(in: lines[separatorIndex]).map { cell in
                    let value = string(cell).trimmingCharacters(in: .whitespaces)
                    switch (value.hasPrefix(":"), value.hasSuffix(":")) {
                    case (true, true): return .center
                    case (false, true): return .right
                    default: return .natural
                    }
                }
            }
            var rows: [[NSAttributedString]] = []
            for index in indices where !(hasHeader && index == separatorIndex) {
                let header = hasHeader && index == indices.lowerBound
                let row = cells(in: lines[index]).enumerated().map { column, cell in
                    renderCell(string(cell), header: header, alignment: column < alignments.count ? alignments[column] : .natural)
                }
                rows.append(row)
            }
            guard rows.contains(where: { !$0.isEmpty }) else { return nil }
            let info = MarkdownTableInfo(cells: rows, hasHeader: hasHeader, width: width)
            if let key { MarkdownTableInfo.cache.setObject(info, forKey: key) }
            return info
        }

        /// 一列的儲存格範圍（開頭與結尾的「|」可有可無）。
        func cells(in line: NSRange) -> [NSRange] {
            let positions = pipes(in: line)
            let bounds = [line.location - 1] + positions + [NSMaxRange(line)]
            var result = zip(bounds, bounds.dropFirst()).map { NSRange(location: $0 + 1, length: max(0, $1 - $0 - 1)) }
            let value = string(line).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("|"), !result.isEmpty { result.removeFirst() }
            if value.hasSuffix("|"), !value.hasSuffix("\\|"), !result.isEmpty { result.removeLast() }
            return result
        }

        /// 一格的內容：行內樣式（粗體、斜體、程式碼、連結…）與換行（<br>）。
        func renderCell(_ raw: String, header: Bool, alignment: NSTextAlignment) -> NSAttributedString {
            var source = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|")
            source = source.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            let font = header ? Theme.bodyFont.withTraits(.traitBold) : Theme.bodyFont
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            style.lineSpacing = 2
            let cell = NSTextStorage(string: source, attributes: [.font: font, .foregroundColor: Theme.text, .paragraphStyle: style])
            let cellContext = Context(storage: cell, text: source as NSString, options: Options(selection: nil, width: .greatestFiniteMagnitude, resolvesLink: options.resolvesLink))
            cellContext.styleInline(NSRange(location: 0, length: (source as NSString).length), active: false, baseFont: font)
            return NSAttributedString(attributedString: cell)
        }

        /// 一行中沒有跳脫的「|」位置（不在 `程式碼` 中）。
        func pipes(in line: NSRange) -> [Int] {
            var result: [Int] = []
            var inCode = false
            var location = line.location
            while location < NSMaxRange(line) {
                let character = text.character(at: location)
                if character == 0x60 { inCode.toggle() }
                if character == 0x7C, !inCode, location == line.location || text.character(at: location - 1) != 0x5C {
                    result.append(location)
                }
                location += 1
            }
            return result
        }

        // MARK: 行內

        func styleInline(_ range: NSRange, active: Bool, baseFont: UIFont? = nil) {
            guard range.length > 0 else { return }
            let source = text.substring(with: range)
            let local = NSRange(location: 0, length: (source as NSString).length)
            func absolute(_ r: NSRange) -> NSRange { NSRange(location: range.location + r.location, length: r.length) }
            var protected: [NSRange] = []
            func isProtected(_ r: NSRange) -> Bool { protected.contains { NSIntersectionRange($0, r).length > 0 } }
            func marker(_ r: NSRange) { hide(absolute(r), dimInstead: active) }

            // `程式碼`
            for match in Patterns.code.matches(in: source, range: local) {
                storage.addAttributes([.font: Theme.monoFont, .backgroundColor: Theme.codeBackground], range: absolute(match.range(at: 1)))
                marker(NSRange(location: match.range.location, length: 1))
                marker(NSRange(location: NSMaxRange(match.range) - 1, length: 1))
                protected.append(match.range)
            }
            // \* 跳脫字元：藏起反斜線，後面的字照原樣顯示（不當成語法）
            for match in Patterns.escape.matches(in: source, range: local) where !isProtected(match.range) {
                marker(NSRange(location: match.range.location, length: 1))
                protected.append(match.range)
            }
            // [[連結]]、![[內嵌]]
            for match in Patterns.wikiLink.matches(in: source, range: local) where !isProtected(match.range) {
                let inner = match.range(at: 2)
                let innerText = (source as NSString).substring(with: inner)
                let target = innerText.split(separator: "|", maxSplits: 1).first.map(String.init) ?? innerText
                let resolved = options.resolvesLink(LiveMarkdown.linkName(target))
                var display = inner
                if let bar = innerText.firstIndex(of: "|") {
                    let offset = (String(innerText[..<bar]) as NSString).length + 1
                    marker(NSRange(location: inner.location, length: offset))
                    display = NSRange(location: inner.location + offset, length: inner.length - offset)
                }
                marker(NSRange(location: match.range.location, length: inner.location - match.range.location))
                marker(NSRange(location: NSMaxRange(inner), length: NSMaxRange(match.range) - NSMaxRange(inner)))
                storage.addAttributes([
                    .foregroundColor: resolved ? Theme.accent : Theme.unresolved,
                    .mdWikiLink: target,
                ], range: absolute(display))
                protected.append(match.range)
            }
            // [文字](網址)
            for match in Patterns.markdownLink.matches(in: source, range: local) where !isProtected(match.range) {
                let label = match.range(at: 2)
                let url = (source as NSString).substring(with: match.range(at: 3))
                marker(NSRange(location: match.range.location, length: label.location - match.range.location))
                marker(NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label)))
                storage.addAttributes([.foregroundColor: Theme.accent, .mdLink: url], range: absolute(label.length > 0 ? label : match.range(at: 3)))
                protected.append(match.range)
            }
            // 網址
            for match in Patterns.url.matches(in: source, range: local) where !isProtected(match.range) {
                storage.addAttributes([
                    .foregroundColor: Theme.accent,
                    .mdLink: (source as NSString).substring(with: match.range),
                ], range: absolute(match.range))
                protected.append(match.range)
            }
            // ***粗斜體***
            for match in Patterns.boldItalic.matches(in: source, range: local) {
                let open = NSRange(location: match.range.location, length: 3)
                let close = NSRange(location: NSMaxRange(match.range) - 3, length: 3)
                guard !isProtected(open), !isProtected(close) else { continue }
                addTraits([.traitBold, .traitItalic], to: absolute(NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open))), baseFont: baseFont)
                marker(open)
                marker(close)
                protected += [open, close]
            }
            // **粗體**、*斜體*、~~刪除線~~、==螢光==
            let spans: [(NSRegularExpression, Int)] = [(Patterns.bold, 2), (Patterns.italicStar, 1), (Patterns.italicUnderscore, 1), (Patterns.strike, 2), (Patterns.highlight, 2)]
            for (index, (pattern, markerLength)) in spans.enumerated() {
                for match in pattern.matches(in: source, range: local) {
                    let open = NSRange(location: match.range.location, length: markerLength)
                    let close = NSRange(location: NSMaxRange(match.range) - markerLength, length: markerLength)
                    guard !isProtected(open), !isProtected(close) else { continue }
                    let body = absolute(NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open)))
                    switch index {
                    case 0: addTraits(.traitBold, to: body, baseFont: baseFont)
                    case 1, 2: addTraits(.traitItalic, to: body, baseFont: baseFont)
                    case 3: storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Theme.secondary], range: body)
                    default: storage.addAttribute(.backgroundColor, value: Theme.highlight, range: body)
                    }
                    marker(open)
                    marker(close)
                }
            }
            // #標籤
            for match in Patterns.tag.matches(in: source, range: local) where !isProtected(match.range) {
                storage.addAttribute(.foregroundColor, value: Theme.accent, range: absolute(match.range))
            }
            // [^註腳]
            for match in Patterns.footnote.matches(in: source, range: local) where !isProtected(match.range) {
                storage.addAttributes([
                    .foregroundColor: Theme.accent,
                    .font: UIFont.systemFont(ofSize: Theme.bodyFont.pointSize * 0.7),
                    .baselineOffset: 6,
                ], range: absolute(match.range))
            }
            // $數學$、%%註解%%、<html>
            for match in Patterns.math.matches(in: source, range: local) where !isProtected(match.range) {
                storage.addAttributes([.font: Theme.monoFont.withTraits(.traitItalic), .foregroundColor: Theme.secondary], range: absolute(match.range))
            }
            for pattern in [Patterns.comment, Patterns.html] {
                for match in pattern.matches(in: source, range: local) where !isProtected(match.range) {
                    storage.addAttribute(.foregroundColor, value: Theme.marker, range: absolute(match.range))
                }
            }
        }

        func addTraits(_ traits: UIFontDescriptor.SymbolicTraits, to range: NSRange, baseFont: UIFont?) {
            storage.enumerateAttribute(.font, in: range) { value, run, _ in
                let font = (value as? UIFont) ?? baseFont ?? Theme.bodyFont
                guard font.pointSize > 1 else { return }
                storage.addAttribute(.font, value: font.withTraits(traits), range: run)
            }
        }
    }

    private enum Patterns {
        static func regex(_ pattern: String) -> NSRegularExpression {
            // 固定的樣式規則，編譯失敗代表程式錯誤
            try! NSRegularExpression(pattern: pattern)
        }

        static let code = regex(#"`([^`\n]+)`"#)
        static let wikiLink = regex(#"(!?)\[\[([^\]\n]+?)\]\]"#)
        static let markdownLink = regex(#"(!?)\[([^\]\n]*)\]\(([^)\s]+)(?:\s+"[^"\n]*")?\)"#)
        static let url = regex(#"https?://[^\s<>()\[\]]+"#)
        static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
        static let italicStar = regex(#"(?<![\*\w])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?![\*\w])"#)
        static let italicUnderscore = regex(#"(?<![_\w])_(?=[^\s_])([^_\n]+?)(?<=[^\s_])_(?![_\w])"#)
        static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
        static let highlight = regex(#"==(?=\S)(.+?)(?<=\S)=="#)
        static let tag = regex(#"(?<![^\s(])#[\p{L}\p{N}_/-]*[\p{L}_/-][\p{L}\p{N}_/-]*"#)
        static let footnote = regex(#"\[\^[^\]\n]+\]"#)
        static let math = regex(#"(?<!\$)\$(?=\S)([^$\n]+?)(?<=\S)\$(?!\$)"#)
        static let comment = regex(#"%%.+?%%"#)
        static let html = regex(#"</?[a-zA-Z][^>\n]*>"#)
        static let quoteMarker = regex(#"^\s*(?:>\s?)+"#)
        static let callout = regex(#"^\[!([\w-]+)\]([+-]?)\s*"#)
        static let listItem = regex(#"^(\s*)([-*+]|\d{1,9}[.)])(\s+)(\[( |x|X)\]\s)?"#)
        static let escape = regex(#"\\[\\`*_{}\[\]()#+\-.!|~=<>$%]"#)
        static let boldItalic = regex(#"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
        static let closingHashes = regex(#"\s+#+\s*$"#)
        static let tableSeparator = regex(#"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$"#)
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

// MARK: - 畫出方框、圓點、底色、框線與圖片

/// TextKit 1 的版面管理：依 LiveMarkdown 設定的屬性，在文字後面畫出待辦方框、清單圓點、引用直線、
/// 程式碼與 callout 的圓角底色、分隔線、表格框線與內嵌圖片。
final class LiveMarkdownLayoutManager: NSLayoutManager {
    var images: [String: UIImage] = [:]

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        func lineRects(for range: NSRange) -> CGRect {
            let glyphs = NSIntersectionRange(glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphsToShow)
            var union = CGRect.null
            guard glyphs.length > 0 else { return union }
            enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in union = union.union(rect) }
            return union.offsetBy(dx: origin.x, dy: origin.y)
        }

        // 區塊底色
        storage.enumerateAttribute(.mdBlockBackground, in: characters) { value, range, _ in
            guard let color = value as? UIColor else { return }
            let rect = lineRects(for: range)
            guard !rect.isNull else { return }
            color.setFill()
            UIBezierPath(roundedRect: rect.insetBy(dx: -6, dy: -2), cornerRadius: 8).fill()
        }
        // 引用直線
        storage.enumerateAttribute(.mdQuote, in: characters) { value, range, _ in
            guard value != nil else { return }
            let rect = lineRects(for: range)
            guard !rect.isNull else { return }
            LiveMarkdown.Theme.line.setFill()
            UIBezierPath(roundedRect: CGRect(x: rect.minX + 2, y: rect.minY + 2, width: 3, height: rect.height - 4), cornerRadius: 1.5).fill()
        }
        // 分隔線
        storage.enumerateAttribute(.mdRule, in: characters) { value, range, _ in
            guard value != nil else { return }
            let rect = lineRects(for: range)
            guard !rect.isNull else { return }
            LiveMarkdown.Theme.line.setFill()
            UIRectFill(CGRect(x: rect.minX, y: rect.midY - 0.5, width: container.size.width, height: 1))
        }
        // DataviewJS：執行畫面疊上來之前先畫底色
        storage.enumerateAttribute(.mdDataview, in: characters) { value, range, _ in
            guard let info = value as? DataviewBlockInfo else { return }
            let rect = lineRects(for: range)
            guard !rect.isNull else { return }
            let spacingBefore = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
            LiveMarkdown.Theme.codeBackground.setFill()
            UIBezierPath(roundedRect: CGRect(x: rect.minX, y: rect.minY + spacingBefore, width: container.size.width, height: info.height), cornerRadius: 10).fill()
        }
        // 表格：整張格線表畫在第一行保留的空間
        storage.enumerateAttribute(.mdTable, in: characters) { value, range, _ in
            guard let info = value as? MarkdownTableInfo else { return }
            let rect = lineRects(for: range)
            guard !rect.isNull else { return }
            let spacingBefore = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
            info.draw(in: CGRect(origin: CGPoint(x: rect.minX, y: rect.minY + spacingBefore), size: info.size))
        }
        /// 某個字的基線位置與字寬（相對於畫布）。
        func glyphMetrics(at characterIndex: Int) -> (x: CGFloat, width: CGFloat, baseline: CGFloat) {
            let glyph = glyphIndexForCharacter(at: characterIndex)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = location(forGlyphAt: glyph)
            let bounds = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            return (line.minX + position.x + origin.x, bounds.width, line.minY + position.y + origin.y)
        }
        // 清單圓點
        storage.enumerateAttribute(.mdBullet, in: characters) { value, range, _ in
            guard value != nil else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont ?? LiveMarkdown.Theme.bodyFont
            let metrics = glyphMetrics(at: range.location)
            let diameter: CGFloat = 5.5
            let center = CGPoint(x: metrics.x + metrics.width / 2, y: metrics.baseline - font.xHeight / 2)
            LiveMarkdown.Theme.secondary.setFill()
            UIBezierPath(ovalIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)).fill()
        }
        // 待辦方框
        storage.enumerateAttribute(.mdCheckbox, in: characters) { value, range, _ in
            guard let done = value as? Bool else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont ?? LiveMarkdown.Theme.bodyFont
            let metrics = glyphMetrics(at: range.location)
            let side = min(font.pointSize + 1, 19)
            let box = CGRect(x: metrics.x + 1, y: metrics.baseline - font.capHeight / 2 - side / 2, width: side, height: side)
            let path = UIBezierPath(roundedRect: box, cornerRadius: 5)
            if done {
                LiveMarkdown.Theme.ink.setFill()
                path.fill()
                let check = UIBezierPath()
                check.move(to: CGPoint(x: box.minX + side * 0.27, y: box.minY + side * 0.52))
                check.addLine(to: CGPoint(x: box.minX + side * 0.44, y: box.minY + side * 0.69))
                check.addLine(to: CGPoint(x: box.minX + side * 0.75, y: box.minY + side * 0.33))
                check.lineWidth = 2
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                UIColor.systemBackground.setStroke()
                check.stroke()
            } else {
                path.lineWidth = 1.6
                LiveMarkdown.Theme.secondary.setStroke()
                path.stroke()
            }
        }
        // 內嵌圖片
        storage.enumerateAttribute(.mdImage, in: characters) { value, range, _ in
            guard let info = value as? MarkdownImageInfo, let image = images[info.name] else { return }
            let rect = lineRects(for: range)
            guard !rect.isNull else { return }
            let spacingBefore = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
            let frame = CGRect(x: rect.minX, y: rect.minY + spacingBefore, width: info.size.width, height: info.size.height)
            let clip = UIBezierPath(roundedRect: frame, cornerRadius: 8)
            UIGraphicsGetCurrentContext()?.saveGState()
            clip.addClip()
            image.draw(in: frame)
            UIGraphicsGetCurrentContext()?.restoreGState()
            LiveMarkdown.Theme.line.setStroke()
            clip.lineWidth = 1
            clip.stroke()
        }
    }
}
