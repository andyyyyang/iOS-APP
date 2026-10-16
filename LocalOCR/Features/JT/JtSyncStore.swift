import Foundation
import Observation

/// 一次編輯（op）：寫成 `.jt/ops/<client>/<editedAt>-<opId>.json` 交給電腦的 JT 套用。
/// 送出前與 JT 回報結果（acks）前都留在本機佇列，畫面先顯示編輯後的值（樂觀顯示）。
struct JtPendingOp: Codable, Identifiable, Equatable {
    let opId: String
    /// 使用者按下去那一刻（ms）；離線排隊的編輯也用這個時間，送出時不改。
    let editedAt: Int64
    let kind: String
    /// 整個 op 的 JSON。
    let payload: Data
    var sent: Bool

    var id: String { opId }
    var object: JtObject { JtJSON.object(payload) ?? [:] }
    var fields: JtObject { object.jtObject("fields") ?? [:] }
}

/// JT 對一個編輯的處理結果（`.jt/acks/<client>.json`）。
struct JtAck {
    let opId: String
    /// applied、partial、superseded、failed
    let status: String
    let error: String

    static func parse(_ data: Data) -> [JtAck] {
        (JtJSON.object(data)?.jtObjects("results") ?? []).map {
            JtAck(opId: $0.jtString("opId"), status: $0.jtString("status"), error: $0.jtString("error"))
        }
    }
}

/// JT Sales Tracker 的同步（jt.v1）：讀電腦的 JT 寫在 vault `.jt/` 的快照，收到變更通知就重抓那個檔；
/// 編輯寫成 op 檔，JT 依編輯時間先後套用後回報結果。規則都在 JT 算好，這裡不判斷狀態、分組或排序。
@MainActor
@Observable
final class JtSyncStore {
    static let shared = JtSyncStore()

    static let kinds = ["meta", "cases", "calendar", "dashboard", "wip", "po"]
    static let statuses = ["進行中", "完成", "取消"]

    private(set) var manifest: JtManifest?
    private(set) var meta: JtMeta?
    private(set) var cases: JtCases?
    private(set) var calendar: JtCalendar?
    private(set) var wip: JtWip?
    private(set) var dashboard: JtObject?
    private(set) var po: JtObject?
    /// 快照種類 → 實體 → 欄位 → 最後編輯時間。
    private(set) var clocks: [String: [String: [String: Double]]] = [:]
    private(set) var pending: [JtPendingOp] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    /// 伺服器上還沒有 `.jt/`：電腦的 JT 還沒配對。
    private(set) var notPaired = false
    private(set) var loadedAt: Date?
    /// 編輯被略過或失敗時的提示。
    var notice: String?

    @ObservationIgnored private var revs: [String: String] = [:]
    @ObservationIgnored private var isSending = false
    @ObservationIgnored private var isRefreshing = false
    private let directory: URL
    /// 測試時不自動送出。
    private let sendsAutomatically: Bool

    init(directory: URL? = nil, sendsAutomatically: Bool = true) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "JT", directoryHint: .isDirectory)
        self.sendsAutomatically = sendsAutomatically
        loadCache()
    }

    var client: String { VaultClient.clientID }
    var isConfigured: Bool { VaultClient.configured() != nil }
    var hasData: Bool { cases != nil || calendar != nil || wip != nil }
    var isComputerOffline: Bool { manifest?.isStale() ?? false }
    var unsentCount: Int { pending.filter { !$0.sent }.count }

    /// 側欄選單的說明列。
    var detailLine: String {
        guard hasData else { return notPaired ? "電腦的 JT 還沒連上" : "甘特、行事曆、在製與機台" }
        let open = cases?.cases.filter { !$0.isClosed }.count ?? 0
        let attention = cases?.cases.filter { $0.tone == "attention" }.count ?? 0
        return "進行中 \(open)" + (attention > 0 ? " · 要注意 \(attention)" : "") + (isComputerOffline ? " · 電腦離線" : "")
    }

    static func opPath(client: String, editedAt: Int64, opId: String) -> String {
        ".jt/ops/\(client)/\(String(format: "%013lld", editedAt))-\(opId).json"
    }

    static func acksPath(client: String) -> String {
        ".jt/acks/\(client).json"
    }

    // MARK: - 讀取

    /// 讀清單，版本有變的快照才重抓；接著讀 acks、送出排隊中的編輯。
    func refresh() async {
        guard !isRefreshing else { return }
        guard let remote = VaultClient.configured() else {
            lastError = "還沒有與同步伺服器配對"
            return
        }
        isRefreshing = true
        isLoading = true
        defer {
            isRefreshing = false
            isLoading = false
        }
        do {
            let file = try await remote.read(".jt/manifest.json")
            guard let object = JtJSON.object(file.data), let manifest = JtManifest(object) else {
                lastError = "JT 的資料格式看不懂（manifest.json）"
                return
            }
            self.manifest = manifest
            notPaired = false
            save(file.data, as: "manifest")
            for kind in Self.kinds {
                guard let entry = manifest.files[kind] else { continue }
                if revs[kind] == entry.rev, !entry.rev.isEmpty { continue }
                await fetch(kind: kind, path: entry.path, remote: remote)
            }
            lastError = nil
            loadedAt = Date()
        } catch VaultError.notFound {
            notPaired = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await readAcks(remote: remote)
        await sendPending()
    }

    /// 伺服器通知 `.jt/` 有檔案變了（只會收到其他裝置與電腦的修改）。
    func handleRemoteChanges(_ paths: [String]) async {
        let jtPaths = paths.filter { $0.hasPrefix(".jt/") }
        guard !jtPaths.isEmpty, let remote = VaultClient.configured() else { return }
        if jtPaths.contains(".jt/manifest.json") {
            await refresh()
            return
        }
        for path in jtPaths {
            if path == Self.acksPath(client: client) {
                await readAcks(remote: remote)
            } else if let kind = manifest?.files.first(where: { $0.value.path == path })?.key ?? Self.kind(forPath: path) {
                await fetch(kind: kind, path: path, remote: remote)
            }
        }
    }

    private static func kind(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard (path as NSString).deletingLastPathComponent == ".jt", name.hasSuffix(".json") else { return nil }
        let kind = String(name.dropLast(5))
        return kinds.contains(kind) ? kind : nil
    }

    private func fetch(kind: String, path: String, remote: VaultClient) async {
        do {
            let file = try await remote.read(path)
            if apply(kind: kind, data: file.data) {
                save(file.data, as: kind)
            }
        } catch {
            if lastError == nil { lastError = "讀不到 \(kind)：\(error.localizedDescription)" }
        }
    }

    /// 套用一份快照，回傳是否看得懂。
    @discardableResult
    func apply(kind: String, data: Data) -> Bool {
        guard let snapshot = JtSnapshot(data: data) else { return false }
        revs[kind] = snapshot.rev
        clocks[kind] = snapshot.clocks
        switch kind {
        case "meta": meta = JtMeta(snapshot.data)
        case "cases": cases = JtCases(snapshot.data)
        case "calendar": calendar = JtCalendar(snapshot.data)
        case "wip": wip = JtWip(snapshot.data)
        case "dashboard": dashboard = snapshot.data
        case "po": po = snapshot.data
        default: return false
        }
        return true
    }

    // MARK: - 快取（離線也能看上次的資料）

    private func cacheURL(_ name: String) -> URL {
        directory.appending(path: name + ".json")
    }

    private func save(_ data: Data, as name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL(name), options: .atomic)
    }

    private func loadCache() {
        if let data = try? Data(contentsOf: cacheURL("manifest")), let object = JtJSON.object(data) {
            manifest = JtManifest(object)
        }
        for kind in Self.kinds {
            if let data = try? Data(contentsOf: cacheURL(kind)) { apply(kind: kind, data: data) }
        }
        if let data = try? Data(contentsOf: cacheURL("pending")), let saved = try? JSONDecoder().decode([JtPendingOp].self, from: data) {
            pending = saved
        }
    }

    private func savePending() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        save(data, as: "pending")
    }

    // MARK: - 編輯

    /// 記下一個編輯（畫面立刻顯示編輯後的值）並送出。
    func submit(_ kind: String, _ body: JtObject) {
        let editedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let opId = UUID().uuidString.lowercased()
        var op = body
        op["schema"] = "jt.v1"
        op["opId"] = opId
        op["client"] = client
        op["editedAt"] = editedAt
        op["kind"] = kind
        guard JSONSerialization.isValidJSONObject(op), let payload = try? JSONSerialization.data(withJSONObject: op, options: [.sortedKeys]) else { return }
        pending.append(JtPendingOp(opId: opId, editedAt: editedAt, kind: kind, payload: payload, sent: false))
        savePending()
        if sendsAutomatically { Task { await sendPending() } }
    }

    /// 依編輯時間先後送出還沒送的編輯；網路不通時留在佇列，下次再送（編輯時間不變）。
    func sendPending() async {
        guard !isSending, let remote = VaultClient.configured() else { return }
        let unsent = pending.filter { !$0.sent }.sorted { $0.editedAt < $1.editedAt }
        guard !unsent.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        for op in unsent {
            let path = Self.opPath(client: client, editedAt: op.editedAt, opId: op.opId)
            do {
                try await remote.write(path, data: op.payload, contentType: "application/json", condition: .createOnly)
                markSent(op.opId)
            } catch VaultError.conflict {
                // 已經送過（上次送出後沒收到回應）
                markSent(op.opId)
            } catch {
                if VaultSyncEngine.isConnectivity(error) { break }
                lastError = "編輯送不出去：\(error.localizedDescription)"
                break
            }
        }
        savePending()
        // 推送沒連上時也拿得到 JT 的處理結果
        Task {
            for delay in [2, 6, 15] {
                try? await Task.sleep(for: .seconds(delay))
                guard pending.contains(where: \.sent) else { return }
                await readAcks(remote: remote)
            }
        }
    }

    private func markSent(_ opId: String) {
        guard let index = pending.firstIndex(where: { $0.opId == opId }) else { return }
        pending[index].sent = true
    }

    private func readAcks(remote: VaultClient) async {
        guard pending.contains(where: \.sent) else { return }
        guard let file = try? await remote.read(Self.acksPath(client: client)) else { return }
        let resolved = Self.resolve(pending: pending, acks: JtAck.parse(file.data))
        if resolved.remaining != pending {
            pending = resolved.remaining
            savePending()
        }
        if let message = resolved.notices.last { notice = message }
    }

    /// 依 acks 清掉 JT 已經處理的編輯；被略過或失敗的回傳提示文字。
    static func resolve(pending: [JtPendingOp], acks: [JtAck]) -> (remaining: [JtPendingOp], notices: [String]) {
        let byId = Dictionary(acks.map { ($0.opId, $0) }, uniquingKeysWith: { first, _ in first })
        var remaining: [JtPendingOp] = []
        var notices: [String] = []
        for op in pending {
            guard op.sent, let ack = byId[op.opId] else {
                remaining.append(op)
                continue
            }
            switch ack.status {
            case "superseded":
                notices.append("別處有更新的修改，已改用最新的內容")
            case "failed":
                notices.append(ack.error.isEmpty ? "電腦的 JT 無法套用這個修改" : ack.error)
            default:
                break
            }
        }
        return (remaining, notices)
    }

    // MARK: - 樂觀顯示：待送的編輯比快照的欄位新時，顯示待送的值

    private func clock(_ kind: String, _ entity: String, _ field: String) -> Double {
        clocks[kind]?[entity]?[field] ?? 0
    }

    /// 這個欄位顯示待送的值嗎（快照的欄位時間比編輯舊）。
    static func shows(_ op: JtPendingOp, clock: Double) -> Bool {
        Double(op.editedAt) > clock
    }

    private func pendingOps(_ kind: String) -> [JtPendingOp] {
        pending.filter { $0.kind == kind }.sorted { $0.editedAt < $1.editedAt }
    }

    /// 案件（套上待送的修改、新增的里程碑與留言）。
    var displayCases: [JtCase] {
        (cases?.cases ?? []).map(overlay)
    }

    func displayCase(_ id: String) -> JtCase? {
        cases?.cases.first { $0.id == id }.map(overlay)
    }

    func overlay(_ original: JtCase) -> JtCase {
        var item = original
        let entity = "case:" + item.id
        for op in pendingOps("case.set") where op.object.jtString("caseId") == item.id {
            let fields = op.fields
            for field in fields.keys where Self.shows(op, clock: clock("cases", entity, field)) {
                switch field {
                case "status": item.status = fields.jtString(field)
                case "etd":
                    let value = fields.jtString(field)
                    // bar 的結束就是 ETD：JT 確認前先畫在新的日期，尾端字改成新日期
                    if item.end == item.etd { item.end = value }
                    item.etd = value
                    item.stat = JtDates.monthDay(value)
                    item.daysToEtd = nil
                case "note": item.note = fields.jtString(field)
                case "project": item.project = fields.jtString(field)
                case "endUser":
                    let value = fields.jtString(field)
                    if value != original.endUserName { item.endUserDomain = "" }
                    item.endUserName = value
                default: break
                }
            }
        }
        for op in pendingOps("milestone.set") where op.object.jtString("caseId") == item.id {
            let milestoneId = op.object.jtString("milestoneId")
            guard let index = item.milestones.firstIndex(where: { $0.id == milestoneId }) else { continue }
            let msEntity = "ms:\(item.id):\(milestoneId)"
            let fields = op.fields
            for field in fields.keys where Self.shows(op, clock: clock("cases", msEntity, field)) {
                switch field {
                case "done": item.milestones[index].done = fields.jtBool(field)
                case "date": item.milestones[index].date = fields.jtString(field)
                case "endDate": item.milestones[index].endDate = fields.jtString(field)
                case "title": item.milestones[index].title = fields.jtString(field)
                default: break
                }
            }
        }
        let deleted = Set(pendingOps("milestone.delete").filter { $0.object.jtString("caseId") == item.id }.map { $0.object.jtString("milestoneId") })
        item.milestones.removeAll { deleted.contains($0.id) }
        for op in pendingOps("milestone.add") where op.object.jtString("caseId") == item.id {
            let fields = op.fields
            item.milestones.append(JtMilestone(
                id: op.object.jtString("tempId"), type: fields.jtString("type"), title: fields.jtString("title"),
                date: fields.jtString("date"), endDate: fields.jtString("endDate"), done: false, note: "", isPending: true
            ))
        }
        for op in pendingOps("comment.add") where op.object.jtString("caseId") == item.id {
            let createdAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(op.editedAt) / 1000))
            item.comments.append(JtComment(id: op.opId, authorId: meta?.me ?? "", text: op.object.jtString("text"), createdAt: createdAt, isPending: true))
        }
        return item
    }

    /// 行事曆項目（套上待送的修改；刪除的不顯示）。
    func displayItems() -> [String: JtCalItem] {
        var items: [String: JtCalItem] = [:]
        let deleted = Set(pendingOps("todo.delete").map { $0.object.jtString("entryId") })
        for original in calendar?.items ?? [] where original.entryId.isEmpty || !deleted.contains(original.entryId) {
            var item = original
            if !item.entryId.isEmpty {
                let entity = "todo:" + item.entryId
                for op in pendingOps("todo.set") where op.object.jtString("entryId") == item.entryId {
                    let fields = op.fields
                    for field in fields.keys where Self.shows(op, clock: clock("calendar", entity, field)) {
                        switch field {
                        case "done": item.done = fields.jtBool(field)
                        case "title": item.title = fields.jtString(field)
                        case "start": item.start = fields.jtString(field)
                        case "note": item.note = fields.jtString(field)
                        default: break
                        }
                    }
                }
            }
            items[item.id] = item
        }
        return items
    }

    /// 這天還沒送到 JT 的新待辦。
    func pendingTodos(on date: String) -> [JtCalItem] {
        pendingOps("todo.create").compactMap { op in
            let fields = op.fields
            let start = fields.jtString("start")
            guard start.hasPrefix(date) else { return nil }
            return JtCalItem(pendingTodo: op.object.jtString("tempId"), title: fields.jtString("title"), date: date)
        }
    }

    func note(on date: String) -> String {
        var text = calendar?.notes[date] ?? ""
        for op in pendingOps("note.set") where op.object.jtString("date") == date {
            if Self.shows(op, clock: clock("calendar", "note:" + date, "text")) { text = op.object.jtString("text") }
        }
        return text
    }

    /// 在製清單（套上待送的釘選／隱藏）。
    var displayWipRows: [JtWipRow] {
        (wip?.rows ?? []).map { original in
            var row = original
            for op in pendingOps("wip.set") where !Set(op.object.jtStrings("pns")).isDisjoint(with: row.pns) {
                let fields = op.fields
                let entity = "wip:" + (row.pns.first ?? row.lead)
                if fields["pinned"] != nil, Self.shows(op, clock: clock("wip", entity, "pinned")) { row.pinned = fields.jtBool("pinned") }
                if fields["hidden"] != nil, Self.shows(op, clock: clock("wip", entity, "hidden")) { row.hidden = fields.jtBool("hidden") }
            }
            return row
        }
    }

    /// 這個實體還有沒處理完的編輯（列上顯示小時鐘）。
    func isPending(caseId: String) -> Bool {
        pending.contains { $0.object.jtString("caseId") == caseId }
    }

    func isPending(entryId: String) -> Bool {
        !entryId.isEmpty && pending.contains { $0.object.jtString("entryId") == entryId }
    }

    // MARK: - 編輯的捷徑

    func setCase(_ caseId: String, _ fields: JtObject) {
        submit("case.set", ["caseId": caseId, "fields": fields])
    }

    func setMilestone(_ caseId: String, _ milestone: JtMilestone, _ fields: JtObject) {
        submit("milestone.set", [
            "caseId": caseId, "milestoneId": milestone.id,
            "match": ["type": milestone.type, "title": milestone.title],
            "fields": fields,
        ])
    }

    func addComment(_ caseId: String, _ text: String) {
        submit("comment.add", ["caseId": caseId, "text": text])
    }

    func setTodo(_ entryId: String, _ fields: JtObject) {
        submit("todo.set", ["entryId": entryId, "fields": fields])
    }

    func createTodo(title: String, date: String) {
        submit("todo.create", ["tempId": "tmp-" + UUID().uuidString.lowercased(), "fields": ["title": title, "start": date, "allDay": true]])
    }

    func setNote(_ date: String, _ text: String) {
        submit("note.set", ["date": date, "text": text])
    }

    func setWip(_ pns: [String], _ fields: JtObject) {
        submit("wip.set", ["pns": pns, "fields": fields])
    }
}
