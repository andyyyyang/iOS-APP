import Foundation

/// 情境判斷結果。
struct Classification: Equatable {
    enum Provider: String {
        case jev
        case onDevice = "on-device"
        case keywords
        case manual

        var displayName: String {
            switch self {
            case .jev: return "Jev"
            case .onDevice: return "Apple Intelligence"
            case .keywords: return "關鍵字"
            case .manual: return "手動選擇"
            }
        }
    }

    var templateID: String
    var confidence: Double?
    var probabilities: [String: Double]
    var provider: Provider

    var jsonValue: JSONValue {
        var members: [(key: String, value: JSONValue)] = [
            (key: "templateId", value: .string(templateID)),
            (key: "confidence", value: confidence.map(JSONValue.number) ?? .null),
            (key: "provider", value: .string(provider.rawValue)),
        ]
        if !probabilities.isEmpty {
            let sorted = probabilities.sorted { $0.value > $1.value }
            members.append((key: "probabilities", value: .object(sorted.map { (key: $0.key, value: JSONValue.number($0.value)) })))
        }
        return .object(members)
    }
}

/// 判斷 OCR 文字屬於哪個情境。新增分類來源（例如其他雲端模型）只要實作這個協定並加入 `ClassifierPipeline`。
protocol DocumentClassifier {
    var provider: Classification.Provider { get }
    func classify(text: String, among templates: [ScanTemplate]) async throws -> Classification
}

/// 離線備援：依樣板關鍵字出現次數判斷。永遠不會失敗。
struct KeywordClassifier: DocumentClassifier {
    var provider: Classification.Provider { .keywords }

    func classify(text: String, among templates: [ScanTemplate]) async throws -> Classification {
        Self.classify(text: text, among: templates)
    }

    static func classify(text: String, among templates: [ScanTemplate]) -> Classification {
        let scores = templates.map { template -> (id: String, score: Double) in
            let hits = template.keywords.filter { !$0.isEmpty && text.localizedCaseInsensitiveContains($0) }.count
            return (template.id, Double(hits))
        }
        let total = scores.reduce(0) { $0 + $1.score }
        guard total > 0, let best = scores.max(by: { $0.score < $1.score }) else {
            let fallback = templates.first { $0.id == ScanTemplate.fallbackID }?.id ?? templates.first?.id ?? ScanTemplate.fallbackID
            return Classification(templateID: fallback, confidence: nil, probabilities: [:], provider: .keywords)
        }
        var probabilities: [String: Double] = [:]
        for entry in scores where entry.score > 0 {
            probabilities[entry.id] = entry.score / total
        }
        return Classification(templateID: best.id, confidence: best.score / total, probabilities: probabilities, provider: .keywords)
    }
}

/// 依序嘗試多個分類器，第一個成功的結果勝出；全部失敗時使用關鍵字分類。
struct ClassifierPipeline {
    var classifiers: [any DocumentClassifier]

    func classify(text: String, among templates: [ScanTemplate]) async -> (Classification, [String]) {
        var failures: [String] = []
        for classifier in classifiers {
            do {
                let result = try await classifier.classify(text: text, among: templates)
                if templates.contains(where: { $0.id == result.templateID }) {
                    return (result, failures)
                }
                failures.append("\(classifier.provider.displayName)：回傳了不存在的情境")
            } catch {
                failures.append("\(classifier.provider.displayName)：\(error.localizedDescription)")
            }
        }
        return (KeywordClassifier.classify(text: text, among: templates), failures)
    }
}

/// 透過自己的伺服器呼叫 Jev（TypeSafe AI）。金鑰只存在伺服器，App 不接觸。
struct ServerJevClassifier: DocumentClassifier {
    let client: ServerClient

    var provider: Classification.Provider { .jev }

    func classify(text: String, among templates: [ScanTemplate]) async throws -> Classification {
        try await client.classify(text: text, templateIDs: templates.map(\.id))
    }
}
