import Foundation

/// 全域搜尋裡 JT 業務追蹤的一筆：案件、待辦與行程、在製料號、機台、出貨交期。
/// 搜尋用的欄位、可以再篩選的欄位，以及點下去要在 JT 頁打開什麼。
struct JtSearchEntry: Equatable, Sendable {
    enum Kind: String, Sendable {
        case caseItem
        case agenda
        case wip
        case machine
        case po
    }

    let kind: Kind
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let fields: [String]
    let facets: [String]
    /// 要打開的案件。
    var caseId = ""
    /// 要在「今天」分頁打開的日期。
    var date = ""
    /// 帶到 JT 頁的搜尋字（在製、機台、出貨）。
    var query = ""
    /// 可以複製的代號（機種、料號、機台）。
    var copyValue = ""
}

/// 從搜尋或其他頁面打開 JT 業務追蹤的某個地方。
struct JtOpenRequest: Equatable {
    let section: JtSection
    var caseId: String?
    var date: String?
    var query: String?
    let id = UUID()
}

extension JtSyncStore {
    /// 全域搜尋要找的 JT 資料（套上還沒送出的修改）。
    func searchEntries() -> [JtSearchEntry] {
        Self.searchEntries(
            cases: displayCases,
            items: displayItems(),
            wip: wip.map { _ in displayWipRows } ?? [],
            machines: wip?.machines ?? [],
            po: po ?? [:],
            meta: meta,
            today: calendar?.today ?? meta?.today ?? JtDates.string(Date())
        )
    }

    static func searchEntries(
        cases: [JtCase],
        items: [String: JtCalItem],
        wip: [JtWipRow],
        machines: [JtMachine],
        po: JtObject,
        meta: JtMeta?,
        today: String
    ) -> [JtSearchEntry] {
        var entries: [JtSearchEntry] = []

        // 案件：還沒結束的在前（依 ETD），完成、取消的在後
        let orderedCases = cases.filter { !$0.isClosed }.sorted { $0.end < $1.end } + cases.filter(\.isClosed).sorted { $0.end > $1.end }
        for item in orderedCases {
            let owner = meta?.owner(item.ownerId)?.name ?? ""
            let detailParts: [String] = [item.customer, item.endUserName, item.isClosed ? item.status : item.stat, item.project, owner]
            var entry = JtSearchEntry(
                kind: .caseItem,
                id: item.id,
                title: item.title,
                detail: detailParts.filter { !$0.isEmpty }.joined(separator: " · "),
                systemImage: "chart.bar.xaxis",
                fields: [item.title, item.model, item.product, item.customer, item.endUserName, item.project, item.note, owner],
                facets: [item.customer, item.project, item.endUserName].filter { !$0.isEmpty }
            )
            entry.caseId = item.id
            entry.copyValue = item.model
            entries.append(entry)
        }

        // 待辦與行程：離今天近的在前
        let todayNumber = JtDayNumber.number(today) ?? 0
        let calendarItems = items.values.sorted { (a: JtCalItem, b: JtCalItem) -> Bool in
            let left = abs((JtDayNumber.number(a.day) ?? todayNumber) - todayNumber)
            let right = abs((JtDayNumber.number(b.day) ?? todayNumber) - todayNumber)
            return left == right ? a.start < b.start : left < right
        }
        for item in calendarItems {
            let kindTitle = JtPalette.calendarKindTitles[item.kind] ?? item.kind
            let when = JtDates.short(item.day) + (item.time.map { " " + $0 } ?? "")
            let detailParts: [String] = [kindTitle, when, item.customer, item.location, item.mailSender.isEmpty ? "" : "信件：" + item.mailSender, item.done ? "已完成" : ""]
            var entry = JtSearchEntry(
                kind: .agenda,
                id: item.id,
                title: item.title,
                detail: detailParts.filter { !$0.isEmpty }.joined(separator: " · "),
                systemImage: item.kind == "todo" ? (item.done ? "checkmark.circle" : "circle") : JtAgendaRow.icon(for: item.kind),
                fields: [item.title, item.subtitle, item.customer, item.location, item.mailSender, item.note, item.day, JtDates.monthDay(item.day)],
                facets: [kindTitle, item.customer].filter { !$0.isEmpty }
            )
            entry.caseId = item.caseId
            entry.date = item.day
            entries.append(entry)
        }

        // 在製料號
        for row in wip where !row.hidden {
            let detailParts: [String] = [row.product == row.model ? "" : row.product, row.customerName, row.pns.joined(separator: "、"), row.retired ? "已結束" : JtPalette.wipTitle(row.state)]
            var entry = JtSearchEntry(
                kind: .wip,
                id: row.id,
                title: row.title,
                detail: detailParts.filter { !$0.isEmpty }.joined(separator: " · "),
                systemImage: "gearshape.2",
                fields: [row.model, row.product, row.label, row.lead, row.customerName] + row.pns + row.machines,
                facets: [row.customerName, JtPalette.wipTitle(row.state)].filter { !$0.isEmpty }
            )
            entry.query = row.model.isEmpty ? (row.pns.first ?? row.label) : row.model
            entry.copyValue = row.pns.first ?? row.lead
            entries.append(entry)
        }

        // 機台
        for machine in machines {
            let state = machine.word.isEmpty ? JtPalette.machineGroupTitle(machine.group) : machine.word
            let detailParts: [String] = [machine.summary.isEmpty ? state : machine.summary, machine.customer, machine.lot]
            var entry = JtSearchEntry(
                kind: .machine,
                id: machine.id,
                title: machine.eqp,
                detail: detailParts.filter { !$0.isEmpty }.joined(separator: " · "),
                systemImage: "square.grid.3x3",
                fields: [machine.eqp, machine.summary, machine.customer, machine.lot, machine.reason, state] + machine.mine,
                facets: [JtPalette.machineGroupTitle(machine.group), machine.customer].filter { !$0.isEmpty }
            )
            entry.query = machine.eqp
            entry.copyValue = machine.eqp
            entries.append(entry)
        }

        // 出貨交期：逾期的在前；欄位用整筆資料的文字（PO 格式同桌面 API）
        let poObjects = po.jtObjects("overdue") + po.jtObjects("items")
        for (index, object) in poObjects.enumerated() {
            let row = JtListRow(object, index: index)
            let texts = object.keys.sorted().compactMap { key -> String? in
                let value = object.jtString(key)
                return value.isEmpty ? nil : value
            }
            var entry = JtSearchEntry(
                kind: .po,
                id: "po:" + row.id,
                title: row.title,
                detail: [row.detail, row.date, row.badge].filter { !$0.isEmpty }.joined(separator: " · "),
                systemImage: "shippingbox",
                fields: [row.title, row.detail, row.date] + texts,
                facets: [object.jtString("customer"), object.jtString("customerName")].filter { !$0.isEmpty }
            )
            entry.query = row.title
            entries.append(entry)
        }
        return entries
    }

    /// 搜尋結果點下去：打開 JT 業務追蹤的那個地方（案件、那一天、在製、機台或出貨）。
    func open(_ entry: JtSearchEntry) {
        switch entry.kind {
        case .caseItem:
            openRequest = JtOpenRequest(section: .gantt, caseId: entry.caseId, query: "")
        case .agenda:
            if entry.caseId.isEmpty {
                openRequest = JtOpenRequest(section: .today, date: entry.date, query: "")
            } else {
                openRequest = JtOpenRequest(section: .gantt, caseId: entry.caseId, query: "")
            }
        case .wip:
            openRequest = JtOpenRequest(section: .wip, query: entry.query)
        case .machine:
            openRequest = JtOpenRequest(section: .machines, query: entry.query)
        case .po:
            openRequest = JtOpenRequest(section: .po, query: entry.query)
        }
    }
}
