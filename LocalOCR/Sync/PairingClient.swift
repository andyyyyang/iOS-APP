import Foundation

/// 配對：用 Obsidian 外掛產生的一次性配對碼（10 分鐘內有效）換到伺服器的 API 金鑰，
/// 不需要手動輸入網址與金鑰。配對連結格式：localocr://pair?server=<網址>&code=XXXX-XXXX。
enum PairingClient {
    struct Link: Equatable {
        let server: URL
        let code: String
    }

    struct Result: Equatable {
        let apiKey: String
        let vaultName: String?
    }

    static let defaultServer = URL(string: "https://localocr-server-production.up.railway.app")!

    /// 解析配對連結（QR Code 或點擊連結）。
    static func parse(_ url: URL) -> Link? {
        guard url.scheme == "localocr", url.host == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              let serverText = components.queryItems?.first(where: { $0.name == "server" })?.value,
              let server = ServerSettings.normalizedURL(serverText) else { return nil }
        return Link(server: server, code: normalizeCode(code))
    }

    /// 配對碼不分大小寫，空白與連字號可有可無：「abcd efgh」→「ABCD-EFGH」。
    static func normalizeCode(_ code: String) -> String {
        let characters = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard characters.count == 8 else { return String(characters) }
        return String(characters.prefix(4)) + "-" + String(characters.suffix(4))
    }

    static func claim(_ link: Link, session: URLSession = .shared) async throws -> Result {
        var request = URLRequest(url: link.server.appending(path: "pair"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(JSONValue.object([(key: "code", value: .string(link.code))]).compactString.utf8)
        let data: Data
        let response: URLResponse
        do {
            let result = try await session.data(for: request)
            data = result.0
            response = result.1
        } catch {
            throw ServerError(status: 0, code: "network", message: "無法連線到伺服器：\(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let value = (try? JSONValue.parse(String(decoding: data, as: UTF8.self))) ?? .null
        switch status {
        case 200:
            guard let apiKey = value["apiKey"]?.stringValue, !apiKey.isEmpty else {
                throw ServerError(status: 0, code: "invalid_response", message: "伺服器回傳格式不正確")
            }
            return Result(apiKey: apiKey, vaultName: value["vaultName"]?.stringValue)
        case 404:
            throw ServerError(status: 0, code: "invalid_code", message: "配對碼不正確或已過期，請在 Obsidian 重新產生。")
        case 429:
            throw ServerError(status: 0, code: "rate_limited", message: "嘗試次數太多，請稍後再試。")
        default:
            throw ServerError(
                status: status,
                code: value["error"]?["code"]?.stringValue ?? "http_\(status)",
                message: value["error"]?["message"]?.stringValue ?? HTTPURLResponse.localizedString(forStatusCode: status)
            )
        }
    }

    /// 儲存配對結果：伺服器網址、金鑰（鑰匙圈）與 vault 名稱。
    /// 舊版插件會傳 notesFolder（固定的筆記資料夾）；筆記可以放在 vault 任何地方，所以不使用。
    @MainActor
    static func apply(_ result: Result, server: URL) {
        UserDefaults.standard.set(server.absoluteString, forKey: ServerSettings.Key.baseURL)
        ServerSettings.apiKey = result.apiKey
        if let vault = result.vaultName, !vault.isEmpty {
            UserDefaults.standard.set(vault, forKey: NotesSettings.Key.vaultName)
        }
    }

    /// 這台裝置上 Obsidian 的 Remotely Save 設定連結（obsidian://remotely-save?func=settings…），點開即可套用。
    static func remotelySaveURI(vaultName: String, client: VaultClient) async throws -> URL {
        guard let base = ServerSettings.baseURL, let key = ServerSettings.apiKey else { throw VaultError.notConfigured }
        let url = VaultClient.url(baseURL: base, path: "/v1/vault/remotely-save", query: [URLQueryItem(name: "vault", value: vaultName)])
        guard let url else { throw ServerError(status: 0, code: "invalid_url", message: "伺服器網址不正確") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await client.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let value = (try? JSONValue.parse(String(decoding: data, as: UTF8.self))) ?? .null
        if status == 503 { throw VaultError.notConfigured }
        guard status == 200, let uri = value["uri"]?.stringValue, let target = URL(string: uri) else {
            throw ServerError(status: status, code: value["error"]?["code"]?.stringValue ?? "http_\(status)", message: value["error"]?["message"]?.stringValue ?? "無法取得同步設定")
        }
        return target
    }
}
