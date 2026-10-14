import Foundation

/// vault 中的一個檔案。
struct VaultEntry: Identifiable, Hashable {
    let path: String
    let size: Int
    let mtime: Date
    let etag: String

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var displayName: String { isMarkdown ? (name as NSString).deletingPathExtension : name }
    var pathExtension: String { (path as NSString).pathExtension.lowercased() }
    var isMarkdown: Bool { pathExtension == "md" }
    var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(pathExtension) }
}

struct VaultListing {
    var files: [VaultEntry]
    /// 子資料夾路徑（以 / 結尾）。
    var folders: [String]
}

struct VaultFile {
    let data: Data
    let etag: String?
    let mtime: Date?

    var text: String { String(decoding: data, as: UTF8.self) }
}

/// 伺服器記下的 vault 變動（GET /v1/vault/changes）。
struct VaultChanges {
    struct Change {
        let path: String?
        /// "write"、"delete" 或 "external"（電腦的 Obsidian 透過 Remotely Save 上傳了檔案，不知道是哪些）。
        let op: String
    }

    let cursor: String
    /// 伺服器重新啟動或漏掉太多變動：應該完整同步一次。
    let reset: Bool
    let changes: [Change]
}

struct VaultSearchHit: Identifiable, Hashable {
    let path: String
    let mtime: Date
    let snippet: String

    var id: String { path }
    var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
}

enum VaultError: LocalizedError {
    /// 檔案在別處被修改（If-Match 不符）或已存在（建立時）。
    case conflict(currentETag: String?)
    case notFound
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .conflict: return "這個筆記在其他地方被修改過。"
        case .notFound: return "找不到這個檔案。"
        case .notConfigured: return "伺服器尚未設定 Obsidian 空間（VAULT_S3_*）。"
        }
    }
}

/// Obsidian vault 的 REST 客戶端（伺服器 /v1/vault，檔案存在 Railway Bucket，由 Remotely Save 同步到各裝置）。
struct VaultClient {
    enum WriteCondition {
        case none
        /// 只有內容沒被改過（ETag 相同）才覆寫。
        case ifMatch(String)
        /// 只在檔案不存在時建立。
        case createOnly
    }

    let baseURL: URL
    let apiKey: String
    var session: URLSession = .shared

    static func configured() -> VaultClient? {
        guard let url = ServerSettings.baseURL, let key = ServerSettings.apiKey, !key.isEmpty else { return nil }
        return VaultClient(baseURL: url, apiKey: key)
    }

    /// 這台裝置的代號（X-LocalOCR-Client）：伺服器的變動通知不會把自己做的修改再通知回來。
    static let clientID: String = {
        let key = "vault.clientID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let id = "app-" + UUID().uuidString.prefix(12).lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    // MARK: - Endpoints

    func status() async throws -> (configured: Bool, prefix: String) {
        let (data, _) = try await send("GET", "/v1/vault/status")
        let value = try JSONValue.parse(String(decoding: data, as: UTF8.self))
        return (value["configured"] == JSONValue.bool(true), value["prefix"]?.stringValue ?? "")
    }

    func list(prefix: String = "", recursive: Bool) async throws -> VaultListing {
        let (data, _) = try await send("GET", "/v1/vault/files", query: [
            URLQueryItem(name: "prefix", value: prefix),
            URLQueryItem(name: "recursive", value: recursive ? "true" : "false"),
        ])
        let value = try JSONValue.parse(String(decoding: data, as: UTF8.self))
        var files: [VaultEntry] = []
        if case .array(let items)? = value["items"] {
            files = items.compactMap(Self.entry(from:))
        }
        var folders: [String] = []
        if case .array(let items)? = value["folders"] {
            folders = items.compactMap(\.stringValue)
        }
        return VaultListing(files: files, folders: folders)
    }

    func read(_ path: String) async throws -> VaultFile {
        let (data, response) = try await send("GET", "/v1/vault/file", query: [URLQueryItem(name: "path", value: path)])
        let mtime = (response.value(forHTTPHeaderField: "X-Vault-Mtime")).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        return VaultFile(data: data, etag: response.value(forHTTPHeaderField: "ETag"), mtime: mtime)
    }

    @discardableResult
    func write(
        _ path: String,
        data: Data,
        contentType: String = "application/octet-stream",
        condition: WriteCondition = .none,
        mtime: Date = .now
    ) async throws -> VaultEntry {
        var headers = [
            "Content-Type": contentType,
            "X-Vault-Mtime": String(Int64(mtime.timeIntervalSince1970 * 1000)),
        ]
        switch condition {
        case .none: break
        case .ifMatch(let etag): headers["If-Match"] = etag
        case .createOnly: headers["If-None-Match"] = "*"
        }
        let (body, _) = try await send("PUT", "/v1/vault/file", query: [URLQueryItem(name: "path", value: path)], headers: headers, body: data)
        let value = try JSONValue.parse(String(decoding: body, as: UTF8.self))
        guard let entry = Self.entry(from: value) else {
            throw ServerError(status: 0, code: "invalid_response", message: "伺服器回傳格式不正確")
        }
        return entry
    }

    @discardableResult
    func writeText(_ path: String, _ text: String, condition: WriteCondition = .none) async throws -> VaultEntry {
        try await write(path, data: Data(text.utf8), contentType: "text/markdown; charset=utf-8", condition: condition)
    }

    func delete(_ path: String, ifMatch: String? = nil) async throws {
        var headers: [String: String] = [:]
        if let ifMatch { headers["If-Match"] = ifMatch }
        _ = try await send("DELETE", "/v1/vault/file", query: [URLQueryItem(name: "path", value: path)], headers: headers)
    }

    /// 整個 vault 的索引（標題、別名、標籤、連結、待辦、摘要）。與 `etag` 相同（沒有變動）時回傳 nil。
    func index(etag: String?) async throws -> (index: VaultIndex, etag: String?)? {
        var headers: [String: String] = [:]
        if let etag { headers["If-None-Match"] = etag }
        let (data, response) = try await send("GET", "/v1/vault/index", headers: headers, allowNotModified: true)
        if response.statusCode == 304 { return nil }
        let index = try JSONDecoder().decode(VaultIndex.self, from: data)
        return (index, response.value(forHTTPHeaderField: "ETag"))
    }

    /// 通知伺服器這台裝置在別的空間（WebDAV）改了檔案：電腦的 Obsidian 會立即同步。
    func reportChanges(paths: [String]) async throws {
        var body: [String: Any] = [:]
        if !paths.isEmpty { body["paths"] = Array(paths.prefix(100)) }
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await send("POST", "/v1/vault/changes", headers: ["Content-Type": "application/json"], body: data)
    }

    /// 推送的 changes 訊息：`{cursor, reset, changes}`。
    static func changes(from value: JSONValue, previousCursor: String?) -> VaultChanges {
        var changes: [VaultChanges.Change] = []
        if case .array(let items)? = value["changes"] {
            changes = items.map { VaultChanges.Change(path: $0["path"]?.stringValue, op: $0["op"]?.stringValue ?? "write") }
        }
        return VaultChanges(cursor: value["cursor"]?.stringValue ?? previousCursor ?? "", reset: value["reset"] == JSONValue.bool(true), changes: changes)
    }

    /// 即時推送的 WebSocket 位址（wss://…/v1/vault/stream）。
    var streamURL: URL? {
        guard let url = Self.url(baseURL: baseURL, path: "/v1/vault/stream", query: []),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        return components.url
    }

    func search(_ query: String, prefix: String = "", limit: Int = 30) async throws -> [VaultSearchHit] {
        let (data, _) = try await send("GET", "/v1/vault/search", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "prefix", value: prefix),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        let value = try JSONValue.parse(String(decoding: data, as: UTF8.self))
        guard case .array(let items)? = value["items"] else { return [] }
        return items.compactMap { item in
            guard let path = item["path"]?.stringValue else { return nil }
            var mtime = Date.distantPast
            if case .number(let milliseconds)? = item["mtime"] { mtime = Date(timeIntervalSince1970: milliseconds / 1000) }
            return VaultSearchHit(path: path, mtime: mtime, snippet: item["snippet"]?.stringValue ?? "")
        }
    }

    // MARK: - Transport

    static func entry(from value: JSONValue) -> VaultEntry? {
        guard let path = value["path"]?.stringValue else { return nil }
        var size = 0
        if case .number(let number)? = value["size"] { size = Int(number) }
        var mtime = Date.distantPast
        if case .number(let milliseconds)? = value["mtime"] { mtime = Date(timeIntervalSince1970: milliseconds / 1000) }
        return VaultEntry(path: path, size: size, mtime: mtime, etag: value["etag"]?.stringValue ?? "")
    }

    /// 查詢參數編碼：URLComponents 不會編碼「+」，伺服器會把它當成空白，所以另外處理。
    static func url(baseURL: URL, path: String, query: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: baseURL.absoluteString + path) else { return nil }
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url
    }

    private func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        allowNotModified: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = Self.url(baseURL: baseURL, path: path, query: query) else {
            throw ServerError(status: 0, code: "invalid_url", message: "伺服器網址不正確")
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.clientID, forHTTPHeaderField: "X-LocalOCR-Client")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            let result = try await session.data(for: request)
            data = result.0
            response = result.1
        } catch {
            throw ServerError(status: 0, code: "network", message: "無法連線到伺服器：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServerError(status: 0, code: "network", message: "伺服器沒有回應")
        }
        guard (200..<300).contains(http.statusCode) || (allowNotModified && http.statusCode == 304) else {
            let value = (try? JSONValue.parse(String(decoding: data, as: UTF8.self))) ?? .null
            let error = value["error"]
            let code = error?["code"]?.stringValue ?? "http_\(http.statusCode)"
            switch (http.statusCode, code) {
            case (412, _): throw VaultError.conflict(currentETag: error?["currentEtag"]?.stringValue)
            case (404, _): throw VaultError.notFound
            case (503, "vault_not_configured"): throw VaultError.notConfigured
            default:
                throw ServerError(
                    status: http.statusCode,
                    code: code,
                    message: error?["message"]?.stringValue ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                )
            }
        }
        return (data, http)
    }
}
