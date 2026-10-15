import Foundation

/// 伺服器的物流追蹤（/v1/logistics，移植自 vault 的「物流追蹤中心」dataviewjs 工具）：清單存在 vault 的
/// 06 日誌/物流追蹤/watchlist.json（電腦上的工具讀寫同一個檔案），伺服器查詢物流商並在背景定時刷新。
struct LogisticsClient: Sendable {
    let baseURL: URL
    let apiKey: String
    var session: URLSession = .shared

    static func configured() -> LogisticsClient? {
        guard let url = ServerSettings.baseURL, let key = ServerSettings.apiKey, !key.isEmpty else { return nil }
        return LogisticsClient(baseURL: url, apiKey: key)
    }

    // MARK: 型別（欄位名稱同 watchlist.json）

    /// 物流歷程的一個站點。
    struct Node: Codable, Equatable, Hashable, Sendable {
        var checkpointDate: String
        var location: String
        var trackingDetail: String
    }

    /// 一筆追蹤的單號。
    struct Item: Codable, Equatable, Identifiable, Sendable {
        var trackingNumber: String
        var courierCode: String
        var courierName: String
        var note: String
        /// transit、delivered、pickup、exception、pending 或 notfound。
        var status: String
        var isArchived: Bool
        var latestEvent: String
        var latestTime: String
        /// 新的在前。
        var trackinfo: [Node]
        var updatedAt: String

        var id: String { trackingNumber }
    }

    struct Courier: Codable, Equatable, Identifiable, Sendable {
        var code: String
        var name: String
        /// 物流商的查件網頁；{number} 換成單號。
        var url: String
        /// 伺服器能自動抓取這家的進度。
        var live: Bool

        var id: String { code }
    }

    struct Status: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var label: String
        /// 例如 #2563eb。
        var color: String
    }

    struct Refresh: Codable, Equatable, Sendable {
        /// 0＝背景刷新關閉。
        var intervalMinutes: Int
        var running: Bool
        var lastRunAt: String?
        var lastRefreshed: Int
        var lastError: String?
    }

    struct List: Codable, Equatable, Sendable {
        var items: [Item]
        var couriers: [Courier]
        var statuses: [Status]
        var dhl: Bool
        var track17: Bool
        var refresh: Refresh
        var path: String
    }

    /// Frontmatter 有物流單號的筆記。
    struct LinkedNote: Codable, Equatable, Identifiable, Sendable {
        var path: String
        var name: String
        var customer: String
        var caseNo: String
        var trackingNumber: String
        var courier: String
        var courierName: String
        var tracked: Bool

        var id: String { path }
    }

    // MARK: 端點

    func list() async throws -> List {
        try decode(List.self, from: await send("GET", "/v1/logistics", timeout: 30))
    }

    /// 新增追蹤：伺服器先查詢物流商，再把單號加到最前面（同一單號則更新）。
    func add(courier: String, number: String, note: String) async throws -> Item {
        try decode(ItemBody.self, from: await send("POST", "/v1/logistics/items", body: ["courier": courier, "number": number, "note": note], timeout: 40)).item
    }

    /// 修改備註、狀態，或結案（archived: true → 已送達）／恢復追蹤（false → 運送中）。
    func update(_ number: String, note: String? = nil, status: String? = nil, archived: Bool? = nil) async throws -> Item {
        var body: [String: Any] = [:]
        if let note { body["note"] = note }
        if let status { body["status"] = status }
        if let archived { body["archived"] = archived }
        return try decode(ItemBody.self, from: await send("PATCH", "/v1/logistics/items/\(Self.escape(number))", body: body, timeout: 20)).item
    }

    func delete(_ number: String) async throws {
        _ = try await send("DELETE", "/v1/logistics/items/\(Self.escape(number))", timeout: 20)
    }

    func refresh(_ number: String) async throws -> Item {
        try decode(ItemBody.self, from: await send("POST", "/v1/logistics/items/\(Self.escape(number))/refresh", timeout: 40)).item
    }

    /// 批次刷新所有追蹤中的單號（一筆接一筆查詢，單號多時要等比較久）。
    func refreshAll() async throws -> (refreshed: Int, items: [Item]) {
        let body = try decode(RefreshBody.self, from: await send("POST", "/v1/logistics/refresh", timeout: 300))
        return (body.refreshed, body.items)
    }

    func archiveDelivered() async throws -> Int {
        try decode(CountBody.self, from: await send("POST", "/v1/logistics/archive-delivered", timeout: 20)).archived ?? 0
    }

    func clearArchived() async throws -> Int {
        try decode(CountBody.self, from: await send("DELETE", "/v1/logistics/archived", timeout: 20)).removed ?? 0
    }

    func linked() async throws -> [LinkedNote] {
        try decode(LinkedBody.self, from: await send("GET", "/v1/logistics/linked", timeout: 90)).notes
    }

    // MARK: 解析

    private struct ItemBody: Decodable { var item: Item }
    private struct RefreshBody: Decodable { var refreshed: Int; var items: [Item] }
    private struct CountBody: Decodable { var archived: Int?; var removed: Int? }
    private struct LinkedBody: Decodable { var notes: [LinkedNote] }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            throw ServerError(status: 0, code: "invalid_response", message: "伺服器的回應無法解讀（\(error.localizedDescription)）")
        }
    }

    // MARK: 傳輸

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval) async throws -> Data {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw ServerError(status: 0, code: "invalid_url", message: "伺服器網址不正確")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(VaultClient.clientID, forHTTPHeaderField: "X-LocalOCR-Client")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        guard (200..<300).contains(status) else {
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = value?["error"] as? [String: Any]
            throw ServerError(
                status: status,
                code: error?["code"] as? String ?? "http_\(status)",
                message: error?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
            )
        }
        return data
    }

    private static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? component
    }
}

/// 物流追蹤的純函式（方便測試）：猜物流商、查件網址、複製用的 Markdown 表格。
enum LogisticsLogic {
    /// 從單號的樣子猜物流商（同伺服器）：SF＋數字＝順豐、1Z…＝UPS、10 碼＝DHL、9 開頭 12 碼＝黑貓、其他 12 或 15 碼＝FedEx。
    static func guessCourier(_ number: String) -> String? {
        let value = normalize(number).uppercased()
        func matches(_ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
        if matches("^SF[0-9]{10,15}$") { return "sf-express" }
        if matches("^1Z[0-9A-Z]{16}$") { return "ups" }
        if matches("^[0-9]{10}$") { return "dhl" }
        if matches("^9[0-9]{11}$") { return "t-cat" }
        if matches("^([0-9]{12}|[0-9]{15})$") { return "fedex" }
        return nil
    }

    /// 去掉空白（掃描或貼上的單號常帶空格）。
    static func normalize(_ number: String) -> String {
        number.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// 看起來像單號：去掉空白與 - 後 8～30 個英數字，且至少有 6 個數字。
    static func looksLikeTrackingNumber(_ text: String) -> Bool {
        let value = normalize(text).replacingOccurrences(of: "-", with: "")
        guard (8...30).contains(value.count), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        return value.filter(\.isNumber).count >= 6
    }

    static func trackingURL(template: String?, number: String) -> URL? {
        let encoded = number.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))) ?? number
        guard let template else { return track17URL(number) }
        return URL(string: template.replacingOccurrences(of: "{number}", with: encoded))
    }

    static func track17URL(_ number: String) -> URL? {
        let encoded = number.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? number
        return URL(string: "https://t.17track.net/zh-tw#nums=\(encoded)")
    }

    /// 工具的「複製表格」：追蹤中的單號。
    static func markdownTable(_ items: [LogisticsClient.Item], statuses: [LogisticsClient.Status]) -> String {
        func cell(_ value: String) -> String {
            value.isEmpty ? "—" : value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        var lines = ["| 狀態 | 物流商 | 單號 | 案件說明 | 最新動態 | 時間 |", "|---|---|---|---|---|---|"]
        for item in items where !item.isArchived {
            let label = statuses.first { $0.id == item.status }?.label ?? statuses.first?.label ?? item.status
            let courier = item.courierName.isEmpty ? item.courierCode : item.courierName
            lines.append("| \(label) | \(cell(courier)) | `\(item.trackingNumber)` | \(cell(item.note)) | \(cell(item.latestEvent)) | \(cell(item.latestTime)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 這則筆記是電腦上的「物流追蹤中心」dataviewjs 工具（在 App 中改開原生的物流追蹤頁）。
    static func isToolNote(path: String, text: String?) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == "物流追蹤.md" { return true }
        return text?.contains("logistics_tracker.py") == true && text?.contains("```dataviewjs") == true
    }
}
