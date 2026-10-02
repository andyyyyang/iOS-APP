import Foundation

/// 保留物件鍵值順序的 JSON 值。
/// 樣板的欄位順序就是輸出的欄位順序，而 JSONSerialization 不保證順序，所以自行解析與輸出。
indirect enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - 解析

extension JSONValue {
    struct ParseError: LocalizedError, Equatable {
        let message: String
        let offset: Int

        var errorDescription: String? { "JSON 格式錯誤（第 \(offset) 個字元附近）：\(message)" }
    }

    static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw parser.error("多餘的內容") }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        var isAtEnd: Bool { index >= scalars.count }

        private static let whitespace: Set<Unicode.Scalar> = [" ", "\n", "\r", "\t"]

        func error(_ message: String) -> ParseError {
            ParseError(message: message, offset: index)
        }

        mutating func skipWhitespace() {
            while !isAtEnd, Self.whitespace.contains(scalars[index]) {
                index += 1
            }
        }

        mutating func parseValue() throws -> JSONValue {
            skipWhitespace()
            guard !isAtEnd else { throw error("內容不完整") }
            switch scalars[index] {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t": try expect("true"); return .bool(true)
            case "f": try expect("false"); return .bool(false)
            case "n": try expect("null"); return .null
            case "-", "0"..."9": return .number(try parseNumber())
            default: throw error("無法辨識的字元「\(scalars[index])」")
            }
        }

        mutating func expect(_ literal: String) throws {
            for scalar in literal.unicodeScalars {
                guard !isAtEnd, scalars[index] == scalar else { throw error("預期為 \(literal)") }
                index += 1
            }
        }

        mutating func parseObject() throws -> JSONValue {
            index += 1
            var members: [(key: String, value: JSONValue)] = []
            skipWhitespace()
            if !isAtEnd, scalars[index] == "}" {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard !isAtEnd, scalars[index] == "\"" else { throw error("物件的鍵必須是字串") }
                let key = try parseString()
                skipWhitespace()
                guard !isAtEnd, scalars[index] == ":" else { throw error("缺少冒號") }
                index += 1
                let value = try parseValue()
                if let existing = members.firstIndex(where: { $0.key == key }) {
                    members[existing].value = value
                } else {
                    members.append((key: key, value: value))
                }
                skipWhitespace()
                guard !isAtEnd else { throw error("物件沒有結束") }
                if scalars[index] == "," {
                    index += 1
                } else if scalars[index] == "}" {
                    index += 1
                    return .object(members)
                } else {
                    throw error("缺少逗號或右大括號")
                }
            }
        }

        mutating func parseArray() throws -> JSONValue {
            index += 1
            var elements: [JSONValue] = []
            skipWhitespace()
            if !isAtEnd, scalars[index] == "]" {
                index += 1
                return .array(elements)
            }
            while true {
                elements.append(try parseValue())
                skipWhitespace()
                guard !isAtEnd else { throw error("陣列沒有結束") }
                if scalars[index] == "," {
                    index += 1
                } else if scalars[index] == "]" {
                    index += 1
                    return .array(elements)
                } else {
                    throw error("缺少逗號或右中括號")
                }
            }
        }

        mutating func parseString() throws -> String {
            index += 1
            var result = String.UnicodeScalarView()
            while true {
                guard !isAtEnd else { throw error("字串沒有結束") }
                let scalar = scalars[index]
                index += 1
                switch scalar {
                case "\"":
                    return String(result)
                case "\\":
                    guard !isAtEnd else { throw error("跳脫字元不完整") }
                    let escaped = scalars[index]
                    index += 1
                    switch escaped {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    case "b": result.append("\u{08}")
                    case "f": result.append("\u{0C}")
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "u": result.append(try parseUnicodeEscape())
                    default: throw error("不支援的跳脫字元")
                    }
                default:
                    result.append(scalar)
                }
            }
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= scalars.count else { throw error("\\u 跳脫不完整") }
            let hex = String(String.UnicodeScalarView(scalars[index..<index + 4]))
            guard let value = UInt32(hex, radix: 16) else { throw error("\\u 跳脫格式錯誤") }
            index += 4
            return value
        }

        mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
            let high = try parseHex4()
            if (0xD800...0xDBFF).contains(high) {
                // UTF-16 代理對
                guard index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" else {
                    throw error("缺少低位代理")
                }
                index += 2
                let low = try parseHex4()
                guard (0xDC00...0xDFFF).contains(low),
                      let scalar = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)) else {
                    throw error("代理對錯誤")
                }
                return scalar
            }
            guard let scalar = Unicode.Scalar(high) else { throw error("無效的 Unicode") }
            return scalar
        }

        mutating func parseNumber() throws -> Double {
            let start = index
            if scalars[index] == "-" { index += 1 }
            while !isAtEnd, "0123456789.eE+-".unicodeScalars.contains(scalars[index]) {
                index += 1
            }
            let literal = String(String.UnicodeScalarView(scalars[start..<index]))
            guard let value = Double(literal), value.isFinite else { throw error("數字格式錯誤") }
            return value
        }
    }
}

// MARK: - 輸出

extension JSONValue {
    /// 縮排兩個空白的 JSON 文字，鍵值順序維持不變。
    func prettyPrinted(indent: Int = 2) -> String {
        var output = ""
        write(to: &output, indent: indent, level: 0)
        return output
    }

    var compactString: String {
        var output = ""
        write(to: &output, indent: nil, level: 0)
        return output
    }

    private func write(to output: inout String, indent: Int?, level: Int) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .number(let value):
            output += Self.format(value)
        case .string(let value):
            output += Self.quote(value)
        case .array(let elements):
            guard !elements.isEmpty else { output += "[]"; return }
            output += "["
            for (offset, element) in elements.enumerated() {
                if offset > 0 { output += "," }
                newline(&output, indent: indent, level: level + 1)
                element.write(to: &output, indent: indent, level: level + 1)
            }
            newline(&output, indent: indent, level: level)
            output += "]"
        case .object(let members):
            guard !members.isEmpty else { output += "{}"; return }
            output += "{"
            for (offset, member) in members.enumerated() {
                if offset > 0 { output += "," }
                newline(&output, indent: indent, level: level + 1)
                output += Self.quote(member.key)
                output += indent == nil ? ":" : ": "
                member.value.write(to: &output, indent: indent, level: level + 1)
            }
            newline(&output, indent: indent, level: level)
            output += "}"
        }
    }

    private func newline(_ output: inout String, indent: Int?, level: Int) {
        guard let indent else { return }
        output += "\n" + String(repeating: " ", count: indent * level)
    }

    /// 整數不輸出小數點（45 而不是 45.0）。
    static func format(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 {
            return String(Int64(number))
        }
        return String(number)
    }

    static func quote(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

// MARK: - 依樣板整理輸出

extension JSONValue {
    /// 讓產生的資料符合樣板結構：欄位順序與樣板相同、缺少的欄位補 null、移除樣板沒有的欄位、
    /// 型別不符時盡量轉換（例如 "45" → 45），無法轉換則為 null。
    func conformed(to sample: JSONValue) -> JSONValue {
        switch (sample, self) {
        case (_, .null):
            return .null
        case (.object(let sampleMembers), .object):
            return .object(sampleMembers.map { member in
                (key: member.key, value: (self[member.key] ?? .null).conformed(to: member.value))
            })
        case (.object, _):
            return .null
        case (.array(let sampleElements), .array(let elements)):
            guard let elementSample = sampleElements.first else { return .array(elements) }
            return .array(elements.map { $0.conformed(to: elementSample) })
        case (.array(let sampleElements), _):
            // 單一值包成陣列
            guard let elementSample = sampleElements.first else { return .array([self]) }
            return .array([conformed(to: elementSample)])
        case (.number, .number), (.bool, .bool), (.string, .string):
            return self
        case (.number, .string(let text)):
            let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
            return Double(cleaned).map(JSONValue.number) ?? .null
        case (.bool, .string(let text)):
            switch text.lowercased() {
            case "true", "yes", "是": return .bool(true)
            case "false", "no", "否": return .bool(false)
            default: return .null
            }
        case (.string, .number(let number)):
            return .string(Self.format(number))
        case (.string, .bool(let value)):
            return .string(value ? "true" : "false")
        case (.null, .string), (.null, .number), (.null, .bool):
            return self
        default:
            return .null
        }
    }
}
