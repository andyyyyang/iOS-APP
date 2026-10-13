import SwiftUI
import UIKit

/// Markdown 的區塊（涵蓋 Obsidian 筆記常用的語法）。
enum MarkdownBlock: Equatable {
    case properties([(key: String, value: String)])
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: ListMarker, indent: Int, text: String)
    case quote(String)
    case callout(kind: String, title: String, body: String)
    case code(language: String, code: String)
    /// `![[檔名]]` 或 `![說明](網址)`。
    case embed(String)
    case rule
    case table([String])

    enum ListMarker: Equatable {
        case bullet
        case number(String)
        case task(Bool)
    }

    static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool {
        switch (lhs, rhs) {
        case (.properties(let a), .properties(let b)): return a.map { "\($0.key)=\($0.value)" } == b.map { "\($0.key)=\($0.value)" }
        case (.heading(let a1, let a2), .heading(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.paragraph(let a), .paragraph(let b)): return a == b
        case (.listItem(let a1, let a2, let a3), .listItem(let b1, let b2, let b3)): return a1 == b1 && a2 == b2 && a3 == b3
        case (.quote(let a), .quote(let b)): return a == b
        case (.callout(let a1, let a2, let a3), .callout(let b1, let b2, let b3)): return a1 == b1 && a2 == b2 && a3 == b3
        case (.code(let a1, let a2), .code(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.embed(let a), .embed(let b)): return a == b
        case (.rule, .rule): return true
        case (.table(let a), .table(let b)): return a == b
        default: return false
        }
    }
}

/// 把 Markdown 文字切成區塊（純函式，方便測試）。
enum MarkdownParser {
    static func blocks(from text: String) -> [MarkdownBlock] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []

        // YAML frontmatter → 屬性
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            blocks.append(.properties(properties(from: Array(lines[1..<end]))))
            lines = Array(lines[(end + 1)...])
        }

        var paragraph: [String] = []
        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language, code: code.joined(separator: "\n")))
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            // HTML 註解（例如 App 管理區段的標記）在 Obsidian 中不顯示
            if trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->") {
                flushParagraph()
                index += 1
                continue
            }
            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var content = lines[index].trimmingCharacters(in: .whitespaces).dropFirst()
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                    quoted.append(String(content))
                    index += 1
                }
                blocks.append(quoteBlock(quoted))
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph()
                var rows: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.table(rows))
                continue
            }
            if let embed = embed(trimmed) {
                flushParagraph()
                blocks.append(.embed(embed))
                index += 1
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
                index += 1
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func properties(from lines: [String]) -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- "), let last = result.popLast() {
                // YAML 清單：接在上一個屬性後面
                let item = unquote(String(trimmed.dropFirst(2)))
                result.append((last.key, last.value.isEmpty ? item : last.value + ", " + item))
            } else if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = unquote(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
                result.append((key, value))
            }
        }
        return result
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last, first == last, first == "\"" || first == "'" else { return text }
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func quoteBlock(_ lines: [String]) -> MarkdownBlock {
        // Obsidian callout：> [!note] 標題
        if let first = lines.first, first.hasPrefix("[!"), let close = first.firstIndex(of: "]") {
            var kind = String(first[first.index(first.startIndex, offsetBy: 2)..<close]).lowercased()
            if kind.hasSuffix("-") || kind.hasSuffix("+") { kind.removeLast() }
            var title = String(first[first.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if title.hasPrefix("-") || title.hasPrefix("+") { title = String(title.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return .callout(kind: kind, title: title, body: lines.dropFirst().joined(separator: "\n"))
        }
        return .quote(lines.joined(separator: "\n"))
    }

    private static func embed(_ line: String) -> String? {
        if line.hasPrefix("![["), line.hasSuffix("]]") {
            let inner = String(line.dropFirst(3).dropLast(2))
            return String(inner.split(separator: "|", maxSplits: 1).first ?? Substring(inner))
        }
        if line.hasPrefix("!["), line.hasSuffix(")"), let open = line.range(of: "](") {
            return String(line[open.upperBound..<line.index(before: line.endIndex)])
        }
        return nil
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indentWidth = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let indent = indentWidth / 2
        let body = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            let text = String(body.dropFirst(2))
            if text.hasPrefix("[ ] ") { return .listItem(marker: .task(false), indent: indent, text: String(text.dropFirst(4))) }
            if text.lowercased().hasPrefix("[x] ") { return .listItem(marker: .task(true), indent: indent, text: String(text.dropFirst(4))) }
            return .listItem(marker: .bullet, indent: indent, text: text)
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(". ") {
            return .listItem(marker: .number(String(digits)), indent: indent, text: String(body.dropFirst(digits.count + 2)))
        }
        return nil
    }
}

/// 行內語法：粗體、斜體、程式碼、連結，以及 Obsidian 的 [[連結]]、==螢光==。
enum MarkdownInline {
    static let wikiScheme = "vault-note"

    static func attributed(_ text: String) -> AttributedString {
        var converted = text
        // [[目標|顯示文字]] → 可點的連結
        converted = replace(#"\[\[([^\]\|]+)\|([^\]]+)\]\]"#, in: converted) { groups in
            "[\(groups[1])](\(wikiScheme):\(encode(groups[0])))"
        }
        converted = replace(#"\[\[([^\]]+)\]\]"#, in: converted) { groups in
            "[\(groups[0])](\(wikiScheme):\(encode(groups[0])))"
        }
        converted = replace(#"==([^=]+)=="#, in: converted) { groups in "**\(groups[0])**" }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: converted, options: options)) ?? AttributedString(text)
    }

    /// 連結網址中的目標筆記名稱。
    static func wikiTarget(from url: URL) -> String? {
        guard url.scheme == wikiScheme else { return nil }
        let raw = url.absoluteString.dropFirst(wikiScheme.count + 1)
        let target = String(raw).removingPercentEncoding ?? String(raw)
        return String(target.split(separator: "#").first ?? Substring(target))
    }

    /// 除了 ASCII 英數字全部編碼（中文與 # 也要編碼，網址才會有效）。
    private static func encode(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func replace(_ pattern: String, in text: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let groups = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(groups))
        }
        return result
    }
}

/// 顯示 Markdown 筆記。`loadEmbed` 依檔名載入內嵌的圖片；點 [[連結]] 時呼叫 `onOpenLink`；
/// 點待辦方框時呼叫 `onToggleTask`（第幾個待辦）；點內嵌圖片時呼叫 `onTapEmbed`（例如編輯手寫區塊）。
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    /// 區塊序號 → 第幾個待辦。
    private let taskIndices: [Int: Int]
    var loadEmbed: (String) async -> UIImage? = { _ in nil }
    var onOpenLink: (String) -> Void = { _ in }
    var onToggleTask: ((Int) -> Void)?
    var onTapEmbed: ((String) -> Void)?

    init(
        text: String,
        loadEmbed: @escaping (String) async -> UIImage? = { _ in nil },
        onOpenLink: @escaping (String) -> Void = { _ in },
        onToggleTask: ((Int) -> Void)? = nil,
        onTapEmbed: ((String) -> Void)? = nil
    ) {
        blocks = MarkdownParser.blocks(from: text)
        var indices: [Int: Int] = [:]
        var count = 0
        for (offset, block) in blocks.enumerated() {
            if case .listItem(.task, _, _) = block {
                indices[offset] = count
                count += 1
            }
        }
        taskIndices = indices
        self.loadEmbed = loadEmbed
        self.onOpenLink = onOpenLink
        self.onToggleTask = onToggleTask
        self.onTapEmbed = onTapEmbed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                view(for: block, at: offset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if let target = MarkdownInline.wikiTarget(from: url) {
                onOpenLink(target)
                return .handled
            }
            return .systemAction
        })
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock, at offset: Int) -> some View {
        switch block {
        case .properties(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.key)
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text(item.value)
                            .textSelection(.enabled)
                    }
                    .font(.footnote)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .heading(let level, let text):
            Text(MarkdownInline.attributed(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            Text(MarkdownInline.attributed(text))
                .textSelection(.enabled)
        case .listItem(let marker, let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                switch marker {
                case .bullet:
                    Text("•").foregroundStyle(.secondary)
                case .number(let number):
                    Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
                case .task(let done):
                    Button {
                        if let index = taskIndices[offset] { onToggleTask?(index) }
                    } label: {
                        Image(systemName: done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(done ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(onToggleTask == nil)
                    .accessibilityLabel(done ? "標為未完成" : "標為完成")
                }
                Text(MarkdownInline.attributed(text))
                    .strikethrough(marker == .task(true))
                    .foregroundStyle(marker == .task(true) ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 20)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3)
                Text(MarkdownInline.attributed(text)).foregroundStyle(.secondary)
            }
        case .callout(let kind, let title, let body):
            CalloutView(kind: kind, title: title, content: body)
        case .code(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .embed(let name):
            if let onTapEmbed {
                Button {
                    onTapEmbed(name)
                } label: {
                    EmbeddedImage(name: name, load: loadEmbed)
                        .overlay(alignment: .topTrailing) {
                            if InkFiles.blockName(fromEmbed: name) != nil {
                                Image(systemName: "pencil.tip.crop.circle.fill")
                                    .font(.title2)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                                    .padding(8)
                            }
                        }
                }
                .buttonStyle(.plain)
            } else {
                EmbeddedImage(name: name, load: loadEmbed)
            }
        case .rule:
            Divider()
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(rows.filter { !$0.contains("---") }.joined(separator: "\n"))
                    .font(.system(.footnote, design: .monospaced))
                    .padding(10)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.weight(.semibold)
        default: return .headline
        }
    }
}

private struct CalloutView: View {
    let kind: String
    let title: String
    let content: String

    private var style: (icon: String, color: Color) {
        switch kind {
        case "summary", "abstract", "tldr": return ("doc.text.magnifyingglass", .teal)
        case "tip", "hint", "important": return ("flame", .orange)
        case "warning", "caution", "attention": return ("exclamationmark.triangle", .orange)
        case "danger", "error", "bug", "failure": return ("xmark.octagon", .red)
        case "success", "check", "done": return ("checkmark.circle", .green)
        case "question", "help", "faq": return ("questionmark.circle", .yellow)
        case "todo": return ("checklist", .blue)
        case "quote", "cite": return ("quote.opening", .gray)
        default: return ("info.circle", .blue)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title.isEmpty ? kind.capitalized : title, systemImage: style.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(style.color)
            if !content.isEmpty {
                Text(MarkdownInline.attributed(content))
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct EmbeddedImage: View {
    let name: String
    let load: (String) async -> UIImage?
    @State private var image: UIImage?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            } else if didLoad {
                Label(name, systemImage: "doc")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .task(id: name) {
            image = await load(name)
            didLoad = true
        }
    }
}
