import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 裝置端 Apple Intelligence（Foundation Models）的可用狀態。
enum OnDeviceAIStatus: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool { self == .available }

    static var current: OnDeviceAIStatus {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailable("此裝置不支援 Apple Intelligence")
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable("請到「設定」開啟 Apple Intelligence")
            case .unavailable(.modelNotReady):
                return .unavailable("模型下載中，請稍後再試")
            case .unavailable:
                return .unavailable("Apple Intelligence 目前無法使用")
            }
        }
        return .unavailable("需要 iOS 26 以上")
        #else
        return .unavailable("此版本未包含 Foundation Models")
        #endif
    }
}

#if canImport(FoundationModels)

/// 把樣板的範例 JSON 轉成 Foundation Models 的動態結構描述（DynamicGenerationSchema），
/// 讓裝置端模型直接產生相同結構的資料。
@available(iOS 26.0, *)
enum TemplateSchemaBuilder {
    static func generationSchema(for sample: JSONValue, excluding excluded: Set<String> = []) throws -> GenerationSchema {
        var counter = 0
        var target = sample
        if case .object(let members) = sample, !excluded.isEmpty {
            let kept = members.filter { !excluded.contains($0.key) }
            target = kept.isEmpty ? sample : .object(kept)
        }
        let root = schema(for: target, counter: &counter)
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func schema(for sample: JSONValue, counter: inout Int) -> DynamicGenerationSchema {
        switch sample {
        case .object(let members) where !members.isEmpty:
            counter += 1
            let name = "Object\(counter)"
            let properties = members.map { member in
                DynamicGenerationSchema.Property(
                    name: member.key,
                    description: hint(for: member.value),
                    schema: schema(for: member.value, counter: &counter),
                    isOptional: true
                )
            }
            return DynamicGenerationSchema(name: name, description: nil, properties: properties)
        case .array(let elements):
            let element = elements.first ?? .string("")
            return DynamicGenerationSchema(
                arrayOf: schema(for: element, counter: &counter),
                minimumElements: nil,
                maximumElements: nil
            )
        case .number:
            return DynamicGenerationSchema(type: Double.self, guides: [])
        case .bool:
            return DynamicGenerationSchema(type: Bool.self, guides: [])
        case .string, .null, .object:
            return DynamicGenerationSchema(type: String.self, guides: [])
        }
    }

    /// 以範例值作為欄位提示，例如「例如：全聯福利中心」。
    private static func hint(for value: JSONValue) -> String? {
        switch value {
        case .string(let text) where !text.isEmpty: return "例如：\(text)"
        case .number, .bool: return "例如：\(value.compactString)"
        default: return nil
        }
    }
}

/// 使用裝置端模型判斷情境。
@available(iOS 26.0, *)
struct OnDeviceClassifier: DocumentClassifier {
    var provider: Classification.Provider { .onDevice }

    func classify(text: String, among templates: [ScanTemplate]) async throws -> Classification {
        let ids = templates.map(\.id)
        let root = DynamicGenerationSchema(
            name: "Classification",
            description: "文件所屬的情境",
            properties: [
                DynamicGenerationSchema.Property(
                    name: "template",
                    description: "情境代碼",
                    schema: DynamicGenerationSchema(type: String.self, guides: [.anyOf(ids)]),
                    isOptional: false
                ),
            ]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])
        // 具體的情境排前面並附上關鍵字；一般文件放最後，只在都不符合時使用
        let ordered = templates.filter { $0.id != ScanTemplate.fallbackID } + templates.filter { $0.id == ScanTemplate.fallbackID }
        let catalog = ordered.map { template -> String in
            let words = template.keywords.map { $0.hasPrefix("!") ? String($0.dropFirst()) : $0 }.prefix(8)
            let hint = words.isEmpty ? "" : "（常見字詞：\(words.joined(separator: "、"))）"
            return "- \(template.id)：\(template.name)。\(template.description)\(hint)"
        }.joined(separator: "\n")
        let instructions = "你是文件分類助理。根據 OCR 文字判斷文件屬於哪一個情境，只能從清單中選擇一個代碼。優先選擇最具體、符合的情境；只有在其他情境都明顯不符合時才選擇 \(ScanTemplate.fallbackID)。"
        let prompt = "情境清單：\n\(catalog)\n\nOCR 文字：\n\"\"\"\n\(PageText.classificationText(PageText.split(text), limit: 1200))\n\"\"\""

        let session = LanguageModelSession(model: OnDeviceModel.extraction, tools: [], instructions: { instructions })
        let response = try await session.respond(
            schema: schema,
            includeSchemaInPrompt: true,
            options: GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: nil)
        ) {
            prompt
        }
        let value = try JSONValue.parse(response.content.jsonString)
        guard let id = value["template"]?.stringValue, ids.contains(id) else {
            throw StructuredExtractionError.invalidOutput
        }
        return Classification(templateID: id, confidence: nil, probabilities: [:], provider: .onDevice)
    }
}

/// 共用的裝置端模型設定。
@available(iOS 26.0, *)
enum OnDeviceModel {
    /// 擷取資料屬於「轉換輸入文字」：使用寬鬆的內容防護，避免一般收據、名片被安全機制誤擋。
    static var extraction: SystemLanguageModel {
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }
}

/// 使用裝置端模型，依樣板結構從 OCR 文字抽取資料。
/// 多頁文件逐頁抽取再合併，因此頁數不受模型上下文長度限制；最後套用樣板規則計算欄位。
@available(iOS 26.0, *)
struct FoundationModelsExtractor: StructuredExtractor {
    /// 每頁依序嘗試的文字長度（字元）。裝置端模型的上下文有限，太長時改用較短的文字再試。
    var characterBudgets = [1800, 900]

    func extract(pages: [String], template: ScanTemplate, progress: (Int, Int) -> Void) async throws -> JSONValue {
        let pages = pages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }
        guard !pages.isEmpty else { throw StructuredExtractionError.generation("沒有可分析的文字") }

        let sample = template.sample
        let rules = template.rules
        let schema = try TemplateSchemaBuilder.generationSchema(for: sample, excluding: TemplateRules.topLevelTargets(of: rules))

        var results: [JSONValue] = []
        var lastError: Error = StructuredExtractionError.invalidOutput
        for (index, page) in pages.enumerated() {
            progress(index + 1, pages.count)
            do {
                results.append(try await extractPage(page, template: template, schema: schema, pageNumber: index + 1, pageCount: pages.count))
            } catch {
                // 單頁失敗（例如與情境無關的附件頁）不影響其他頁
                lastError = error
            }
        }
        guard !results.isEmpty else {
            throw StructuredExtractionError.generation(AIErrorDescriber.describe(lastError))
        }
        let merged = JSONValue.merged(results, sample: sample)
        return TemplateRules.apply(rules, to: merged).conformed(to: sample).removingHelperFields()
    }

    private func extractPage(
        _ text: String,
        template: ScanTemplate,
        schema: GenerationSchema,
        pageNumber: Int,
        pageCount: Int
    ) async throws -> JSONValue {
        var lastError: Error = StructuredExtractionError.invalidOutput
        for budget in characterBudgets {
            do {
                return try await extractOnce(
                    text: String(text.prefix(budget)),
                    template: template,
                    schema: schema,
                    pageLabel: pageCount > 1 ? "第 \(pageNumber)／\(pageCount) 頁" : nil
                )
            } catch {
                lastError = error
                if text.count <= budget { break }
            }
        }
        throw lastError
    }

    private func extractOnce(text: String, template: ScanTemplate, schema: GenerationSchema, pageLabel: String?) async throws -> JSONValue {
        let instructions = Self.instructions(for: template)
        var prompt = "情境：\(template.name)\n"
        if let pageLabel {
            prompt += "這是多頁文件的\(pageLabel)，只擷取本頁出現的資訊。\n"
        }
        prompt += "\nOCR 文字：\n\"\"\"\n\(text)\n\"\"\""

        let session = LanguageModelSession(model: OnDeviceModel.extraction, tools: [], instructions: { instructions })
        let response = try await session.respond(
            schema: schema,
            includeSchemaInPrompt: true,
            options: GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: nil)
        ) {
            prompt
        }
        guard let value = try? JSONValue.parse(response.content.jsonString) else {
            throw StructuredExtractionError.invalidOutput
        }
        return value.conformed(to: template.sample)
    }

    static func instructions(for template: ScanTemplate) -> String {
        var lines = [
            "你是資料擷取助理，負責把 OCR 文字整理成指定結構的 JSON。",
            "只能使用文字中實際出現的資訊，不可臆測或編造；找不到的欄位就省略。",
            "保留原文的語言與寫法，修正明顯的 OCR 錯字即可。",
            "文件情境：\(template.name)（\(template.description)）",
        ]
        if !template.instructions.isEmpty {
            lines.append("額外規則：\(template.instructions)")
        }
        return lines.joined(separator: "\n")
    }
}

/// 診斷畫面使用的模型資訊。
@available(iOS 26.0, *)
enum OnDeviceAIDiagnostics {
    static var supportsCurrentLocale: Bool {
        SystemLanguageModel.default.supportsLocale(Locale.current)
    }

    static var supportedLanguageNames: [String] {
        SystemLanguageModel.default.supportedLanguages
            .map { Locale.current.localizedString(forIdentifier: $0.minimalIdentifier) ?? $0.minimalIdentifier }
            .sorted()
    }
}

#endif

/// 把模型錯誤轉成使用者看得懂的說明（不依賴特定錯誤型別，iOS 26 與 27 的錯誤型別不同）。
enum AIErrorDescriber {
    static func describe(_ error: Error) -> String {
        var parts: [String] = []
        if let hint = hint(for: String(describing: error)) {
            parts.append(hint)
        }
        if let localized = error as? LocalizedError {
            for text in [localized.errorDescription, localized.failureReason, localized.recoverySuggestion] {
                if let text, !text.isEmpty, !parts.contains(text) { parts.append(text) }
            }
        } else {
            parts.append(error.localizedDescription)
        }
        return parts.joined(separator: "\n")
    }

    static func hint(for raw: String) -> String? {
        // 所有生成錯誤都帶有 Context，因此要比對完整的錯誤名稱
        let text = raw.lowercased()
        if text.contains("guardrail") { return "內容觸發了 Apple Intelligence 的安全機制。" }
        if text.contains("exceededcontextwindowsize") || text.contains("contextsizeexceeded") {
            return "文字太長，超過裝置端模型可處理的長度。"
        }
        if text.contains("unsupportedlanguageorlocale") {
            return "Apple Intelligence 的語言設定不支援這段文字，請到「設定 → Apple Intelligence 與 Siri」確認語言。"
        }
        if text.contains("assetsunavailable") { return "Apple Intelligence 模型尚未下載完成，請連上 Wi-Fi 並稍後再試。" }
        if text.contains("ratelimited") { return "請求太頻繁，或 App 不在前景，請稍後再試。" }
        if text.contains("refusal") { return "模型拒絕處理這段內容。" }
        if text.contains("decodingfailure") { return "模型輸出無法對應到樣板結構，請簡化樣板後再試。" }
        return nil
    }
}

/// 結構化抽取引擎。目前實作為裝置端 Foundation Models；未來可加入其他模型提供者。
protocol StructuredExtractor {
    /// `pages`：每頁的 OCR 文字；`progress`：（目前頁, 總頁數）。
    func extract(pages: [String], template: ScanTemplate, progress: (Int, Int) -> Void) async throws -> JSONValue
}

extension StructuredExtractor {
    func extract(text: String, template: ScanTemplate) async throws -> JSONValue {
        try await extract(pages: [text], template: template, progress: { _, _ in })
    }
}

/// 多頁文字以空白行分隔（OCR 結果與紀錄都以此格式保存）。
enum PageText {
    static func split(_ text: String) -> [String] {
        let pages = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return pages.isEmpty ? [text] : pages
    }

    /// 分類用的摘要：每頁取開頭一段，讓多頁文件的每一頁都能被看到。
    static func classificationText(_ pages: [String], limit: Int = 1500) -> String {
        guard pages.count > 1 else { return String((pages.first ?? "").prefix(limit)) }
        let perPage = max(200, limit / pages.count)
        return String(pages.map { String($0.prefix(perPage)) }.joined(separator: "\n\n").prefix(limit))
    }
}

enum StructuredExtractionError: LocalizedError {
    case unavailable(String)
    case invalidOutput
    case generation(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .invalidOutput: return "模型輸出的格式不正確，請再試一次。"
        case .generation(let detail): return detail
        }
    }
}
