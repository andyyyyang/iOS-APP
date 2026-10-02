import Foundation

/// 樣板規則：AI 抽取後以程式確定地補上或計算欄位（固定值、加總、串接、除法、日期、代碼對照…）。
/// 金額與計算交給程式，AI 只負責讀出文件上印的內容。
///
/// 每條規則是一個物件，`set` 為目標欄位（`field` 或 `array[].field`），其餘鍵決定運算：
/// - `value`：固定值
/// - `copy`：複製另一個欄位
/// - `template`：字串樣式，`{field}` 代入欄位值
/// - `sum`：加總一或多個路徑的數字
/// - `join` + `separator`：串接路徑上的字串
/// - `divide`：[分子, 分母]，可加 `round`（小數位數）
/// - `today`：今天日期（YYYY-MM-DD）
/// - `generate`："base36time"：時間戳記 id
/// - `lookup` + `table`：依同一層的欄位值對照設定
/// - `onlyIfEmpty`：目標已有值時不覆寫
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
        }
        return nil
    }

    static func apply(
        _ rules: [JSONValue],
        to data: JSONValue,
        now: Date = Date(),
        makeID: () -> String = TemplateRules.base36TimeID
    ) -> JSONValue {
        guard case .object(var members) = data else { return data }
        for rule in rules {
            guard let target = rule["set"]?.stringValue else { continue }
            if let (arrayKey, field) = splitArrayPath(target) {
                applyToElements(rule, arrayKey: arrayKey, field: field, members: &members)
            } else {
                if rule["onlyIfEmpty"] == JSONValue.bool(true), !isEmpty(value(of: target, in: members)) { continue }
                if let result = evaluate(rule, members: members, now: now, makeID: makeID) {
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
        if case .array(let operands)? = rule["divide"], operands.count == 2,
           let numeratorPath = operands[0].stringValue, let denominatorPath = operands[1].stringValue {
            guard let numerator = value(of: numeratorPath, in: members).flatMap(number),
                  let denominator = value(of: denominatorPath, in: members).flatMap(number),
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
        return nil
    }

    private static func applyToElements(
        _ rule: JSONValue,
        arrayKey: String,
        field: String,
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
                result = evaluate(rule, members: fields, now: Date(), makeID: base36TimeID)
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
            result = result.replacingOccurrences(of: "{\(member.key)}", with: text(member.value) ?? "")
        }
        return result
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
        case .array:
            var seen = Set<String>()
            var combined: [JSONValue] = []
            for value in values {
                guard case .array(let elements) = value else { continue }
                for element in elements where !element.isBlank {
                    if seen.insert(element.compactString).inserted {
                        combined.append(element)
                    }
                }
            }
            return .array(combined)
        default:
            return values.first { !$0.isBlank } ?? .null
        }
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
