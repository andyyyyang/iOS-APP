import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 日誌整理用的模型：可以時用 Private Cloud Compute（Apple 伺服器上的模型，較準確、上下文 32K），否則裝置端。
/// Private Cloud Compute 需要 iOS 27、Apple Intelligence 裝置、網路、使用者每天的額度（iCloud+ 較高），
/// 以及 App 取得 Apple 核准的授權（com.apple.developer.private-cloud-compute）。任何一項不行就自動改用裝置端，一小時內不再試。
@MainActor
enum JournalAI {
    enum Engine: String, Sendable {
        case privateCloud
        case onDevice

        var title: String { self == .privateCloud ? "Private Cloud Compute" : "裝置端" }
    }

    static let privateCloudKey = "journal.privateCloudCompute"

    /// App 已經有 Apple 核准的 Private Cloud Compute 授權（com.apple.developer.private-cloud-compute）。
    /// 沒有授權時完全不碰 Private Cloud Compute 的 API（沒有授權就建立模型可能讓 App 當掉）；核准並加入授權後改成 true。
    static let isEntitled = false

    /// 設定中的選擇（預設開）。
    static var prefersPrivateCloud: Bool {
        UserDefaults.standard.object(forKey: privateCloudKey) as? Bool ?? true
    }

    /// 上次用 Private Cloud Compute 失敗的原因（設定頁顯示）。
    private(set) static var lastIssue: String?
    private static var pausedUntil: Date?

    /// 一天（或一段日誌）的摘要、重點、待跟進。
    static func insights(for text: String) async throws -> (NoteInsights, Engine) {
        if let insights = await cloudInsights(for: text) {
            return (insights, .privateCloud)
        }
        return (try await NoteIntelligence.insights(for: text), .onDevice)
    }

    /// 自由寫作（統整）：雲端可以時用雲端；不行時用裝置端，輸入截短到裝置端放得下的長度。
    static func write(prompt: String, instructions: String, onDeviceLimit: Int = 2400) async -> (String, Engine)? {
        if let text = await cloudText(prompt: prompt, instructions: instructions) {
            return (text, .privateCloud)
        }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        guard let text = try? await OnDeviceWriter.write(prompt: String(prompt.prefix(onDeviceLimit)), instructions: instructions) else { return nil }
        return (text, .onDevice)
        #else
        return nil
        #endif
    }

    /// 設定頁顯示的狀態。
    static var cloudStatus: String {
        guard isEntitled else { return "目前用裝置端" }
        #if canImport(FoundationModels) && compiler(>=6.4)
        guard #available(iOS 27.0, *) else { return "需要 iOS 27 以上" }
        return PrivateCloud.status
        #else
        return "此版本不支援"
        #endif
    }

    private static var isPaused: Bool {
        if let pausedUntil, pausedUntil > Date() { return true }
        return false
    }

    private static func pause(_ issue: String) {
        lastIssue = issue
        pausedUntil = Date().addingTimeInterval(3600)
    }

    private static func cloudInsights(for text: String) async -> NoteInsights? {
        guard isEntitled, prefersPrivateCloud, !isPaused else { return nil }
        #if canImport(FoundationModels) && compiler(>=6.4)
        guard #available(iOS 27.0, *) else { return nil }
        do {
            let insights = try await PrivateCloud.insights(for: String(text.prefix(20_000)))
            lastIssue = nil
            return insights
        } catch {
            pause(PrivateCloud.describe(error))
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func cloudText(prompt: String, instructions: String) async -> String? {
        guard isEntitled, prefersPrivateCloud, !isPaused else { return nil }
        #if canImport(FoundationModels) && compiler(>=6.4)
        guard #available(iOS 27.0, *) else { return nil }
        do {
            let text = try await PrivateCloud.text(prompt: String(prompt.prefix(24_000)), instructions: instructions)
            lastIssue = nil
            return text
        } catch {
            pause(PrivateCloud.describe(error))
            return nil
        }
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
/// 裝置端的自由寫作（統整）。
@available(iOS 26.0, *)
enum OnDeviceWriter {
    static func write(prompt: String, instructions: String) async throws -> String {
        if case .unavailable(let reason) = OnDeviceAIStatus.current {
            throw NoteIntelligenceError.unavailable(reason)
        }
        let session = LanguageModelSession(model: OnDeviceModel.extraction, tools: [], instructions: { instructions })
        return try await session.respond(to: prompt).content
    }
}
#endif

#if canImport(FoundationModels) && compiler(>=6.4)
/// Private Cloud Compute（iOS 27 SDK 才有）。
@available(iOS 27.0, *)
@MainActor
private enum PrivateCloud {
    private struct Unavailable: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static var status: String {
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available:
            return model.quotaUsage.isLimitReached ? "今天的額度用完了" : "可以使用"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "這台裝置不支援 Apple Intelligence"
            case .systemNotReady: return "Apple Intelligence 還沒準備好"
            @unknown default: return "目前無法使用"
            }
        }
    }

    private static func model() throws -> PrivateCloudComputeLanguageModel {
        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable else { throw Unavailable(reason: status) }
        guard !model.quotaUsage.isLimitReached else { throw Unavailable(reason: "今天的額度用完了") }
        return model
    }

    static func insights(for text: String) async throws -> NoteInsights {
        let instructions = """
        你是筆記整理助理。根據使用者的日誌內容（手寫辨識的文字，含少量錯字）整理出標題、摘要、重點、待辦與標籤。
        只能根據內容，不可編造；保留原文的語言（繁體中文就用繁體中文）。
        """
        let session = LanguageModelSession(model: try model(), instructions: instructions)
        let response = try await session.respond(to: "日誌內容：\n\"\"\"\n\(text)\n\"\"\"", generating: GeneratedNoteInsights.self)
        let content = response.content
        return NoteInsights(
            title: content.title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: content.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: content.keyPoints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            actionItems: content.actionItems.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            tags: content.tags.map(NoteIntelligence.cleanTag).filter { !$0.isEmpty }
        )
    }

    static func text(prompt: String, instructions: String) async throws -> String {
        let session = LanguageModelSession(model: try model(), instructions: instructions)
        return try await session.respond(to: prompt).content
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .networkFailure: return "連不上 Private Cloud Compute"
            case .quotaLimitReached: return "今天的額度用完了"
            case .serviceUnavailable: return "Private Cloud Compute 暫時無法使用"
            @unknown default: return error.localizedDescription
            }
        }
        if let error = error as? Unavailable { return error.reason }
        // 沒有 Apple 核准的授權時，模型顯示可以用，但請求會失敗
        return "請求失敗：\(error.localizedDescription)"
    }
}
#endif
