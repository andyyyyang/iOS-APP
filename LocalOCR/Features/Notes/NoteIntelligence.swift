import Foundation
import PencilKit
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

enum NoteIntelligenceError: LocalizedError {
    case unavailable(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .empty: return "沒有可以整理的內容"
        }
    }
}

/// 筆記的 AI 處理：手寫辨識（Vision）＋整理（裝置端 Foundation Models），全程在裝置上執行。
enum NoteIntelligence {
    /// 把畫布逐段（切在筆跡之間的空白）轉成圖片交給 Vision 辨識；空白段略過。各段以空白行分隔。
    @MainActor
    static func recognizeHandwriting(
        drawing: PKDrawing,
        progress: (Int, Int) -> Void = { _, _ in }
    ) async throws -> String {
        let service = OCRService()
        let bands = CanvasLayout.bands(for: drawing)
        var pages: [String] = []
        for (index, band) in bands.enumerated() where drawing.hasStrokes(in: band) {
            progress(index + 1, bands.count)
            let image = PaperRenderer.canvasImage(drawing: drawing, rect: band, paper: .blank, scale: 2)
            let page = try await service.recognize(image)
            if !page.text.isEmpty {
                pages.append(page.text)
            }
        }
        return pages.joined(separator: "\n\n")
    }

    /// 整理文字：標題、摘要、重點、待辦、標籤。
    static func insights(for text: String) async throws -> NoteInsights {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NoteIntelligenceError.empty }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            throw NoteIntelligenceError.unavailable("需要 iOS 26 以上與 Apple Intelligence")
        }
        if case .unavailable(let reason) = OnDeviceAIStatus.current {
            throw NoteIntelligenceError.unavailable(reason)
        }
        do {
            return try await GeneratedNoteInsights.generate(from: String(trimmed.prefix(3000)))
        } catch {
            throw NoteIntelligenceError.unavailable(AIErrorDescriber.describe(error))
        }
        #else
        throw NoteIntelligenceError.unavailable("此版本未包含 Foundation Models")
        #endif
    }

    /// 一次能請 AI 修改的最多字數（裝置端模型的上下文有限，要留空間給修改後的文字）。
    static let editCharacterLimit = 1800

    /// 依使用者的要求修改 Markdown（修正錯字、改寫、做成表格、翻譯…），回傳修改後的 Markdown。
    static func editMarkdown(_ text: String, instruction: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NoteIntelligenceError.empty }
        guard text.count <= editCharacterLimit else {
            throw NoteIntelligenceError.unavailable("內容太長，請選取 \(editCharacterLimit) 字以內")
        }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            throw NoteIntelligenceError.unavailable("需要 iOS 26 以上與 Apple Intelligence")
        }
        if case .unavailable(let reason) = OnDeviceAIStatus.current {
            throw NoteIntelligenceError.unavailable(reason)
        }
        do {
            let edited = NoteMarkdownEditing.cleanAIOutput(try await MarkdownAIEditor.edit(trimmed, instruction: instruction))
            guard !edited.isEmpty else { throw NoteIntelligenceError.empty }
            return NoteMarkdownEditing.preservingSurroundingWhitespace(original: text, edited: edited)
        } catch let error as NoteIntelligenceError {
            throw error
        } catch {
            throw NoteIntelligenceError.unavailable(AIErrorDescriber.describe(error))
        }
        #else
        throw NoteIntelligenceError.unavailable("此版本未包含 Foundation Models")
        #endif
    }

    /// 標籤只保留文字，去掉 # 與空白（Obsidian 標籤不能有空白）。
    static func cleanTag(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

#if canImport(FoundationModels)
/// 請裝置端模型修改 Markdown（只輸出修改後的文字）。
@available(iOS 26.0, *)
enum MarkdownAIEditor {
    static func edit(_ text: String, instruction: String) async throws -> String {
        let instructions = """
        你是 Obsidian Markdown 筆記的編輯助理。依照使用者的要求修改提供的文字，只輸出修改後的 Markdown，不要加任何說明、開場白或 ``` 圍欄。
        保留原本的語言（繁體中文就用繁體中文，除非要求翻譯）、沒有要求修改的內容，以及 Obsidian 語法：[[連結]]、![[內嵌]]、#標籤、- [ ] 待辦、> [!callout]、表格。
        不可編造原文沒有的事實。
        """
        let session = LanguageModelSession(model: OnDeviceModel.extraction, tools: [], instructions: { instructions })
        let response = try await session.respond(to: "要求：\(instruction)\n\n要修改的文字：\n\"\"\"\n\(text)\n\"\"\"")
        return response.content
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedNoteInsights {
    @Guide(description: "筆記的標題，簡短明確，不超過 20 個字")
    var title: String

    @Guide(description: "摘要，三句話以內，使用筆記原本的語言")
    var summary: String

    @Guide(description: "重點，每點一句話，最多 6 點")
    var keyPoints: [String]

    @Guide(description: "筆記中提到要做的事，每項一句話；沒有就是空陣列")
    var actionItems: [String]

    @Guide(description: "1 到 5 個主題標籤，不含 # 符號")
    var tags: [String]

    static func generate(from text: String) async throws -> NoteInsights {
        let instructions = """
        你是筆記整理助理。根據使用者的筆記內容（可能是手寫辨識的文字，含少量錯字）整理出標題、摘要、重點、待辦與標籤。
        只能根據筆記內容，不可編造；保留原文的語言（繁體中文就用繁體中文）。
        """
        let session = LanguageModelSession(model: OnDeviceModel.extraction, tools: [], instructions: { instructions })
        let response = try await session.respond(
            generating: GeneratedNoteInsights.self,
            includeSchemaInPrompt: true,
            options: GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: nil)
        ) {
            "筆記內容：\n\"\"\"\n\(text)\n\"\"\""
        }
        let content = response.content
        return NoteInsights(
            title: content.title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: content.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: content.keyPoints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            actionItems: content.actionItems.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            tags: content.tags.map(NoteIntelligence.cleanTag).filter { !$0.isEmpty }
        )
    }
}
#endif
