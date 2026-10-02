import Foundation

/// 樣板規則：AI 抽取後以程式確定地補上或計算欄位（固定值、加總、串接、除法、日期、代碼對照…）。
/// 金額與計算交給程式，AI 只負責讀出文件上印的內容。
///
/// 每條規則是一個物件，`set` 為目標欄位（`field` 或 `array[].field`），其餘鍵決定運算：
/// - `value`：固定值
/// - `copy`：複製另一個欄位
/// - `template`：字串樣式，`{field}` 代入欄位值，`{field:,}` 數字加千分位
/// - `sum`：加總一或多個路徑的數字
/// - `join` + `separator`：串接路徑上的字串
/// - `divide`：[分子, 分母]（路徑或數字），可加 `round`（小數位數）
/// - `match` + `separator`：以正規表示式從整份 OCR 文字找出所有符合的字串（去除重複、依出現順序串接）；
///   有括號群組時取各群組串接（例如 `(JT)[ -]?(\d{7})` 把「JT 2609240」整理成「JT2609240」）；找不到時保留原值
/// - `today`：今天日期（YYYY-MM-DD）
/// - `generate`："base36time"：時間戳記 id
/// - `lookup` + `table`：依同一層的欄位值對照設定
/// - `onlyIfEmpty`：目標已有值時不覆寫
///
/// 路徑可為 `field`、`array[].field` 或純值陣列 `array[]`。以 `_` 開頭的頂層欄位是輔助欄位：
/// 由 AI 擷取、供規則計算，最後會從輸出移除（例如報單各品項數量 → 加總成 qty）。
/// `_title`、`_subtitle` 是紀錄列表顯示的名稱與副標（例如 JT 號；總金額與單價），不會輸出。
enum TemplateRules {
    /// 規則會設定的頂層欄位；這些欄位不需要 AI 產生。
    static func topLevelTargets(of rules: [JSONValue]) -> Set<String> {
        Set(rules.compactMap { rule in
            guard let target = rule["set"]?.stringValue, !target.contains("[]") else { return nil }
            return target
        })
    }

    static func validate(_ rules: JSONValue) -> String? {
        guard case .array(let items) = rules else { return "規則必須是 JSON 陣列 [ … ]" }
        for (index, item) in items.enumerated() {
            guard case .object = item, let target = item["set"]?.stringValue, !target.isEmpty else {
                return "第 \(index + 1) 條規則缺少 \"set\""
            }
            if let pattern = item["match"]?.stringValue, (try? NSRegularExpression(pattern: pattern)) == nil {
                return "第 \(index + 1) 條規則的 match 不是有效的正規表示式"
            }
        }
        return nil
    }

    /// `text`：整份文件的 OCR 文字，供 `match` 規則使用。
    static func apply(
        _ rules: [JSONValue],
        to data: JSONValue,
        text: String = "",
        now: Date = Date(),
        makeID: () -> String = TemplateRules.base36TimeID
    ) -> JSONValue {
        guard case .object(var members) = data else { return data }
        for rule in rules {
            guard let target = rule["set"]?.stringValue else { continue }
            if let (arrayKey, field) = splitArrayPath(target) {
                applyToElements(rule, arrayKey: arrayKey, field: field, text: text, members: &members)
            } else {
                if rule["onlyIfEmpty"] == JSONValue.bool(true), !isEmpty(value(of: target, in: members)) { continue }
                if let result = evaluate(rule, members: members, text: text, now: now, makeID: makeID) {
                    set(target, to: result, in: &members)
                }
            }
        }
        return .object(members)
    }

    // MARK: - Evaluation

    private static func evaluate(
        _ rule: JSONValue,
        members: [(key: String, value: JSONValue)],
        text documentText: String,
        now: Date,
        makeID: () -> String
    ) -> JSONValue? {
        if let constant = rule["value"] {
            return constant
        }
        if let source = rule["copy"]?.stringValue {
            return value(of: source, in: members)
        }
        if let pattern = rule["template"]?.stringValue {
            return .string(render(pattern, members: members))
        }
        if case .array(let paths)? = rule["sum"] {
            let numbers = paths.compactMap(\.stringValue).flatMap { values(at: $0, in: members) }.compactMap(number)
            guard !numbers.isEmpty else { return .null }
            return .number(rounded(numbers.reduce(0, +), digits: 6))
        }
        if let path = rule["join"]?.stringValue {
            let separator = rule["separator"]?.stringValue ?? ", "
            let parts = values(at: path, in: members).compactMap(text).filter { !$0.isEmpty }
            return .string(parts.joined(separator: separator))
        }
        if case .array(let operands)? = rule["divide"], operands.count == 2 {
            guard let numerator = operand(operands[0], in: members),
                  let denominator = operand(operands[1], in: members),
                  denominator != 0 else { return .null }
            var digits = 6
            if case .number(let places)? = rule["round"] { digits = Int(places) }
            return .number(rounded(numerator / denominator, digits: digits))
        }
        if rule["today"] == JSONValue.bool(true) {
            return .string(dateFormatter.string(from: now))
        }
        if rule["generate"]?.stringValue == "base36time" {
            return .string(makeID())
        }
        if let keyField = rule["lookup"]?.stringValue, case .object(let table)? = rule["table"] {
            guard let key = value(of: keyField, in: members).flatMap(text) else { return nil }
            return table.first { $0.key == key }?.value
        }
        if let pattern = rule["match"]?.stringValue {
            let found = matches(of: pattern, in: documentText)
            guard !found.isEmpty else { return nil }
            return .string(found.joined(separator: rule["separator"]?.stringValue ?? ", "))
        }
        return nil
    }

    /// 所有符合的字串（去除重複、依出現順序）；有括號群組時取各群組串接。
    static func matches(of pattern: String, in text: String) -> [String] {
        guard !text.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let ranges = match.numberOfRanges > 1 ? (1..<match.numberOfRanges).map { match.range(at: $0) } : [match.range]
            let piece = ranges.compactMap { Range($0, in: text).map { String(text[$0]) } }.joined()
            if !piece.isEmpty, !found.contains(piece) {
                found.append(piece)
            }
        }
        return found
    }

    /// `divide` 的運算元：欄位路徑或數字。
    private static func operand(_ operand: JSONValue, in members: [(key: String, value: JSONValue)]) -> Double? {
        switch operand {
        case .number(let constant): return constant
        case .string(let path): return value(of: path, in: members).flatMap(number)
        default: return nil
        }
    }

    private static func applyToElements(
        _ rule: JSONValue,
        arrayKey: String,
        field: String,
        text documentText: String,
        members: inout [(key: String, value: JSONValue)]
    ) {
        guard case .array(let elements)? = value(of: arrayKey, in: members) else { return }
        let updated = elements.map { element -> JSONValue in
            guard case .object(var fields) = element else { return element }
            if rule["onlyIfEmpty"] == JSONValue.bool(true), !isEmpty(value(of: field, in: fields)) { return element }
            let result: JSONValue?
            if let keyField = rule["lookup"]?.stringValue, case .object(let table)? = rule["table"] {
                result = value(of: keyField, in: fields).flatMap(text).flatMap { key in table.first { $0.key == key }?.value }
            } else {
                result = evaluate(rule, members: fields, text: documentText, now: Date(), makeID: base36TimeID)
            }
            if let result { set(field, to: result, in: &fields) }
            return .object(fields)
        }
        set(arrayKey, to: .array(updated), in: &members)
    }

    // MARK: - Paths

    /// "taxItems[].name" → ("taxItems", "name")
    private static func splitArrayPath(_ path: String) -> (String, String)? {
        let parts = path.components(separatedBy: "[].")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    private static func value(of key: String, in members: [(key: String, value: JSONValue)]) -> JSONValue? {
        members.first { $0.key == key }?.value
    }

    private static func values(at path: String, in members: [(key: String, value: JSONValue)]) -> [JSONValue] {
        // "quantities[]"：純值陣列的所有元素
        if path.hasSuffix("[]"), !path.contains("[]."), case .array(let elements)? = value(of: String(path.dropLast(2)), in: members) {
            return elements
        }
        if let (arrayKey, field) = splitArrayPath(path) {
            guard case .array(let elements)? = value(of: arrayKey, in: members) else { return [] }
            return elements.compactMap { $0[field] }
        }
        return value(of: path, in: members).map { [$0] } ?? []
    }

    private static func set(_ key: String, to newValue: JSONValue, in members: inout [(key: String, value: JSONValue)]) {
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = newValue
        } else {
            members.append((key: key, value: newValue))
        }
    }

    // MARK: - Helpers

    private static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let number): return number
        case .string(let text): return Double(text.replacingOccurrences(of: ",", with: ""))
        default: return nil
        }
    }

    private static func text(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return text
        case .number(let number): return JSONValue.format(number)
        case .bool(let flag): return flag ? "true" : "false"
        default: return nil
        }
    }

    private static func isEmpty(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: return true
        case .string(let text)?: return text.isEmpty
        default: return false
        }
    }

    private static func render(_ pattern: String, members: [(key: String, value: JSONValue)]) -> String {
        var result = pattern
        for member in members {
            if result.contains("{\(member.key):,}") {
                result = result.replacingOccurrences(of: "{\(member.key):,}", with: grouped(member.value) ?? "")
            }
            result = result.replacingOccurrences(of: "{\(member.key)}", with: text(member.value) ?? "")
        }
        return result
    }

    /// 數字加千分位（13146 → 13,146）；非數字照原樣。
    private static func grouped(_ value: JSONValue) -> String? {
        guard case .number(let number) = value else { return text(value) }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSNumber(value: number))
    }

    static func rounded(_ value: Double, digits: Int) -> Double {
        let factor = pow(10, Double(max(0, min(digits, 10))))
        return (value * factor).rounded() / factor
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 與使用者既有紀錄相同格式的 id：毫秒時間戳記（36 進位）＋ 3 個隨機字元。
    static func base36TimeID() -> String {
        let milliseconds = Int(Date().timeIntervalSince1970 * 1000)
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let suffix = String((0..<3).map { _ in alphabet.randomElement()! })
        return String(milliseconds, radix: 36) + suffix
    }
}

// MARK: - 多頁合併

extension JSONValue {
    /// 合併多頁分別抽取的結果（皆已符合樣板結構）：
    /// 單一值取第一個非空值；陣列依頁序串接，並移除空白與重複的項目。
    static func merged(_ values: [JSONValue], sample: JSONValue) -> JSONValue {
        guard let first = values.first else { return .null }
        guard values.count > 1 else { return first }
        switch sample {
        case .object(let sampleMembers):
            return .object(sampleMembers.map { member in
                (key: member.key, value: merged(values.compactMap { $0[member.key] }, sample: member.value))
            })
        case .array(let sampleElements):
            var combined: [JSONValue] = []
            if case .object? = sampleElements.first {
                // 物件項目（例如每張發票）：逐項去除重複，避免同一頁掃兩次重複計入
                var seen = Set<String>()
                for value in values {
                    guard case .array(let elements) = value else { continue }
                    for element in elements where !element.isBlank && seen.insert(element.compactString).inserted {
                        combined.append(element)
                    }
                }
            } else {
                // 純值項目（例如報單各品項數量）：同一頁內的相同數值都要保留，只略過整頁重複的結果
                var seenPages = Set<String>()
                for value in values {
                    guard case .array(let elements) = value else { continue }
                    let kept = elements.filter { !$0.isBlank }
                    guard !kept.isEmpty, seenPages.insert(JSONValue.array(kept).compactString).inserted else { continue }
                    combined.append(contentsOf: kept)
                }
            }
            return .array(combined)
        default:
            return values.first { !$0.isBlank } ?? .null
        }
    }

    /// 移除以 `_` 開頭的頂層輔助欄位：它們只提供給規則計算，不屬於輸出格式。
    func removingHelperFields() -> JSONValue {
        guard case .object(let members) = self else { return self }
        return .object(members.filter { !$0.key.hasPrefix("_") })
    }

    /// null、空字串、空陣列，或所有欄位都是空值的物件。
    var isBlank: Bool {
        switch self {
        case .null: return true
        case .string(let text): return text.trimmingCharacters(in: .whitespaces).isEmpty
        case .array(let elements): return elements.allSatisfy(\.isBlank)
        case .object(let members): return members.allSatisfy { $0.value.isBlank }
        case .number, .bool: return false
        }
    }
}

// MARK: - 紀錄名稱與副標

extension TemplateRules {
    static let titleField = "_title"
    static let subtitleField = "_subtitle"

    /// 紀錄的名稱與副標：以最終資料計算樣板中 `set` 為 `_title`／`_subtitle` 的規則。
    /// `template` 以「 · 」分段，欄位沒有值的段落會省略（例如還沒有單價時只顯示總金額）。
    static func display(rules: [JSONValue], data: JSONValue) -> (title: String?, subtitle: String?) {
        guard case .object(let members) = data else { return (nil, nil) }
        func compute(_ field: String) -> String? {
            guard let rule = rules.last(where: { $0["set"]?.stringValue == field }) else { return nil }
            let rendered: String?
            if let pattern = rule["template"]?.stringValue {
                let segments = pattern.components(separatedBy: " · ").filter { segment in
                    placeholders(in: segment).allSatisfy { !isEmpty(value(of: $0, in: members)) }
                }
                rendered = render(segments.joined(separator: " · "), members: members)
            } else {
                rendered = evaluate(rule, members: members, text: "", now: Date(), makeID: { "" }).flatMap(text)
            }
            let trimmed = rendered?.trimmingCharacters(in: .whitespaces) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return (compute(titleField), compute(subtitleField))
    }

    /// 字串樣式中的欄位名稱：「總金額 {amount:,}」→ ["amount"]。
    private static func placeholders(in pattern: String) -> [String] {
        matches(of: "\\{([^{}:]+)(?::,)?\\}", in: pattern)
    }
}

// MARK: - 防止照抄與編造

extension JSONValue {
    /// 移除在頁面文字中找不到的數字與代碼（含 6 個以上數字的字串，例如發票號碼、統編），避免模型照抄範例或編造。
    /// 比對時只看英數字並校正常見 OCR 混淆（O→0、I/l→1），所以「FR-14077356」「1,556」都對得上。
    /// 日期（可能由民國年換算）與一般文字不檢查。
    func grounded(in pageText: String) -> JSONValue {
        grounded(haystack: Self.groundingKey(pageText))
    }

    private func grounded(haystack: String) -> JSONValue {
        switch self {
        case .object(let members):
            return .object(members.map { (key: $0.key, value: $0.value.grounded(haystack: haystack)) })
        case .array(let elements):
            return .array(elements.compactMap { element in
                let checked = element.grounded(haystack: haystack)
                switch (element, checked) {
                case (.number, .null), (.string, .null): return nil
                default: return checked
                }
            })
        case .number(let number):
            return haystack.contains(Self.groundingKey(Self.format(number))) ? self : .null
        case .string(let text):
            guard Self.needsGrounding(text) else { return self }
            return haystack.contains(Self.groundingKey(text)) ? self : .null
        case .bool, .null:
            return self
        }
    }

    private static func needsGrounding(_ text: String) -> Bool {
        let digits = text.filter { $0.isASCII && $0.isNumber }.count
        guard digits >= 6 else { return false }
        return text.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) == nil
    }

    private static func groundingKey(_ text: String) -> String {
        String(text.uppercased().compactMap { character -> Character? in
            switch character {
            case "O": return "0"
            case "I", "L", "|": return "1"
            default: return character.isASCII && (character.isLetter || character.isNumber) ? character : nil
            }
        })
    }
}
