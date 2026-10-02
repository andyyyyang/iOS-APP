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
    /// 判斷依據（只在 App 顯示，不上傳）。
    var reason: String? = nil

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

/// 強特徵：以 `!` 開頭的關鍵字（例如統一編號、公司名稱），只出現在該情境的文件上。
/// 只有一個情境命中時直接判定，不交給 AI；同時命中多個情境則交由後續分類器。
struct SignalClassifier: DocumentClassifier {
    struct NotDecisive: LocalizedError {
        var errorDescription: String? { "沒有可直接判定的強特徵" }
    }

    var provider: Classification.Provider { .keywords }

    func classify(text: String, among templates: [ScanTemplate]) async throws -> Classification {
        guard let result = Self.classify(text: text, among: templates) else { throw NotDecisive() }
        return result
    }

    static func classify(text: String, among templates: [ScanTemplate]) -> Classification? {
        let matches = templates.compactMap { template -> (id: String, hits: [String])? in
            let hits = template.strongSignals.filter { text.localizedCaseInsensitiveContains($0) }
            return hits.isEmpty ? nil : (template.id, hits)
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        return Classification(
            templateID: match.id,
            confidence: 1,
            probabilities: [match.id: 1],
            provider: .keywords,
            reason: "依強特徵「\(match.hits.prefix(3).joined(separator: "、"))」判斷"
        )
    }
}

/// 離線備援：依樣板關鍵字出現次數判斷。永遠不會失敗。
/// 「一般文件」只在其他情境都沒有命中時才勝出（權重較低）。
struct KeywordClassifier: DocumentClassifier {
    var provider: Classification.Provider { .keywords }

    func classify(text: String, among templates: [ScanTemplate]) async throws -> Classification {
        Self.classify(text: text, among: templates)
    }

    static func classify(text: String, among templates: [ScanTemplate]) -> Classification {
        if let strong = SignalClassifier.classify(text: text, among: templates) {
            return strong
        }
        let scores = templates.map { template -> (id: String, score: Double) in
            let words = template.keywords.map { $0.hasPrefix("!") ? String($0.dropFirst()) : $0 }
            let hits = words.filter { !$0.isEmpty && text.localizedCaseInsensitiveContains($0) }.count
            let weight = template.id == ScanTemplate.fallbackID ? 0.5 : 1
            return (template.id, Double(hits) * weight)
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

    init(classifiers: [any DocumentClassifier]) {
        self.classifiers = classifiers
    }

    func classify(text: String, among templates: [ScanTemplate]) async -> (Classification, [String]) {
        var failures: [String] = []
        // 強特徵最優先：命中唯一情境時不需要呼叫 AI 或網路
        if let strong = SignalClassifier.classify(text: text, among: templates) {
            return (strong, [])
        }
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
