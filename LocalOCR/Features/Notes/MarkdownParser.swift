import Foundation

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
