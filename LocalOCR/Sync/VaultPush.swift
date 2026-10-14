import Foundation

/// 伺服器推送的事件（WebSocket /v1/vault/stream）。
enum VaultPushEvent {
    /// 連線完成（`reset`：斷線太久或伺服器重新啟動，漏掉的變動要靠完整同步補上）。
    case ready(cursor: String, reset: Bool)
    /// 其他裝置的修改（不含這台裝置自己做的）。
    case changes(VaultChanges)
}

/// 連線結束的原因。
enum VaultPushOutcome: Equatable {
    /// 網路中斷、伺服器重新部署等：稍後重新連線。
    case disconnected
    /// 伺服器還沒有即時推送（舊版）。
    case unsupported
    case unauthorized
    case notConfigured
}

/// 即時推送：與伺服器保持一條 WebSocket 連線，其他裝置修改 vault 時伺服器立即送來，不必輪詢。
/// 第一個訊息用 API 金鑰登入（瀏覽器的 WebSocket 不能帶標頭，所以伺服器用訊息驗證）；
/// 每 30 秒送一次 ping 確認連線還在，斷線時結束，由呼叫端重新連線。
@MainActor
enum VaultPush {
    static func run(client: VaultClient, since: String?, onEvent: @escaping @MainActor (VaultPushEvent) async -> Void) async -> VaultPushOutcome {
        guard let url = client.streamURL else { return .unsupported }
        let task = client.session.webSocketTask(with: URLRequest(url: url, timeoutInterval: 30))
        task.resume()
        let heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                let alive = await withCheckedContinuation { continuation in
                    task.sendPing { error in continuation.resume(returning: error == nil) }
                }
                if !alive {
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        defer {
            heartbeat.cancel()
            task.cancel(with: .goingAway, reason: nil)
        }

        do {
            var auth: [String: String] = ["type": "auth", "token": client.apiKey, "client": VaultClient.clientID]
            if let since { auth["since"] = since }
            let data = try JSONSerialization.data(withJSONObject: auth)
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
            while !Task.isCancelled {
                let text: String
                switch try await task.receive() {
                case .string(let string): text = string
                case .data(let data): text = String(decoding: data, as: UTF8.self)
                @unknown default: continue
                }
                guard let value = try? JSONValue.parse(text) else { continue }
                switch value["type"]?.stringValue {
                case "ready":
                    await onEvent(.ready(cursor: value["cursor"]?.stringValue ?? since ?? "", reset: value["reset"] == JSONValue.bool(true)))
                case "changes":
                    await onEvent(.changes(VaultClient.changes(from: value, previousCursor: since)))
                case "error":
                    switch value["code"]?.stringValue {
                    case "unauthorized": return .unauthorized
                    case "vault_not_configured": return .notConfigured
                    default: continue
                    }
                default:
                    continue
                }
            }
            return .disconnected
        } catch {
            // 舊版伺服器沒有 /v1/vault/stream：升級連線時回 404
            if let response = task.response as? HTTPURLResponse, response.statusCode == 404 {
                return .unsupported
            }
            return .disconnected
        }
    }
}
