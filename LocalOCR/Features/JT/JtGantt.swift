import SwiftUI

// JT 業務追蹤的甘特：照桌面版 JT Sales Tracker 的甘特排版（工具列、左欄、bar、里程碑、ETD 旗），
// 分組與排序用 JT 算好的 layouts；完成、取消的案件平常不顯示（「完成」分頁才看得到）。

// MARK: - 比例與篩選

enum JtGanttScale: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "日"
        case .week: return "週"
        case .month: return "月"
        }
    }

    /// 一天的寬度。
    var dayWidth: CGFloat {
        switch self {
        case .day: return 34
        case .week: return 14
        case .month: return 4.5
        }
    }

    var finer: JtGanttScale {
        switch self {
        case .day, .week: return .day
        case .month: return .week
        }
    }

    var coarser: JtGanttScale {
        switch self {
        case .day: return .week
        case .week, .month: return .month
        }
    }
}

/// 工具列的「全部｜進行中｜注意｜待出貨｜完成」：依 JT 算好的顯示狀態（tone）。
enum JtGanttFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case attention
    case ready
    case closed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .active: return "進行中"
        case .attention: return "注意"
        case .ready: return "待出貨"
        case .closed: return "完成"
        }
    }

    /// 「全部」是還沒結束的案件：完成、取消的自動隱藏，在「完成」分頁看。
    func includes(_ item: JtCase) -> Bool {
        switch self {
        case .all: return !item.isClosed
        case .active: return item.tone == "active"
        case .attention: return item.tone == "attention"
        case .ready: return item.tone == "ready"
        case .closed: return item.isClosed
        }
    }
}

// MARK: - 列

struct JtGanttGroup {
    let row: JtGroupRow
    /// 這一組目前顯示的案件（篩選後）。
    let members: [JtCase]
    let isCollapsed: Bool

    /// 組內客戶都一樣：那幾列不再重複顯示客戶，改顯示終端客戶。
    var sameCustomer: Bool { Set(members.map(\.customer)).count == 1 }
    var attention: Int { members.filter { $0.tone == "attention" }.count }
}

enum JtGanttRow: Identifiable {
    case group(JtGanttGroup)
    case item(JtCase, indent: Bool, sameCustomer: Bool)

    static let caseHeight: CGFloat = 54
    static let groupHeight: CGFloat = 40

    var id: String {
        switch self {
        case .group(let group): return "group:" + group.row.id
        case .item(let item, _, _): return "case:" + item.id
        }
    }

    var height: CGFloat {
        switch self {
        case .group: return Self.groupHeight
        case .item: return Self.caseHeight
        }
    }

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

enum JtGanttModel {
    /// 照 JT 的列順序排出要畫的列：篩掉的案件不畫，組裡沒有案件的標題也不畫；收合的組只畫標題。
    static func rows(
        layout: [JtLayoutRow],
        cases: [String: JtCase],
        include: (JtCase) -> Bool,
        collapsed: Set<String>,
        expandAll: Bool
    ) -> [JtGanttRow] {
        var rows: [JtGanttRow] = []
        var groupOf: [String: JtGanttGroup] = [:]
        var hidden: Set<String> = []
        for entry in layout {
            switch entry {
            case .group(let group):
                let members = group.caseIds.compactMap { cases[$0] }.filter(include)
                guard !members.isEmpty else { continue }
                let isCollapsed = !expandAll && collapsed.contains(group.id)
                let info = JtGanttGroup(row: group, members: members, isCollapsed: isCollapsed)
                for member in members { groupOf[member.id] = info }
                if isCollapsed { hidden.formUnion(group.caseIds) }
                rows.append(.group(info))
            case .item(let caseId):
                guard !hidden.contains(caseId), let item = cases[caseId], include(item) else { continue }
                let group = groupOf[caseId]
                rows.append(.item(item, indent: group != nil, sameCustomer: group?.sameCustomer ?? false))
            }
        }
        return rows
    }

    /// 沒有 JT 排好的列時：依 ETD 由近到遠。
    static func fallbackLayout(_ cases: [JtCase]) -> [JtLayoutRow] {
        cases.sorted { (a: JtCase, b: JtCase) -> Bool in
            let left = a.etd.isEmpty ? a.end : a.etd
            let right = b.etd.isEmpty ? b.end : b.etd
            return left < right
        }
        .map { JtLayoutRow.item($0.id) }
    }
}

// MARK: - 時間軸

struct JtTimeline {
    let firstDay: Int
    let days: Int
    let dayWidth: CGFloat
    let todayDay: Int

    var width: CGFloat { CGFloat(days) * dayWidth }
    var todayX: CGFloat { x(day: todayDay) }

    /// 這天左緣的位置（超出範圍時夾在兩端）。
    func x(day: Int) -> CGFloat {
        min(max(CGFloat(day - firstDay) * dayWidth, 0), width)
    }

    func x(_ text: String) -> CGFloat? {
        JtDayNumber.number(text).map { x(day: $0) }
    }

    /// 範圍：所有案件的開始到結束、至少今天 −30 到 +90 天，前後最多 18 個月（同桌面的時間軸範圍）。
    static func make(cases: [JtCase], today: String, dayWidth: CGFloat) -> JtTimeline {
        let now = JtDayNumber.number(today) ?? JtDayNumber.number(JtDates.string(Date())) ?? 0
        var lower = now - 30
        var upper = now + 90
        for item in cases {
            if let start = JtDayNumber.number(item.start) { lower = min(lower, start) }
            if let end = JtDayNumber.number(item.end) { upper = max(upper, end) }
            if let etd = JtDayNumber.number(item.etd) { upper = max(upper, etd) }
        }
        lower = max(lower - 7, now - 540)
        upper = min(upper + 30, now + 540)
        return JtTimeline(firstDay: lower, days: upper - lower + 1, dayWidth: dayWidth, todayDay: now)
    }
}

/// 案件 bar 的位置（點與寬度都已換算好）。
struct JtBarGeometry {
    let x0: CGFloat
    let x1: CGFloat
    let progressX: CGFloat
    /// ETD 旗（三角形）的左緣：ETD 那天的右緣。
    let flagX: CGFloat
    let etd: String

    var width: CGFloat { max(x1 - x0, 4) }

    init(item: JtCase, timeline: JtTimeline, dragDays: Int = 0) {
        let dayWidth = timeline.dayWidth
        let originalEtd = JtDayNumber.number(item.etd) ?? JtDayNumber.number(item.end)
        let startDay = JtDayNumber.number(item.start) ?? originalEtd ?? timeline.todayDay
        var endDay = JtDayNumber.number(item.end) ?? originalEtd ?? startDay
        var etdDay = originalEtd ?? endDay
        if dragDays != 0 {
            // 拖 ETD 旗：bar 的結束就是 ETD 時跟著動
            if endDay == etdDay { endDay += dragDays }
            etdDay += dragDays
        }
        x0 = timeline.x(day: startDay)
        var right = timeline.x(day: endDay) + dayWidth
        // 今天的藍線畫在今天的正中間：延伸到今天、填到目前進度都停在同一條線上（同桌面版）
        let todayLine = timeline.todayX + dayWidth / 2
        if item.tone == "attention", !item.isClosed {
            right = max(right, todayLine)
        }
        x1 = max(right, x0 + 4)
        if item.isClosed || item.tone == "ready" {
            progressX = x1
        } else if let progress = JtDayNumber.number(item.progressDate) {
            progressX = min(max(timeline.x(day: progress) + dayWidth / 2, x0), x1)
        } else {
            progressX = x0
        }
        flagX = timeline.x(day: etdDay) + dayWidth
        etd = JtDayNumber.string(etdDay)
    }
}

/// bar 上的里程碑點：太近的合成一顆數字膠囊。
struct JtMarkerDot: Identifiable {
    let id: String
    let x: CGFloat
    let count: Int
    let done: Bool
    let overdue: Bool
    let titles: [String]

    static func clusters(_ markers: [JtMarker], timeline: JtTimeline, isClosed: Bool, spacing: CGFloat = 12) -> [JtMarkerDot] {
        var points: [(x: CGFloat, marker: JtMarker)] = []
        for marker in markers {
            guard let day = JtDayNumber.number(marker.date) else { continue }
            points.append((timeline.x(day: day) + timeline.dayWidth / 2, marker))
        }
        points.sort { $0.x < $1.x }
        var result: [JtMarkerDot] = []
        var group: [(x: CGFloat, marker: JtMarker)] = []
        func flush() {
            guard let first = group.first else { return }
            let total = group.reduce(CGFloat(0)) { $0 + $1.x }
            let overdue = group.contains { item in
                !isClosed && !item.marker.done && (JtDayNumber.number(item.marker.date) ?? Int.max) < timeline.todayDay
            }
            result.append(JtMarkerDot(
                id: first.marker.id.isEmpty ? "\(first.x)" : first.marker.id,
                x: total / CGFloat(group.count),
                count: group.count,
                done: group.allSatisfy { $0.marker.done },
                overdue: overdue,
                titles: group.map { $0.marker.title.isEmpty ? $0.marker.type : $0.marker.title }
            ))
            group = []
        }
        for point in points {
            if let last = group.last, point.x - last.x >= spacing { flush() }
            group.append(point)
        }
        flush()
        return result
    }
}

/// 時間軸的捲動位置（只有日期列跟著捲動重畫，案件列不會）。
@MainActor
@Observable
final class JtGanttScroll {
    var offsetX: CGFloat = 0
    var viewport: CGFloat = 0
}

// MARK: - 甘特

struct JtGanttView: View {
    let store: JtSyncStore
    @Binding var query: String
    let onOpen: (String) -> Void

    @AppStorage("jt.groupMode") private var mode = "etd-asc"
    @AppStorage("jt.collapsedGroups") private var collapsedRaw = ""
    @AppStorage("jt.scale") private var scaleRaw = JtGanttScale.week.rawValue
    @AppStorage("jt.filter") private var filterRaw = JtGanttFilter.all.rawValue
    @AppStorage("jt.owners") private var ownersRaw = ""
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var scroll = JtGanttScroll()
    @State private var position = ScrollPosition(edge: .leading)
    @State private var showsLegend = false
    @State private var endUserCase: JtCaseReference?
    @State private var projectCase: JtCase?
    @State private var projectDraft = ""
    @State private var renamingGroup: JtGanttGroup?
    @State private var renameDraft = ""

    private var scale: JtGanttScale { JtGanttScale(rawValue: scaleRaw) ?? .week }
    private var filter: JtGanttFilter { JtGanttFilter(rawValue: filterRaw) ?? .all }
    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }
    private var owners: Set<String> { Set(ownersRaw.split(separator: "\n").map(String.init)) }
    private var labelWidth: CGFloat { sizeClass == .compact ? 176 : 290 }
    private var today: String { store.meta?.today ?? store.calendar?.today ?? JtDates.string(Date()) }

    var body: some View {
        let cases = store.displayCases
        let byId = Dictionary(cases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let timeline = JtTimeline.make(cases: cases, today: today, dayWidth: scale.dayWidth)
        let inScope = cases.filter { inFilter($0) }
        let rows = visibleRows(byId)
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(DS.hairline).frame(height: 1)
            header(timeline: timeline, caseCount: inScope.count)
            Rectangle().fill(DS.hairline).frame(height: 1)
            if rows.isEmpty {
                emptyState
                Spacer(minLength: 0)
            } else {
                chart(rows: rows, timeline: timeline)
            }
        }
        .onAppear { scrollToToday(timeline, animated: false) }
        .onChange(of: scaleRaw) { old, _ in keepCenter(oldScale: JtGanttScale(rawValue: old) ?? .week) }
        .sheet(item: $endUserCase) { reference in
            JtEndUserPicker(store: store, caseId: reference.id)
        }
        .alert("新專案", isPresented: Binding(get: { projectCase != nil }, set: { if !$0 { projectCase = nil } })) {
            TextField("專案名稱", text: $projectDraft)
            Button("建立") {
                let name = projectDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if let item = projectCase, !name.isEmpty { store.setCase(item.id, ["project": name]) }
                projectCase = nil
            }
            Button("取消", role: .cancel) { projectCase = nil }
        }
        .alert("重新命名專案", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("專案名稱", text: $renameDraft)
            Button("儲存") {
                let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if let group = renamingGroup, !name.isEmpty {
                    for caseId in group.row.caseIds { store.setCase(caseId, ["project": name]) }
                }
                renamingGroup = nil
            }
            Button("取消", role: .cancel) { renamingGroup = nil }
        }
    }

    private func inFilter(_ item: JtCase) -> Bool {
        filter.includes(item) && (owners.isEmpty || owners.contains(item.ownerId))
    }

    private func visibleRows(_ byId: [String: JtCase]) -> [JtGanttRow] {
        let layouts = store.cases?.layouts ?? [:]
        let fallback = JtGanttModel.fallbackLayout(Array(byId.values))
        let layout: [JtLayoutRow] = layouts[mode] ?? layouts["etd-asc"] ?? fallback
        let text = query.trimmingCharacters(in: .whitespaces)
        let expandAll = filter != .all || !text.isEmpty
        return JtGanttModel.rows(
            layout: layout,
            cases: byId,
            include: { (item: JtCase) -> Bool in inFilter(item) && item.matches(text) },
            collapsed: collapsed,
            expandAll: expandAll
        )
    }

    // MARK: 工具列

    private var toolbar: some View {
        let modes: [(value: String, title: String)] = (store.meta?.groupModes ?? JtMeta.defaultModes).map { (value: $0.mode, title: $0.label) }
        let scales: [(value: String, title: String)] = JtGanttScale.allCases.map { (value: $0.rawValue, title: $0.title) }
        let filters: [(value: String, title: String)] = JtGanttFilter.allCases.map { (value: $0.rawValue, title: $0.title) }
        return ScrollView(.horizontal) {
            HStack(spacing: 10) {
                Text(JtDates.short(today))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(DS.text)
                Button("今天") { scrollToToday(nil, animated: true) }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                SegmentedPills(options: scales, selection: $scaleRaw)
                SegmentedPills(options: filters, selection: $filterRaw)
                HStack(spacing: 6) {
                    Text("排序")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                    SegmentedPills(options: modes, selection: $mode)
                }
                ownerChips
                Button { showsLegend = true } label: {
                    Text("圖例").font(.footnote.weight(.medium))
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                .popover(isPresented: $showsLegend) {
                    JtGanttLegend(ownerColor: ownerColor(store.meta?.me ?? ""))
                        .presentationCompactAdaptation(.popover)
                }
            }
            .padding(.horizontal, sizeClass == .compact ? 16 : 20)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    /// 業務頭像：點一下只看那位業務的案件（可以多選），再點一次取消。
    private var ownerChips: some View {
        HStack(spacing: 4) {
            ForEach(store.meta?.owners ?? []) { owner in
                let isOn = owners.isEmpty || owners.contains(owner.id)
                Button { toggleOwner(owner.id) } label: {
                    Text(owner.initial.isEmpty ? String(owner.name.prefix(2)).uppercased() : owner.initial)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(jtHex: owner.foreground) ?? .white)
                        .frame(width: 28, height: 28)
                        .background(owner.color, in: Circle())
                        .opacity(isOn ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(owner.name)
                .accessibilityAddTraits(owners.contains(owner.id) ? .isSelected : [])
            }
        }
    }

    private func toggleOwner(_ id: String) {
        var set = owners
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        ownersRaw = set.sorted().joined(separator: "\n")
    }

    // MARK: 日期列

    private func header(timeline: JtTimeline, caseCount: Int) -> some View {
        HStack(spacing: 0) {
            SearchField(placeholder: "篩選 \(caseCount) 件…", text: $query, height: 30)
                .padding(.horizontal, 8)
                .frame(width: labelWidth, height: JtTimelineHeader.height)
            Rectangle().fill(DS.hairline).frame(width: 1, height: JtTimelineHeader.height)
            // 用 overlay 放日期列：它跟時間軸一樣寬，不能參與排版（否則整列被撐寬、左欄的搜尋被擠出畫面）
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: JtTimelineHeader.height)
                .overlay(alignment: .topLeading) {
                    JtTimelineHeader(timeline: timeline, scale: scale, scroll: scroll)
                }
                .clipped()
        }
    }

    // MARK: 列

    private func chart(rows: [JtGanttRow], timeline: JtTimeline) -> some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        labelRow(row)
                            .frame(width: labelWidth, height: row.height)
                            .background(row.isGroup ? Self.groupTint : Color.clear)
                        Rectangle().fill(DS.hairline.opacity(0.6)).frame(height: 0.5)
                    }
                }
                .frame(width: labelWidth)
                Rectangle().fill(DS.hairline).frame(width: 1)
                ScrollView(.horizontal) {
                    timelineColumn(rows: rows, timeline: timeline)
                }
                .scrollIndicators(.hidden)
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGRect.self) { geometry in
                    CGRect(origin: geometry.contentOffset, size: geometry.containerSize)
                } action: { _, frame in
                    scroll.offsetX = frame.minX
                    scroll.viewport = frame.width
                }
                .simultaneousGesture(
                    MagnifyGesture().onEnded { value in
                        if value.magnification > 1.25 {
                            scaleRaw = scale.finer.rawValue
                        } else if value.magnification < 0.8 {
                            scaleRaw = scale.coarser.rawValue
                        }
                    }
                )
            }
            .padding(.bottom, 90)
        }
        .refreshable { await store.refresh() }
    }

    private static let groupTint = DS.control.opacity(0.55)

    private func timelineColumn(rows: [JtGanttRow], timeline: JtTimeline) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                timelineRow(row, timeline: timeline)
                    .frame(width: timeline.width, height: row.height, alignment: .topLeading)
                    .background(row.isGroup ? Self.groupTint : Color.clear)
                Rectangle().fill(DS.hairline.opacity(0.6)).frame(width: timeline.width, height: 0.5)
            }
        }
        .frame(width: timeline.width, alignment: .leading)
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(JtPalette.today.opacity(0.8))
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
                .offset(x: timeline.todayX + timeline.dayWidth / 2 - 0.75)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func labelRow(_ row: JtGanttRow) -> some View {
        switch row {
        case .group(let group):
            Button { toggle(group.row.id) } label: {
                JtGanttGroupLabel(group: group, mode: mode, title: groupTitle(group), meta: store.meta)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { groupMenu(group) }
        case .item(let item, let indent, let sameCustomer):
            JtGanttLabel(
                item: item,
                indent: indent,
                sameCustomer: sameCustomer,
                isPending: store.isPending(caseId: item.id),
                onOpen: { onOpen(item.id) }
            )
            .contentShape(Rectangle())
            .onTapGesture { onOpen(item.id) }
            .contextMenu { caseMenu(item) }
        }
    }

    @ViewBuilder
    private func timelineRow(_ row: JtGanttRow, timeline: JtTimeline) -> some View {
        switch row {
        case .group(let group):
            JtGroupBar(group: group, timeline: timeline, ownerColor: ownerColor)
                .contentShape(Rectangle())
                .onTapGesture { toggle(group.row.id) }
        case .item(let item, _, _):
            JtCaseTimelineRow(
                item: item,
                timeline: timeline,
                ownerColor: ownerColor(item.ownerId),
                onOpen: { onOpen(item.id) },
                onEtd: { etd in store.setCase(item.id, ["etd": etd]) }
            )
            .contextMenu { caseMenu(item) }
        }
    }

    private func ownerColor(_ id: String) -> Color {
        store.meta?.owner(id)?.color ?? Color(red: 0.55, green: 0.5, blue: 0.76)
    }

    private func groupTitle(_ group: JtGanttGroup) -> String {
        if mode == "owner", let owner = store.meta?.owner(group.row.key) { return owner.name }
        return group.row.label.isEmpty ? group.row.key : group.row.label
    }

    private func toggle(_ groupId: String) {
        var set = collapsed
        if set.contains(groupId) { set.remove(groupId) } else { set.insert(groupId) }
        withAnimation(.easeOut(duration: 0.2)) {
            collapsedRaw = set.sorted().joined(separator: "\n")
        }
    }

    // MARK: 長按選單

    private var projects: [String] {
        Array(Set(store.displayCases.map(\.project).filter { !$0.isEmpty })).sorted()
    }

    @ViewBuilder
    private func caseMenu(_ item: JtCase) -> some View {
        Button { onOpen(item.id) } label: {
            Label("打開案件", systemImage: "doc.text.magnifyingglass")
        }
        Menu {
            ForEach(projects, id: \.self) { name in
                Button {
                    if name != item.project { store.setCase(item.id, ["project": name]) }
                } label: {
                    if name == item.project { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Button {
                projectDraft = item.model.isEmpty ? item.title : item.model
                projectCase = item
            } label: {
                Label("新專案…", systemImage: "folder.badge.plus")
            }
            if !item.project.isEmpty {
                Button(role: .destructive) { store.setCase(item.id, ["project": ""]) } label: {
                    Label("移出「\(item.project)」", systemImage: "folder.badge.minus")
                }
            }
        } label: {
            Label(item.project.isEmpty ? "專案" : "專案：\(item.project)", systemImage: "folder")
        }
        Button { endUserCase = JtCaseReference(id: item.id) } label: {
            Label(item.endUserName.isEmpty ? "指定終端客戶…" : "終端客戶：\(item.endUserName)…", systemImage: "building.2")
        }
        Menu {
            ForEach(JtSyncStore.statuses, id: \.self) { status in
                Button {
                    if status != item.status { store.setCase(item.id, ["status": status]) }
                } label: {
                    if status == item.status { Label(status, systemImage: "checkmark") } else { Text(status) }
                }
            }
        } label: {
            Label("狀態：\(item.status)", systemImage: "flag")
        }
    }

    @ViewBuilder
    private func groupMenu(_ group: JtGanttGroup) -> some View {
        if mode == "project" {
            Button {
                renameDraft = group.row.label
                renamingGroup = group
            } label: {
                Label("重新命名…", systemImage: "pencil")
            }
            Button(role: .destructive) {
                for caseId in group.row.caseIds { store.setCase(caseId, ["project": ""]) }
            } label: {
                Label("解散專案", systemImage: "folder.badge.minus")
            }
        }
        Button { collapseAll(true) } label: { Label("全部收合", systemImage: "rectangle.compress.vertical") }
        Button { collapseAll(false) } label: { Label("全部展開", systemImage: "rectangle.expand.vertical") }
    }

    private func collapseAll(_ fold: Bool) {
        guard fold else {
            collapsedRaw = ""
            return
        }
        let groups = (store.cases?.layouts[mode] ?? []).compactMap { row -> String? in
            if case .group(let group) = row { return group.id }
            return nil
        }
        collapsedRaw = Set(groups).union(collapsed).sorted().joined(separator: "\n")
    }

    // MARK: 捲動

    private func scrollToToday(_ given: JtTimeline?, animated: Bool) {
        let timeline = given ?? JtTimeline.make(cases: store.displayCases, today: today, dayWidth: scale.dayWidth)
        let lead = scroll.viewport > 0 ? scroll.viewport * 0.3 : 120
        let target = max(timeline.todayX - lead, 0)
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.3)) { position.scrollTo(x: target) }
            } else {
                position.scrollTo(x: target)
            }
        }
    }

    /// 換比例時，畫面中間的日期留在中間。
    private func keepCenter(oldScale: JtGanttScale) {
        let center = scroll.offsetX + scroll.viewport / 2
        let day = center / oldScale.dayWidth
        let target = max(day * scale.dayWidth - scroll.viewport / 2, 0)
        DispatchQueue.main.async { position.scrollTo(x: target) }
    }

    private var emptyState: some View {
        let text = query.trimmingCharacters(in: .whitespaces)
        let title: String
        if !text.isEmpty {
            title = "找不到「\(text)」"
        } else if filter == .all {
            title = "沒有進行中的案件"
        } else {
            title = "沒有「\(filter.title)」的案件"
        }
        return EmptyStateView(title: title)
    }
}

// MARK: - 日期列

struct JtTimelineHeader: View {
    let timeline: JtTimeline
    let scale: JtGanttScale
    let scroll: JtGanttScroll

    static let height: CGFloat = 42
    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    struct Tick: Identifiable {
        let id: Int
        let x: CGFloat
        let label: String
        let isMonth: Bool
        let isWeekend: Bool
    }

    var body: some View {
        let ticks = Self.ticks(timeline: timeline, scale: scale, from: scroll.offsetX - 200, to: scroll.offsetX + max(scroll.viewport, 1400) + 200)
        let todayParts = JtDayNumber.civil(timeline.todayDay)
        let sticky = Self.stickyMonth(timeline: timeline, offset: scroll.offsetX)
        ZStack(alignment: .topLeading) {
            if let sticky {
                Text(sticky)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DS.text)
                    .fixedSize()
                    .offset(x: max(scroll.offsetX, 0) + 6, y: 5)
            }
            ForEach(ticks.filter { !$0.isMonth || $0.x >= scroll.offsetX + 2 }) { tick in
                Text(tick.label)
                    .font(.system(size: tick.isMonth ? 11 : 10, weight: tick.isMonth ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(tick.isMonth ? DS.text : (tick.isWeekend ? DS.textTertiary : DS.textSecondary))
                    .fixedSize()
                    .offset(x: tick.x, y: tick.isMonth ? 5 : 23)
            }
            Text("\(todayParts.month)/\(todayParts.day)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(JtPalette.today, in: Capsule())
                .fixedSize()
                .position(x: timeline.todayX + timeline.dayWidth / 2, y: 30)
        }
        .frame(width: timeline.width, height: Self.height, alignment: .topLeading)
        .offset(x: -scroll.offsetX)
        .allowsHitTesting(false)
    }

    /// 畫面左緣那個月的名稱（貼在左邊，捲到月中也知道是哪個月）；下個月的標籤快到左緣時讓位。
    static func stickyMonth(timeline: JtTimeline, offset: CGFloat) -> String? {
        let index = min(max(Int(offset / timeline.dayWidth), 0), max(timeline.days - 1, 0))
        let parts = JtDayNumber.civil(timeline.firstDay + index)
        // 這個月 1 日的標籤還完整看得到時不必另外標
        let monthStartX = CGFloat(index - (parts.day - 1)) * timeline.dayWidth + 2
        guard monthStartX < max(offset, 0) + 2 else { return nil }
        let nextYear = parts.month == 12 ? parts.year + 1 : parts.year
        let nextMonth = parts.month == 12 ? 1 : parts.month + 1
        let nextX = timeline.x(day: JtDayNumber.fromCivil(year: nextYear, month: nextMonth, day: 1))
        guard nextX - max(offset, 0) > 110 else { return nil }
        return "\(months[parts.month - 1]) \(parts.year)"
    }

    /// 看得到的範圍內的刻度：每月 1 日標英文月份；週＝1、8、15、22、29 日，日＝每天，月＝1、15 日。
    static func ticks(timeline: JtTimeline, scale: JtGanttScale, from: CGFloat, to: CGFloat) -> [Tick] {
        let dayWidth = timeline.dayWidth
        let first = max(Int(from / dayWidth), 0)
        let last = min(Int(to / dayWidth) + 1, timeline.days - 1)
        guard first <= last else { return [] }
        var ticks: [Tick] = []
        for index in first...last {
            let day = timeline.firstDay + index
            let parts = JtDayNumber.civil(day)
            let x = CGFloat(index) * dayWidth
            if parts.day == 1 {
                let name = months[parts.month - 1]
                ticks.append(Tick(id: -day, x: x + 2, label: parts.month == 1 ? "\(name) \(parts.year)" : name, isMonth: true, isWeekend: false))
            }
            let weekday = JtDayNumber.weekday(day)
            let isWeekend = weekday == 0 || weekday == 6
            switch scale {
            case .day:
                ticks.append(Tick(id: day, x: x + dayWidth / 2 - 6, label: String(format: "%2d", parts.day), isMonth: false, isWeekend: isWeekend))
            case .week:
                if [1, 8, 15, 22, 29].contains(parts.day) {
                    ticks.append(Tick(id: day, x: x, label: String(format: "%02d", parts.day), isMonth: false, isWeekend: false))
                }
            case .month:
                if parts.day == 1 || parts.day == 15 {
                    ticks.append(Tick(id: day, x: x, label: String(format: "%02d", parts.day), isMonth: false, isWeekend: false))
                }
            }
        }
        return ticks
    }
}

// MARK: - 左欄

/// 左欄的案件：客戶 logo（組內客戶都一樣時改成圓形終端客戶 logo）、品名與客戶，在製、注意與更多按鈕。
struct JtGanttLabel: View {
    let item: JtCase
    let indent: Bool
    let sameCustomer: Bool
    let isPending: Bool
    let onOpen: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        HStack(spacing: 8) {
            logo
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(item.isClosed ? DS.textTertiary : DS.text)
                        .strikethrough(item.tone == "cancelled")
                        .lineLimit(1)
                    if isPending {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let wip = item.wip {
                Image(systemName: "building.2")
                    .font(.system(size: 11))
                    .foregroundStyle(JtPalette.wipColor(wip.tone))
                    .accessibilityLabel("在製：\(wip.text.isEmpty ? wip.material : wip.text)")
            }
            if item.tone == "attention" {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.warning)
                    .accessibilityLabel(attentionText)
            }
            // iPhone 的左欄窄：點整列就打開案件，不放「…」
            if sizeClass != .compact {
                Button(action: onOpen) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.textTertiary)
                        .frame(width: 26, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("案件詳細")
            }
        }
        .padding(.leading, indent ? (sizeClass == .compact ? 16 : 26) : (sizeClass == .compact ? 8 : 10))
        .padding(.trailing, sizeClass == .compact ? 6 : 2)
    }

    private var subtitle: String {
        sameCustomer ? item.endUserName : item.customer
    }

    private var attentionText: String {
        guard let days = item.overdueDays, !item.overdueLabel.isEmpty else { return "注意" }
        return "注意：\(item.overdueLabel)逾期 \(days) 天未完成"
    }

    @ViewBuilder
    private var logo: some View {
        if sameCustomer {
            if item.endUserName.isEmpty {
                // 同桌面版：沒有終端客戶時留白（桌面滑過才出現虛線框）；長按選單可以指定
                Color.clear
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            } else {
                JtLogo(domain: item.endUserDomain, name: item.endUserName, circle: true, size: 24)
            }
        } else {
            JtLogo(domain: item.customerDomain, name: item.customer, size: 24, badgeDomain: item.endUserDomain, badgeName: item.endUserName)
        }
    }
}

struct JtGanttGroupLabel: View {
    let group: JtGanttGroup
    let mode: String
    let title: String
    let meta: JtMeta?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.textSecondary)
                .rotationEffect(.degrees(group.isCollapsed ? -90 : 0))
                .frame(width: 12)
            icon
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.text)
                .lineLimit(1)
            Text("\(group.members.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(DS.textTertiary)
            Spacer(minLength: 0)
            if group.attention > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("\(group.attention)")
                }
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(DS.warning)
                .accessibilityLabel("注意 \(group.attention) 件")
            }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var icon: some View {
        if mode == "customer" {
            JtLogo(domain: meta?.customerDomains[group.row.label] ?? group.members.first?.customerDomain ?? "", name: group.row.label, size: 22)
        } else if mode == "owner" {
            Circle()
                .fill(meta?.owner(group.row.key)?.color ?? DS.textSecondary)
                .frame(width: 8, height: 8)
        } else if group.sameCustomer, let first = group.members.first {
            JtLogo(domain: first.customerDomain, name: first.customer, size: 18)
        }
    }
}

// MARK: - 時間軸上的 bar

/// 一個案件的時間軸列：點一下打開案件，拖 ETD 旗改出貨日。
struct JtCaseTimelineRow: View {
    let item: JtCase
    let timeline: JtTimeline
    let ownerColor: Color
    let onOpen: () -> Void
    let onEtd: (String) -> Void

    @State private var dragDays = 0
    @State private var isDragging = false

    var body: some View {
        let geometry = JtBarGeometry(item: item, timeline: timeline, dragDays: dragDays)
        ZStack(alignment: .topLeading) {
            JtCaseBar(item: item, timeline: timeline, geometry: geometry, ownerColor: ownerColor, dragLabel: isDragging ? JtDates.monthDay(geometry.etd) : nil)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
            if !item.isClosed {
                Color.clear
                    .frame(width: 30, height: 36)
                    .contentShape(Rectangle())
                    .offset(x: geometry.flagX - 11, y: 9)
                    .highPriorityGesture(etdDrag)
                    .accessibilityLabel("拖動改 ETD")
            }
        }
        .sensoryFeedback(.selection, trigger: dragDays)
    }

    private var etdDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                isDragging = true
                dragDays = Int((value.translation.width / timeline.dayWidth).rounded())
            }
            .onEnded { _ in
                let days = dragDays
                let base = item.etd.isEmpty ? item.end : item.etd
                isDragging = false
                dragDays = 0
                guard days != 0, let day = JtDayNumber.number(base) else { return }
                onEtd(JtDayNumber.string(day + days))
            }
    }
}

struct JtCaseBar: View {
    let item: JtCase
    let timeline: JtTimeline
    let geometry: JtBarGeometry
    let ownerColor: Color
    var dragLabel: String?

    static let barTop: CGFloat = 14
    static let barHeight: CGFloat = 26
    private var midY: CGFloat { Self.barTop + Self.barHeight / 2 }

    private var isAttention: Bool { item.tone == "attention" && !item.isClosed }
    private var isOverdue: Bool { !item.isClosed && (item.daysToEtd ?? 0) < 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            delays
            bar
            markers
            flag
        }
        .frame(width: timeline.width, height: JtGanttRow.caseHeight, alignment: .topLeading)
    }

    // 延期：原訂日到延期後畫一條淡紅
    @ViewBuilder
    private var delays: some View {
        ForEach(item.markers) { marker in
            if let original = JtDayNumber.number(marker.originalDate), let moved = JtDayNumber.number(marker.date), original < moved {
                let start = timeline.x(day: original) + timeline.dayWidth / 2
                let end = timeline.x(day: moved) + timeline.dayWidth / 2
                Capsule()
                    .fill(DS.danger.opacity(0.3))
                    .frame(width: max(end - start, 2), height: 3)
                    .offset(x: start, y: Self.barTop + Self.barHeight + 3)
            }
        }
    }

    private var bar: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let progressWidth = max(geometry.progressX - geometry.x0, 0)
        return ZStack(alignment: .leading) {
            shape.fill(baseFill)
            if progressWidth > 0, !item.isClosed, item.tone != "ready" {
                Rectangle()
                    .fill(ownerColor.opacity(0.58))
                    .frame(width: progressWidth)
            }
        }
        .frame(width: geometry.width, height: Self.barHeight)
        .clipShape(shape)
        .overlay(border(shape))
        .offset(x: geometry.x0, y: Self.barTop)
    }

    private var baseFill: Color {
        if item.isClosed { return DS.textTertiary.opacity(0.24) }
        if item.tone == "ready" { return ownerColor.opacity(0.72) }
        return ownerColor.opacity(0.15)
    }

    @ViewBuilder
    private func border(_ shape: RoundedRectangle) -> some View {
        if isAttention {
            shape.strokeBorder(DS.warning, style: StrokeStyle(lineWidth: 1.3, dash: [4, 3]))
        } else if item.tone == "ready" {
            shape.strokeBorder(ownerColor, lineWidth: 1.2)
        } else if !item.isClosed {
            shape.strokeBorder(ownerColor.opacity(0.35), lineWidth: 1)
        }
    }

    private var markers: some View {
        let dots = JtMarkerDot.clusters(item.markers, timeline: timeline, isClosed: item.isClosed)
        let tint = item.isClosed ? DS.textTertiary : ownerColor
        return ForEach(dots) { dot in
            if dot.count > 1 {
                HStack(spacing: 2) {
                    Circle().fill(Color.white).frame(width: 6, height: 6)
                    Text("\(dot.count)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 4)
                .frame(height: 14)
                .background(dot.overdue ? DS.danger : tint, in: Capsule())
                .fixedSize()
                .position(x: dot.x, y: midY)
                .accessibilityLabel(dot.titles.joined(separator: "、"))
            } else {
                let ring = dot.overdue ? DS.danger : tint
                ZStack {
                    Circle().fill(dot.done ? Color.white : DS.pane)
                    Circle().strokeBorder(ring, lineWidth: dot.overdue ? 2 : 1.6)
                    if !dot.done {
                        Circle().fill(ring).frame(width: 4, height: 4)
                    }
                }
                .frame(width: 12, height: 12)
                .position(x: dot.x, y: midY)
                .accessibilityLabel(dot.titles.first ?? "")
            }
        }
    }

    private var flag: some View {
        let color: Color = isOverdue ? DS.danger : (item.isClosed ? DS.textTertiary : ownerColor)
        let urgent = !item.isClosed && (item.daysToEtd ?? 99) <= 3
        let text = dragLabel.map { "ETD \($0)" } ?? item.stat
        return HStack(spacing: 4) {
            JtFlagShape()
                .fill(color)
                .frame(width: 8, height: 10)
            Text(text)
                .font(.system(size: 11, weight: urgent || dragLabel != nil ? .bold : .medium).monospacedDigit())
                .foregroundStyle(urgent || dragLabel != nil ? DS.text : DS.textSecondary)
                .strikethrough(item.tone == "cancelled")
                .fixedSize()
        }
        .offset(x: geometry.flagX, y: midY - 7)
    }
}

/// ETD 旗：向右的三角形。
struct JtFlagShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 分組標題列的總覽條：開始到結束（有注意的案件時延到今天），每個成員的 ETD 一顆點。
struct JtGroupBar: View {
    let group: JtGanttGroup
    let timeline: JtTimeline
    let ownerColor: (String) -> Color

    var body: some View {
        let dayWidth = timeline.dayWidth
        let starts = group.members.compactMap { JtDayNumber.number($0.start) }
        let ends = group.members.compactMap { JtDayNumber.number($0.end) }
        let x0 = timeline.x(group.row.start) ?? starts.min().map { timeline.x(day: $0) } ?? 0
        var x1 = (timeline.x(group.row.end) ?? ends.max().map { timeline.x(day: $0) } ?? x0) + dayWidth
        if group.attention > 0 { x1 = max(x1, timeline.todayX + dayWidth / 2) }
        let midY = JtGanttRow.groupHeight / 2
        return ZStack(alignment: .topLeading) {
            Capsule()
                .fill(DS.textTertiary.opacity(0.32))
                .frame(width: max(x1 - x0, 4), height: 4)
                .offset(x: x0, y: midY - 2)
            ForEach(group.members) { member in
                if let x = timeline.x(member.etd.isEmpty ? member.end : member.etd) {
                    Circle()
                        .fill(dotColor(member))
                        .frame(width: 7, height: 7)
                        .position(x: x + dayWidth / 2, y: midY)
                }
            }
        }
    }

    private func dotColor(_ member: JtCase) -> Color {
        if member.isClosed { return DS.textTertiary }
        if member.tone == "attention" { return DS.warning }
        return ownerColor(member.ownerId)
    }
}

// MARK: - 圖例

struct JtGanttLegend: View {
    let ownerColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("圖例").font(.headline).foregroundStyle(DS.text)
            row("進行中") { sampleBar(fill: ownerColor.opacity(0.15), progress: 0.55, stroke: ownerColor.opacity(0.35), dashed: false) }
            row("待出貨") { sampleBar(fill: ownerColor.opacity(0.72), progress: 0, stroke: ownerColor, dashed: false) }
            row("注意") { sampleBar(fill: ownerColor.opacity(0.15), progress: 0.4, stroke: DS.warning, dashed: true) }
            row("完成／取消") { sampleBar(fill: DS.textTertiary.opacity(0.24), progress: 0, stroke: .clear, dashed: false) }
            Divider()
            row("里程碑") {
                HStack(spacing: 6) {
                    dot(done: false, color: ownerColor)
                    dot(done: true, color: ownerColor)
                    dot(done: false, color: DS.danger)
                    Text("3")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(height: 14)
                        .background(ownerColor, in: Capsule())
                }
            }
            row("延期") {
                Capsule().fill(DS.danger.opacity(0.3)).frame(width: 44, height: 3)
            }
            row("ETD") {
                HStack(spacing: 4) {
                    JtFlagShape().fill(ownerColor).frame(width: 8, height: 10)
                    Text("剩 7d").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.textSecondary)
                }
            }
            row("今天") {
                Rectangle().fill(JtPalette.today).frame(width: 1.5, height: 18)
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private func row<Sample: View>(_ title: String, @ViewBuilder sample: () -> Sample) -> some View {
        HStack(spacing: 10) {
            sample()
                .frame(width: 70, alignment: .leading)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
        }
    }

    private func sampleBar(fill: Color, progress: CGFloat, stroke: Color, dashed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return ZStack(alignment: .leading) {
            shape.fill(fill)
            if progress > 0 {
                Rectangle().fill(ownerColor.opacity(0.58)).frame(width: 64 * progress)
            }
        }
        .frame(width: 64, height: 16)
        .clipShape(shape)
        .overlay(shape.strokeBorder(stroke, style: StrokeStyle(lineWidth: 1.2, dash: dashed ? [4, 3] : [])))
    }

    private func dot(done: Bool, color: Color) -> some View {
        ZStack {
            Circle().fill(done ? Color.white : DS.pane)
            Circle().strokeBorder(color, lineWidth: 1.6)
            if !done { Circle().fill(color).frame(width: 4, height: 4) }
        }
        .frame(width: 12, height: 12)
    }
}

// MARK: - 指定終端客戶

struct JtEndUserPicker: View {
    let store: JtSyncStore
    let caseId: String

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let current = store.displayCase(caseId)?.endUserName ?? ""
        let names = (store.meta?.endUsers ?? []).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        NavigationStack {
            List {
                if !current.isEmpty {
                    Button(role: .destructive) { pick("") } label: {
                        Label("清除指定（目前：\(current)）", systemImage: "xmark.circle")
                    }
                }
                if !typed.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) {
                    Button { pick(typed) } label: {
                        Label("使用「\(typed)」", systemImage: "plus")
                    }
                }
                ForEach(names, id: \.self) { name in
                    Button { pick(name) } label: {
                        HStack(spacing: 10) {
                            JtLogo(domain: "", name: name, circle: true, size: 22)
                            Text(name).foregroundStyle(DS.text)
                            Spacer()
                            if name == current {
                                Image(systemName: "checkmark").foregroundStyle(DS.link)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "終端客戶")
            .navigationTitle("指定終端客戶")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pick(_ name: String) {
        store.setCase(caseId, ["endUser": name])
        dismiss()
    }
}

// MARK: - Logo

/// 客戶（圓角方形）或終端客戶（圓形）的 logo：抓不到時顯示縮寫（低飽和的色塊，同桌面版）。
/// 下單客戶的 logo 右下角可以帶一個圓形的終端客戶角標。
struct JtLogo: View {
    let domain: String
    let name: String
    var circle = false
    var size: CGFloat = 24
    var badgeDomain = ""
    var badgeName = ""

    var body: some View {
        let radius: CGFloat = circle ? size / 2 : size * 0.27
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(DS.hairline, lineWidth: 0.5))
            .overlay(alignment: .bottomTrailing) { badge }
    }

    @ViewBuilder
    private var content: some View {
        if let url = Self.url(domain) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                        .padding(circle ? 3 : 2)
                        .frame(width: size, height: size)
                        .background(Color.white)
                } else {
                    initials
                }
            }
        } else {
            initials
        }
    }

    private var initials: some View {
        Text(Self.initials(name))
            .font(.system(size: size <= 18 ? 8 : (size <= 24 ? 9 : 11), weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.hue(name))
    }

    @ViewBuilder
    private var badge: some View {
        if let url = Self.url(badgeDomain) {
            let side = size * 0.58
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().padding(1)
                } else {
                    Text(Self.initials(badgeName))
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: side, height: side)
                        .background(Self.hue(badgeName))
                }
            }
            .frame(width: side, height: side)
            .background(Color.white)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(DS.hairline, lineWidth: 0.5))
            .offset(x: 4, y: 4)
        }
    }

    static func url(_ domain: String) -> URL? {
        let trimmed = domain.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(trimmed).ico")
    }

    /// 「AMD-Xilinx」→「AX」、「Amkor」→「AM」（括號內的字不算）。
    static func initials(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let parts = clean.split { $0 == " " || $0 == "-" || $0 == "_" || $0 == "/" }
        if parts.count >= 2, let first = parts[0].first, let second = parts[1].first {
            return String([first, second]).uppercased()
        }
        return String(clean.prefix(2)).uppercased()
    }

    /// 名稱雜湊成色相（同桌面版：hsl(h 22% 56%)）。
    static func hueDegrees(_ name: String) -> Int {
        var hash: Int32 = 0
        for unit in name.utf16 { hash = hash &* 31 &+ Int32(unit) }
        return abs(Int(hash)) % 360
    }

    static func hue(_ name: String) -> Color {
        let lightness = 0.56
        let saturation = 0.22
        let value = lightness + saturation * min(lightness, 1 - lightness)
        let hsbSaturation = value == 0 ? 0 : 2 * (1 - lightness / value)
        return Color(hue: Double(hueDegrees(name)) / 360, saturation: hsbSaturation, brightness: value)
    }
}
