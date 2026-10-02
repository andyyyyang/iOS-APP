import Foundation
import Security
import UIKit

/// 伺服器連線設定。網址存在 UserDefaults，API 金鑰存在鑰匙圈。
enum ServerSettings {
    enum Key {
        static let baseURL = "server.baseURL"
        static let autoUpload = "server.autoUpload"
        static let useJev = "ai.useJev"
    }

    private static let apiKeyAccount = "server.apiKey"

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Key.baseURL: "",
            Key.autoUpload: true,
            Key.useJev: true,
        ])
    }

    static var baseURL: URL? {
        normalizedURL(UserDefaults.standard.string(forKey: Key.baseURL) ?? "")
    }

    static var apiKey: String? {
        get { KeychainStore.string(for: apiKeyAccount) }
        set { KeychainStore.set(newValue?.trimmingCharacters(in: .whitespacesAndNewlines), for: apiKeyAccount) }
    }

    static var isConfigured: Bool { ServerClient.configured() != nil }

    /// 補上 https://、移除結尾斜線；格式不正確時回傳 nil。
    static func normalizedURL(_ string: String) -> URL? {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }
}

enum KeychainStore {
    private static let service = Bundle.main.bundleIdentifier ?? "LocalOCR"

    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

struct ServerError: LocalizedError {
    let status: Int
    let code: String
    let message: String

    var errorDescription: String? {
        switch status {
        case 401: return "API 金鑰不正確（401）"
        case 0: return message
        default: return "伺服器錯誤 \(status)：\(message)"
        }
    }
}

/// LocalOCR 伺服器的 REST 客戶端（規格見 docs/API.md）。
struct ServerClient {
    let baseURL: URL
    let apiKey: String
    var session: URLSession = .shared

    static func configured() -> ServerClient? {
        guard let url = ServerSettings.baseURL, let key = ServerSettings.apiKey, !key.isEmpty else { return nil }
        return ServerClient(baseURL: url, apiKey: key)
    }

    // MARK: - Endpoints

    /// 回傳伺服器是否已設定 Jev。
    func health() async throws -> (version: String, jev: Bool) {
        let value = try await send("GET", "/health", authorized: false)
        return (value["version"]?.stringValue ?? "?", value["jev"] == JSONValue.bool(true))
    }

    func fetchTemplates() async throws -> [ScanTemplate] {
        let value = try await send("GET", "/v1/templates")
        guard case .array(let items)? = value["items"] else { return [] }
        return items.compactMap(Self.template(from:))
    }

    func upsertTemplate(_ template: ScanTemplate) async throws {
        let keywords = JSONValue.array(template.keywords.map(JSONValue.string))
        let body = JSONValue.object([
            (key: "id", value: .string(template.id)),
            (key: "name", value: .string(template.name)),
            (key: "description", value: .string(template.description)),
            (key: "keywords", value: keywords),
            (key: "sample", value: template.sample),
            (key: "instructions", value: .string(template.instructions)),
        ])
        _ = try await send("PUT", "/v1/templates/\(Self.escape(template.id))", body: body)
    }

    func classify(text: String, templateIDs: [String]) async throws -> Classification {
        let body = JSONValue.object([
            (key: "text", value: .string(String(text.prefix(8000)))),
            (key: "templateIds", value: .array(templateIDs.map(JSONValue.string))),
        ])
        let value = try await send("POST", "/v1/classify", body: body)
        guard let id = value["templateId"]?.stringValue else {
            throw ServerError(status: 0, code: "invalid_response", message: "分類結果格式不正確")
        }
        var probabilities: [String: Double] = [:]
        if case .object(let members)? = value["probabilities"] {
            for member in members {
                if case .number(let probability) = member.value { probabilities[member.key] = probability }
            }
        }
        var confidence: Double?
        if case .number(let number)? = value["confidence"] { confidence = number }
        return Classification(templateID: id, confidence: confidence, probabilities: probabilities, provider: .jev)
    }

    func upsertScan(id: UUID, payload: JSONValue) async throws {
        _ = try await send("PUT", "/v1/scans/\(id.uuidString)", body: payload)
    }

    // MARK: - Transport

    private func send(_ method: String, _ path: String, body: JSONValue? = nil, authorized: Bool = true) async throws -> JSONValue {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw ServerError(status: 0, code: "invalid_url", message: "伺服器網址不正確")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.compactString.utf8)
        }

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
        let text = String(decoding: data, as: UTF8.self)
        let value = text.isEmpty ? JSONValue.null : ((try? JSONValue.parse(text)) ?? .null)

        guard (200..<300).contains(status) else {
            let error = value["error"]
            throw ServerError(
                status: status,
                code: error?["code"]?.stringValue ?? "http_\(status)",
                message: error?["message"]?.stringValue ?? HTTPURLResponse.localizedString(forStatusCode: status)
            )
        }
        return value
    }

    private static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? component
    }

    static func template(from value: JSONValue) -> ScanTemplate? {
        guard let id = value["id"]?.stringValue, let name = value["name"]?.stringValue,
              let sample = value["sample"], case .object = sample else { return nil }
        var keywords: [String] = []
        if case .array(let items)? = value["keywords"] {
            keywords = items.compactMap(\.stringValue)
        }
        var version = 1
        if case .number(let number)? = value["version"] { version = Int(number) }
        return ScanTemplate(
            id: id,
            name: name,
            description: value["description"]?.stringValue ?? "",
            keywords: keywords,
            sampleJSON: sample.compactString,
            instructions: value["instructions"]?.stringValue ?? "",
            origin: .server,
            version: version
        )
    }
}

// MARK: - 上傳掃描紀錄

enum ScanUploader {
    static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 依 docs/API.md 的 Scan 格式建立上傳內容。
    @MainActor
    static func payload(for record: ScanRecord, id: UUID) -> JSONValue {
        JSONValue.object([
            (key: "id", value: .string(id.uuidString)),
            (key: "createdAt", value: .string(dateFormatter.string(from: record.createdAt))),
            (key: "source", value: .string(record.source)),
            (key: "text", value: .string(record.text)),
            (key: "templateId", value: record.templateID.map(JSONValue.string) ?? .null),
            (key: "classification", value: record.classificationValue ?? .null),
            (key: "data", value: record.dataValue ?? .null),
            (key: "lineCount", value: .number(Double(record.lineCount))),
            (key: "averageConfidence", value: record.averageConfidence.map(JSONValue.number) ?? .null),
            (key: "pageCount", value: .number(Double(record.pageCount))),
            (key: "device", value: .string(UIDevice.current.model)),
        ])
    }

    @MainActor
    static func upload(_ record: ScanRecord) async throws {
        guard let client = ServerClient.configured() else {
            throw ServerError(status: 0, code: "not_configured", message: "尚未設定伺服器")
        }
        let id = record.remoteID ?? UUID()
        record.remoteID = id
        try await client.upsertScan(id: id, payload: payload(for: record, id: id))
        record.syncedAt = Date()
    }
}
