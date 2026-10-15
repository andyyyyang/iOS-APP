import Foundation
import Observation

// 「Jentech 業務快查與物流中心」（Obsidian 插件 jentech-tools，原始碼在 vault 的 scratch/plugin_src）的資料：
// 通訊錄（全公司完整通訊錄.md 的表格）、客戶與 SAP T-Code、開案 Checklist、BPM 追蹤（06 日誌/BPM 追蹤/latest.json）、
// 人員與客戶卡片、SOP 導覽、黑貓託運名冊（ezprint CSV）。客戶、代碼、案件與卡片來自伺服器的 vault 索引（筆記屬性），
// 通訊錄、BPM 與 CSV 讀取檔案內容。

/// 通訊錄的一筆。
struct JentechContact: Identifiable, Equatable, Sendable {
    /// 在通訊錄中的順序（同一人可能列在不同課別，id 要唯一）。
    var order: Int
    var plant: String
    var dept: String
    /// 原始欄位（可能含 [[連結]]）。
    var rawName: String
    var ext: String
    var mvpn: String

    var id: Int { order }
    var name: String { JentechLogic.displayName(rawName) }
    /// [[連結]] 指向的筆記。
    var linkTarget: String? { JentechLogic.linkTarget(rawName) }
    /// 複製時用的號碼：有分機用分機，否則 MVPN（同插件）。
    var copyValue: String { JentechLogic.hasNumber(ext) ? ext : (JentechLogic.hasNumber(mvpn) ? mvpn : "") }
}

/// 代碼查詢的一筆：客戶或 SAP T-Code。
struct JentechCode: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case customer = "客戶", tcode = "TCode" }
    var kind: Kind
    var code: String
    var alias: String
    var name: String
    var fullName: String
    var detail: String
    var path: String

    var id: String { path }
    /// 「別稱 / 客代」或代碼。
    var displayCode: String { alias.isEmpty ? (code.isEmpty ? "—" : code) : "\(alias) / \(code)" }
}

/// 開案 Checklist。
struct JentechCase: Identifiable, Equatable, Sendable {
    var path: String
    var file: String
    var caseNo: String
    var sapNo: String
    var product: String
    var customer: String
    var osat: String
    var bpmRdmn: String
    var created: String

    var id: String { path }
}

/// BPM 追蹤（scripts/bpm_tracking.py 寫的 latest.json）。
struct JentechBpm: Decodable, Equatable, Sendable {
    struct Item: Decodable, Equatable, Identifiable, Sendable {
        var idx: String
        var status: String
        var processName: String
        var subject: String
        var currentStep: String
        var signTime: String
        var daysStuck: Int?
        var isWorking: Bool

        var id: String { "\(idx)|\(processName)|\(subject)" }

        private enum CodingKeys: String, CodingKey {
            case idx, status, subject
            case processName = "process_name"
            case currentStep = "current_step"
            case signTime = "sign_time"
            case daysStuck = "days_stuck"
            case isWorking = "is_working"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? container.decode(Int.self, forKey: .idx) { idx = String(number) } else { idx = (try? container.decode(String.self, forKey: .idx)) ?? "" }
            status = (try? container.decode(String.self, forKey: .status)) ?? ""
            processName = (try? container.decode(String.self, forKey: .processName)) ?? ""
            subject = (try? container.decode(String.self, forKey: .subject)) ?? ""
            currentStep = (try? container.decode(String.self, forKey: .currentStep)) ?? ""
            signTime = (try? container.decode(String.self, forKey: .signTime)) ?? ""
            daysStuck = try? container.decode(Int.self, forKey: .daysStuck)
            isWorking = (try? container.decode(Bool.self, forKey: .isWorking)) ?? false
        }
    }

    var fetchedAt: String
    var total: Int
    var stuckThreshold: Int
    var items: [Item]

    private enum CodingKeys: String, CodingKey {
        case items, total
        case fetchedAt = "fetched_at"
        case stuckThreshold = "stuck_threshold"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = (try? container.decode(String.self, forKey: .fetchedAt)) ?? ""
        items = (try? container.decode([Item].self, forKey: .items)) ?? []
        total = (try? container.decode(Int.self, forKey: .total)) ?? items.count
        stuckThreshold = (try? container.decode(Int.self, forKey: .stuckThreshold)) ?? 3
    }

    /// 卡關 ≥ 門檻天數、不是工程做樣中的（要催）。
    var stuck: [Item] { items.filter { ($0.daysStuck ?? -1) >= stuckThreshold && !$0.isWorking } }
    /// 卡關 ≥ 門檻但正常工作中。
    var working: [Item] { items.filter { ($0.daysStuck ?? -1) >= stuckThreshold && $0.isWorking } }
}

/// 人員卡或客戶卡（03 人員／04 客戶下的筆記）。
struct JentechCard: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case person, customer }
    var kind: Kind
    var path: String
    var name: String
    var english: String

    var id: String { path }
}

/// SOP 導覽的一項（同插件的清單）。
struct JentechSop: Identifiable, Equatable, Sendable {
    var stage: String
    var name: String
    var file: String
    var tags: [String]

    var id: String { file }
}

/// 黑貓託運名冊（ezprint CSV）的一筆。
struct JentechShipment: Identifiable, Equatable, Sendable {
    var recipient: String
    var phone: String
    var mobile: String
    var address: String
    var item: String
    var orderNo: String
    var shipDate: String

    var id: String { "\(orderNo)|\(recipient)|\(address)" }
}

/// 純函式（方便測試）。
enum JentechLogic {
    static let plants = ["華亞廠", "大園一廠", "大園二廠", "平鎮廠"]
    static let directoryPath = "03 人員/通訊錄/全公司完整通訊錄.md"
    static let bpmPath = "06 日誌/BPM 追蹤/latest.json"

    /// 通訊錄：四個廠區的表格列（| 廠區 | 部門 | 姓名 | 分機 | MVPN |），略過表頭與目錄表（同插件）。
    static func parseContacts(_ markdown: String) -> [JentechContact] {
        var contacts: [JentechContact] = []
        for line in markdown.components(separatedBy: "\n") where line.hasPrefix("|") {
            // 表格中的 [[筆記\|顯示]] 以 \| 跳脫，不是欄位分隔
            let cols = line.replacingOccurrences(of: "\\|", with: "\u{1F}").components(separatedBy: "|")
                .map { $0.replacingOccurrences(of: "\u{1F}", with: "|").trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 6 else { continue }
            let plant = cols[1].replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
            let name = cols[3]
            let ext = cols[4]
            guard plants.contains(plant), !ext.contains("分機"), !name.contains("(03)") else { continue }
            contacts.append(JentechContact(order: contacts.count, plant: plant, dept: cols[2], rawName: name, ext: ext, mvpn: cols[5]))
        }
        return contacts
    }

    private static let linkPattern = try! NSRegularExpression(pattern: #"\[\[([^\]\|]+)(?:\|([^\]]+))?\]\]"#)

    /// [[目標|顯示]] → 顯示（沒有連結時原樣）。
    static func displayName(_ raw: String) -> String {
        let ns = raw as NSString
        guard let match = linkPattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return raw }
        let shown = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 1)
        return ns.substring(with: shown).trimmingCharacters(in: .whitespaces)
    }

    static func linkTarget(_ raw: String) -> String? {
        let ns = raw as NSString
        guard let match = linkPattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }

    static func hasNumber(_ value: String) -> Bool {
        value.contains { $0.isNumber }
    }

    /// 撥號用的號碼（只留數字、* 與 #）；沒有數字時 nil。
    static func dialable(_ value: String) -> String? {
        let digits = value.filter { $0.isASCII && ($0.isNumber || $0 == "*" || $0 == "#") }
        return digits.contains(where: \.isNumber) ? digits : nil
    }

    /// 符合搜尋：任一欄位包含（不分大小寫）。
    static func matches(_ query: String, _ fields: [String]) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return fields.contains { $0.localizedCaseInsensitiveContains(text) }
    }

    /// 索引中筆記屬性的文字（清單以「, 」連接，巢狀或空白為空字串）。
    static func text(_ properties: [String: VaultIndex.Property], _ key: String) -> String {
        switch properties[key] {
        case .text(let value): return value
        case .list(let values): return values.joined(separator: ", ")
        case .empty, .none: return ""
        }
    }

    static func codes(from notes: [VaultIndex.Note]) -> [JentechCode] {
        var results: [JentechCode] = []
        for note in notes {
            let props = note.properties
            let type = text(props, "type")
            let base = ((note.path as NSString).lastPathComponent as NSString).deletingPathExtension
            if note.path.hasPrefix("04 客戶"), type == "customer" {
                let industry = text(props, "industry")
                let region = text(props, "region")
                results.append(JentechCode(
                    kind: .customer, code: text(props, "credit_account"), alias: text(props, "alias"), name: base,
                    fullName: text(props, "name").isEmpty ? base : text(props, "name"),
                    detail: [industry, region].filter { !$0.isEmpty }.joined(separator: " "), path: note.path
                ))
            } else if note.path.hasPrefix("11 SOP/常用代碼/代碼紀錄/TCode"), type == "code" {
                let code = text(props, "code")
                results.append(JentechCode(
                    kind: .tcode, code: code.isEmpty ? base.replacingOccurrences(of: "^tc-", with: "", options: .regularExpression) : code,
                    alias: "", name: text(props, "name"), fullName: "", detail: text(props, "detail"), path: note.path
                ))
            }
        }
        // 客戶依別稱（或名稱）、T-Code 依代碼排序（同插件）
        return results.sorted { a, b in
            let keyA = a.kind == .customer ? (a.alias.isEmpty ? a.name : a.alias) : a.code
            let keyB = b.kind == .customer ? (b.alias.isEmpty ? b.name : b.alias) : b.code
            return keyA.localizedStandardCompare(keyB) == .orderedAscending
        }
    }

    static func cases(from notes: [VaultIndex.Note]) -> [JentechCase] {
        let items = notes.compactMap { note -> JentechCase? in
            guard note.path.hasPrefix("05 客戶案件/開案 Checklist"), text(note.properties, "type") == "checklist" else { return nil }
            let props = note.properties
            return JentechCase(
                path: note.path,
                file: ((note.path as NSString).lastPathComponent as NSString).deletingPathExtension,
                caseNo: text(props, "case_no"), sapNo: text(props, "sap_no"), product: text(props, "product"),
                customer: text(props, "customer"), osat: text(props, "osat"), bpmRdmn: text(props, "bpm_rdmn"), created: text(props, "created")
            )
        }
        // 新案在前：有日期的依日期降序，沒有日期的放後面再依開案號降序
        return items.sorted { a, b in
            switch (a.created.isEmpty, b.created.isEmpty) {
            case (false, false): return a.created > b.created
            case (true, false): return false
            case (false, true): return true
            case (true, true): return a.caseNo > b.caseNo
            }
        }
    }

    static func cards(from notes: [VaultIndex.Note]) -> [JentechCard] {
        notes.compactMap { note -> JentechCard? in
            let type = text(note.properties, "type")
            let base = ((note.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let name = text(note.properties, "name").isEmpty ? base : text(note.properties, "name")
            if type == "person", note.path.hasPrefix("03 人員") {
                return JentechCard(kind: .person, path: note.path, name: name, english: text(note.properties, "english_name"))
            }
            if type == "customer", note.path.hasPrefix("04 客戶") {
                return JentechCard(kind: .customer, path: note.path, name: name, english: text(note.properties, "english_name"))
            }
            return nil
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// ezprint 託運單 CSV：依標題欄位對應（Excel 文字前綴 ' 去掉）。
    static func parseShipments(_ csv: String) -> [JentechShipment] {
        let lines = csv.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { return [] }
        let columns = splitCSV(header)
        func index(_ names: [String]) -> Int? { names.lazy.compactMap { name in columns.firstIndex { $0.hasPrefix(name) } }.first }
        let recipient = index(["收件人姓名", "收件人"]) ?? 0
        let phone = index(["收件人電話"])
        let mobile = index(["收件人手機"])
        let address = index(["收件人地址", "地址"])
        let item = index(["品名說明", "備註"])
        let order = index(["訂單編號"])
        let date = index(["出貨日期"])
        return lines.dropFirst().compactMap { line in
            let cells = splitCSV(line)
            func cell(_ at: Int?) -> String {
                guard let at, at < cells.count else { return "" }
                var value = cells[at].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("'") { value.removeFirst() }
                return value
            }
            let name = cell(recipient)
            guard !name.isEmpty else { return nil }
            return JentechShipment(recipient: name, phone: cell(phone), mobile: cell(mobile), address: cell(address), item: cell(item), orderNo: cell(order), shipDate: cell(date))
        }
    }

    /// 一行 CSV（支援雙引號包住的欄位）。
    static func splitCSV(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var quoted = false
        var chars = Array(line)[...]
        while let char = chars.popFirst() {
            if char == "\"" {
                if quoted, chars.first == "\"" {
                    current.append("\"")
                    chars = chars.dropFirst()
                } else {
                    quoted.toggle()
                }
            } else if char == ",", !quoted {
                cells.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        cells.append(current)
        return cells
    }

    // MARK: 卡片

    /// 卡片筆記的位置：人員 03 人員/部門/中文 英文.md；客戶 04 客戶/英文（或中文）.md（同插件）。
    static func cardPath(kind: JentechCard.Kind, values: [String: String]) -> String? {
        let name = (values["name"] ?? "").trimmingCharacters(in: .whitespaces)
        let english = (values["english_name"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|")
        func clean(_ text: String) -> String { text.components(separatedBy: unsafe).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
        switch kind {
        case .person:
            let dept = clean((values["dept"] ?? "").isEmpty ? "業務處" : values["dept"]!)
            return "03 人員/\(dept)/\(clean(english.isEmpty ? name : "\(name) \(english)")).md"
        case .customer:
            return "04 客戶/\(clean(english.isEmpty ? name : english)).md"
        }
    }

    /// 一個 frontmatter 值：清單為 [a, b]，需要時加雙引號。
    static func yamlValue(_ value: String, isList: Bool) -> String {
        if isList {
            let items = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return "[\(items.map { quoteIfNeeded($0) }.joined(separator: ", "))]"
        }
        return quoteIfNeeded(value)
    }

    static func quoteIfNeeded(_ value: String) -> String {
        let special = value.first.map { "[]{}#&*!|>'\"%@`,".contains($0) } ?? false
        guard special || value.contains(": ") || value.contains(" #") || value.hasSuffix(":") || value != value.trimmingCharacters(in: .whitespaces) else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 新卡片的內容：frontmatter（空白欄位略過）、標題與「基本資料」段落（同插件）。
    static func newCard(fields: [(key: String, value: String, isList: Bool)]) -> String {
        var lines = ["---"]
        for field in fields where !field.value.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("\(field.key): \(yamlValue(field.value, isList: field.isList))")
        }
        let name = fields.first { $0.key == "name" }?.value ?? ""
        lines += ["---", "", "# \(name)", "", "## 基本資料", ""]
        return lines.joined(separator: "\n")
    }

    /// 改寫筆記的 frontmatter：`set` 的欄位取代（或加在最後），`remove` 的欄位刪除，其他欄位（含巢狀內容）原樣保留。
    static func updateFrontmatter(_ text: String, set: [(key: String, value: String, isList: Bool)], remove: Set<String>) -> String {
        var lines = text.components(separatedBy: "\n")
        let hasFrontmatter = lines.first?.trimmingCharacters(in: .whitespaces) == "---"
        var end: Int? = hasFrontmatter ? lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) : nil
        if end == nil {
            lines.insert(contentsOf: ["---", "---"], at: 0)
            end = 1
        }
        guard var close = end else { return text }
        // 每個頂層欄位佔的行：欄位那一行，加上後面縮排或清單項目的行
        func blocks() -> [(key: String, range: Range<Int>)] {
            var result: [(key: String, range: Range<Int>)] = []
            var index = 1
            while index < close {
                let line = lines[index]
                if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("-"), !line.hasPrefix("#") {
                    let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                    var next = index + 1
                    while next < close, lines[next].hasPrefix(" ") || lines[next].hasPrefix("\t") || lines[next].hasPrefix("- ") || lines[next].isEmpty {
                        next += 1
                    }
                    result.append((key: key, range: index..<next))
                    index = next
                } else {
                    index += 1
                }
            }
            return result
        }
        for key in remove {
            if let block = blocks().first(where: { $0.key == key }) {
                lines.removeSubrange(block.range)
                close -= block.range.count
            }
        }
        for field in set {
            let rendered = "\(field.key): \(yamlValue(field.value, isList: field.isList))"
            if let block = blocks().first(where: { $0.key == field.key }) {
                lines.replaceSubrange(block.range, with: [rendered])
                close -= block.range.count - 1
            } else {
                lines.insert(rendered, at: close)
                close += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: SOP

    /// 插件的 SOP 清單（流程階段、名稱、筆記、標籤）。
    static let sops: [JentechSop] = [
        .init(stage: "前置作業", name: "BPM 品號基本資料申請 (MM01 / VD51 客戶品號對照)", file: "SOP - BPM 品號基本資料申請", tags: ["#品號", "#料號", "#mm01", "#vd51", "#master-data"]),
        .init(stage: "前置作業", name: "BPM 新開案流程（樣品開案 ➔ 取得 S/T 單號）", file: "SOP - BPM 新開案流程", tags: ["#開案", "#新案", "#樣品單", "#s開案號", "#t開案號", "#po-list"]),
        .init(stage: "前置作業", name: "新圖面報價流程 (RFQ 成本分析與利潤審核)", file: "SOP - 新圖面報價流程", tags: ["#報價", "#rfq", "#quotation", "#成本分析", "#costing", "#markup"]),
        .init(stage: "前置作業", name: "BPM 用印申請書 (合約 / NDA 用印)", file: "SOP - BPM 用印申請書", tags: ["#用印", "#合約", "#nda", "#保密協議", "#印信"]),
        .init(stage: "客戶訂單", name: "SAP 訂單流程（標準訂單 ZOR1 — 量產 1000 / 2600）", file: "SOP - SAP 訂單流程（標準訂單）", tags: ["#zor1", "#標準訂單", "#量產訂單", "#va01", "#so", "#sales-order"]),
        .init(stage: "客戶訂單", name: "SAP 訂單流程（樣品訂單 ZOR3 — 收費樣品 1030）", file: "SOP - SAP 訂單流程（樣品訂單）", tags: ["#zor3", "#樣品訂單", "#收費樣品", "#sample-order", "#va01", "#so"]),
        .init(stage: "客戶訂單", name: "SAP 訂單流程（免費樣品 ZOR4 — FOC 1040 國外報關）", file: "SOP - SAP 訂單流程（免費樣品訂單）", tags: ["#zor4", "#免費樣品", "#foc", "#free-sample", "#va01", "#so"]),
        .init(stage: "客戶訂單", name: "SAP 訂單流程（Debit Note ZDR1 — 扣款 / 模具費）", file: "SOP - SAP 訂單流程（Debit Note）", tags: ["#zdr1", "#debit-note", "#dn", "#扣款", "#模具費", "#va01"]),
        .init(stage: "出貨作業", name: "SAP 開銷貨單（CO06 撥庫存 ➔ VL01N 開交貨單 ➔ VL03N 列印）", file: "SOP - SAP 開銷貨單", tags: ["#銷貨單", "#交貨單", "#co06", "#vl01n", "#vl03n", "#delivery", "#dn"]),
        .init(stage: "出貨作業", name: "免費樣品與快遞出貨作業 (DHL 國際報關 / 黑貓 國內宅急便)", file: "SOP - 免費樣品與快遞出貨作業 (DHL與黑貓)", tags: ["#快遞", "#dhl", "#黑貓", "#國際快遞", "#報關", "#invoice", "#foc出貨"]),
        .init(stage: "立帳請款", name: "SAP 銷貨立帳（VF04 發票清單 ➔ VF03 列印銷貨立帳單）", file: "SOP - SAP 立帳（VF04 VF03）", tags: ["#billing", "#立帳", "#銷帳", "#發票", "#invoice", "#vf04", "#vf03", "#請款", "#ar"]),
        .init(stage: "立帳請款", name: "SAP 客戶匯款沖帳明細（FBL5N 標準外幣抓未清 JT 號銷帳）", file: "SOP - SAP 客戶匯款沖帳明細（FBL5N）", tags: ["#fbl5n", "#沖帳", "#銷帳", "#匯款", "#外幣沖帳", "#remittance", "#對帳", "#jt號", "#ar"]),
        .init(stage: "立帳請款", name: "SAP 費用請款單（員工差旅 / 代墊款 FV60）", file: "SOP - SAP 費用請款單（員工）", tags: ["#fv60", "#請款", "#員工報銷", "#差旅費", "#代墊款", "#expense"]),
    ]

    static let sopStages = ["前置作業", "客戶訂單", "出貨作業", "立帳請款"]
    static let sopQuickTags = ["#billing", "#銷帳", "#va01", "#zor1", "#zor3", "#zor4", "#zdr1", "#fbl5n", "#vf04", "#vl01n", "#mm01", "#報價", "#dhl", "#黑貓"]

    /// SOP 搜尋：名稱、階段、筆記或標籤包含關鍵字（# 可有可無）。
    static func sopMatches(_ sop: JentechSop, _ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return true }
        let bare = text.hasPrefix("#") ? String(text.dropFirst()) : text
        return ([sop.stage, sop.name, sop.file] + sop.tags).contains { $0.lowercased().contains(text) || $0.lowercased().contains(bare) }
    }
}

/// 業務快查的資料（各頁共用；通訊錄與 BPM 讀一次後留著）。
@MainActor
@Observable
final class JentechStore {
    static let shared = JentechStore()

    private(set) var contacts: [JentechContact] = []
    private(set) var contactsError: String?
    private(set) var isLoadingContacts = false
    private(set) var bpm: JentechBpm?
    private(set) var bpmError: String?
    private(set) var isLoadingBpm = false
    /// 最近的通訊錄搜尋（最多 8 個）。
    private(set) var contactHistory: [String] = UserDefaults.standard.stringArray(forKey: "jentech.contactHistory") ?? []

    private var index: VaultIndexStore { .shared }
    private var notes: [VaultIndex.Note] { Array(index.notes.values) }

    var codes: [JentechCode] { JentechLogic.codes(from: notes) }
    var cases: [JentechCase] { JentechLogic.cases(from: notes) }
    var cards: [JentechCard] { JentechLogic.cards(from: notes) }

    /// SOP 筆記的路徑（索引中依檔名找）。
    func path(forNote name: String) -> String? {
        index.notes.keys.first { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension == name }
    }

    /// 黑貓託運名冊的 CSV（檔名含 ezprint 的 .csv，新的在前）。
    var shipmentFiles: [String] {
        index.files.filter { $0.path.lowercased().hasSuffix(".csv") && $0.path.lowercased().contains("ezprint") }
            .sorted { $0.mtime > $1.mtime }
            .map(\.path)
    }

    /// 確保索引已載入（客戶、代碼、案件、卡片、SOP 都來自索引）。
    func ensureIndex() async {
        await index.load()
        if index.notes.isEmpty || (index.updatedAt.map { Date().timeIntervalSince($0) > 60 } ?? true) {
            await index.refresh()
        }
    }

    func loadContacts(force: Bool = false) async {
        guard force || contacts.isEmpty, !isLoadingContacts else { return }
        isLoadingContacts = true
        defer { isLoadingContacts = false }
        do {
            let data = try await DataviewData.read(JentechLogic.directoryPath)
            contacts = JentechLogic.parseContacts(String(decoding: data, as: UTF8.self))
            contactsError = contacts.isEmpty ? "通訊錄中沒有可讀的表格列" : nil
        } catch {
            contactsError = "讀不到 \(JentechLogic.directoryPath)：\(error.localizedDescription)"
        }
    }

    func loadBpm() async {
        guard !isLoadingBpm else { return }
        isLoadingBpm = true
        defer { isLoadingBpm = false }
        do {
            // 每次重新下載（排程每天更新兩次）
            let data: Data
            if let client = VaultClient.configured() {
                data = try await client.read(JentechLogic.bpmPath).data
            } else {
                data = try await DataviewData.read(JentechLogic.bpmPath)
            }
            bpm = try JSONDecoder().decode(JentechBpm.self, from: data)
            bpmError = nil
        } catch {
            bpmError = "讀不到 \(JentechLogic.bpmPath)：\(error.localizedDescription)"
        }
    }

    func loadShipments(_ path: String) async throws -> [JentechShipment] {
        let data = try await DataviewData.read(path)
        return JentechLogic.parseShipments(String(decoding: data, as: UTF8.self))
    }

    func remember(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        contactHistory.removeAll { $0 == text }
        contactHistory.insert(text, at: 0)
        if contactHistory.count > 8 { contactHistory.removeLast(contactHistory.count - 8) }
        UserDefaults.standard.set(contactHistory, forKey: "jentech.contactHistory")
    }

    func clearHistory() {
        contactHistory = []
        UserDefaults.standard.removeObject(forKey: "jentech.contactHistory")
    }
}
