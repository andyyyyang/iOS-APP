import Foundation

/// 在既有筆記中插入 AI 整理的內容（放在屬性之後），並把標籤合併到屬性。
enum NoteMarkdownEditing {
    static func insertingInsights(_ insights: NoteInsights, into text: String) -> String {
        var block = ["> [!summary] AI 摘要"]
        block.append(contentsOf: insights.summary.split(whereSeparator: \.isNewline).map { "> \($0)" })
        if !insights.keyPoints.isEmpty {
            block.append(">")
            block.append(contentsOf: insights.keyPoints.map { "> - \($0)" })
        }
        let callout = block.joined(separator: "\n") + "\n\n"

        var lines = text.components(separatedBy: "\n")
        var frontmatter: [String] = []
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            frontmatter = Array(lines[0...end])
            lines = Array(lines[(end + 1)...])
        }
        let tags = insights.tags.map(NoteIntelligence.cleanTag).filter { !$0.isEmpty }
        frontmatter = mergingTags(tags, into: frontmatter)
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        let head = frontmatter.isEmpty ? "" : frontmatter.joined(separator: "\n") + "\n\n"
        return head + callout + body + (body.isEmpty ? "" : "\n")
    }

    /// 合併標籤到 YAML 屬性（沒有屬性時建立）。只處理清單或單行陣列格式的 tags。
    static func mergingTags(_ tags: [String], into frontmatter: [String]) -> [String] {
        guard !tags.isEmpty else { return frontmatter }
        var lines = frontmatter.isEmpty ? ["---", "---"] : frontmatter
        let closing = lines.count - 1
        if let index = lines.firstIndex(where: { $0.hasPrefix("tags:") }) {
            let inline = lines[index].dropFirst(5).trimmingCharacters(in: .whitespaces)
            var existing: [String] = []
            var end = index + 1
            if inline.hasPrefix("[") {
                existing = inline.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            } else if !inline.isEmpty {
                existing = [inline]
            }
            while end < closing, lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                existing.append(lines[end].trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))
                end += 1
            }
            let merged = existing + tags.filter { !existing.contains($0) }
            lines.replaceSubrange(index..<end, with: ["tags:"] + merged.map { "  - \($0)" })
        } else {
            lines.insert(contentsOf: ["tags:"] + tags.map { "  - \($0)" }, at: closing)
        }
        return lines
    }

    /// 合併標籤到整篇 Markdown 的屬性中。
    static func mergingTagsInto(markdown text: String, tags: [String]) -> String {
        guard !tags.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            let merged = mergingTags(tags, into: Array(lines[0...end]))
            lines.replaceSubrange(0...end, with: merged)
            return lines.joined(separator: "\n")
        }
        return mergingTags(tags, into: []).joined(separator: "\n") + "\n\n" + text
    }

    /// 切換第 `index` 個待辦（與閱讀模式顯示的順序相同：略過屬性、程式碼區塊與引用）。
    static func togglingTask(at index: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var count = 0
        var inCode = false
        var inFrontmatter = lines.first?.trimmingCharacters(in: .whitespaces) == "---"
        for lineIndex in lines.indices {
            let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            if inFrontmatter {
                if lineIndex > 0 && trimmed == "---" { inFrontmatter = false }
                continue
            }
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            guard !inCode else { continue }
            for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
                let rest = trimmed.dropFirst(2)
                let isOpen = rest.hasPrefix("[ ] ")
                let isDone = rest.lowercased().hasPrefix("[x] ")
                guard isOpen || isDone else { continue }
                if count == index, let range = lines[lineIndex].range(of: isOpen ? "[ ]" : (rest.hasPrefix("[x]") ? "[x]" : "[X]")) {
                    lines[lineIndex].replaceSubrange(range, with: isOpen ? "[x]" : "[ ]")
                    return lines.joined(separator: "\n")
                }
                count += 1
            }
        }
        return text
    }

    /// 在游標位置插入一段（前後補上換行，讓內嵌圖片自成一行）。
    static func inserting(_ snippet: String, into text: String, at location: Int) -> (text: String, cursor: Int) {
        let nsText = text as NSString
        let location = min(max(location, 0), nsText.length)
        let before = nsText.substring(to: location)
        let after = nsText.substring(from: location)
        let prefix = before.isEmpty || before.hasSuffix("\n") ? "" : "\n"
        let suffix = after.hasPrefix("\n") ? "" : "\n"
        let insertion = prefix + snippet + suffix
        return (before + insertion + after, (before as NSString).length + (insertion as NSString).length)
    }
}
