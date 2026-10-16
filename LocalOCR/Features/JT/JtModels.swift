import Foundation
import SwiftUI

// JT Sales Tracker（電腦上的業務追蹤）與 App 的同步資料（協定 jt.v1，規格在 JT 那邊的 docs/JT-SYNC.md）。
// JT 用桌面版同一批函式把狀態、分組、排序、標籤文字都算好，寫成 vault 的 `.jt/` 快照；App 只負責排版，
// 不自己判斷。這裡的解析很寬鬆：欄位缺了或型別不同都不會讓整份資料讀不出來。

typealias JtObject = [String: Any]

enum JtJSON {
    static func object(_ data: Data) -> JtObject? {
        (try? JSONSerialization.jsonObject(with: data)) as? JtObject
    }
}

extension Dictionary where Key == String, Value == Any {
    /// 字串欄位（數字也轉成字串）；沒有時是空字串。
    func jtString(_ key: String) -> String {
        jtOptionalString(key) ?? ""
    }

    func jtOptionalString(_ key: String) -> String? {
        switch self[key] {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return nil
        }
    }

    func jtInt(_ key: String) -> Int? {
        switch self[key] {
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value)
        default: return nil
        }
    }

    func jtDouble(_ key: String) -> Double? {
        switch self[key] {
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    func jtBool(_ key: String) -> Bool {
        switch self[key] {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String: return value == "true" || value == "1"
        default: return false
        }
    }

    func jtObject(_ key: String) -> JtObject? {
        self[key] as? JtObject
    }

    func jtObjects(_ key: String) -> [JtObject] {
        (self[key] as? [Any])?.compactMap { $0 as? JtObject } ?? []
    }

    func jtStrings(_ key: String) -> [String] {
        (self[key] as? [Any])?.compactMap { item -> String? in
            if let value = item as? String { return value }
            if let value = item as? NSNumber { return value.stringValue }
            return nil
        } ?? []
    }
}

// MARK: - 快照與清單

/// 一份快照檔：`{ schema, kind, rev, generatedAt, data, clocks }`。
struct JtSnapshot {
    let kind: String
    let rev: String
    let generatedAt: Double
    let data: JtObject
    /// 可編輯欄位的最後編輯時間（實體 → 欄位 → ms，0 表示同步開始前就是這個值）。
    let clocks: [String: [String: Double]]

    init?(data raw: Data) {
        guard let object = JtJSON.object(raw), let data = object.jtObject("data") else { return nil }
        kind = object.jtString("kind")
        rev = object.jtString("rev")
        generatedAt = object.jtDouble("generatedAt") ?? 0
        self.data = data
        var clocks: [String: [String: Double]] = [:]
        for (entity, value) in object.jtObject("clocks") ?? [:] {
            guard let fields = value as? JtObject else { continue }
            var times: [String: Double] = [:]
            for field in fields.keys {
                times[field] = fields.jtDouble(field) ?? 0
            }
            clocks[entity] = times
        }
        self.clocks = clocks
    }
}

/// `.jt/manifest.json`：各快照檔的版本與 JT 最後一次心跳。
struct JtManifest {
    struct File {
        let path: String
        let rev: String
        let updatedAt: Double
    }

    let device: String
    /// ms；超過 3 分鐘沒更新表示電腦離線。
    let heartbeatAt: Double
    let files: [String: File]

    init?(_ object: JtObject) {
        guard object.jtString("schema").hasPrefix("jt.") || object["files"] != nil else { return nil }
        device = object.jtString("device")
        heartbeatAt = object.jtDouble("heartbeatAt") ?? 0
        var files: [String: File] = [:]
        for (kind, value) in object.jtObject("files") ?? [:] {
            guard let file = value as? JtObject else { continue }
            let path = file.jtOptionalString("path") ?? ".jt/\(kind).json"
            files[kind] = File(path: path, rev: file.jtString("rev"), updatedAt: file.jtDouble("updatedAt") ?? 0)
        }
        self.files = files
    }

    /// 電腦的 JT 超過 3 分鐘沒有心跳。
    func isStale(now: Date = Date()) -> Bool {
        heartbeatAt > 0 && now.timeIntervalSince1970 * 1000 - heartbeatAt > 180_000
    }
}

// MARK: - meta.json

struct JtOwner: Identifiable {
    let id: String
    let name: String
    let initial: String
    let background: String
    let foreground: String

    var color: Color { Color(jtHex: background) ?? DS.textSecondary }
}

struct JtMeta {
    let today: String
    let me: String
    let owners: [JtOwner]
    let customerDomains: [String: String]
    let groupModes: [(mode: String, label: String)]
    /// 終端客戶的候選名單（指定終端客戶時選）。
    let endUsers: [String]

    static let defaultModes: [(mode: String, label: String)] = [
        ("etd-asc", "出貨"), ("owner", "業務"), ("status", "狀態"), ("customer", "客戶"), ("project", "專案"),
    ]

    init(_ data: JtObject) {
        today = data.jtString("today")
        me = data.jtString("me")
        owners = data.jtObjects("owners").map { owner in
            let color = owner.jtObject("color") ?? [:]
            return JtOwner(
                id: owner.jtString("id"),
                name: owner.jtString("name"),
                initial: owner.jtString("initial"),
                background: color.jtString("bg"),
                foreground: color.jtString("fg")
            )
        }
        var domains: [String: String] = [:]
        for customer in data.jtObjects("customers") {
            let domain = customer.jtString("domain")
            guard !domain.isEmpty else { continue }
            domains[customer.jtString("name")] = domain
        }
        customerDomains = domains
        endUsers = ((data["endUsers"] as? [Any]) ?? []).compactMap { item -> String? in
            if let name = item as? String { return name }
            return (item as? JtObject)?.jtString("name")
        }.filter { !$0.isEmpty }
        let modes = data.jtObjects("groupModes").map { (mode: $0.jtString("mode"), label: $0.jtString("label")) }.filter { !$0.mode.isEmpty }
        groupModes = modes.isEmpty ? Self.defaultModes : modes
    }

    func owner(_ id: String) -> JtOwner? {
        owners.first { $0.id == id }
    }
}

// MARK: - cases.json

struct JtMarker: Identifiable {
    let id: String
    let type: String
    let title: String
    let date: String
    let originalDate: String
    let done: Bool
}

struct JtMilestone: Identifiable {
    let id: String
    var type: String
    var title: String
    var date: String
    var endDate: String
    var done: Bool
    var note: String
    /// 還沒送到 JT 的新增（暫時的 id）。
    var isPending = false
}

struct JtComment: Identifiable {
    let id: String
    let authorId: String
    let text: String
    let createdAt: String
    var isPending = false
}

struct JtCaseWip {
    let material: String
    let eqp: String
    let state: String
    let text: String
    let tone: String
}

struct JtCase: Identifiable {
    let id: String
    let ownerId: String
    let customer: String
    let customerDomain: String
    let product: String
    let model: String
    let customName: String?
    var status: String
    let tone: String
    var stat: String
    let start: String
    var end: String
    var etd: String
    let etdFrom: String
    var daysToEtd: Int?
    let progressDate: String
    let schedule: String
    let scheduleDays: Int?
    let overdueDays: Int?
    let overdueLabel: String
    let progressDone: Int
    let progressTotal: Int
    let markers: [JtMarker]
    var milestones: [JtMilestone]
    var note: String
    var project: String
    var endUserName: String
    var endUserDomain: String
    let wip: JtCaseWip?
    var comments: [JtComment]

    var title: String {
        if let customName, !customName.isEmpty { return customName }
        return product
    }

    var isClosed: Bool { tone == "done" || tone == "cancelled" }

    init(_ item: JtObject) {
        id = item.jtString("id")
        ownerId = item.jtString("ownerId")
        customer = item.jtString("customer")
        customerDomain = item.jtString("customerDomain")
        product = item.jtString("product")
        model = item.jtString("model")
        customName = item.jtOptionalString("customName")
        status = item.jtString("status")
        tone = item.jtString("tone")
        stat = item.jtString("stat")
        start = item.jtString("start")
        end = item.jtString("end")
        etd = item.jtString("etd")
        etdFrom = item.jtString("etdFrom")
        daysToEtd = item.jtInt("daysToEtd")
        progressDate = item.jtString("progressDate")
        schedule = item.jtString("schedule")
        scheduleDays = item.jtInt("scheduleDays")
        overdueDays = item.jtInt("overdueDays")
        overdueLabel = item.jtString("overdueLabel")
        let progress = item.jtObject("progress") ?? [:]
        progressDone = progress.jtInt("done") ?? 0
        progressTotal = progress.jtInt("total") ?? 0
        markers = item.jtObjects("markers").map {
            JtMarker(id: $0.jtString("id"), type: $0.jtString("type"), title: $0.jtString("title"), date: $0.jtString("date"), originalDate: $0.jtString("origDate"), done: $0.jtBool("done"))
        }
        milestones = item.jtObjects("milestones").map {
            JtMilestone(id: $0.jtString("id"), type: $0.jtString("type"), title: $0.jtString("title"), date: $0.jtString("date"), endDate: $0.jtString("endDate"), done: $0.jtBool("done"), note: $0.jtString("note"))
        }
        note = item.jtString("note")
        project = item.jtString("project")
        let endUser = item.jtObject("endUser") ?? [:]
        endUserName = endUser.jtString("name")
        endUserDomain = endUser.jtString("domain")
        wip = item.jtObject("wip").map {
            JtCaseWip(material: $0.jtString("material"), eqp: $0.jtString("eqp"), state: $0.jtString("state"), text: $0.jtString("text"), tone: $0.jtString("tone"))
        }
        comments = item.jtObjects("comments").map {
            JtComment(id: $0.jtString("id"), authorId: $0.jtString("authorId"), text: $0.jtString("text"), createdAt: $0.jtString("createdAt"))
        }
    }

    /// 搜尋：品名、客戶、型號、專案、終端客戶、備註。
    func matches(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return [title, product, customer, model, project, endUserName, note].contains { $0.localizedCaseInsensitiveContains(text) }
    }
}

struct JtGroupRow {
    let id: String
    let key: String
    let label: String
    let count: Int
    let attention: Int
    let start: String
    let end: String
    let caseIds: [String]
}

/// 甘特的一列：可收合的分組標題，或一個案件。
enum JtLayoutRow: Identifiable {
    case group(JtGroupRow)
    case item(String)

    var id: String {
        switch self {
        case .group(let group): return "group:" + group.id
        case .item(let caseId): return "case:" + caseId
        }
    }
}

struct JtCases {
    let cases: [JtCase]
    let layouts: [String: [JtLayoutRow]]

    init(_ data: JtObject) {
        cases = data.jtObjects("cases").map(JtCase.init).filter { !$0.id.isEmpty }
        var layouts: [String: [JtLayoutRow]] = [:]
        for (mode, value) in data.jtObject("layouts") ?? [:] {
            let rows = (value as? [Any])?.compactMap { $0 as? JtObject } ?? []
            layouts[mode] = rows.compactMap(Self.row)
        }
        self.layouts = layouts
    }

    private static func row(_ object: JtObject) -> JtLayoutRow? {
        if object.jtString("type") == "group" {
            return .group(JtGroupRow(
                id: object.jtString("id"),
                key: object.jtString("key"),
                label: object.jtString("label"),
                count: object.jtInt("count") ?? 0,
                attention: object.jtInt("attention") ?? 0,
                start: object.jtString("start"),
                end: object.jtString("end"),
                caseIds: object.jtStrings("caseIds")
            ))
        }
        let caseId = object.jtString("caseId")
        return caseId.isEmpty ? nil : .item(caseId)
    }
}

// MARK: - calendar.json

struct JtCalItem: Identifiable {
    let id: String
    let kind: String
    var title: String
    let subtitle: String
    var start: String
    let end: String
    let allDay: Bool
    var done: Bool
    let overdue: Bool
    let location: String
    var note: String
    let entryId: String
    let caseId: String
    let customer: String
    let progress: String
    let joinURL: String
    let mailSender: String
    var isPending = false

    init(_ item: JtObject) {
        id = item.jtString("id")
        kind = item.jtString("kind")
        title = item.jtString("title")
        subtitle = item.jtString("subtitle")
        start = item.jtString("start")
        end = item.jtString("end")
        allDay = item.jtBool("allDay")
        done = item.jtBool("done")
        overdue = item.jtBool("overdue")
        location = item.jtString("location")
        note = item.jtString("note")
        entryId = item.jtString("entryId")
        caseId = item.jtString("caseId")
        customer = item.jtString("customer")
        progress = item.jtString("progress")
        joinURL = item.jtString("joinUrl")
        mailSender = item.jtObject("mail")?.jtString("sender") ?? ""
    }

    init(pendingTodo id: String, title: String, date: String) {
        self.id = id
        kind = "todo"
        self.title = title
        subtitle = ""
        start = date
        end = ""
        allDay = true
        done = false
        overdue = false
        location = ""
        note = ""
        entryId = ""
        caseId = ""
        customer = ""
        progress = ""
        joinURL = ""
        mailSender = ""
        isPending = true
    }

    /// 這個項目的日期（YYYY-MM-DD）。
    var day: String { String(start.prefix(10)) }

    /// 有時間的項目顯示 HH:mm。
    var time: String? {
        guard !allDay, start.count >= 16 else { return nil }
        return String(start.dropFirst(11).prefix(5))
    }

    /// 待辦與信件備忘可以打勾。
    var isCheckable: Bool { kind == "todo" || !mailSender.isEmpty }
}

struct JtDay {
    let carried: Set<String>
    let groups: [(kind: String, ids: [String])]
}

struct JtCalendar {
    let today: String
    let items: [JtCalItem]
    let notes: [String: String]
    let holidays: [String: String]
    let days: [String: JtDay]
    let outlookError: String

    init(_ data: JtObject) {
        today = data.jtString("today")
        items = data.jtObjects("items").map(JtCalItem.init).filter { !$0.id.isEmpty }
        var notes: [String: String] = [:]
        for (date, value) in data.jtObject("notes") ?? [:] {
            if let text = value as? String { notes[date] = text }
        }
        self.notes = notes
        var holidays: [String: String] = [:]
        for holiday in data.jtObjects("holidays") {
            holidays[holiday.jtString("date")] = holiday.jtString("name")
        }
        self.holidays = holidays
        var days: [String: JtDay] = [:]
        for (date, value) in data.jtObject("days") ?? [:] {
            guard let day = value as? JtObject else { continue }
            let groups = day.jtObjects("groups").map { (kind: $0.jtString("kind"), ids: $0.jtStrings("ids")) }
            days[date] = JtDay(carried: Set(day.jtStrings("carried")), groups: groups)
        }
        self.days = days
        outlookError = data.jtObject("outlook")?.jtString("error") ?? ""
    }
}

// MARK: - wip.json

struct JtWipRow: Identifiable {
    let lead: String
    let pns: [String]
    let label: String
    let customerName: String
    let rowCount: Int
    let state: String
    var pinned: Bool
    var hidden = false

    var id: String { lead.isEmpty ? label : lead }
}

struct JtMachine: Identifiable {
    let eqp: String
    let dept: String
    let word: String
    let group: String
    let summary: String
    let reason: String
    let customer: String
    let lot: String
    let durationMinutes: Double?
    let mine: [String]

    var id: String { eqp }
    var isMine: Bool { !mine.isEmpty }
}

struct JtWip {
    let rows: [JtWipRow]
    let machines: [JtMachine]
    let boardConfigured: Bool
    let boardFetchedAt: String

    init(_ data: JtObject) {
        var hidden: Set<String> = []
        var pinned: Set<String> = []
        for item in data.jtObjects("tracked") {
            let pn = item.jtString("productPn")
            if item.jtBool("hidden") { hidden.insert(pn) }
            if item.jtBool("pinned") { pinned.insert(pn) }
        }
        rows = data.jtObjects("merged").map { item in
            let pns = item.jtStrings("pns")
            let lead = item.jtString("lead")
            let keys = pns.isEmpty ? [lead] : pns
            return JtWipRow(
                lead: lead,
                pns: keys,
                label: item.jtString("label"),
                customerName: item.jtString("customerName"),
                rowCount: item.jtInt("rowCount") ?? 0,
                state: item.jtString("state"),
                pinned: item.jtBool("pinned") || keys.contains { pinned.contains($0) },
                hidden: keys.allSatisfy { hidden.contains($0) }
            )
        }
        let board = data.jtObject("board") ?? [:]
        boardConfigured = board.jtBool("configured")
        boardFetchedAt = board.jtString("fetchedAt")
        machines = board.jtObjects("machines").map { item in
            JtMachine(
                eqp: item.jtString("eqp"),
                dept: item.jtString("dept"),
                word: item.jtString("word"),
                group: item.jtString("group"),
                summary: item.jtString("summary"),
                reason: item.jtString("reason"),
                customer: item.jtString("customer"),
                lot: item.jtString("lot"),
                durationMinutes: item.jtDouble("durationMin"),
                mine: item.jtObjects("mine").map { $0.jtString("pn") }
            )
        }.filter { !$0.eqp.isEmpty }
    }
}

// MARK: - 儀表板、PO（與桌面 API 同格式：只取常見的欄位顯示）

/// 一筆通知或出貨：從物件中挑常見的欄位當標題、說明與日期。
struct JtListRow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let date: String
    let badge: String
    let isAlert: Bool

    private static let titleKeys = ["title", "label", "customName", "product", "model", "modelName", "customer", "customerName", "name", "text", "message"]
    private static let detailKeys = ["customer", "customerName", "reason", "kind", "type", "station", "stage", "note", "detail", "summary", "lot"]
    private static let dateKeys = ["etd", "date", "due", "dueDate", "deliveryDate", "shipDate", "at", "createdAt", "start"]
    private static let badgeKeys = ["severity", "status", "state", "qty", "quantity"]

    init(_ object: JtObject, index: Int) {
        let title = Self.titleKeys.lazy.map { object.jtString($0) }.first { !$0.isEmpty } ?? ""
        self.title = title.isEmpty ? "（未命名）" : title
        let details = Self.detailKeys.map { object.jtString($0) }.filter { !$0.isEmpty && $0 != title }
        var seen: Set<String> = []
        detail = details.filter { seen.insert($0).inserted }.prefix(3).joined(separator: " · ")
        date = String((Self.dateKeys.lazy.map { object.jtString($0) }.first { !$0.isEmpty } ?? "").prefix(16))
        badge = Self.badgeKeys.lazy.map { object.jtString($0) }.first { !$0.isEmpty } ?? ""
        let severity = object.jtString("severity") + object.jtString("kind")
        isAlert = object.jtBool("overdue") || severity.contains("overdue") || severity.contains("danger") || severity.contains("逾期")
        id = (object.jtOptionalString("id") ?? "") + "#\(index)"
    }

    static func rows(_ objects: [JtObject]) -> [JtListRow] {
        objects.enumerated().map { JtListRow($1, index: $0) }
    }
}

// MARK: - 日期與顏色

enum JtDates {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func date(_ text: String) -> Date? {
        guard text.count >= 10 else { return nil }
        return formatter.date(from: String(text.prefix(10)))
    }

    static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// `from` 到 `to` 相差幾天（同一天 0）。
    static func days(from: Date, to: Date) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }

    static func shifted(_ text: String, by days: Int) -> String {
        guard let date = date(text), let moved = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: date) else { return text }
        return string(moved)
    }

    /// 「10/16」
    static func monthDay(_ text: String) -> String {
        guard let day = JtDayNumber.number(text) else { return text }
        let parts = JtDayNumber.civil(day)
        return "\(parts.month)/\(parts.day)"
    }

    /// 「10/16（四）」
    static func short(_ text: String) -> String {
        guard let date = date(text) else { return text }
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.month, .day, .weekday], from: date)
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        let weekday = weekdays[((parts.weekday ?? 1) - 1) % 7]
        return "\(parts.month ?? 0)/\(parts.day ?? 0)（\(weekday)）"
    }
}

/// 日期換成 1970-01-01 起算的第幾天（整數運算，不受時區影響）：甘特每畫一列都要換算很多次，不用 DateFormatter。
enum JtDayNumber {
    static func number(_ text: String) -> Int? {
        let bytes = Array(text.utf8.prefix(10))
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return nil }
        func value(_ range: Range<Int>) -> Int? {
            var result = 0
            for index in range {
                let digit = Int(bytes[index]) - 48
                guard digit >= 0, digit <= 9 else { return nil }
                result = result * 10 + digit
            }
            return result
        }
        guard let year = value(0..<4), let month = value(5..<7), let day = value(8..<10),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return fromCivil(year: year, month: month, day: day)
    }

    static func fromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civil(_ number: Int) -> (year: Int, month: Int, day: Int) {
        let z = number + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    static func string(_ number: Int) -> String {
        let parts = civil(number)
        return String(format: "%04d-%02d-%02d", parts.year, parts.month, parts.day)
    }

    /// 0＝星期日。
    static func weekday(_ number: Int) -> Int {
        ((number + 4) % 7 + 7) % 7
    }
}

extension Color {
    /// "#3D5BD9" 或 "3D5BD9"。
    init?(jtHex text: String) {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

enum JtPalette {
    /// 今天的軸線與日期膠囊（藍底白字，淺色深色都讀得清楚）。
    static let today = Color(red: 0.25, green: 0.47, blue: 0.96)

    /// 在製狀態：run 綠、stuck 玫瑰紅、wait 琥珀、idle 灰。
    static func wipColor(_ state: String) -> Color {
        switch state {
        case "run": return DS.success
        case "stuck": return DS.danger
        case "wait": return DS.warning
        default: return DS.textTertiary
        }
    }

    static func wipTitle(_ state: String) -> String {
        switch state {
        case "run": return "生產中"
        case "stuck": return "卡住"
        case "wait": return "等待"
        case "idle": return "閒置"
        default: return state
        }
    }

    /// 機台看板：run mint、down rose、fai sand、mold sky、pm violet，idle 無底。
    static func machinePastel(_ group: String) -> DS.Pastel? {
        switch group {
        case "run": return .mint
        case "down": return .blush
        case "fai": return .butter
        case "mold": return .sky
        case "pm": return .lavender
        default: return nil
        }
    }

    static func machineGroupTitle(_ group: String) -> String {
        switch group {
        case "run": return "生產中"
        case "down": return "停機"
        case "fai": return "首件"
        case "mold": return "換模"
        case "pm": return "保養"
        case "idle": return "閒置"
        default: return group
        }
    }

    static let calendarKindTitles: [String: String] = [
        "todo": "待辦", "milestone": "里程碑", "etd": "出貨", "po": "PO", "meeting": "會議",
    ]
}
