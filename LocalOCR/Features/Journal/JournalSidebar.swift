import SwiftUI

/// 開著的日誌筆記本：右側欄的「日誌」面板從這裡讀內容，並請筆記本翻頁、新增或刪除頁面、整理。
@MainActor
@Observable
final class JournalSession {
    static let shared = JournalSession()

    struct Actions {
        var showPage: (Int) -> Void
        var addPage: () -> Void
        var deletePage: (Int) -> Void
        /// 立即整理這本（`true`：每一頁重新辨識、每一天重新整理）。
        var organize: (Bool) -> Void
        var openModel: (String) -> Void
    }

    private(set) var path: String?
    private(set) var notebook: JournalNotebook?
    private(set) var isOrganizing = false
    /// 畫面上的頁（兩頁並排時是左邊那頁）。
    private(set) var visiblePage = 0
    @ObservationIgnored private(set) var actions: Actions?

    func attach(path: String, actions: Actions) {
        self.path = path
        self.actions = actions
    }

    func update(path: String, notebook: JournalNotebook?, isOrganizing: Bool, visiblePage: Int) {
        guard self.path == path else { return }
        if self.notebook != notebook { self.notebook = notebook }
        if self.isOrganizing != isOrganizing { self.isOrganizing = isOrganizing }
        if self.visiblePage != visiblePage { self.visiblePage = visiblePage }
    }

    func detach(path: String) {
        guard self.path == path else { return }
        self.path = nil
        notebook = nil
        actions = nil
    }
}

/// 刪除頁面的確認文字（筆記本與右側欄共用）。
enum JournalDeletePrompt {
    static func title(_ index: Int?) -> String {
        guard let index else { return "" }
        return "刪除第 \(index + 1) 頁？"
    }

    static func message(pageCount: Int) -> String {
        pageCount > 1 ? "這一頁的筆跡會一起刪除，無法復原。" : "這是唯一的一頁：會清成今天的空白頁。"
    }
}

/// 右側欄的「日誌」：月曆（標出國定假日、補班日與寫了日誌的日子），點日期翻到那天的頁面，下面列出那天的頁面、
/// 摘要、重點、待跟進與提到的機種。整理是自動的（停筆後辨識、閒置或離開時整理），狀態列在最下面；
/// 要強制整理或全部重新整理在「⋯」選單。
struct JournalSidebarPanel: View {
    let path: String

    @Environment(Workspace.self) private var workspace
    @State private var session = JournalSession.shared
    @State private var organizer = JournalOrganizer.shared
    @AppStorage(JournalViewMode.storageKey) private var viewModeRaw = JournalViewMode.scroll.rawValue
    @State private var selectedDay: String?
    @State private var shownYear = 0
    @State private var shownMonth = 0
    @State private var holidayRevision = 0
    @State private var pendingDelete: Int?
    @State private var confirmsRebuild = false

    var body: some View {
        if session.path == path, let notebook = session.notebook, let actions = session.actions {
            content(notebook, actions: actions)
        } else {
            Text("打開日誌筆記本後，這裡會有月曆與每天的整理。")
                .font(.footnote)
                .foregroundStyle(DS.textTertiary)
                .padding(.top, 8)
        }
    }

    private func content(_ notebook: JournalNotebook, actions: JournalSession.Actions) -> some View {
        let pagesByDay = Dictionary(notebook.pagesByDay.map { ($0.date, $0.pages) }) { first, _ in first }
        let day = selectedDay ?? visibleDay(notebook) ?? JournalLayout.day()
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                monthHeader(actions: actions)
                calendarGrid(notebook, pagesByDay: pagesByDay, selected: day, actions: actions)
                monthHolidays
                Rectangle().fill(DS.hairline).frame(height: 1)
                dayDetail(day, notebook: notebook, pages: pagesByDay[day] ?? [], actions: actions)
                statusLine
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .onAppear { follow(notebook) }
        .onChange(of: session.visiblePage) { _, _ in
            if let notebook = session.notebook { follow(notebook) }
        }
        .task(id: shownYear) {
            guard shownYear > 0 else { return }
            await TaiwanHolidays.fetchIfNeeded(year: shownYear)
            holidayRevision += 1
        }
        .confirmationDialog(
            JournalDeletePrompt.title(pendingDelete),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除", role: .destructive) {
                if let index = pendingDelete { actions.deletePage(index) }
                pendingDelete = nil
            }
        } message: {
            Text(JournalDeletePrompt.message(pageCount: notebook.pages.count))
        }
        .confirmationDialog("全部重新整理？", isPresented: $confirmsRebuild, titleVisibility: .visible) {
            Button("全部重新整理") {
                actions.organize(true)
                organizer.sweep(force: true, rebuild: true)
            }
        } message: {
            Text("每一本日誌的每一頁重新辨識、每一天重新整理，再重新統整。頁面多時要一段時間，會在背景一件一件做。")
        }
    }

    // MARK: 月曆

    private func visibleDay(_ notebook: JournalNotebook) -> String? {
        notebook.pages.indices.contains(session.visiblePage) ? notebook.pages[session.visiblePage].date : nil
    }

    /// 畫布翻到哪一天，月曆就選那一天。
    private func follow(_ notebook: JournalNotebook) {
        let day = visibleDay(notebook) ?? JournalLayout.day()
        selectedDay = day
        let (year, month) = JournalCalendar.yearMonth(of: day)
        shownYear = year
        shownMonth = month
    }

    private func monthHeader(actions: JournalSession.Actions) -> some View {
        HStack(spacing: 4) {
            Text("\(String(shownYear)) 年 \(shownMonth) 月")
                .font(.headline)
                .foregroundStyle(DS.text)
            Spacer(minLength: 4)
            Button { showMonth(offset: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(CircleIconButtonStyle(size: 30))
                .accessibilityLabel("上個月")
            Button("今天") { goToday(actions: actions) }
                .font(.footnote.weight(.medium))
                .foregroundStyle(DS.text)
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
            Button { showMonth(offset: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(CircleIconButtonStyle(size: 30))
                .accessibilityLabel("下個月")
            moreMenu(actions: actions)
        }
    }

    private func moreMenu(actions: JournalSession.Actions) -> some View {
        Menu {
            Button { actions.addPage() } label: { Label("新增一頁", systemImage: "doc.badge.plus") }
            Divider()
            Button { actions.organize(false) } label: { Label("立即整理這本", systemImage: "wand.and.stars") }
            Button { organizer.sweep(force: true) } label: { Label("整理全部日誌", systemImage: "books.vertical") }
            Button(role: .destructive) { confirmsRebuild = true } label: { Label("全部重新整理…", systemImage: "arrow.clockwise") }
            if let overview = JournalOrganizer.overviewPath() {
                Button { workspace.openNote(overview) } label: { Label("打開「日誌統整」", systemImage: "doc.text.magnifyingglass") }
            }
            Divider()
            Picker("顯示方式", selection: $viewModeRaw) {
                ForEach(JournalViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode.rawValue)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.text)
                .frame(width: 30, height: 30)
                .background(DS.control, in: Circle())
        }
        .accessibilityLabel("更多")
    }

    private func showMonth(offset: Int) {
        let (year, month) = JournalCalendar.shifted(year: shownYear, month: shownMonth, by: offset)
        shownYear = year
        shownMonth = month
    }

    private func goToday(actions: JournalSession.Actions) {
        let today = JournalLayout.day()
        select(today, pages: session.notebook.map { notebook in notebook.pages.indices.filter { notebook.pages[$0].date == today } } ?? [], actions: actions)
        let (year, month) = JournalCalendar.yearMonth(of: today)
        shownYear = year
        shownMonth = month
    }

    /// 選一天：有頁面就翻到那天的第一頁。
    private func select(_ day: String, pages: [Int], actions: JournalSession.Actions) {
        selectedDay = day
        if let first = pages.first { actions.showPage(first) }
    }

    private func calendarGrid(_ notebook: JournalNotebook, pagesByDay: [String: [Int]], selected: String, actions: JournalSession.Actions) -> some View {
        let cells = JournalCalendar.cells(year: shownYear, month: shownMonth)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        let today = JournalLayout.day()
        _ = holidayRevision
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(Array(JournalCalendar.weekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(index == 0 || index == 6 ? DS.danger.opacity(0.8) : DS.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 2)
            }
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                if let cell {
                    dayCell(cell, pages: pagesByDay[cell] ?? [], summarized: notebook.days[cell] != nil, isSelected: cell == selected, isToday: cell == today, actions: actions)
                } else {
                    Color.clear.frame(height: 40)
                }
            }
        }
    }

    private func dayCell(_ day: String, pages: [Int], summarized: Bool, isSelected: Bool, isToday: Bool, actions: JournalSession.Actions) -> some View {
        let number = Int(day.suffix(2)) ?? 0
        let isOff = JournalCalendar.isDayOff(day)
        let isMakeup = TaiwanHolidays.isMakeupWorkday(day)
        let numberColor: Color = isSelected ? DS.onPrimary : (isOff ? DS.danger : DS.text)
        let dotColor: Color = summarized ? DS.link : DS.textSecondary
        return VStack(spacing: 2) {
            Text("\(number)")
                .font(.system(size: 14, weight: isSelected || isToday ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(numberColor)
                .frame(width: 30, height: 30)
                .background {
                    if isSelected {
                        Circle().fill(DS.primary)
                    } else if isToday {
                        Circle().strokeBorder(DS.text, lineWidth: 1)
                    }
                }
            Circle()
                .fill(pages.isEmpty ? Color.clear : dotColor)
                .frame(width: 5, height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .overlay(alignment: .topTrailing) {
            if isMakeup {
                Text("班")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { select(day, pages: pages, actions: actions) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(day, pages: pages.count))
        .accessibilityAddTraits(.isButton)
    }

    private func accessibilityLabel(_ day: String, pages: Int) -> String {
        var parts = [JournalLayout.heading(for: day)]
        if let holiday = TaiwanHolidays.holiday(on: day) { parts.append(holiday) }
        if pages > 0 { parts.append("\(pages) 頁日誌") }
        return parts.joined(separator: "，")
    }

    /// 這個月的國定假日（含補假）與補班日。
    @ViewBuilder
    private var monthHolidays: some View {
        let entries = JournalCalendar.cells(year: shownYear, month: shownMonth).compactMap { $0 }.compactMap { day -> String? in
            let date = String(day.suffix(5)).replacingOccurrences(of: "-", with: "/")
            if let name = TaiwanHolidays.holiday(on: day) { return date + " " + name }
            if TaiwanHolidays.isMakeupWorkday(day) { return date + " 補班" }
            return nil
        }
        if !entries.isEmpty {
            Text(entries.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(DS.danger.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 那一天

    @ViewBuilder
    private func dayDetail(_ day: String, notebook: JournalNotebook, pages: [Int], actions: JournalSession.Actions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(JournalLayout.heading(for: day))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.text)
                if let holiday = TaiwanHolidays.holiday(on: day) {
                    Text(holiday)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DS.danger)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(DS.danger.opacity(0.12), in: Capsule())
                }
            }
            if pages.isEmpty {
                Text(day == JournalLayout.day() ? "今天還沒寫。" : "這天沒有寫日誌。")
                    .font(.footnote)
                    .foregroundStyle(DS.textTertiary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(pages, id: \.self) { index in
                        Button("第 \(index + 1) 頁") { actions.showPage(index) }
                            .buttonStyle(PillButtonStyle(kind: index == session.visiblePage ? .primary : .secondary, compact: true))
                            .contextMenu {
                                Button(role: .destructive) { pendingDelete = index } label: { Label("刪除這一頁", systemImage: "trash") }
                            }
                    }
                }
                let pageItems = pages.filter { notebook.pages.indices.contains($0) }.map { notebook.pages[$0] }
                let models = JournalMarkdown.linkedModels(in: pageItems)
                if !models.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(models, id: \.path) { model in
                            Button { actions.openModel(model.path) } label: {
                                Label(model.code, systemImage: "link")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(DS.text)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(DS.Pastel.sky.color, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let insights = notebook.days[day], !insights.summary.isEmpty {
                    insightsView(insights)
                } else {
                    Text("還沒整理：停筆一陣子後會自動辨識與整理。")
                        .font(.footnote)
                        .foregroundStyle(DS.textTertiary)
                }
            }
        }
    }

    private func insightsView(_ insights: JournalDay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(insights.summary)
                .font(.footnote)
                .foregroundStyle(DS.text)
                .fixedSize(horizontal: false, vertical: true)
            if !insights.keyPoints.isEmpty {
                Text("重點").font(.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
                ForEach(insights.keyPoints, id: \.self) { point in
                    Text("• " + point).font(.caption).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !insights.actionItems.isEmpty {
                Text("待跟進").font(.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
                ForEach(insights.actionItems, id: \.self) { item in
                    Text("☐ " + item).font(.caption).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 自動整理的狀態

    private var statusLine: some View {
        HStack(spacing: 6) {
            if session.isOrganizing || organizer.isWorking {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "checkmark.circle").font(.caption2)
            }
            Text(statusText)
                .font(.caption2)
                .lineLimit(2)
        }
        .foregroundStyle(DS.textTertiary)
        .padding(.top, 4)
    }

    private var statusText: String {
        if session.isOrganizing { return "正在整理這本…" }
        if let current = organizer.current { return current + "…" }
        guard let finished = organizer.lastFinished else { return "自動整理：停筆後辨識，閒置或離開時整理" }
        let time = finished.formatted(date: .omitted, time: .shortened)
        let engine = organizer.lastEngine.map { "（" + $0.title + "）" } ?? ""
        return "已自動整理 · " + time + engine
    }
}
