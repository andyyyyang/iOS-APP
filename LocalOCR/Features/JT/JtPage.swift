import SwiftUI

/// JT 業務追蹤：電腦上 JT Sales Tracker 的甘特、今天、在製、機台、出貨與通知（資料與規則都由 JT 算好）。
enum JtSection: String, CaseIterable, Identifiable {
    case gantt
    case today
    case wip
    case machines
    case po
    case alerts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gantt: return "甘特"
        case .today: return "今天"
        case .wip: return "在製"
        case .machines: return "機台"
        case .po: return "出貨"
        case .alerts: return "通知"
        }
    }

    var systemImage: String {
        switch self {
        case .gantt: return "chart.bar.xaxis"
        case .today: return "calendar"
        case .wip: return "gearshape.2"
        case .machines: return "square.grid.3x3"
        case .po: return "shippingbox"
        case .alerts: return "bell"
        }
    }
}

struct JtPage: View {
    @State private var store = JtSyncStore.shared
    @AppStorage("jt.section") private var sectionRaw = JtSection.gantt.rawValue
    @State private var query = ""
    @State private var openCase: JtCaseReference?

    private var section: JtSection { JtSection(rawValue: sectionRaw) ?? .gantt }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            PageToolbar("JT 業務追蹤", subtitle: subtitle, query: $query, searchPlaceholder: "客戶、品名、料號、專案") {
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(CircleIconButtonStyle())
                .accessibilityLabel("重新讀取")
            } chips: {
                ForEach(JtSection.allCases) { item in
                    Button { sectionRaw = item.rawValue } label: {
                        FilterChip(title: item.title, isActive: item == section, systemImage: item.systemImage)
                    }
                    .buttonStyle(.plain)
                }
            }
            if store.isComputerOffline {
                banner("電腦的 JT 離線中：這裡顯示的是最後一次的資料，編輯會在電腦開機後依編輯時間套用", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
            } else if store.unsentCount > 0 {
                banner("\(store.unsentCount) 個編輯還沒送出（連上網路後自動送出）", systemImage: "icloud.slash")
            }
            content
        }
        .background(DS.pane)
        .task {
            await store.refresh()
            // 推送沒連上時的備援：每 30 秒看一次清單（版本沒變不會重抓）
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await store.refresh()
            }
        }
        .sheet(item: $openCase) { reference in
            JtCaseDetail(caseId: reference.id)
        }
        .toast($store.notice)
    }

    private var subtitle: String {
        if let manifest = store.manifest, manifest.heartbeatAt > 0 {
            let date = Date(timeIntervalSince1970: manifest.heartbeatAt / 1000)
            return "電腦 \(manifest.device.isEmpty ? "JT" : manifest.device) · 更新於 \(date.formatted(date: .omitted, time: .shortened))"
        }
        return store.isLoading ? "讀取中…" : ""
    }

    private func banner(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(text).font(.footnote)
            Spacer(minLength: 0)
        }
        .foregroundStyle(DS.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(DS.Pastel.butter.color)
    }

    @ViewBuilder
    private var content: some View {
        if !store.isConfigured {
            EmptyStateView(title: "還沒有與同步伺服器配對", message: "先在「設定」與 Obsidian 配對，JT 的資料會經由同一個伺服器同步過來。")
        } else if !store.hasData {
            if store.notPaired {
                EmptyStateView(title: "電腦的 JT 還沒連上", message: "在電腦的 JT Sales Tracker 打開「設定 → iPhone／iPad」，輸入 Obsidian「LocalOCR：配對 iPhone／iPad」產生的配對碼，資料就會自動出現在這裡。")
            } else if let error = store.lastError {
                EmptyStateView(title: "讀不到 JT 的資料", message: error)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            }
        } else {
            switch section {
            case .gantt:
                JtGanttView(store: store, query: query) { openCase = JtCaseReference(id: $0) }
            case .today:
                JtDayView(store: store) { openCase = JtCaseReference(id: $0) }
            case .wip:
                JtWipView(store: store, query: query)
            case .machines:
                JtMachinesView(store: store, query: query)
            case .po:
                JtPoView(store: store, query: query)
            case .alerts:
                JtAlertsView(store: store, query: query)
            }
        }
    }
}

struct JtCaseReference: Identifiable {
    let id: String
}

// MARK: - 甘特

/// 甘特的一列（分組標題或案件）。
enum JtGanttRow: Identifiable {
    case group(JtGroupRow, collapsed: Bool)
    case item(JtCase)

    var id: String {
        switch self {
        case .group(let group, _): return "group:" + group.id
        case .item(let item): return "case:" + item.id
        }
    }

    var height: CGFloat {
        switch self {
        case .group: return 36
        case .item: return 52
        }
    }
}

/// 時間軸：哪一天畫在哪裡。
struct JtTimeline {
    let first: Date
    let days: Int
    let dayWidth: CGFloat
    let today: String

    var width: CGFloat { CGFloat(days) * dayWidth }

    /// 這天左緣的位置（超出範圍時夾在兩端）。
    func x(_ text: String) -> CGFloat? {
        guard let date = JtDates.date(text) else { return nil }
        let offset = CGFloat(JtDates.days(from: first, to: date)) * dayWidth
        return min(max(offset, 0), width)
    }

    /// 範圍：案件的開始到結束，前後最多今天 −45 天與 +150 天，至少涵蓋今天 −7 到 +30 天。
    static func make(cases: [JtCase], today: String, dayWidth: CGFloat) -> JtTimeline {
        let now = JtDates.date(today) ?? Calendar(identifier: .gregorian).startOfDay(for: Date())
        let calendar = Calendar(identifier: .gregorian)
        let earliest = calendar.date(byAdding: .day, value: -45, to: now) ?? now
        let latest = calendar.date(byAdding: .day, value: 150, to: now) ?? now
        var lower = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        var upper = calendar.date(byAdding: .day, value: 30, to: now) ?? now
        for item in cases {
            if let start = JtDates.date(item.start), start < lower { lower = max(start, earliest) }
            if let end = JtDates.date(item.end), end > upper { upper = min(end, latest) }
        }
        let days = JtDates.days(from: lower, to: upper) + 8
        return JtTimeline(first: lower, days: days, dayWidth: dayWidth, today: JtDates.string(now))
    }
}

struct JtGanttView: View {
    let store: JtSyncStore
    let query: String
    let onOpen: (String) -> Void

    @AppStorage("jt.groupMode") private var mode = "etd-asc"
    @AppStorage("jt.collapsedGroups") private var collapsedRaw = ""
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }
    private var labelWidth: CGFloat { sizeClass == .compact ? 150 : 270 }
    private var dayWidth: CGFloat { sizeClass == .compact ? 5 : 8 }
    private static let headerHeight: CGFloat = 26

    var body: some View {
        let cases = store.displayCases
        let byId = Dictionary(cases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = visibleRows(byId)
        let today = store.meta?.today ?? store.calendar?.today ?? JtDates.string(Date())
        let timeline = JtTimeline.make(cases: cases, today: today, dayWidth: dayWidth)
        let modes: [(value: String, title: String)] = (store.meta?.groupModes ?? JtMeta.defaultModes).map { (value: $0.mode, title: $0.label) }
        VStack(spacing: 0) {
            HStack {
                SegmentedPills(options: modes, selection: $mode)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, sizeClass == .compact ? 16 : 24)
            .padding(.bottom, 8)
            Rectangle().fill(DS.hairline).frame(height: 1)
            if rows.isEmpty {
                EmptyStateView(title: query.isEmpty ? "沒有案件" : "找不到「\(query)」")
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        labels(rows)
                        Rectangle().fill(DS.hairline).frame(width: 1)
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal) {
                                timelineColumn(rows, byId: byId, timeline: timeline)
                            }
                            .scrollIndicators(.hidden)
                            .onAppear { proxy.scrollTo("jt-today", anchor: .leading) }
                        }
                    }
                    .padding(.bottom, 90)
                }
            }
        }
    }

    private func visibleRows(_ byId: [String: JtCase]) -> [JtGanttRow] {
        let fallback: [JtLayoutRow] = byId.values.sorted { (a: JtCase, b: JtCase) -> Bool in a.end < b.end }.map { JtLayoutRow.item($0.id) }
        let layouts = store.cases?.layouts ?? [:]
        let layout: [JtLayoutRow] = layouts[mode] ?? layouts["etd-asc"] ?? fallback
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        var rows: [JtGanttRow] = []
        var hidden: Set<String> = []
        for row in layout {
            switch row {
            case .group(let group):
                let members = group.caseIds.compactMap { byId[$0] }.filter { $0.matches(query) }
                if searching && members.isEmpty {
                    hidden.formUnion(group.caseIds)
                    continue
                }
                let isCollapsed = !searching && collapsed.contains(group.id)
                if isCollapsed { hidden.formUnion(group.caseIds) }
                rows.append(.group(group, collapsed: isCollapsed))
            case .item(let caseId):
                guard !hidden.contains(caseId), let item = byId[caseId], item.matches(query) else { continue }
                rows.append(.item(item))
            }
        }
        return rows
    }

    private func toggle(_ groupId: String) {
        var set = collapsed
        if set.contains(groupId) { set.remove(groupId) } else { set.insert(groupId) }
        collapsedRaw = set.sorted().joined(separator: "\n")
    }

    // MARK: 左欄

    private func labels(_ rows: [JtGanttRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Self.headerHeight)
            ForEach(rows) { row in
                labelRow(row)
                    .frame(height: row.height)
                Rectangle().fill(DS.hairline.opacity(0.6)).frame(height: 0.5)
            }
        }
        .frame(width: labelWidth)
    }

    @ViewBuilder
    private func labelRow(_ row: JtGanttRow) -> some View {
        switch row {
        case .group(let group, let isCollapsed):
            Button { toggle(group.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.textSecondary)
                        .frame(width: 14)
                    Text(groupTitle(group))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    Text("\(group.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(DS.textTertiary)
                    if group.attention > 0 {
                        Text("⚠\(group.attention)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(DS.warning)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .background(DS.control.opacity(0.6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .item(let item):
            Button { onOpen(item.id) } label: {
                JtCaseLabel(item: item, owner: store.meta?.owner(item.ownerId), showsEndUserOnly: mode == "customer", isPending: store.isPending(caseId: item.id))
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func groupTitle(_ group: JtGroupRow) -> String {
        if mode == "owner", let owner = store.meta?.owner(group.key) { return owner.name }
        return group.label.isEmpty ? group.key : group.label
    }

    // MARK: 時間軸

    private func timelineColumn(_ rows: [JtGanttRow], byId: [String: JtCase], timeline: JtTimeline) -> some View {
        let totalHeight = rows.reduce(Self.headerHeight) { $0 + $1.height + 0.5 }
        let todayX = timeline.x(timeline.today) ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            JtTimelineHeader(timeline: timeline)
                .frame(height: Self.headerHeight)
            ForEach(rows) { row in
                timelineRow(row, byId: byId, timeline: timeline)
                    .frame(width: timeline.width, height: row.height, alignment: .topLeading)
                Rectangle().fill(DS.hairline.opacity(0.6)).frame(width: timeline.width, height: 0.5)
            }
        }
        .frame(width: timeline.width, alignment: .leading)
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(DS.danger.opacity(0.55))
                .frame(width: 1.5, height: totalHeight)
                .offset(x: todayX + timeline.dayWidth / 2)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            // 捲到今天用的定位點
            HStack(spacing: 0) {
                Color.clear.frame(width: max(todayX - 60, 0), height: 1)
                Color.clear.frame(width: 1, height: 1).id("jt-today")
                Spacer(minLength: 0)
            }
            .frame(width: timeline.width)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func timelineRow(_ row: JtGanttRow, byId: [String: JtCase], timeline: JtTimeline) -> some View {
        switch row {
        case .group(let group, _):
            JtGroupBar(group: group, members: group.caseIds.compactMap { byId[$0] }, timeline: timeline)
                .background(DS.control.opacity(0.35))
        case .item(let item):
            Button { onOpen(item.id) } label: {
                JtCaseBar(item: item, timeline: timeline, ownerColor: store.meta?.owner(item.ownerId)?.color ?? DS.link)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// 時間軸上方：每月 1 日標月份，每週一畫一條細線。
struct JtTimelineHeader: View {
    let timeline: JtTimeline

    var body: some View {
        let calendar = Calendar(identifier: .gregorian)
        let marks: [(x: CGFloat, label: String, isMonth: Bool)] = (0..<timeline.days).compactMap { (offset: Int) -> (x: CGFloat, label: String, isMonth: Bool)? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: timeline.first) else { return nil }
            let parts = calendar.dateComponents([.month, .day, .weekday], from: date)
            let x = CGFloat(offset) * timeline.dayWidth
            if parts.day == 1 { return (x, "\(parts.month ?? 0)月", true) }
            if parts.weekday == 2 { return (x, "\(parts.day ?? 0)", false) }
            return nil
        }
        ZStack(alignment: .topLeading) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                Text(mark.label)
                    .font(.system(size: 9, weight: mark.isMonth ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(mark.isMonth ? DS.text : DS.textTertiary)
                    .fixedSize()
                    .offset(x: mark.x + 2, y: 6)
            }
        }
        .frame(width: timeline.width, alignment: .topLeading)
    }
}

/// 左欄的案件：客戶 logo（客戶分組時改成圓形終端客戶 logo）、名稱與客戶。
struct JtCaseLabel: View {
    let item: JtCase
    let owner: JtOwner?
    let showsEndUserOnly: Bool
    let isPending: Bool

    var body: some View {
        HStack(spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(item.isClosed ? DS.textTertiary : DS.text)
                        .strikethrough(item.tone == "cancelled")
                        .lineLimit(1)
                    if isPending {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if !showsEndUserOnly { parts.append(item.customer) }
        if !item.endUserName.isEmpty { parts.append(item.endUserName) }
        if let owner { parts.append(owner.name) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var avatar: some View {
        if showsEndUserOnly {
            JtLogo(domain: item.endUserDomain, name: item.endUserName, circle: true)
        } else {
            JtLogo(domain: item.customerDomain, name: item.customer)
                .overlay(alignment: .bottomTrailing) {
                    if !item.endUserName.isEmpty {
                        JtLogo(domain: item.endUserDomain, name: item.endUserName, circle: true, size: 14)
                            .overlay(Circle().strokeBorder(DS.pane, lineWidth: 1.5))
                            .offset(x: 4, y: 4)
                    }
                }
        }
    }
}

/// 客戶（圓角方形）或終端客戶（圓形）的 logo，抓不到時顯示第一個字。
struct JtLogo: View {
    let domain: String
    let name: String
    var circle = false
    var size: CGFloat = 28

    var body: some View {
        let radius: CGFloat = circle ? size / 2 : size * 0.25
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(DS.control)
            if let url = logoURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(size * 0.14)
                    } else {
                        initial
                    }
                }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var logoURL: URL? {
        domain.isEmpty ? nil : URL(string: "https://icons.duckduckgo.com/ip3/\(domain).ico")
    }

    private var initial: some View {
        Text(String(name.prefix(1)))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(DS.textSecondary)
    }
}

/// 案件的 bar：開始到結束（需要注意且未完成時延伸到今天、虛線框），進度填到 progressDate，
/// 里程碑標記（延期的從原訂日畫淡紅條），結束處的 ETD 旗與尾端文字。
struct JtCaseBar: View {
    let item: JtCase
    let timeline: JtTimeline
    let ownerColor: Color

    private var isAttention: Bool { item.tone == "attention" && !item.isClosed }

    private var tint: Color {
        switch item.tone {
        case "attention": return DS.warning
        case "done", "cancelled": return DS.textTertiary
        default: return ownerColor
        }
    }

    var body: some View {
        let x0 = timeline.x(item.start) ?? 0
        var x1 = (timeline.x(item.end) ?? x0) + timeline.dayWidth
        if isAttention, let todayX = timeline.x(timeline.today) { x1 = max(x1, todayX + timeline.dayWidth) }
        let progressEnd: CGFloat = (timeline.x(item.progressDate) ?? x0) + timeline.dayWidth
        let progressX: CGFloat = item.tone == "ready" ? x1 : min(max(progressEnd, x0), x1)
        let width: CGFloat = max(x1 - x0, 4)
        return ZStack(alignment: .topLeading) {
            barBackground(width: width)
                .offset(x: x0, y: 14)
            if progressX > x0 {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tint.opacity(item.isClosed ? 0.35 : 0.75))
                    .frame(width: progressX - x0, height: 16)
                    .offset(x: x0, y: 14)
            }
            ForEach(item.markers) { marker in
                markerView(marker)
            }
            HStack(spacing: 3) {
                Image(systemName: "flag.fill").font(.system(size: 8))
                Text(item.stat)
                    .font(.system(size: 10, weight: .semibold))
                    .strikethrough(item.tone == "cancelled")
            }
            .foregroundStyle(isAttention ? DS.warning : DS.textSecondary)
            .fixedSize()
            .offset(x: x1 + 4, y: 15)
        }
    }

    @ViewBuilder
    private func barBackground(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        if isAttention {
            shape.fill(DS.warning.opacity(0.14))
                .overlay(shape.strokeBorder(DS.warning, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                .frame(width: width, height: 16)
        } else if item.tone == "ready" {
            shape.fill(tint.opacity(0.2))
                .overlay(shape.strokeBorder(tint, lineWidth: 1.5))
                .frame(width: width, height: 16)
        } else {
            shape.fill(tint.opacity(item.isClosed ? 0.18 : 0.28))
                .frame(width: width, height: 16)
        }
    }

    @ViewBuilder
    private func markerView(_ marker: JtMarker) -> some View {
        if let x = timeline.x(marker.date) {
            let center = x + timeline.dayWidth / 2
            if let original = timeline.x(marker.originalDate), !marker.originalDate.isEmpty, original < x {
                Rectangle()
                    .fill(DS.danger.opacity(0.25))
                    .frame(width: x - original, height: 4)
                    .offset(x: original + timeline.dayWidth / 2, y: 34)
            }
            Rectangle()
                .fill(marker.done ? tint : DS.pane)
                .overlay(Rectangle().strokeBorder(tint, lineWidth: 1.2))
                .frame(width: 8, height: 8)
                .rotationEffect(.degrees(45))
                .offset(x: center - 4, y: 18)
        }
    }
}

/// 分組標題列的總覽條：開始到結束，每個成員的 ETD 一顆點。
struct JtGroupBar: View {
    let group: JtGroupRow
    let members: [JtCase]
    let timeline: JtTimeline

    var body: some View {
        let x0 = timeline.x(group.start) ?? 0
        let x1 = (timeline.x(group.end) ?? x0) + timeline.dayWidth
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(DS.textTertiary.opacity(0.3))
                .frame(width: max(x1 - x0, 4), height: 6)
                .offset(x: x0, y: 15)
            ForEach(members) { item in
                if let x = timeline.x(item.etd.isEmpty ? item.end : item.etd) {
                    Circle()
                        .fill(item.tone == "attention" ? DS.warning : DS.textSecondary)
                        .frame(width: 6, height: 6)
                        .offset(x: x + timeline.dayWidth / 2 - 3, y: 15)
                }
            }
        }
    }
}
