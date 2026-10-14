import Foundation

/// 伺服器上的雲端 AI（/v1/assistant/*）：Jev 判斷要求需不需要多步驟的工作，需要時交給伺服器上的 Claude，
/// 它把 vault 當成電腦的檔案系統來整理（搜尋、閱讀、新增、修改、搬移、刪除到 .trash），也能在沙盒中執行程式。
struct AssistantClient: Sendable {
    let baseURL: URL
    let apiKey: String
    var session: URLSession = .shared

    static func configured() -> AssistantClient? {
        guard let url = ServerSettings.baseURL, let key = ServerSettings.apiKey, !key.isEmpty else { return nil }
        return AssistantClient(baseURL: url, apiKey: key)
    }

    // MARK: 型別

    struct Route: Equatable, Sendable {
        /// question、edit 或 task。
        let kind: String
        /// device 或 cloud。
        let route: String
        let confidence: Double
        /// jev 或 heuristic。
        let provider: String
        let cloudAvailable: Bool
        /// simple、moderate 或 hard（有帶預算時）。
        var difficulty: String?
        /// device、small、medium 或 large（有帶預算時）。
        var tier: String?
        /// 那一級目前的模型。
        var model: String?
        /// 思考程度：low、medium 或 high。
        var effort: String?

        var isCloud: Bool { route == "cloud" }

        /// 「困難的多步驟工作」。
        var summary: String {
            let level: String
            switch difficulty {
            case "simple": level = "簡單的"
            case "moderate": level = "中等的"
            case "hard": level = "困難的"
            default: level = ""
            }
            let what: String
            switch kind {
            case "task": what = "多步驟工作"
            case "edit": what = "修改"
            default: what = "問題"
            }
            return level + what
        }
    }

    struct Edit: Equatable, Sendable {
        let id: String
        let op: String
        let path: String
        let from: String?
        let summary: String
        let undone: Bool
    }

    enum Event: Equatable, Sendable {
        case message(String)
        case tool(String)
        case edit(Edit)
        case file(String)
        case error(String)
    }

    struct Run: Equatable, Sendable {
        let id: String
        let status: String
        let model: String
        let events: [(seq: Int, event: Event)]
        let answer: String?
        let error: String?
        let sources: [String]
        let edits: [Edit]

        var isRunning: Bool { status == "running" }

        static func == (lhs: Run, rhs: Run) -> Bool {
            lhs.id == rhs.id && lhs.status == rhs.status && lhs.events.map(\.seq) == rhs.events.map(\.seq) && lhs.answer == rhs.answer
        }
    }

    struct HistoryTurn: Sendable {
        let role: String
        let text: String
    }

    // MARK: 端點

    /// 伺服器是否設定了雲端 AI（/health 的 assistant）。
    func isAvailable() async -> Bool {
        guard let value = try? await send("GET", "/health", authorized: false, timeout: 10) else { return false }
        return value["assistant"] as? Bool == true
    }

    /// 判斷這個要求交給誰。`budget`：low、medium 或 high（伺服器依種類與難度選裝置端或哪一級的雲端模型）。
    func route(_ text: String, context: String?, budget: String? = nil, deviceAvailable: Bool = true) async throws -> Route {
        var body: [String: Any] = ["text": String(text.prefix(4000))]
        if let context { body["context"] = String(context.prefix(2000)) }
        if let budget {
            body["budget"] = budget
            body["deviceAvailable"] = deviceAvailable
        }
        let value = try await send("POST", "/v1/assistant/route", body: body, timeout: 8)
        return Self.route(from: value)
    }

    /// 開始一個雲端工作。`rulesPath`：nil 自動尋找、空字串不使用規則；`tier`、`effort` 來自 route 的判斷（沒有時用最好的模型）。
    func startRun(
        prompt: String,
        history: [HistoryTurn],
        rulesPath: String?,
        openNote: String?,
        transcriptPath: String?,
        timeZone: TimeZone,
        tier: String? = nil,
        effort: String? = nil
    ) async throws -> Run {
        var body: [String: Any] = [
            "prompt": prompt,
            "history": history.suffix(12).map { ["role": $0.role, "text": String($0.text.prefix(4000))] },
            "timeZone": timeZone.identifier,
        ]
        if let rulesPath { body["rulesPath"] = rulesPath.isEmpty ? NSNull() : rulesPath }
        if let openNote { body["openNote"] = openNote }
        if let transcriptPath { body["transcriptPath"] = transcriptPath }
        if let tier { body["tier"] = tier }
        if let effort { body["effort"] = effort }
        let value = try await send("POST", "/v1/assistant/runs", body: body, timeout: 30)
        return Self.run(from: value)
    }

    /// 取得工作的新事件（`after` 之後）；沒有新事件時最多等 `wait` 秒。
    func run(_ id: String, after: Int, wait: Int = 25) async throws -> Run {
        let value = try await send("GET", "/v1/assistant/runs/\(Self.escape(id))?after=\(after)&wait=\(wait)", timeout: TimeInterval(wait + 15))
        return Self.run(from: value)
    }

    func cancel(_ id: String) async throws {
        _ = try await send("POST", "/v1/assistant/runs/\(Self.escape(id))/cancel", body: [:], timeout: 15)
    }

    /// 復原雲端 AI 做的修改，回傳成功復原的代碼與失敗原因。
    func undo(_ id: String, editIDs: [String]) async throws -> (undone: [String], failed: [String: String]) {
        let value = try await send("POST", "/v1/assistant/runs/\(Self.escape(id))/undo", body: ["editIds": editIDs], timeout: 30)
        var failed: [String: String] = [:]
        for item in value["failed"] as? [[String: Any]] ?? [] {
            if let id = item["id"] as? String { failed[id] = item["reason"] as? String ?? "無法復原" }
        }
        return (value["undone"] as? [String] ?? [], failed)
    }

    // MARK: 解析

    static func route(from value: [String: Any]) -> Route {
        Route(
            kind: value["kind"] as? String ?? "question",
            route: value["route"] as? String ?? "device",
            confidence: (value["confidence"] as? NSNumber)?.doubleValue ?? 0,
            provider: value["provider"] as? String ?? "heuristic",
            cloudAvailable: value["cloudAvailable"] as? Bool ?? false,
            difficulty: value["difficulty"] as? String,
            tier: value["tier"] as? String,
            model: value["model"] as? String,
            effort: value["effort"] as? String
        )
    }

    static func run(from value: [String: Any]) -> Run {
        let events: [(seq: Int, event: Event)] = (value["events"] as? [[String: Any]] ?? []).compactMap { item in
            guard let seq = (item["seq"] as? NSNumber)?.intValue, let event = event(from: item) else { return nil }
            return (seq, event)
        }
        var error: String?
        if let object = value["error"] as? [String: Any] {
            error = object["message"] as? String ?? object["code"] as? String
        }
        return Run(
            id: value["id"] as? String ?? "",
            status: value["status"] as? String ?? "running",
            model: value["model"] as? String ?? "",
            events: events,
            answer: value["answer"] as? String,
            error: error,
            sources: value["sources"] as? [String] ?? [],
            edits: (value["edits"] as? [[String: Any]] ?? []).compactMap(edit(from:))
        )
    }

    static func event(from item: [String: Any]) -> Event? {
        switch item["type"] as? String {
        case "message": return (item["text"] as? String).map(Event.message)
        case "tool": return .tool(item["summary"] as? String ?? item["name"] as? String ?? "使用工具")
        case "edit": return (item["edit"] as? [String: Any]).flatMap(edit(from:)).map(Event.edit)
        case "file": return (item["path"] as? String).map(Event.file)
        case "error": return .error(item["message"] as? String ?? "發生錯誤")
        default: return nil
        }
    }

    static func edit(from item: [String: Any]) -> Edit? {
        guard let id = item["id"] as? String, let path = item["path"] as? String else { return nil }
        return Edit(
            id: id,
            op: item["op"] as? String ?? "update",
            path: path,
            from: item["from"] as? String,
            summary: item["summary"] as? String ?? "",
            undone: item["undone"] as? Bool ?? false
        )
    }

    // MARK: 傳輸

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil, authorized: Bool = true, timeout: TimeInterval) async throws -> [String: Any] {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw ServerError(status: 0, code: "invalid_url", message: "伺服器網址不正確")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(VaultClient.clientID, forHTTPHeaderField: "X-LocalOCR-Client")
        if authorized { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServerError(status: 0, code: "network", message: "無法連線到伺服器：\(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let error = value["error"] as? [String: Any]
            throw ServerError(
                status: status,
                code: error?["code"] as? String ?? "http_\(status)",
                message: error?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
            )
        }
        return value
    }

    private static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? component
    }
}
