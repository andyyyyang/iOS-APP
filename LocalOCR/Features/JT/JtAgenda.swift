import SwiftUI

// JT 的「這天的清單」：JT 業務追蹤的「今天」分頁與右側欄的待辦共用。
// 照 JT 排好的每日清單（待辦、里程碑、出貨、PO、會議；沒做完的待辦延續到今天、完成的沉到該段最下面）。

struct JtAgendaSection: Identifiable {
    let kind: String
    var items: [JtCalItem]
    let carried: Set<String>

    var id: String { kind }
    var title: String { JtPalette.calendarKindTitles[kind] ?? kind }
}

extension JtSyncStore {
    /// 分段順序（同桌面版的 buildDayGroups）。
    static let agendaKinds = ["todo", "milestone", "etd", "po", "meeting"]

    func agenda(on date: String) -> [JtAgendaSection] {
        Self.agenda(on: date, items: displayItems(), days: calendar?.days ?? [:], pending: pendingTodos(on: date))
    }

    /// 這天的清單：JT 排好的 `days[date].groups`（含延續的待辦）；範圍外的日子用落在這天的項目依種類分段。
    /// 還沒送到 JT 的新待辦接在待辦段；完成的沉到每段最下面（剛打勾的也馬上沉下去）。
    static func agenda(on date: String, items: [String: JtCalItem], days: [String: JtDay], pending: [JtCalItem]) -> [JtAgendaSection] {
        var result: [JtAgendaSection] = []
        if let day = days[date] {
            for group in day.groups {
                let list = group.ids.compactMap { items[$0] }
                if !list.isEmpty { result.append(JtAgendaSection(kind: group.kind, items: list, carried: day.carried)) }
            }
        } else {
            let onDay = items.values
                .filter { $0.day == date }
                .sorted { (a: JtCalItem, b: JtCalItem) -> Bool in a.start == b.start ? a.title < b.title : a.start < b.start }
            for kind in agendaKinds {
                let list = onDay.filter { $0.kind == kind }
                if !list.isEmpty { result.append(JtAgendaSection(kind: kind, items: list, carried: [])) }
            }
        }
        if !pending.isEmpty {
            if let index = result.firstIndex(where: { $0.kind == "todo" }) {
                result[index].items += pending
            } else {
                result.insert(JtAgendaSection(kind: "todo", items: pending, carried: []), at: 0)
            }
        }
        for index in result.indices {
            let list = result[index].items
            result[index].items = list.filter { !$0.done } + list.filter(\.done)
        }
        return result
    }

    /// 月曆上每天的點：有幾個項目、幾個還沒完成（JT 排好的日子含延續的待辦）。
    static func agendaMarks(items: [String: JtCalItem], days: [String: JtDay]) -> [String: (total: Int, open: Int)] {
        var marks: [String: (total: Int, open: Int)] = [:]
        for item in items.values {
            let day = item.day
            var mark = marks[day] ?? (0, 0)
            mark.total += 1
            if !item.done { mark.open += 1 }
            marks[day] = mark
        }
        for (date, day) in days {
            let list = day.groups.flatMap(\.ids).compactMap { items[$0] }
            marks[date] = (list.count, list.filter { !$0.done }.count)
        }
        return marks
    }
}

// MARK: - 共用的列

struct JtAgendaSectionView: View {
    let section: JtAgendaSection
    let store: JtSyncStore
    var compact = false
    let onOpenCase: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.textSecondary)
                Text("\(section.items.filter { !$0.done }.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(DS.textTertiary)
            }
            VStack(spacing: 0) {
                ForEach(section.items) { item in
                    JtAgendaRow(
                        item: item,
                        isCarried: section.carried.contains(item.id),
                        isPending: item.isPending || store.isPending(entryId: item.entryId),
                        compact: compact,
                        onToggle: {
                            guard !item.entryId.isEmpty else { return }
                            store.setTodo(item.entryId, ["done": !item.done])
                        },
                        onOpenCase: item.caseId.isEmpty ? nil : { onOpenCase(item.caseId) }
                    )
                    if item.id != section.items.last?.id {
                        Rectangle().fill(DS.hairline).frame(height: 0.5).padding(.leading, compact ? 32 : 36)
                    }
                }
            }
            .background(DS.card, in: RoundedRectangle(cornerRadius: compact ? 10 : DS.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: compact ? 10 : DS.radius, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1))
        }
    }
}

/// 一個項目：待辦與信件備忘可以打勾；會議顯示時間與加入連結；跟案件有關的可以打開案件。
struct JtAgendaRow: View {
    let item: JtCalItem
    let isCarried: Bool
    let isPending: Bool
    var compact = false
    let onToggle: () -> Void
    let onOpenCase: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 8 : 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let time = item.time {
                        Text(time)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(DS.textSecondary)
                    }
                    Text(item.title)
                        .font(compact ? .system(size: 13.5) : .subheadline)
                        .foregroundStyle(item.done ? DS.textTertiary : (item.overdue ? DS.danger : DS.text))
                        .strikethrough(item.done)
                        .lineLimit(compact ? 3 : 2)
                    if isPending {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                let detail = Self.detail(item)
                if !detail.isEmpty {
                    Text(detail)
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(2)
                }
                if isCarried {
                    Text("延續自 \(JtDates.monthDay(item.day))")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(DS.warning)
                }
            }
            Spacer(minLength: 0)
            if let url = URL(string: item.joinURL), !item.joinURL.isEmpty {
                Link(destination: url) {
                    Image(systemName: "video").font(.system(size: compact ? 12 : 14))
                }
                .buttonStyle(CircleIconButtonStyle(size: compact ? 26 : 30))
                .accessibilityLabel("加入會議")
            }
            if let onOpenCase {
                Button(action: onOpenCase) {
                    Image(systemName: "chevron.right").font(.system(size: compact ? 11 : 12, weight: .semibold))
                }
                .buttonStyle(CircleIconButtonStyle(size: compact ? 26 : 30))
                .accessibilityLabel("打開案件")
            }
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 8 : 9)
    }

    @ViewBuilder
    private var leading: some View {
        if item.isCheckable {
            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: compact ? 16 : 18))
                    .foregroundStyle(item.done ? DS.success : DS.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(item.entryId.isEmpty)
            .accessibilityLabel(item.done ? "標示為未完成" : "標示為完成")
        } else {
            Image(systemName: Self.icon(for: item.kind))
                .font(.system(size: compact ? 12 : 14))
                .foregroundStyle(item.overdue ? DS.danger : DS.textSecondary)
                .frame(width: compact ? 16 : 18)
                .padding(.top, 2)
        }
    }

    static func detail(_ item: JtCalItem) -> String {
        var parts: [String] = [item.subtitle, item.customer]
        if !item.progress.isEmpty { parts.append("進度 " + item.progress) }
        parts.append(item.location)
        if !item.mailSender.isEmpty { parts.append("信件：" + item.mailSender) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func icon(for kind: String) -> String {
        switch kind {
        case "meeting": return "person.2"
        case "milestone": return "diamond"
        case "etd": return "flag"
        case "po": return "shippingbox"
        default: return "circle"
        }
    }
}

/// 新增待辦（寫到 Outlook「JT-待辦」）。
struct JtAddTodoField: View {
    let store: JtSyncStore
    let date: String
    var compact = false

    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.textTertiary)
            TextField("新增待辦", text: $text)
                .textFieldStyle(.plain)
                .font(compact ? .system(size: 13.5) : .subheadline)
                .submitLabel(.done)
                .onSubmit(submit)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("新增", action: submit)
                    .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            }
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 7 : 8)
        .background(DS.control, in: RoundedRectangle(cornerRadius: compact ? 10 : DS.radius, style: .continuous))
    }

    private func submit() {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        store.createTodo(title: title, date: date)
        text = ""
    }
}

/// 這天的備忘（Markdown，存在電腦的 JT）。
struct JtDayNoteCard: View {
    let store: JtSyncStore
    let date: String
    var compact = false

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        let note = store.note(on: date)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("備忘").font(.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
                Spacer()
                if isEditing {
                    Button("取消") { isEditing = false }
                        .font(.footnote)
                        .foregroundStyle(DS.textSecondary)
                    Button("儲存") {
                        store.setNote(date, draft)
                        isEditing = false
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                } else {
                    Button(note.isEmpty ? "寫備忘" : "編輯") {
                        draft = note
                        isEditing = true
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(DS.link)
                }
            }
            if isEditing {
                TextEditor(text: $draft)
                    .font(compact ? .system(size: 13.5) : .subheadline)
                    .frame(minHeight: compact ? 90 : 120)
                    .scrollContentBackground(.hidden)
            } else if !note.isEmpty {
                Text(Self.rendered(note))
                    .font(compact ? .system(size: 13.5) : .subheadline)
                    .foregroundStyle(DS.text)
                    .textSelection(.enabled)
            } else {
                Text("這天還沒有備忘").font(.footnote).foregroundStyle(DS.textTertiary)
            }
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard(.butter, padding: 0)
        .onChange(of: date) { _, _ in isEditing = false }
    }

    static func rendered(_ note: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: note, options: options)) ?? AttributedString(note)
    }
}

// MARK: - 右側欄

/// 右側欄的待辦（沒有開著筆記時）：JT 的待辦與行事曆。上面是月曆（國定假日、補班、有項目的日子有點），
/// 下面是選的那天的清單：打勾、新增待辦、備忘都會寫回電腦的 JT（Outlook）。
struct JtAgendaPanel: View {
    @Environment(Workspace.self) private var workspace
    @State private var store: JtSyncStore
    @State private var selected = ""
    @State private var shownYear = 0
    @State private var shownMonth = 0
    @State private var holidayRevision = 0
    @State private var openCase: JtCaseReference?

    init(store: JtSyncStore = .shared) {
        _store = State(initialValue: store)
    }

    /// 電腦的 JT 有配對（或還不知道）時右側欄用 JT 的待辦；確定沒有配對時用筆記裡的待辦。
    static var isAvailable: Bool {
        let store = JtSyncStore.shared
        return store.hasData || (store.isConfigured && !store.notPaired)
    }

    private var today: String { store.calendar?.today ?? store.meta?.today ?? JtDates.string(Date()) }

    var body: some View {
        let date = selected.isEmpty ? today : selected
        let items = store.displayItems()
        let days = store.calendar?.days ?? [:]
        let sections = JtSyncStore.agenda(on: date, items: items, days: days, pending: store.pendingTodos(on: date))
        let marks = JtSyncStore.agendaMarks(items: items, days: days)
        let openTodos = sections.filter { $0.kind == "todo" }.flatMap(\.items).filter { !$0.done }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("待辦")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text("JT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DS.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(DS.control, in: Capsule())
                Spacer()
                Text("\(openTodos) 件未完成")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
            }
            .padding(.horizontal, 2)
            if !store.hasData {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        monthHeader
                        calendarGrid(marks: marks, selected: date)
                        monthHolidays
                        Rectangle().fill(DS.hairline).frame(height: 1)
                        dayHeader(date)
                        if sections.isEmpty {
                            Text(date == today ? "今天沒有待辦或行程" : "這天沒有待辦或行程")
                                .font(.footnote)
                                .foregroundStyle(DS.textTertiary)
                        }
                        ForEach(sections) { section in
                            JtAgendaSectionView(section: section, store: store, compact: true) { openCase = JtCaseReference(id: $0) }
                        }
                        JtAddTodoField(store: store, date: date, compact: true)
                        JtDayNoteCard(store: store, date: date, compact: true)
                        statusLine
                        Button { workspace.open(.jt) } label: {
                            Label("打開 JT 業務追蹤", systemImage: WorkspaceTab.jt.systemImage)
                                .font(.footnote.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.link)
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await store.refresh() }
            }
        }
        .onAppear { if shownYear == 0 { show(month: today) } }
        .task { await store.refresh() }
        .task(id: shownYear) {
            guard shownYear > 0 else { return }
            await TaiwanHolidays.fetchIfNeeded(year: shownYear)
            holidayRevision += 1
        }
        .sheet(item: $openCase) { reference in
            JtCaseDetail(caseId: reference.id)
        }
        .toast($store.notice)
    }

    // MARK: 月曆

    private var monthHeader: some View {
        HStack(spacing: 4) {
            Text("\(String(shownYear)) 年 \(shownMonth) 月")
                .font(.headline)
                .foregroundStyle(DS.text)
            Spacer(minLength: 4)
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(CircleIconButtonStyle(size: 30))
                .accessibilityLabel("上個月")
            Button("今天") {
                selected = ""
                show(month: today)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(DS.text)
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(CircleIconButtonStyle(size: 30))
                .accessibilityLabel("下個月")
        }
    }

    private func show(month day: String) {
        let parts = JournalCalendar.yearMonth(of: day)
        shownYear = parts.year
        shownMonth = parts.month
    }

    private func shift(_ offset: Int) {
        let parts = JournalCalendar.shifted(year: shownYear, month: shownMonth, by: offset)
        shownYear = parts.year
        shownMonth = parts.month
    }

    private func calendarGrid(marks: [String: (total: Int, open: Int)], selected: String) -> some View {
        let cells = JournalCalendar.cells(year: shownYear, month: shownMonth)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
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
                    dayCell(cell, mark: marks[cell], isSelected: cell == selected, isToday: cell == today)
                } else {
                    Color.clear.frame(height: 40)
                }
            }
        }
    }

    private func dayCell(_ day: String, mark: (total: Int, open: Int)?, isSelected: Bool, isToday: Bool) -> some View {
        let number = Int(day.suffix(2)) ?? 0
        let isOff = JournalCalendar.isDayOff(day) || store.calendar?.holidays[day] != nil
        let isMakeup = TaiwanHolidays.isMakeupWorkday(day)
        let numberColor: Color = isSelected ? DS.onPrimary : (isOff ? DS.danger : DS.text)
        let dotColor: Color = (mark?.open ?? 0) > 0 ? DS.link : ((mark?.total ?? 0) > 0 ? DS.textTertiary : Color.clear)
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
                .fill(dotColor)
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
        .onTapGesture { selected = day == today ? "" : day }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(day, mark: mark))
        .accessibilityAddTraits(.isButton)
    }

    private func accessibilityLabel(_ day: String, mark: (total: Int, open: Int)?) -> String {
        var parts = [JtDates.short(day)]
        if let holiday = holidayName(day) { parts.append(holiday) }
        if let mark, mark.total > 0 { parts.append("\(mark.open) 件未完成，共 \(mark.total) 件") }
        return parts.joined(separator: "，")
    }

    private func holidayName(_ day: String) -> String? {
        if let name = store.calendar?.holidays[day], !name.isEmpty { return name }
        return TaiwanHolidays.holiday(on: day)
    }

    @ViewBuilder
    private var monthHolidays: some View {
        let entries = JournalCalendar.cells(year: shownYear, month: shownMonth).compactMap { $0 }.compactMap { day -> String? in
            let date = JtDates.monthDay(day)
            if let name = holidayName(day) { return date + " " + name }
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

    private func dayHeader(_ date: String) -> some View {
        HStack(spacing: 6) {
            Text(date == today ? "今天 \(JtDates.short(date))" : JtDates.short(date))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.text)
            if let holiday = holidayName(date) {
                Text(holiday)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DS.danger)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(DS.danger.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if store.isComputerOffline {
            Label("電腦離線", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.caption)
                .foregroundStyle(DS.warning)
        } else if store.unsentCount > 0 {
            Label("\(store.unsentCount) 個修改待送出", systemImage: "icloud.slash")
                .font(.caption)
                .foregroundStyle(DS.textSecondary)
        }
        if let error = store.calendar?.outlookError, !error.isEmpty {
            Text("Outlook 同步問題：\(error)")
                .font(.caption)
                .foregroundStyle(DS.warning)
        }
    }
}
