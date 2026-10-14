import Foundation

/// 設定 → AI 功能：存在這台裝置的 AI 選項。雲端的選項在每次開始雲端工作時傳給伺服器（POST /v1/assistant/runs），
/// 沒有選的就用伺服器的預設（Railway 的 ASSISTANT_* 變數）。
enum AISettings {
    /// 雲端的三個等級，由便宜到最好。
    static let tiers = ["small", "medium", "large"]

    /// 某個等級固定用的模型；沒有值或空字串＝自動（伺服器跟著新模型更新）。
    static func modelKey(_ tier: String) -> String { "ai.model.\(tier)" }
    /// 網路搜尋、執行程式：沒有值＝依伺服器預設，"on"／"off"＝這台裝置的選擇。
    static let webSearchKey = "ai.webSearch"
    static let codeExecutionKey = "ai.codeExecution"
    /// 一次雲端工作最多幾步（模型呼叫）；0＝伺服器的上限。
    static let maxTurnsKey = "ai.maxTurns"
    /// 筆記上方與鍵盤工具列的「AI」按鈕（請 AI 修改筆記）。
    static let noteButtonKey = "ai.noteButton"
    /// 右側欄的「AI」整理（摘要、重點、待辦與標籤）。
    static let notePanelKey = "ai.notePanel"

    static func tierTitle(_ tier: String) -> String {
        switch tier {
        case "small": return "便宜"
        case "medium": return "平衡"
        default: return "最好"
        }
    }

    /// 自動時通常是哪個系列的模型。
    static func tierFamily(_ tier: String) -> String {
        switch tier {
        case "small": return "claude-haiku"
        case "medium": return "claude-sonnet"
        default: return "claude-opus"
        }
    }

    static func model(for tier: String, defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: modelKey(tier)) ?? ""
        return value.isEmpty ? nil : value
    }

    /// "on"／"off" → true／false；沒有選 → nil（依伺服器）。
    static func choice(_ key: String, defaults: UserDefaults = .standard) -> Bool? {
        switch defaults.string(forKey: key) {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    static func maxTurns(defaults: UserDefaults = .standard) -> Int? {
        let value = defaults.integer(forKey: maxTurnsKey)
        return value > 0 ? value : nil
    }

    /// 預設開啟的功能開關。
    static func isOn(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    /// 開始雲端工作時帶給伺服器的選項（nil＝用伺服器的預設）。
    struct RunOptions: Equatable, Sendable {
        var model: String?
        var webSearch: Bool?
        var codeExecution: Bool?
        var maxTurns: Int?
    }

    static func runOptions(tier: String?, defaults: UserDefaults = .standard) -> RunOptions {
        RunOptions(
            model: model(for: tier ?? "large", defaults: defaults),
            webSearch: choice(webSearchKey, defaults: defaults),
            codeExecution: choice(codeExecutionKey, defaults: defaults),
            maxTurns: maxTurns(defaults: defaults)
        )
    }
}
