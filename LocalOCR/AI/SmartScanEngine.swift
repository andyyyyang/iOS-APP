import Foundation
import Observation

/// 智慧掃描的結果：判斷出的情境，以及依情境樣板產生的 JSON。
struct SmartScanOutcome {
    var template: ScanTemplate
    var classification: Classification
    /// 依樣板產生的資料；裝置不支援 Apple Intelligence 時為 nil。
    var data: JSONValue?
    var extractionError: String?
    /// 分類器失敗而改用下一個來源的紀錄。
    var notes: [String]
}

/// 單一入口：OCR 文字 → 判斷情境（Jev → 裝置端模型 → 關鍵字）→ 依樣板抽取 JSON。
@MainActor
enum SmartScanEngine {
    static func classifierPipeline(useJev: Bool) -> ClassifierPipeline {
        var classifiers: [any DocumentClassifier] = []
        if useJev, let client = ServerClient.configured() {
            classifiers.append(ServerJevClassifier(client: client))
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), OnDeviceAIStatus.current.isAvailable {
            classifiers.append(OnDeviceClassifier())
        }
        #endif
        return ClassifierPipeline(classifiers: classifiers)
    }

    static func makeExtractor() -> (any StructuredExtractor)? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), OnDeviceAIStatus.current.isAvailable {
            return FoundationModelsExtractor()
        }
        #endif
        return nil
    }

    static func run(
        text: String,
        templates: [ScanTemplate],
        forcedTemplate: ScanTemplate? = nil,
        useJev: Bool,
        onClassified: (ScanTemplate, Classification) -> Void = { _, _ in }
    ) async -> SmartScanOutcome {
        precondition(!templates.isEmpty, "至少需要一個情境樣板")

        let result: (Classification, [String])
        if let forcedTemplate {
            result = (Classification(templateID: forcedTemplate.id, confidence: nil, probabilities: [:], provider: .manual), [])
        } else {
            result = await classifierPipeline(useJev: useJev).classify(text: text, among: templates)
        }
        let (classification, notes) = result
        let template = templates.first { $0.id == classification.templateID } ?? templates[0]
        onClassified(template, classification)

        guard let extractor = makeExtractor() else {
            return SmartScanOutcome(
                template: template,
                classification: classification,
                data: nil,
                extractionError: OnDeviceAIStatus.current.unavailableReason,
                notes: notes
            )
        }
        do {
            let data = try await extractor.extract(text: text, template: template)
            return SmartScanOutcome(template: template, classification: classification, data: data, extractionError: nil, notes: notes)
        } catch {
            return SmartScanOutcome(
                template: template,
                classification: classification,
                data: nil,
                extractionError: error.localizedDescription,
                notes: notes
            )
        }
    }
}

extension OnDeviceAIStatus {
    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// 結果頁使用的智慧掃描狀態。
@MainActor
@Observable
final class SmartScanModel {
    enum Phase {
        case idle
        case classifying
        case extracting(ScanTemplate, Classification)
        case finished(SmartScanOutcome)
    }

    private(set) var phase: Phase = .idle

    var outcome: SmartScanOutcome? {
        if case .finished(let outcome) = phase { return outcome }
        return nil
    }

    var isRunning: Bool {
        switch phase {
        case .classifying, .extracting: return true
        case .idle, .finished: return false
        }
    }

    func run(text: String, templates: [ScanTemplate], forcedTemplate: ScanTemplate? = nil, useJev: Bool) async -> SmartScanOutcome? {
        guard !isRunning, !templates.isEmpty else { return nil }
        phase = .classifying
        let outcome = await SmartScanEngine.run(
            text: text,
            templates: templates,
            forcedTemplate: forcedTemplate,
            useJev: useJev
        ) { template, classification in
            self.phase = .extracting(template, classification)
        }
        phase = .finished(outcome)
        return outcome
    }
}
