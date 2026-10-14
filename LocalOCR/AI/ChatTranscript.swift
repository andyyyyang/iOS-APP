import Foundation

/// AI 對話紀錄：每段對話是 vault 中的一則筆記（預設在「AI 對話」資料夾），每問一次就在最後加上一組問答。
/// 格式與伺服器的雲端 AI 寫入的相同，所以同一段對話裡裝置端與雲端的回答都記在一起：
///
///     ---
///     type: ai-chat
///     created: 2026-10-14T11:55:00+08:00
///     tags: [ai-chat]
///     ---
///
///     ## 🙋 2026-10-14 11:55
///     問題
///
///     ## 🤖 裝置端 AI
///     回答
///
///     > 來源：[[A]]、[[B]]
///     > 修改：新增 [[X]]；修改 [[Y]]
enum ChatTranscript {
    static let questionMarker = "## 🙋"
    static let answerMarker = "## 🤖"
    static let sourcesPrefix = "> 來源："
    static let editsPrefix = "> 修改："

    enum Engine: String {
        case device = "裝置端 AI"
        case cloud = "雲端 AI"
        case search = "搜尋結果"
    }

    static func header(created: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return "---\ntype: ai-chat\ncreated: \(formatter.string(from: created))\ntags: [ai-chat]\n---\n"
    }

    static func turn(question: String, answer: String, engine: Engine, sources: [String], edits: [AgentEdit], date: Date, timeZone: TimeZone) -> String {
        var lines = [
            "\(questionMarker) \(timestamp(date, timeZone: timeZone))",
            question.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            "\(answerMarker) \(engine.rawValue)",
            answer.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        var footer: [String] = []
        let names = uniqued(sources.map(title(of:)))
        if !names.isEmpty { footer.append(sourcesPrefix + names.map { "[[\($0)]]" }.joined(separator: "、")) }
        if !edits.isEmpty { footer.append(editsPrefix + edits.map(describe).joined(separator: "；")) }
        if !footer.isEmpty { lines += [""] + footer }
        return lines.joined(separator: "\n") + "\n"
    }

    static func describe(_ edit: AgentEdit) -> String {
        switch edit.op {
        case .create: return "新增 [[\(title(of: edit.path))]]"
        case .update: return "修改 [[\(title(of: edit.path))]]"
        case .move: return "搬移 [[\(title(of: edit.from ?? edit.path))]] → [[\(title(of: edit.path))]]"
        case .delete: return "刪除 [[\(title(of: edit.path))]]"
        }
    }

    /// 把一組問答加到紀錄的最後（沒有紀錄時建立）。
    static func appending(_ turn: String, to existing: String?, created: Date, timeZone: TimeZone) -> String {
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return header(created: created, timeZone: timeZone) + "\n" + turn
        }
        var base = existing
        while base.hasSuffix("\n\n") { base.removeLast() }
        if !base.hasSuffix("\n") { base += "\n" }
        return base + "\n" + turn
    }

    /// 新對話的檔名：「2026-10-14 1155 第一個問題.md」。
    static func fileName(for question: String, date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|#^[]\n\r\t")
        var title = question.components(separatedBy: forbidden).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        if title.count > 24 { title = String(title.prefix(24)) }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " .。？?！!，,、：；"))
        return "\(formatter.string(from: date))\(title.isEmpty ? "" : " " + title).md"
    }

    /// 讀回紀錄中的問答（打開以前的對話時）。
    static func parse(_ text: String) -> [AssistantMessage] {
        var messages: [AssistantMessage] = []
        var role: AssistantMessage.Role?
        var body: [String] = []
        var engine: Engine?

        func flush() {
            guard let role else { return }
            var lines = body
            var sources: [String] = []
            var footnotes: [String] = []
            while let last = lines.last?.trimmingCharacters(in: .whitespaces), last.isEmpty || last.hasPrefix(sourcesPrefix) || last.hasPrefix(editsPrefix) {
                lines.removeLast()
                if last.hasPrefix(sourcesPrefix) {
                    sources = linkNames(in: String(last.dropFirst(sourcesPrefix.count)))
                } else if last.hasPrefix(editsPrefix) {
                    footnotes.insert(String(last.dropFirst(2)), at: 0)
                }
            }
            var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !footnotes.isEmpty { text += (text.isEmpty ? "" : "\n\n") + footnotes.joined(separator: "\n") }
            var message = AssistantMessage(role: role, text: text)
            message.sources = sources
            if role == .assistant { message.engine = engine.map(AssistantMessage.Engine.init) }
            messages.append(message)
        }

        var inFrontmatter = false
        for (index, line) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
            if index == 0 && line == "---" {
                inFrontmatter = true
                continue
            }
            if inFrontmatter {
                if line == "---" { inFrontmatter = false }
                continue
            }
            if line.hasPrefix(questionMarker) {
                flush()
                role = .user
                body = []
            } else if line.hasPrefix(answerMarker) {
                flush()
                role = .assistant
                body = []
                engine = Engine(rawValue: line.dropFirst(answerMarker.count).trimmingCharacters(in: .whitespaces))
            } else if role != nil {
                body.append(line)
            }
        }
        flush()
        return messages
    }

    static func title(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    private static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func linkNames(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\]\|]+)(?:\|[^\]]*)?\]\]"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    private static func uniqued(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }
}

/// 把對話寫進 vault（透過伺服器的 MCP，不經過這台裝置的同步）。
enum ChatTranscriptWriter {
    /// 加上一組問答；檔案在這之間被改過（例如伺服器剛寫入雲端 AI 的回答）時重新讀取再寫。
    static func append(_ turn: String, to path: String, created: Date, timeZone: TimeZone = .current, mcp: VaultMCPClient) async throws {
        for attempt in 0..<3 {
            let existing = try await mcp.read(path)
            let content = ChatTranscript.appending(turn, to: existing?.content, created: created, timeZone: timeZone)
            do {
                try await mcp.write(path, content: content, ifMatch: existing?.etag)
                return
            } catch where attempt < 2 && error.localizedDescription.contains("precondition_failed") {
                continue
            }
        }
    }
}
