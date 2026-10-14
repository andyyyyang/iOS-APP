import Foundation

/// LocalOCR 伺服器的 MCP（Streamable HTTP、無狀態、JSON 回應）：AI 透過它在線上搜尋、讀取與修改 vault，
/// 不必把筆記下載到這台裝置。工具與 Claude 等 agent 使用的相同（vault_search、vault_read、vault_list、vault_write）。
struct VaultMCPClient: Sendable {
    let baseURL: URL
    let apiKey: String
    var session: URLSession = .shared

    static func configured() -> VaultMCPClient? {
        guard let url = ServerSettings.baseURL, let key = ServerSettings.apiKey, !key.isEmpty else { return nil }
        return VaultMCPClient(baseURL: url, apiKey: key)
    }

    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 呼叫一個 MCP 工具，回傳各段文字內容。工具回報錯誤（isError）時丟出 ToolError。
    func callTool(_ name: String, arguments: [String: Any]) async throws -> [String] {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1...1_000_000),
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ]
        guard let url = URL(string: baseURL.absoluteString + "/mcp") else { throw ToolError(message: "伺服器網址不正確") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(VaultClient.clientID, forHTTPHeaderField: "X-LocalOCR-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ToolError(message: "無法連線到伺服器：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw ToolError(message: "伺服器沒有回應") }
        guard (200..<300).contains(http.statusCode) else {
            throw ToolError(message: http.statusCode == 401 ? "伺服器 API 金鑰不正確" : "伺服器回應錯誤（HTTP \(http.statusCode)）")
        }
        return try Self.parseToolResult(Self.jsonPayload(from: data))
    }

    /// 回應可能是 JSON，也可能是 SSE（data: {...}）。
    static func jsonPayload(from data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespaces).hasPrefix("{") else { return data }
        let lines = text.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }
        guard let last = lines.last else { return data }
        return Data(last.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
    }

    static func parseToolResult(_ data: Data) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError(message: "MCP 回應格式不正確")
        }
        if let error = object["error"] as? [String: Any] {
            throw ToolError(message: error["message"] as? String ?? "MCP 錯誤")
        }
        guard let result = object["result"] as? [String: Any] else { throw ToolError(message: "MCP 回應格式不正確") }
        let texts = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        if result["isError"] as? Bool == true {
            throw ToolError(message: texts.joined(separator: "\n"))
        }
        return texts
    }

    // MARK: vault 工具

    struct SearchHit: Equatable, Sendable {
        let path: String
        let snippet: String
    }

    struct Note: Equatable, Sendable {
        let path: String
        let etag: String
        let content: String
    }

    func search(_ query: String, limit: Int = 8) async throws -> [SearchHit] {
        let texts = try await callTool("vault_search", arguments: ["query": query, "limit": limit])
        guard let first = texts.first, let object = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any] else { return [] }
        return (object["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let path = item["path"] as? String else { return nil }
            return SearchHit(path: path, snippet: (item["snippet"] as? String ?? "").replacingOccurrences(of: "\n", with: " "))
        }
    }

    /// 讀取筆記；不存在時回傳 nil。
    func read(_ path: String) async throws -> Note? {
        let texts: [String]
        do {
            texts = try await callTool("vault_read", arguments: ["path": path])
        } catch let error as ToolError where error.message.contains("not_found") || error.message.contains("找不到") || error.message.contains("Not found") {
            return nil
        }
        guard let meta = texts.first, let object = try? JSONSerialization.jsonObject(with: Data(meta.utf8)) as? [String: Any] else { return nil }
        return Note(path: object["path"] as? String ?? path, etag: object["etag"] as? String ?? "", content: texts.count > 1 ? texts[1] : "")
    }

    func list(folder: String) async throws -> (files: [String], folders: [String]) {
        var arguments: [String: Any] = [:]
        if !folder.isEmpty { arguments["prefix"] = folder.hasSuffix("/") ? folder : folder + "/" }
        let texts = try await callTool("vault_list", arguments: arguments)
        guard let first = texts.first, let object = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any] else { return ([], []) }
        let files = (object["items"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        let folders = object["folders"] as? [String] ?? []
        return (files, folders)
    }

    /// 寫入筆記：`ifMatch` 為 nil 時只新增（已存在就失敗）。回傳新的 etag。
    @discardableResult
    func write(_ path: String, content: String, ifMatch: String?) async throws -> String {
        var arguments: [String: Any] = ["path": path, "content": content]
        if let ifMatch { arguments["ifMatch"] = ifMatch } else { arguments["createOnly"] = true }
        let texts = try await callTool("vault_write", arguments: arguments)
        guard let first = texts.first, let object = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any] else { return "" }
        return object["etag"] as? String ?? ""
    }
}
