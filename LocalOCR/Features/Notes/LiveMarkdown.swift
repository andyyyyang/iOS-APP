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
    /// 表格的直線位置（藏起來的「|」）。
    static let mdTablePipe = NSAttributedString.Key("localocr.md.tablePipe")
    /// 表格的一列（值：是否為標題列），畫框線與標題底色。
    static let mdTableRow = NSAttributedString.Key("localocr.md.tableRow")
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
                    styleCode(index...last)
                    index = last + 1
                    continue
                }
                if value.hasPrefix("|") {
                    var end = index
                    while end + 1 < lines.count, trimmed(end + 1).hasPrefix("|") { end += 1 }
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
                styleInline(line, active: isActive(line))
                index += 1
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
            styleInline(NSRange(location: line.location + hashes + spaces, length: line.length - hashes - spaces), active: active, baseFont: font)
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
            let separator = Patterns.tableSeparator
            func raw() {
                for index in indices {
                    storage.addAttribute(.font, value: Theme.monoFont, range: lines[index])
                    for pipe in pipes(in: lines[index]) {
                        storage.addAttribute(.foregroundColor, value: Theme.marker, range: NSRange(location: pipe, length: 1))
                    }
                }
            }
            guard !active, indices.count >= 2 else {
                raw()
                return
            }
            let hasHeader = separator.firstMatch(in: string(lines[indices.lowerBound + 1]), range: NSRange(location: 0, length: lines[indices.lowerBound + 1].length)) != nil
            var rows: [(line: NSRange, pipes: [Int], cells: [NSRange], header: Bool)] = []
            for index in indices {
                let line = lines[index]
                if hasHeader, index == indices.lowerBound + 1 {
                    hide(line, dimInstead: false)
                    continue
                }
                let header = hasHeader && index == indices.lowerBound
                let positions = pipes(in: line)
                var cells: [NSRange] = []
                for (offset, pipe) in positions.enumerated() {
                    let end = offset + 1 < positions.count ? positions[offset + 1] : NSMaxRange(line)
                    if offset + 1 == positions.count, end - pipe - 1 <= 0 { break }
                    if offset + 1 == positions.count, string(NSRange(location: pipe + 1, length: end - pipe - 1)).trimmingCharacters(in: .whitespaces).isEmpty { break }
                    cells.append(NSRange(location: pipe + 1, length: end - pipe - 1))
                }
                if header { storage.addAttribute(.font, value: Theme.bodyFont.withTraits(.traitBold), range: line) }
                for cell in cells { styleInline(cell, active: false, baseFont: header ? Theme.bodyFont.withTraits(.traitBold) : nil) }
                for pipe in positions {
                    storage.addAttributes(Theme.hidden, range: NSRange(location: pipe, length: 1))
                    storage.addAttribute(.mdTablePipe, value: true, range: NSRange(location: pipe, length: 1))
                }
                rows.append((line, positions, cells, header))
            }
            // 每一欄的寬度：最寬的儲存格加上左右留白；放不下時改顯示原始文字
            let padding: CGFloat = 10
            var columns: [CGFloat] = []
            for row in rows {
                for (column, cell) in row.cells.enumerated() {
                    let width = width(of: cell) + padding * 2
                    if column < columns.count { columns[column] = max(columns[column], width) } else { columns.append(width) }
                }
            }
            guard columns.reduce(0, +) + CGFloat(columns.count + 1) <= options.width else {
                for index in indices {
                    storage.setAttributes(Theme.bodyAttributes, range: paragraph(lines[index]))
                }
                raw()
                return
            }
            for row in rows {
                for (column, cell) in row.cells.enumerated() {
                    let opening = cell.location - 1
                    let cellWidth = width(of: cell)
                    if cell.length == 0 {
                        storage.addAttribute(.kern, value: columns[column], range: NSRange(location: opening, length: 1))
                    } else {
                        storage.addAttribute(.kern, value: padding, range: NSRange(location: opening, length: 1))
                        let last = NSRange(location: NSMaxRange(cell) - 1, length: 1)
                        let existing = storage.attribute(.kern, at: last.location, effectiveRange: nil) as? CGFloat ?? 0
                        storage.addAttribute(.kern, value: existing + columns[column] - padding - cellWidth, range: last)
                    }
                }
                storage.addAttribute(.mdTableRow, value: row.header, range: row.line)
                setParagraphStyle(Theme.paragraphStyle {
                    $0.lineSpacing = 0
                    $0.paragraphSpacingBefore = 6
                    $0.paragraphSpacing = 6
                }, lines: index(of: row.line)...index(of: row.line))
            }
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
        // 表格：標題列底色與框線
        storage.enumerateAttribute(.mdTableRow, in: characters) { value, range, _ in
            guard let header = value as? Bool else { return }
            let glyphs = NSIntersectionRange(glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphsToShow)
            guard glyphs.length > 0 else { return }
            var pipes: [CGFloat] = []
            storage.enumerateAttribute(.mdTablePipe, in: range) { pipe, pipeRange, _ in
                guard pipe != nil else { return }
                for index in pipeRange.location..<NSMaxRange(pipeRange) {
                    let glyph = glyphIndexForCharacter(at: index)
                    let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    pipes.append(line.minX + location(forGlyphAt: glyph).x + origin.x)
                }
            }
            let rect = lineRects(for: range)
            guard !rect.isNull, let left = pipes.min(), let right = pipes.max(), right > left else { return }
            let row = CGRect(x: left, y: rect.minY, width: right - left, height: rect.height)
            if header {
                LiveMarkdown.Theme.tableHeader.setFill()
                UIRectFill(row)
            }
            LiveMarkdown.Theme.line.setFill()
            UIRectFill(CGRect(x: row.minX, y: row.maxY - 0.5, width: row.width, height: 1))
            if header || range.location == 0 || storage.attribute(.mdTableRow, at: max(range.location - 2, 0), effectiveRange: nil) == nil {
                UIRectFill(CGRect(x: row.minX, y: row.minY - 0.5, width: row.width, height: 1))
            }
            for x in pipes {
                UIRectFill(CGRect(x: x - 0.5, y: row.minY, width: 1, height: row.height))
            }
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
