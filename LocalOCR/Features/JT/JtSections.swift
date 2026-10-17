import SwiftUI

// JT 業務追蹤的其他分頁：今天（行事曆）、在製、機台、出貨、通知，以及案件的詳細與編輯。

// MARK: - 今天

struct JtDayView: View {
    let store: JtSyncStore
    let onOpenCase: (String) -> Void

    @State private var selected = ""
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let today = store.calendar?.today ?? store.meta?.today ?? JtDates.string(Date())
        let date = selected.isEmpty ? today : selected
        let sections = store.agenda(on: date)
        VStack(spacing: 0) {
            dateStrip(today: today, selected: date)
            Rectangle().fill(DS.hairline).frame(height: 1)
            ToolScroll {
                header(date: date, today: today)
                if sections.isEmpty {
                    Text("這天沒有項目")
                        .font(.footnote)
                        .foregroundStyle(DS.textTertiary)
                        .padding(.vertical, 8)
                }
                ForEach(sections) { section in
                    JtAgendaSectionView(section: section, store: store, onOpenCase: onOpenCase)
                }
                JtAddTodoField(store: store, date: date)
                JtDayNoteCard(store: store, date: date)
                if let error = store.calendar?.outlookError, !error.isEmpty {
                    Text("Outlook 同步問題：\(error)")
                        .font(.caption)
                        .foregroundStyle(DS.warning)
                }
            }
        }
    }

    private func dateStrip(today: String, selected: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(-7...21, id: \.self) { offset in
                        let day = JtDates.shifted(today, by: offset)
                        dayChip(day, isSelected: day == selected, isToday: offset == 0)
                            .id(day)
                    }
                }
                .padding(.horizontal, sizeClass == .compact ? 16 : 24)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
        }
    }

    private func dayChip(_ day: String, isSelected: Bool, isToday: Bool) -> some View {
        let date = JtDates.date(day) ?? Date()
        let parts = Calendar(identifier: .gregorian).dateComponents([.day, .weekday], from: date)
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        let isHoliday = store.calendar?.holidays[day] != nil || JournalCalendar.isDayOff(day)
        let count = store.calendar?.days[day]?.groups.reduce(0) { $0 + $1.ids.count } ?? 0
        return Button { self.selected = day } label: {
            VStack(spacing: 2) {
                Text(weekdays[((parts.weekday ?? 1) - 1) % 7])
                    .font(.caption2)
                    .foregroundStyle(isSelected ? DS.onPrimary : (isHoliday ? DS.danger : DS.textSecondary))
                Text("\(parts.day ?? 0)")
                    .font(.system(size: 15, weight: isToday ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isSelected ? DS.onPrimary : DS.text)
                Circle()
                    .fill(count > 0 ? (isSelected ? DS.onPrimary : DS.link) : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: 40, height: 54)
            .background(isSelected ? DS.primary : (isToday ? DS.control : Color.clear), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func header(date: String, today: String) -> some View {
        HStack(spacing: 8) {
            Text(date == today ? "今天 \(JtDates.short(date))" : JtDates.short(date))
                .font(.headline)
                .foregroundStyle(DS.text)
            if let holiday = store.calendar?.holidays[date] ?? TaiwanHolidays.holiday(on: date), !holiday.isEmpty {
                Text(holiday)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DS.danger)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(DS.danger.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }
}

// MARK: - 在製

struct JtWipView: View {
    let store: JtSyncStore
    let query: String
    @State private var showsHidden = false

    var body: some View {
        let rows = store.displayWipRows.filter { (row: JtWipRow) -> Bool in
            if row.hidden && !showsHidden { return false }
            return matches(row)
        }
        let ordered = rows.filter(\.pinned) + rows.filter { !$0.pinned }
        ToolScroll {
            HStack(spacing: 8) {
                MetricTile(title: "追蹤中", value: "\(store.displayWipRows.filter { !$0.hidden }.count)", pastel: .sky)
                MetricTile(title: "卡住", value: "\(rows.filter { $0.state == "stuck" }.count)", pastel: .blush, valueColor: DS.danger)
                MetricTile(title: "生產中", value: "\(rows.filter { $0.state == "run" }.count)", pastel: .mint)
            }
            ToggleChip(title: "顯示隱藏的料號", isOn: $showsHidden)
            if ordered.isEmpty {
                EmptyStateView(title: "沒有在製項目")
            }
            ForEach(ordered) { row in
                wipRow(row)
            }
        }
    }

    private func matches(_ row: JtWipRow) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        let fields: [String] = [row.label, row.customerName, row.pns.joined(separator: " ")]
        return fields.contains { $0.localizedCaseInsensitiveContains(text) }
    }

    private func wipRow(_ row: JtWipRow) -> some View {
        HStack(spacing: 10) {
            Circle().fill(JtPalette.wipColor(row.state)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if row.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(DS.textSecondary) }
                    Text(row.label.isEmpty ? row.lead : row.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(row.hidden ? DS.textTertiary : DS.text)
                        .lineLimit(1)
                }
                Text(wipDetail(row))
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Text(JtPalette.wipTitle(row.state))
                .font(.caption.weight(.semibold))
                .foregroundStyle(JtPalette.wipColor(row.state))
        }
        .padding(12)
        .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1))
        .contextMenu {
            Button { store.setWip(row.pns, ["pinned": !row.pinned]) } label: {
                Label(row.pinned ? "取消釘選" : "釘選", systemImage: row.pinned ? "pin.slash" : "pin")
            }
            Button { store.setWip(row.pns, ["hidden": !row.hidden]) } label: {
                Label(row.hidden ? "不再隱藏" : "隱藏", systemImage: row.hidden ? "eye" : "eye.slash")
            }
        }
    }
}

private func wipDetail(_ row: JtWipRow) -> String {
    var parts: [String] = [row.customerName, row.pns.joined(separator: "、")]
    if row.rowCount > 0 { parts.append("\(row.rowCount) 筆") }
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
}

// MARK: - 機台

struct JtMachinesView: View {
    let store: JtSyncStore
    let query: String
    @State private var filter = "mine"

    private static let filters: [(value: String, title: String)] = [
        ("mine", "我的機台"), ("all", "全部"), ("down", "停機"), ("run", "生產中"), ("mold", "換模"), ("pm", "保養"), ("fai", "首件"), ("idle", "閒置"),
    ]

    var body: some View {
        let machines = (store.wip?.machines ?? []).filter { (machine: JtMachine) -> Bool in
            shows(machine)
        }
        ToolScroll {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Self.filters, id: \.value) { option in
                        Button { filter = option.value } label: {
                            FilterChip(title: option.title, isActive: filter == option.value)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            if let wip = store.wip, !wip.boardConfigured, wip.machines.isEmpty {
                EmptyStateView(title: "機台看板還沒設定", message: "在電腦的 JT 設定機台看板（MES）後就會出現。")
            } else if machines.isEmpty {
                EmptyStateView(title: filter == "mine" ? "沒有跑你的料號的機台" : "沒有符合的機台")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 8)], spacing: 8) {
                ForEach(machines) { machine in
                    machineCard(machine)
                }
            }
            if let fetched = store.wip?.boardFetchedAt, !fetched.isEmpty {
                Text("看板更新於 \(fetched)").font(.caption).foregroundStyle(DS.textTertiary)
            }
        }
    }

    private func shows(_ machine: JtMachine) -> Bool {
        switch filter {
        case "mine": if !machine.isMine { return false }
        case "all": break
        default: if machine.group != filter { return false }
        }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        let fields: [String] = [machine.eqp, machine.customer, machine.summary, machine.lot]
        return fields.contains { $0.localizedCaseInsensitiveContains(text) }
    }

    private func machineCard(_ machine: JtMachine) -> some View {
        let pastel = JtPalette.machinePastel(machine.group)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(machine.eqp).font(.subheadline.weight(.bold)).foregroundStyle(DS.text)
                if machine.isMine {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(DS.warning)
                }
                Spacer(minLength: 0)
                Text(machine.word.isEmpty ? JtPalette.machineGroupTitle(machine.group) : machine.word)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DS.textSecondary)
            }
            Text(machine.summary.isEmpty ? machine.reason : machine.summary)
                .font(.caption)
                .foregroundStyle(DS.text)
                .lineLimit(2)
            Text([machine.customer, machine.lot].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(pastel?.color ?? DS.card, in: RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(pastel == nil ? DS.cardBorder : Color.clear, lineWidth: 1))
    }
}

// MARK: - 出貨與通知（與桌面版 API 同格式：顯示常見欄位）

struct JtListSection: View {
    let title: String
    let rows: [JtListRow]
    var tint: Color = DS.textSecondary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Text("\(rows.count)").font(.caption2.monospacedDigit()).foregroundStyle(DS.textTertiary)
            }
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.subheadline)
                                .foregroundStyle(row.isAlert ? DS.danger : DS.text)
                                .lineLimit(2)
                            if !row.detail.isEmpty {
                                Text(row.detail).font(.caption).foregroundStyle(DS.textSecondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            if !row.date.isEmpty {
                                Text(row.date).font(.caption.monospacedDigit()).foregroundStyle(DS.textSecondary)
                            }
                            if !row.badge.isEmpty {
                                Text(row.badge).font(.caption2.weight(.semibold)).foregroundStyle(DS.textTertiary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    if row.id != rows.last?.id {
                        Rectangle().fill(DS.hairline).frame(height: 0.5).padding(.leading, 12)
                    }
                }
            }
            .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1))
        }
    }
}

private func jtFiltered(_ rows: [JtListRow], _ query: String) -> [JtListRow] {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return rows }
    return rows.filter { $0.title.localizedCaseInsensitiveContains(text) || $0.detail.localizedCaseInsensitiveContains(text) }
}

struct JtPoView: View {
    let store: JtSyncStore
    let query: String

    var body: some View {
        let data = store.po ?? [:]
        let overdue = jtFiltered(JtListRow.rows(data.jtObjects("overdue")), query)
        let items = jtFiltered(JtListRow.rows(data.jtObjects("items")), query)
        ToolScroll {
            if overdue.isEmpty && items.isEmpty {
                EmptyStateView(title: "沒有出貨追蹤", message: "電腦的 JT 會列出前 14 天到後 60 天的交期。")
            }
            if !overdue.isEmpty {
                JtListSection(title: "逾期", rows: overdue, tint: DS.danger)
            }
            if !items.isEmpty {
                JtListSection(title: "交期", rows: items)
            }
            Text("出貨日期與備註請在電腦的 JT 或 PO LIST 修改。")
                .font(.caption)
                .foregroundStyle(DS.textTertiary)
        }
    }
}

struct JtAlertsView: View {
    let store: JtSyncStore
    let query: String

    private static let titles: [(key: String, title: String)] = [
        ("items", "待處理"), ("poDue", "PO 交期"), ("recentChanges", "異動通知"), ("poChanges", "PO 異動"), ("wipChanges", "在製異動"),
    ]

    var body: some View {
        let list = sections()
        ToolScroll {
            if list.isEmpty {
                EmptyStateView(title: "沒有通知")
            }
            ForEach(list, id: \.title) { section in
                JtListSection(title: section.title, rows: section.rows, tint: section.title == "待處理" ? DS.warning : DS.textSecondary)
            }
        }
    }

    /// 已知的段落依固定順序，其他非空的清單接在後面（JT 加了新的通知種類也看得到）。
    private func sections() -> [(title: String, rows: [JtListRow])] {
        let data = store.dashboard ?? [:]
        let known = Set(Self.titles.map(\.key))
        var entries = Self.titles
        for key in data.keys.sorted() where !known.contains(key) && !data.jtObjects(key).isEmpty {
            entries.append((key: key, title: key))
        }
        var result: [(title: String, rows: [JtListRow])] = []
        for entry in entries {
            let rows = jtFiltered(JtListRow.rows(data.jtObjects(entry.key)), query)
            if !rows.isEmpty { result.append((title: entry.title, rows: rows)) }
        }
        return result
    }
}

// MARK: - 案件詳細與編輯

struct JtCaseDetail: View {
    let caseId: String

    @State private var store = JtSyncStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var noteDraft = ""
    @State private var projectDraft = ""
    @State private var commentDraft = ""
    @State private var didLoadDrafts = false

    var body: some View {
        NavigationStack {
            Group {
                if let item = store.displayCase(caseId) {
                    content(item)
                } else {
                    EmptyStateView(title: "找不到這個案件", message: "可能已在電腦的 JT 刪除。")
                }
            }
            .background(DS.pane)
            .navigationTitle("案件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func content(_ item: JtCase) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(item)
                statusSection(item)
                etdSection(item)
                textSection(title: "專案", text: $projectDraft, original: item.project, multiline: false) {
                    store.setCase(item.id, ["project": projectDraft.trimmingCharacters(in: .whitespacesAndNewlines)])
                }
                textSection(title: "備註", text: $noteDraft, original: item.note, multiline: true) {
                    store.setCase(item.id, ["note": noteDraft])
                }
                milestones(item)
                comments(item)
                if let wip = item.wip {
                    wipSection(wip)
                }
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            guard !didLoadDrafts else { return }
            noteDraft = item.note
            projectDraft = item.project
            didLoadDrafts = true
        }
    }

    private func header(_ item: JtCase) -> some View {
        HStack(alignment: .top, spacing: 12) {
            JtLogo(domain: item.customerDomain, name: item.customer, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(DS.text)
                    .textSelection(.enabled)
                Text([item.customer, item.endUserName, store.meta?.owner(item.ownerId)?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(DS.textSecondary)
                HStack(spacing: 6) {
                    Text(item.stat)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.tone == "attention" ? DS.warning : DS.textSecondary)
                    if item.progressTotal > 0 {
                        Text("進度 \(item.progressDone)/\(item.progressTotal)").font(.caption).foregroundStyle(DS.textSecondary)
                    }
                    if !item.overdueLabel.isEmpty, let days = item.overdueDays, days > 0 {
                        Text("\(item.overdueLabel) 逾期 \(days) 天").font(.caption).foregroundStyle(DS.danger)
                    }
                    if store.isPending(caseId: item.id) {
                        Label("同步中", systemImage: "clock").font(.caption2).foregroundStyle(DS.textTertiary)
                    }
                }
                if item.model != item.title, !item.model.isEmpty {
                    Text(item.model).font(.caption.monospaced()).foregroundStyle(DS.textTertiary).textSelection(.enabled)
                }
            }
        }
    }

    private func statusSection(_ item: JtCase) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("狀態").font(.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
            SegmentedPills(
                options: JtSyncStore.statuses.map { (value: $0, title: $0) },
                selection: Binding(get: { item.status }, set: { value in
                    guard value != item.status else { return }
                    store.setCase(item.id, ["status": value])
                })
            )
        }
    }

    private func etdSection(_ item: JtCase) -> some View {
        HStack {
            Text("ETD").font(.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
            Spacer()
            DatePicker(
                "ETD",
                selection: Binding(get: { JtDates.date(item.etd) ?? Date() }, set: { date in
                    let value = JtDates.string(date)
                    guard value != item.etd else { return }
                    store.setCase(item.id, ["etd": value])
                }),
                displayedComponents: .date
            )
            .labelsHidden()
            if !item.etdFrom.isEmpty {
                Button("取消延期") { store.setCase(item.id, ["etdFrom": ""]) }
                    .font(.footnote)
            }
        }
    }

    private func textSection(title: String, text: Binding<String>, original: String, multiline: Bool, save: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
                Spacer()
                if text.wrappedValue != original {
                    Button("儲存") { save() }
                        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                }
            }
            if multiline {
                TextEditor(text: text)
                    .font(.subheadline)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(DS.control, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
            } else {
                TextField(title, text: text)
                    .font(.subheadline)
                    .padding(10)
                    .background(DS.control, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
                    .onSubmit(save)
            }
        }
    }

    private func milestones(_ item: JtCase) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("里程碑").font(.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
            if item.milestones.isEmpty {
                Text("沒有里程碑").font(.footnote).foregroundStyle(DS.textTertiary)
            }
            ForEach(item.milestones) { milestone in
                HStack(spacing: 10) {
                    Button {
                        store.setMilestone(item.id, milestone, ["done": !milestone.done])
                    } label: {
                        Image(systemName: milestone.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(milestone.done ? DS.success : DS.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(milestone.isPending)
                    VStack(alignment: .leading, spacing: 1) {
                        Text([milestone.type, milestone.title].filter { !$0.isEmpty }.joined(separator: "：")).font(.subheadline).foregroundStyle(DS.text)
                        Text(milestone.endDate.isEmpty ? milestone.date : "\(milestone.date) ～ \(milestone.endDate)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if milestone.isPending {
                        Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(DS.textTertiary)
                    }
                }
            }
        }
    }

    private func comments(_ item: JtCase) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("留言").font(.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
            ForEach(item.comments) { comment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(store.meta?.owner(comment.authorId)?.name ?? comment.authorId)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DS.text)
                        Text(String(comment.createdAt.prefix(16)).replacingOccurrences(of: "T", with: " "))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(DS.textTertiary)
                        if comment.isPending {
                            Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(DS.textTertiary)
                        }
                    }
                    Text(comment.text).font(.subheadline).foregroundStyle(DS.text).textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.control, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
            }
            HStack(spacing: 8) {
                TextField("寫留言（寫到 Outlook 案件）", text: $commentDraft, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...4)
                Button("送出") {
                    let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    store.addComment(item.id, text)
                    commentDraft = ""
                }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .background(DS.control, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
        }
    }

    private func wipSection(_ wip: JtCaseWip) -> some View {
        HStack(spacing: 8) {
            Circle().fill(JtPalette.wipColor(wip.tone)).frame(width: 10, height: 10)
            Text([wip.material, wip.eqp, wip.text].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(DS.text)
            Spacer(minLength: 0)
        }
        .padding(12)
        .pastelCard(.sky, padding: 0)
    }
}
