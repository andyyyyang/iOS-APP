import Foundation

/// 一個機種與它的整理筆記（主卡）：手寫的「#代號」依它模糊比對，連到這則筆記。
struct ModelEntry: Identifiable, Hashable, Sendable {
    /// 產品代號，例如 0851563HS、CV90-A3316-X1、PLP0263E。
    let code: String
    /// 主卡的路徑。
    let path: String
    /// 主卡的檔名（連結用）。
    let title: String
    /// 其他寫法：開案單號、SAP 料號、客戶料號、專案代稱…
    let aliases: [String]
    let customer: String
    /// 尺寸、產品線等簡短說明。
    let detail: String

    var id: String { path }
}

/// 比對結果：分數 1 是完全相同，越低越不確定。
struct ModelMatch: Equatable, Sendable {
    let entry: ModelEntry
    let score: Double
}

/// 機種清單與模糊比對。清單來自伺服器的 vault 索引：frontmatter `type: model` 的筆記，或檔名是「代號 主卡」的筆記
/// （開案資料夾的慣例）。手寫辨識常把 O/0、I/1、S/5 認錯，比對時兩邊都換成同一種寫法再比。
enum ModelCatalog {
    static let mainCardSuffix = " 主卡"

    // MARK: 清單

    static func entries(from notes: [VaultIndex.Note]) -> [ModelEntry] {
        var byCode: [String: (entry: ModelEntry, rank: Int)] = [:]
        for note in notes {
            let stem = ((note.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let props = note.properties
            let type = text(props, "type")
            let rank: Int
            var code = text(props, "code")
            if type == "model" {
                rank = 2
            } else if stem.hasSuffix(mainCardSuffix) {
                rank = 1
            } else {
                continue
            }
            if code.isEmpty {
                code = stem.hasSuffix(mainCardSuffix) ? String(stem.dropLast(mainCardSuffix.count)) : stem
            }
            code = code.trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty else { continue }
            let folder = (note.path as NSString).deletingLastPathComponent
            var aliases = note.aliases
            for key in ["aliases", "case_no", "sap_no", "customer_pn", "pn", "project"] {
                aliases += list(props, key)
            }
            // 開案資料夾「T12608029 60016062 0851563HS 44.6x57.6 T3.038」中的開案單號與 SAP 料號
            aliases += caseNumbers(in: (folder as NSString).lastPathComponent)
            let customer = text(props, "customer").isEmpty ? customerFromPath(note.path) : text(props, "customer")
            let detail = [text(props, "product_line"), text(props, "size"), text(props, "thickness")]
                .filter { !$0.isEmpty }.joined(separator: " ")
            let entry = ModelEntry(
                code: code, path: note.path, title: stem,
                aliases: unique(aliases.filter { normalize($0) != normalize(code) }),
                customer: customer, detail: detail
            )
            let key = normalize(code)
            if let existing = byCode[key], existing.rank >= rank { continue }
            byCode[key] = (entry, rank)
        }
        return byCode.values.map(\.entry).sorted { $0.code.localizedStandardCompare($1.code) == .orderedAscending }
    }

    /// 沒有伺服器索引時（只用 WebDAV）：依這台裝置上的筆記檔名找「代號 主卡」。
    static func entries(fromNotePaths paths: [String]) -> [ModelEntry] {
        paths.compactMap { path in
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard stem.hasSuffix(mainCardSuffix) else { return nil }
            let code = String(stem.dropLast(mainCardSuffix.count)).trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty else { return nil }
            return ModelEntry(code: code, path: path, title: stem,
                              aliases: caseNumbers(in: ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent),
                              customer: customerFromPath(path), detail: "")
        }
    }

    // MARK: 比對

    /// 依手寫（辨識出來）的文字找機種，最可能的在前；沒有夠像的就是空陣列。
    static func match(_ raw: String, in entries: [ModelEntry], limit: Int = 4) -> [ModelMatch] {
        let query = normalize(raw)
        guard query.count >= 3 else { return [] }
        let queryShape = shape(query)
        var best: [String: ModelMatch] = [:]
        for entry in entries {
            var score = 0.0
            for key in [entry.code] + entry.aliases {
                let normalized = normalize(key)
                guard normalized.count >= 3 else { continue }
                score = max(score, similarity(query: query, queryShape: queryShape, key: normalized) * (key == entry.code ? 1 : 0.97))
            }
            if score > 0, score > (best[entry.path]?.score ?? 0) {
                best[entry.path] = ModelMatch(entry: entry, score: score)
            }
        }
        var results = best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry.code < $1.entry.code }
        // 只靠「包含」比對到很多個時不算數（太模糊）
        if let first = results.first, first.score < 0.7, results.count > 1, results[1].score == first.score {
            results = []
        }
        return Array(results.prefix(limit))
    }

    /// 自動連結：最可能的機種夠確定、而且明顯比第二名像時才回傳。
    static func confidentMatch(_ matches: [ModelMatch]) -> ModelEntry? {
        guard let first = matches.first, first.score >= 0.8 else { return nil }
        if matches.count > 1, matches[1].score >= first.score - 0.05 { return nil }
        return first.entry
    }

    static func similarity(query: String, queryShape: String, key: String) -> Double {
        if query == key { return 1 }
        let keyShape = shape(key)
        if queryShape == keyShape { return 0.95 }
        // 少寫了後綴（0851563 → 0851563HS）或前綴
        if query.count >= 5, key.hasPrefix(query) || keyShape.hasPrefix(queryShape) { return 0.88 }
        if query.count >= 6, key.hasSuffix(query) || keyShape.hasSuffix(queryShape) { return 0.82 }
        let distance = levenshtein(Array(queryShape), Array(keyShape))
        let length = max(queryShape.count, keyShape.count)
        if length >= 5, distance == 1 { return 0.8 }
        if length >= 8, distance == 2 { return 0.66 }
        if query.count >= 4, key.contains(query) || keyShape.contains(queryShape) { return 0.6 }
        return 0
    }

    // MARK: 正規化

    /// 大寫、全形轉半形，只留英數字（去掉 #、空白、-、_、.）。
    static func normalize(_ text: String) -> String {
        let half = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return String(half.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
    }

    /// 手寫辨識容易互相認錯的字換成同一個（兩邊都換，O 與 0 就會一樣）。
    static func shape(_ normalized: String) -> String {
        String(normalized.map { character -> Character in
            switch character {
            case "O", "Q", "D": return "0"
            case "I", "L", "|", "T": return "1"
            case "Z": return "2"
            case "S": return "5"
            case "B": return "8"
            case "G": return "6"
            default: return character
            }
        })
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, cb) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: 工具

    /// 開案資料夾名稱中的開案單號（T/S + 8 碼）與 SAP 料號（600 開頭 8 碼）。
    static func caseNumbers(in folderName: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9])([TS]\d{8}|600\d{5})(?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(folderName.startIndex..., in: folderName)
        return regex.matches(in: folderName, range: range).compactMap { Range($0.range(at: 1), in: folderName).map { String(folderName[$0]) } }
    }

    /// 「05 客戶案件/02 正式開案 NPI/Amkor/…」中的客戶名稱。
    static func customerFromPath(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(where: { $0.contains("正式開案") || $0.contains("詢報價") }), index + 2 < parts.count else { return "" }
        return parts[index + 1]
    }

    private static func text(_ properties: [String: VaultIndex.Property], _ key: String) -> String {
        switch properties[key] {
        case .text(let value): return value
        case .list(let values): return values.joined(separator: ", ")
        case .empty, .none: return ""
        }
    }

    private static func list(_ properties: [String: VaultIndex.Property], _ key: String) -> [String] {
        switch properties[key] {
        case .text(let value): return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case .list(let values): return values
        case .empty, .none: return []
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert(normalize($0)).inserted }
    }
}
