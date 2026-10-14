import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - 知識庫 AI（首頁）
//
// 像 Cowork：在首頁問問題或下指令，裝置端的 Apple Intelligence 透過 LocalOCR 伺服器的 MCP
// 在線上搜尋、閱讀、修改 vault（不下載到這台裝置），回答時附上來源筆記；修改過的筆記可以復原。
// 每次對話前讀取 vault 的編輯規則，修改時照著做。

/// AI 改過的一則筆記（可以復原）。
struct AgentEdit: Identifiable, Equatable, Sendable {
    enum Op: String, Sendable {
        case create, update, move, delete
    }

    /// 裝置端是自己產生的代碼，雲端是伺服器的修改代碼。
    let id: String
    let op: Op
    /// 搬移時是新的位置。
    let path: String
    var from: String?
    let summary: String
    /// 裝置端：修改前的內容（新增的筆記是 nil，復原時刪除）。
    var previous: String?
    /// 裝置端：修改後的版本（復原時確認沒有被別人改過）。
    var etag: String = ""
    /// 雲端：所屬的工作（復原由伺服器處理）。
    var runID: String?

    /// 裝置端的修改。
    init(path: String, summary: String, previous: String?, etag: String) {
        id = UUID().uuidString
        op = previous == nil ? .create : .update
        self.path = path
        self.summary = summary
        self.previous = previous
        self.etag = etag
    }

    /// 雲端 AI 的修改。
    init(_ edit: AssistantClient.Edit, runID: String) {
        id = edit.id
        op = Op(rawValue: edit.op) ?? .update
        path = edit.path
        from = edit.from
        summary = edit.summary
        self.runID = runID
    }
}

/// AI 做的事（畫面上顯示成一列）。
enum AgentStep: Equatable, Sendable {
    case search(query: String, count: Int)
    case read(path: String)
    case list(folder: String)
    case edit(AgentEdit)
    case failed(String)
    /// Jev 的判斷（交給哪個 AI）。
    case route(String)
    /// 雲端 AI 使用的工具（伺服器給的說明）。
    case tool(String)
    /// 雲端 AI 在工具之間說的話。
    case narration(String)
    /// 雲端 AI 在沙盒中產生、存進 vault 的檔案。
    case file(String)
}

/// 工具執行時回報的事件。
enum AgentEvent: Sendable {
    case step(AgentStep)
    /// 搜尋找到的筆記（回答中提到時列為來源）。
    case found(String)
    /// 讀過原文的筆記（一定列為來源）。
    case read(String)
}

/// 工具在背景執行，透過它回報給畫面。
struct AgentEventSink: Sendable {
    let send: @Sendable (AgentEvent) async -> Void
}

struct AssistantMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    /// 回答這則訊息的 AI。
    enum Engine: Equatable {
        case device
        case cloud(model: String)
        case search

        init(_ engine: ChatTranscript.Engine) {
            switch engine {
            case .device: self = .device
            case .cloud: self = .cloud(model: "")
            case .search: self = .search
            }
        }

        var transcript: ChatTranscript.Engine {
            switch self {
            case .device: return .device
            case .cloud: return .cloud
            case .search: return .search
            }
        }

        var label: String {
            switch self {
            case .device: return "裝置端 AI"
            case .cloud: return "雲端 AI"
            case .search: return "搜尋結果"
            }
        }
    }

    let id = UUID()
    let role: Role
    var text: String
    var steps: [AgentStep] = []
    /// 來源筆記的路徑（舊紀錄中是筆記名稱）。
    var sources: [String] = []
    var isError = false
    var engine: Engine?
    /// 雲端工作的代碼（停止、復原用）。
    var runID: String?

    var edits: [AgentEdit] {
        steps.compactMap { step in
            if case .edit(let edit) = step { return edit }
            return nil
        }
    }
}

/// 修改筆記的純函式（方便測試）。
enum KnowledgeEditing {
    /// 正規化 AI 給的路徑：去掉 [[ ]] 與 |別名，補上 .md。
    static func normalizedPath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]「」\"'"))
        if let bar = path.firstIndex(of: "|") { path = String(path[..<bar]) }
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !path.lowercased().hasSuffix(".md") { path += ".md" }
        return LocalVault.normalize(path)
    }

    /// 把文字加到某個標題的段落最後（找不到標題時在最後新增這個標題）；沒有指定標題時加在筆記最後。
    static func appending(_ text: String, under heading: String?, in content: String) -> String {
        let added = text.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        let heading = heading?.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces)) ?? ""
        var lines = content.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }

        func level(_ line: String) -> Int? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hashes = trimmed.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes), trimmed.dropFirst(hashes).hasPrefix(" ") else { return nil }
            return hashes
        }
        func title(_ line: String) -> String {
            line.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
        }
        /// 清單接清單不留空行，其他段落之間留一個空行。
        func needsBlankLine(after previous: String?) -> Bool {
            guard let previous, !previous.trimmingCharacters(in: .whitespaces).isEmpty, level(previous) == nil else { return false }
            return !(isListItem(previous) && isListItem(added[0]))
        }

        guard !heading.isEmpty else {
            return (lines + (needsBlankLine(after: lines.last) ? [""] : []) + added).joined(separator: "\n") + "\n"
        }
        guard let start = lines.firstIndex(where: { level($0) != nil && title($0) == heading.lowercased() }),
              let headingLevel = level(lines[start]) else {
            let separator = lines.isEmpty ? [] : [""]
            return (lines + separator + ["## \(heading)"] + added).joined(separator: "\n") + "\n"
        }
        var end = lines.count
        if start + 1 < lines.count {
            for index in (start + 1)..<lines.count {
                if let other = level(lines[index]), other <= headingLevel {
                    end = index
                    break
                }
            }
        }
        // 段落最後的空行之前插入
        var insertAt = end
        while insertAt > start + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        var block = added
        if needsBlankLine(after: lines[insertAt - 1]) { block.insert("", at: 0) }
        // 下一個標題前留一個空行
        if insertAt < lines.count, !lines[insertAt].trimmingCharacters(in: .whitespaces).isEmpty { block.append("") }
        lines.insert(contentsOf: block, at: insertAt)
        return lines.joined(separator: "\n") + "\n"
    }

    static func isListItem(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
        let digits = trimmed.prefix { $0.isNumber }
        return !digits.isEmpty && trimmed.dropFirst(digits.count).hasPrefix(". ")
    }

    /// 長筆記分段給模型讀（裝置端模型的上下文有限）。
    static func part(_ content: String, number: Int, size: Int = 1000) -> (text: String, number: Int, total: Int) {
        let characters = Array(content)
        let total = max(1, Int(ceil(Double(characters.count) / Double(size))))
        let index = min(max(number, 1), total)
        let start = (index - 1) * size
        let end = min(start + size, characters.count)
        return (String(characters[start..<end]), index, total)
    }
}

/// 依名稱或路徑找到筆記（AI 常只給名稱）。
enum KnowledgeLookup {
    static func note(_ raw: String, mcp: VaultMCPClient) async throws -> VaultMCPClient.Note? {
        let path = KnowledgeEditing.normalizedPath(raw)
        if let note = try await mcp.read(path) { return note }
        let name = (path as NSString).lastPathComponent.lowercased()
        let hits = try await mcp.search(String((path as NSString).lastPathComponent.dropLast(3)), limit: 20)
        if let hit = hits.first(where: { ($0.path as NSString).lastPathComponent.lowercased() == name }) {
            return try await mcp.read(hit.path)
        }
        return nil
    }
}

#if canImport(FoundationModels)

// MARK: - 工具

@available(iOS 26.0, *)
struct SearchNotesTool: Tool {
    let name = "searchNotes"
    let description = "在使用者的 Obsidian 知識庫中搜尋筆記的檔名與內容，回傳筆記路徑與符合處的摘錄。回答關於筆記的問題前要先搜尋。"
    let mcp: VaultMCPClient
    let sink: AgentEventSink
    /// 不搜尋的資料夾（AI 對話紀錄，避免引用自己以前的回答）。
    var excludedFolder: String?

    @Generable
    struct Arguments {
        @Guide(description: "搜尋的關鍵字，一到三個詞")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            var hits = try await mcp.search(arguments.query, limit: 8)
            if let excludedFolder, !excludedFolder.isEmpty {
                hits.removeAll { $0.path.hasPrefix(excludedFolder + "/") }
            }
            hits = Array(hits.prefix(5))
            await sink.send(.step(.search(query: arguments.query, count: hits.count)))
            guard !hits.isEmpty else { return "沒有找到符合「\(arguments.query)」的筆記，可以換個關鍵字再搜尋。" }
            for hit in hits { await sink.send(.found(hit.path)) }
            return hits.map { "- \($0.path)：\(String($0.snippet.prefix(100)))" }.joined(separator: "\n")
        } catch {
            await sink.send(.step(.failed("搜尋失敗：\(error.localizedDescription)")))
            return "搜尋失敗：\(error.localizedDescription)"
        }
    }
}

@available(iOS 26.0, *)
struct ReadNoteTool: Tool {
    let name = "readNote"
    let description = "讀取一則筆記的原文。長筆記分段讀取，回傳中會說明共有幾段。"
    let mcp: VaultMCPClient
    let sink: AgentEventSink

    @Generable
    struct Arguments {
        @Guide(description: "筆記的路徑（例如「工作/會議紀錄.md」）或名稱")
        var path: String
        @Guide(description: "第幾段，從 1 開始；第一次讀不用填")
        var part: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            guard let note = try await KnowledgeLookup.note(arguments.path, mcp: mcp) else {
                return "找不到「\(arguments.path)」這則筆記，請先用 searchNotes 搜尋正確的路徑。"
            }
            await sink.send(.read(note.path))
            await sink.send(.step(.read(path: note.path)))
            let part = KnowledgeEditing.part(note.content, number: arguments.part ?? 1)
            let more = part.number < part.total ? "\n（還有第 \(part.number + 1)～\(part.total) 段，需要時用 part 讀取）" : ""
            return "路徑：\(note.path)（第 \(part.number)/\(part.total) 段）\n\(part.text)\(more)"
        } catch {
            await sink.send(.step(.failed("讀取失敗：\(error.localizedDescription)")))
            return "讀取失敗：\(error.localizedDescription)"
        }
    }
}

@available(iOS 26.0, *)
struct ListFolderTool: Tool {
    let name = "listFolder"
    let description = "列出知識庫某個資料夾中的子資料夾與筆記；空字串是最上層。"
    let mcp: VaultMCPClient
    let sink: AgentEventSink

    @Generable
    struct Arguments {
        @Guide(description: "資料夾路徑，最上層用空字串")
        var folder: String
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            let folder = arguments.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let result = try await mcp.list(folder: folder)
            await sink.send(.step(.list(folder: folder)))
            let folders = result.folders.filter { !$0.hasPrefix(".") }.prefix(40).joined(separator: "、")
            let files = result.files.filter { $0.hasSuffix(".md") }.prefix(40).joined(separator: "、")
            return "資料夾：\(folder.isEmpty ? "（最上層）" : folder)\n子資料夾：\(folders.isEmpty ? "無" : folders)\n筆記：\(files.isEmpty ? "無" : files)"
        } catch {
            return "列出失敗：\(error.localizedDescription)"
        }
    }
}

@available(iOS 26.0, *)
struct CreateNoteTool: Tool {
    let name = "createNote"
    let description = "新增一則筆記（Markdown）。已經有同名的筆記時會失敗，改用 appendToNote 或 replaceInNote。"
    let mcp: VaultMCPClient
    let sink: AgentEventSink

    @Generable
    struct Arguments {
        @Guide(description: "新筆記的路徑，例如「收件匣/會議重點.md」")
        var path: String
        @Guide(description: "筆記的完整 Markdown 內容")
        var content: String
    }

    func call(arguments: Arguments) async throws -> String {
        let path = KnowledgeEditing.normalizedPath(arguments.path)
        do {
            let etag = try await mcp.write(path, content: arguments.content, ifMatch: nil)
            await sink.send(.step(.edit(AgentEdit(path: path, summary: "新增筆記", previous: nil, etag: etag))))
            await sink.send(.read(path))
            return "已新增 \(path)。"
        } catch {
            if error.localizedDescription.contains("precondition_failed") {
                return "已經有 \(path) 這則筆記，請改用 appendToNote 或 replaceInNote。"
            }
            await sink.send(.step(.failed("新增失敗：\(error.localizedDescription)")))
            return "新增失敗：\(error.localizedDescription)"
        }
    }
}

@available(iOS 26.0, *)
struct AppendToNoteTool: Tool {
    let name = "appendToNote"
    let description = "在既有筆記加入內容：加在某個標題的段落最後，或筆記最後。原有內容不變。"
    let mcp: VaultMCPClient
    let sink: AgentEventSink

    @Generable
    struct Arguments {
        @Guide(description: "筆記的路徑或名稱")
        var path: String
        @Guide(description: "要加入的 Markdown 文字")
        var text: String
        @Guide(description: "加在哪個標題的段落（不含 #）；不填就加在最後")
        var heading: String?
    }

    func call(arguments: Arguments) async throws -> String {
        await KnowledgeWrite.modify(arguments.path, summary: "加入內容", mcp: mcp, sink: sink) { content in
            KnowledgeEditing.appending(arguments.text, under: arguments.heading, in: content)
        }
    }
}

@available(iOS 26.0, *)
struct ReplaceInNoteTool: Tool {
    let name = "replaceInNote"
    let description = "修改既有筆記的一段文字：把原文中完全相同的一段換成新的文字，其他內容不變。先用 readNote 讀取原文再修改。"
    let mcp: VaultMCPClient
    let sink: AgentEventSink

    @Generable
    struct Arguments {
        @Guide(description: "筆記的路徑或名稱")
        var path: String
        @Guide(description: "要被取代的原文（必須和筆記中的文字完全相同）")
        var original: String
        @Guide(description: "取代成的新文字")
        var replacement: String
    }

    func call(arguments: Arguments) async throws -> String {
        await KnowledgeWrite.modify(arguments.path, summary: "修改內容", mcp: mcp, sink: sink) { content in
            guard let range = content.range(of: arguments.original) else { return nil }
            return content.replacingCharacters(in: range, with: arguments.replacement)
        }
    }
}

/// 讀取 → 修改 → 帶 etag 寫回；中間被別人改過就重新讀取再試一次。
@available(iOS 26.0, *)
enum KnowledgeWrite {
    static func modify(_ raw: String, summary: String, mcp: VaultMCPClient, sink: AgentEventSink, transform: (String) -> String?) async -> String {
        do {
            for attempt in 0..<2 {
                guard let note = try await KnowledgeLookup.note(raw, mcp: mcp) else {
                    return "找不到「\(raw)」這則筆記。要新增的話請用 createNote。"
                }
                guard let updated = transform(note.content) else {
                    return "\(note.path) 中找不到要取代的原文，請先用 readNote 讀取，複製完全相同的文字再試。"
                }
                guard updated != note.content else { return "\(note.path) 沒有需要修改的地方。" }
                do {
                    let etag = try await mcp.write(note.path, content: updated, ifMatch: note.etag)
                    await sink.send(.step(.edit(AgentEdit(path: note.path, summary: summary, previous: note.content, etag: etag))))
                    await sink.send(.read(note.path))
                    return "已更新 \(note.path)。"
                } catch where attempt == 0 && error.localizedDescription.contains("precondition_failed") {
                    continue
                }
            }
            return "\(raw) 一直在別處被修改，沒有寫入。"
        } catch {
            await sink.send(.step(.failed("修改失敗：\(error.localizedDescription)")))
            return "修改失敗：\(error.localizedDescription)"
        }
    }
}

// MARK: - 對話

@available(iOS 26.0, *)
@MainActor
final class KnowledgeAgentSession {
    private var session: LanguageModelSession

    init(rules: String?, mcp: VaultMCPClient, sink: AgentEventSink, historyFolder: String?) {
        let tools: [any Tool] = [
            SearchNotesTool(mcp: mcp, sink: sink, excludedFolder: historyFolder),
            ReadNoteTool(mcp: mcp, sink: sink),
            ListFolderTool(mcp: mcp, sink: sink),
            CreateNoteTool(mcp: mcp, sink: sink),
            AppendToNoteTool(mcp: mcp, sink: sink),
            ReplaceInNoteTool(mcp: mcp, sink: sink),
        ]
        let instructions = Self.instructions(rules: rules)
        session = LanguageModelSession(model: OnDeviceModel.extraction, tools: tools, instructions: { instructions })
    }

    static func instructions(rules: String?) -> String {
        """
        你是使用者 Obsidian 知識庫的 AI 助理，可以搜尋、閱讀與修改筆記。筆記都在線上，只能透過工具取得：
        1. 回答關於筆記的問題前，先用 searchNotes 搜尋；需要細節時用 readNote 讀原文。只根據工具取得的內容回答，找不到就直接說找不到，不可以編造。
        2. 回答中用 [[筆記名稱]] 標出資訊的來源（名稱是不含 .md 的檔名）。
        3. 使用者要你記錄、整理、新增或修改筆記時，直接用 createNote、appendToNote 或 replaceInNote 完成，再簡短說明做了什麼。不要整篇改寫；保留原有內容、屬性（--- 區塊）、[[連結]] 與來源網址；新增的內容有出處時附上 [[來源筆記]] 或網址。
        4. 一定要遵守 vault 編輯規則。
        5. 用繁體中文，簡潔回答。
        vault 編輯規則：\(rules?.isEmpty == false ? "\n" + rules! : "（沒有）")
        """
    }

    func respond(to prompt: String) async throws -> String {
        try await session.respond(to: prompt).content
    }

    /// 超過上下文長度時。
    static func isContextOverflow(_ error: Error) -> Bool {
        // iOS 26 與 27 的錯誤型別不同，比對名稱
        let text = String(describing: error).lowercased()
        return text.contains("exceededcontextwindowsize") || text.contains("contextsizeexceeded")
    }
}
#endif
