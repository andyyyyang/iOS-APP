import SwiftUI

/// 物流追蹤（移植自 vault 的「物流追蹤中心」dataviewjs 工具與它的 Python 爬蟲）：
/// 新增單號（可用相機掃條碼）、追蹤中清單（狀態、最新動態、物流歷程、刷新、查件、結案、刪除）、已結案、
/// 筆記中的單號，以及背景追蹤與 API 設定。清單存在 vault 的 watchlist.json，伺服器負責查詢與背景刷新。
struct LogisticsPage: View {
    enum Tab: Hashable {
        case active
        case archived
        case linked
        case shipments
        case settings
    }

    /// 取代電腦上的工具筆記開啟時，那則筆記的路徑（選單中可以改看原始筆記）。
    var sourceNote: String?

    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    @State private var store = LogisticsStore.shared
    @State private var tab: Tab = .active
    @State private var query = ""
    @State private var statusFilter: String?
    @State private var expanded: String?
    @State private var editingNote: LogisticsClient.Item?
    @State private var noteDraft = ""
    @State private var deleting: LogisticsClient.Item?
    @State private var confirmsClear = false
    @State private var showsScanner = false
    @State private var shipmentFile: String?
    @State private var shipments: [JentechShipment] = []
    @State private var shipmentError: String?

    // 新增追蹤
    @State private var courier = "t-cat"
    @State private var courierPicked = false
    @State private var number = ""
    @State private var note = ""
    @FocusState private var numberFocused: Bool

    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
        .background(DS.pane)
        .task { await store.ensureLoaded() }
        .onChange(of: tab) { _, tab in
            if tab == .linked { Task { await store.loadLinked() } }
            if tab == .shipments { Task { await loadShipments() } }
        }
        .onChange(of: number) { _, value in
            if !courierPicked, let guess = LogisticsLogic.guessCourier(value) { courier = guess }
        }
        .overlay(alignment: .bottom) { toastView }
        .alert("修改案件備註", isPresented: Binding(get: { editingNote != nil }, set: { if !$0 { editingNote = nil } })) {
            TextField("備註", text: $noteDraft)
            Button("取消", role: .cancel) { editingNote = nil }
            Button("儲存") {
                if let item = editingNote { Task { await store.update(item, note: noteDraft) } }
                editingNote = nil
            }
        }
        .confirmationDialog(
            "確定刪除單號 \(deleting?.trackingNumber ?? "")？",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除", role: .destructive) {
                if let item = deleting { Task { await store.remove(item) } }
                deleting = nil
            }
        }
        .confirmationDialog("確定清空所有已結案的單號？", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("清空結案清單", role: .destructive) { Task { await store.clearArchived() } }
        }
        .fullScreenCover(isPresented: $showsScanner) {
            TrackingNumberScanner { found in
                number = found
                showsScanner = false
            } onCancel: {
                showsScanner = false
            }
            .ignoresSafeArea()
        }
    }

    // MARK: 上方

    private var subtitle: String {
        if store.isLoading && store.loadedAt == nil { return "讀取中…" }
        if let error = store.error, store.items.isEmpty { return error }
        return "追蹤中 \(store.active.count) · 已結案 \(store.archived.count)"
    }

    private var topBar: some View {
        PageToolbar("物流追蹤", subtitle: subtitle, query: $query, searchPlaceholder: "搜尋單號、備註、物流商、動態") {
            Button {
                Task { await store.refreshAll() }
            } label: {
                if store.isRefreshingAll {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(CircleIconButtonStyle())
            .disabled(store.isRefreshingAll)
            .accessibilityLabel("批次刷新")
            moreMenu
        } chips: {
            SegmentedPills(options: [
                (value: Tab.active, title: (isCompact ? "追蹤 " : "追蹤中 ") + "\(store.active.count)"),
                (value: Tab.archived, title: (isCompact ? "結案 " : "已結案 ") + "\(store.archived.count)"),
                (value: Tab.linked, title: isCompact ? "筆記" : "筆記單號"),
                (value: Tab.shipments, title: isCompact ? "名冊" : "託運名冊"),
                (value: Tab.settings, title: "設定"),
            ], selection: $tab)
            if tab == .active {
                Menu {
                    Button {
                        statusFilter = nil
                    } label: {
                        if statusFilter == nil { Label("全部狀態", systemImage: "checkmark") } else { Text("全部狀態") }
                    }
                    ForEach(store.statuses) { status in
                        Button {
                            statusFilter = status.id
                        } label: {
                            if statusFilter == status.id { Label(status.label, systemImage: "checkmark") } else { Text(status.label) }
                        }
                    }
                } label: {
                    FilterChip(title: statusFilter.flatMap { store.status($0)?.label } ?? "狀態", isActive: statusFilter != nil, systemImage: "line.3.horizontal.decrease")
                }
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button {
                Task { await store.archiveDelivered() }
            } label: {
                Label("結案已送達", systemImage: "checkmark.seal")
            }
            Button {
                UIPasteboard.general.string = LogisticsLogic.markdownTable(store.items, statuses: store.statuses)
                store.toast = "已複製追蹤中清單的 Markdown 表格"
            } label: {
                Label("複製表格", systemImage: "tablecells")
            }
            Button {
                Task { await store.load() }
            } label: {
                Label("重新讀取", systemImage: "arrow.triangle.2.circlepath")
            }
            if let sourceNote {
                Divider()
                Button {
                    workspace.showSource(of: sourceNote)
                } label: {
                    Label("開啟原始筆記", systemImage: "doc.text")
                }
            }
            if !store.archived.isEmpty {
                Divider()
                Button(role: .destructive) {
                    confirmsClear = true
                } label: {
                    Label("清空結案清單", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.text)
                .frame(width: 34, height: 34)
                .background(DS.control, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("更多")
    }

    // MARK: 內容

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                switch tab {
                case .active: activeList
                case .archived: archivedList
                case .linked: linkedList
                case .shipments: shipmentList
                case .settings: settingsView
                }
            }
            .padding(.horizontal, isCompact ? 16 : 24)
            .padding(.bottom, 90)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            switch tab {
            case .linked: await store.loadLinked()
            case .shipments: await loadShipments()
            default: await store.load()
            }
        }
    }

    private func matches(_ item: LogisticsClient.Item) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return [item.trackingNumber, item.note, item.courierName, item.latestEvent].contains { $0.localizedCaseInsensitiveContains(text) }
    }

    @ViewBuilder
    private var activeList: some View {
        addCard
        if let error = store.error, store.loadedAt == nil, !store.isLoading {
            Text(error)
                .font(.footnote)
                .foregroundStyle(DS.warning)
        }
        let items = store.active.filter { matches($0) && (statusFilter == nil || $0.status == statusFilter) }
        if items.isEmpty {
            if store.isLoading && store.loadedAt == nil {
                ProgressView().frame(maxWidth: .infinity).padding(30)
            } else {
                EmptyStateView(title: store.active.isEmpty ? "目前沒有追蹤中的單號" : "沒有符合的單號")
            }
        } else {
            ForEach(items) { item in
                LogisticsItemCard(
                    item: item,
                    isExpanded: expanded == item.trackingNumber,
                    onToggle: { withAnimation(.easeOut(duration: 0.2)) { expanded = expanded == item.trackingNumber ? nil : item.trackingNumber } },
                    onEditNote: {
                        noteDraft = item.note
                        editingNote = item
                    },
                    onDelete: { deleting = item }
                )
            }
        }
    }

    // MARK: 新增追蹤

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(store.couriers) { option in
                        Button {
                            courier = option.code
                            courierPicked = true
                        } label: {
                            if courier == option.code { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                        }
                    }
                } label: {
                    FilterChip(title: store.courier(courier)?.name ?? courier, isActive: true, systemImage: "shippingbox")
                }
                Spacer()
            }
            HStack(spacing: 8) {
                TextField("輸入快遞單號", text: $number)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .focused($numberFocused)
                    .onSubmit { addItem() }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(DS.control, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
                if TrackingNumberScanner.isSupported {
                    Button {
                        numberFocused = false
                        showsScanner = true
                    } label: {
                        Image(systemName: "barcode.viewfinder")
                    }
                    .buttonStyle(CircleIconButtonStyle(size: 40))
                    .accessibilityLabel("掃描託運單")
                }
            }
            TextField("備註", text: $note)
                .submitLabel(.done)
                .onSubmit { addItem() }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(DS.control, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
            Button {
                addItem()
            } label: {
                HStack(spacing: 8) {
                    if store.busy.contains(LogisticsLogic.normalize(number)) { ProgressView().tint(DS.onPrimary) }
                    Text("新增追蹤")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            .disabled(LogisticsLogic.normalize(number).isEmpty || store.busy.contains(LogisticsLogic.normalize(number)))
        }
        .card(padding: 14)
    }

    private func addItem() {
        let value = LogisticsLogic.normalize(number)
        guard !value.isEmpty, !store.busy.contains(value) else { return }
        numberFocused = false
        let chosen = courier
        let remark = note
        Task {
            if await store.add(courier: chosen, number: value, note: remark) {
                number = ""
                note = ""
                courierPicked = false
                statusFilter = nil
            }
        }
    }

    // MARK: 已結案

    @ViewBuilder
    private var archivedList: some View {
        let items = store.archived.filter(matches)
        if items.isEmpty {
            EmptyStateView(title: store.archived.isEmpty ? "目前沒有已結案的單號" : "沒有符合的單號")
        } else {
            Text("共 \(store.archived.count) 筆")
                .font(.footnote)
                .foregroundStyle(DS.textSecondary)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.courierName).font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
                        Spacer()
                        Text(item.latestTime.isEmpty ? "—" : item.latestTime)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                    }
                    Text(item.trackingNumber)
                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                        .foregroundStyle(DS.text)
                        .textSelection(.enabled)
                    if !item.note.isEmpty {
                        Text(item.note).font(.subheadline).foregroundStyle(DS.textSecondary)
                    }
                    Text(item.latestEvent.isEmpty ? "已送達結案" : item.latestEvent)
                        .font(.footnote)
                        .foregroundStyle(DS.textSecondary)
                    HStack(spacing: 6) {
                        Button("恢復追蹤") { Task { await store.update(item, archived: false) } }
                            .buttonStyle(SmallPillStyle())
                        Button("刪除") { deleting = item }
                            .buttonStyle(SmallPillStyle(destructive: true))
                    }
                    .padding(.top, 2)
                }
                .card(padding: 14)
            }
        }
    }

    // MARK: 筆記單號關聯

    @ViewBuilder
    private var linkedList: some View {
        if store.isLoadingLinked && store.linked.isEmpty {
            ProgressView("尋找筆記中的單號…").frame(maxWidth: .infinity).padding(30)
        } else if store.linked.isEmpty {
            EmptyStateView(title: "筆記中沒有物流單號")
        } else {
            ForEach(store.linked.filter { query.isEmpty || [$0.name, $0.customer, $0.trackingNumber, $0.caseNo].contains(where: { $0.localizedCaseInsensitiveContains(query) }) }) { linked in
                HStack(alignment: .center, spacing: 12) {
                    Button {
                        workspace.open(.note(linked.path))
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(linked.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DS.text)
                                .lineLimit(1)
                            Text([linked.customer, linked.courierName].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(DS.textSecondary)
                            Text(linked.trackingNumber)
                                .font(.system(.footnote, design: .monospaced).weight(.bold))
                                .foregroundStyle(DS.text)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if linked.tracked {
                        Chip(text: "追蹤中", pastel: .mint)
                    } else {
                        Button {
                            Task { await store.track(linked) }
                        } label: {
                            if store.busy.contains(linked.trackingNumber) { ProgressView() } else { Text("加入追蹤") }
                        }
                        .buttonStyle(SmallPillStyle())
                    }
                }
                .card(padding: 14)
            }
        }
    }

    // MARK: 託運名冊

    private func loadShipments() async {
        await JentechStore.shared.ensureIndex()
        let files = JentechStore.shared.shipmentFiles
        if shipmentFile == nil || !files.contains(shipmentFile ?? "") { shipmentFile = files.first }
        guard let file = shipmentFile else {
            shipments = []
            shipmentError = nil
            return
        }
        do {
            shipments = try await JentechStore.shared.loadShipments(file)
            shipmentError = nil
        } catch {
            shipmentError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var shipmentList: some View {
        let files = JentechStore.shared.shipmentFiles
        if files.count > 1 {
            Menu {
                ForEach(files, id: \.self) { file in
                    Button((file as NSString).lastPathComponent) {
                        shipmentFile = file
                        Task { await loadShipments() }
                    }
                }
            } label: {
                FilterChip(title: ((shipmentFile ?? "") as NSString).lastPathComponent, isActive: true, systemImage: "doc.text")
            }
        }
        if let error = shipmentError {
            Text(error).font(.footnote).foregroundStyle(DS.warning)
        }
        let rows = shipments.filter { query.isEmpty || [$0.recipient, $0.address, $0.orderNo, $0.item, $0.mobile, $0.phone].contains(where: { $0.localizedCaseInsensitiveContains(query) }) }
        if files.isEmpty {
            EmptyStateView(title: "沒有託運名冊")
        } else if rows.isEmpty {
            EmptyStateView(title: shipments.isEmpty ? "名冊是空的" : "沒有符合的收件人")
        } else {
            Text("\(((shipmentFile ?? "") as NSString).lastPathComponent)：共 \(shipments.count) 筆收件人")
                .font(.footnote)
                .foregroundStyle(DS.textSecondary)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(row.recipient).font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
                        Spacer()
                        if !row.orderNo.isEmpty {
                            Text(row.orderNo).font(.system(.caption, design: .monospaced)).foregroundStyle(DS.textSecondary)
                        }
                    }
                    Text(row.address).font(.footnote).foregroundStyle(DS.text).textSelection(.enabled)
                    HStack(spacing: 6) {
                        ForEach([row.mobile, row.phone].filter { !$0.isEmpty }, id: \.self) { number in
                            if let dial = JentechLogic.dialable(number), let url = URL(string: "tel:\(dial)") {
                                Button {
                                    openURL(url)
                                } label: {
                                    Label(number, systemImage: "phone")
                                }
                                .buttonStyle(SmallPillStyle())
                            }
                        }
                        CopyButton(value: row.address, label: "地址")
                        Spacer(minLength: 0)
                    }
                    if !row.item.isEmpty || !row.shipDate.isEmpty {
                        Text([row.item, row.shipDate.isEmpty ? "" : "出貨 \(row.shipDate)"].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(DS.textSecondary)
                    }
                }
                .card(padding: 12)
            }
        }
    }

    // MARK: 設定

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsCard("背景追蹤", systemImage: "clock.arrow.circlepath") {
                if let info = store.refreshInfo {
                    if info.intervalMinutes > 0 {
                        Text("每 \(Self.interval(info.intervalMinutes)) 自動刷新")
                    } else {
                        Text("背景刷新已關閉")
                    }
                    if let last = info.lastRunAt.flatMap(Self.parseDate) {
                        Text("上次刷新：\(last.formatted(date: .abbreviated, time: .shortened))，共 \(info.lastRefreshed) 筆")
                            .foregroundStyle(DS.textSecondary)
                    }
                    if let error = info.lastError {
                        Text("上次失敗：\(error)").foregroundStyle(DS.warning)
                    }
                } else {
                    Text(store.error ?? "讀取中…").foregroundStyle(DS.textSecondary)
                }
            }
            settingsCard("自動抓取的物流商", systemImage: "shippingbox") {
                ForEach(store.couriers) { option in
                    HStack {
                        Text(option.name)
                        Spacer()
                        Text(option.live ? "自動抓取" : "開啟官網查件")
                            .foregroundStyle(option.live ? DS.success : DS.textSecondary)
                    }
                }
            }
            settingsCard("DHL 官方 API", systemImage: "key") {
                if store.dhl {
                    Label("已設定", systemImage: "checkmark.circle.fill").foregroundStyle(DS.success)
                } else {
                    Button("開啟 DHL Developer Portal") {
                        if let url = URL(string: "https://developer.dhl.com/user/register") { openURL(url) }
                    }
                    .buttonStyle(SmallPillStyle())
                }
            }
            settingsCard("17TRACK API", systemImage: "globe") {
                if store.track17 {
                    Label("已設定", systemImage: "checkmark.circle.fill").foregroundStyle(DS.success)
                } else {
                    Button("開啟 17TRACK API") {
                        if let url = URL(string: "https://api.17track.net") { openURL(url) }
                    }
                    .buttonStyle(SmallPillStyle())
                }
            }
            settingsCard("資料", systemImage: "doc") {
                Text(store.path)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private func settingsCard<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.text)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .font(.subheadline)
            .foregroundStyle(DS.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }

    nonisolated static func interval(_ minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60) 小時" : "\(minutes) 分鐘"
    }

    nonisolated static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: 提示

    @ViewBuilder
    private var toastView: some View {
        if let toast = store.toast {
            Text(toast)
                .font(.footnote.weight(.medium))
                .foregroundStyle(DS.onPrimary)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(DS.primary, in: Capsule(style: .continuous))
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(2.2))
                    withAnimation { store.toast = nil }
                }
        }
    }
}

/// 一筆追蹤中的單號：狀態、物流商、單號（點一下複製）、備註（點一下修改）、最新動態，以及操作與物流歷程。
struct LogisticsItemCard: View {
    let item: LogisticsClient.Item
    let isExpanded: Bool
    var onToggle: () -> Void
    var onEditNote: () -> Void
    var onDelete: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var store = LogisticsStore.shared
    @State private var copied = false

    private var statusColor: Color { LogisticsStatusChip.color(store.status(item.status)?.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(store.statuses) { status in
                        Button {
                            Task { await store.update(item, status: status.id) }
                        } label: {
                            if status.id == item.status { Label(status.label, systemImage: "checkmark") } else { Text(status.label) }
                        }
                    }
                } label: {
                    LogisticsStatusChip(label: store.status(item.status)?.label ?? item.status, color: statusColor)
                }
                .accessibilityLabel("狀態")
                Text(item.courierName.isEmpty ? item.courierCode : item.courierName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.latestTime)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
            }
            Button {
                UIPasteboard.general.string = item.trackingNumber
                copied = true
            } label: {
                HStack(spacing: 6) {
                    Text(item.trackingNumber)
                        .font(.system(.body, design: .monospaced).weight(.bold))
                        .foregroundStyle(DS.text)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(copied ? DS.success : DS.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("點一下複製單號")
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1))
                copied = false
            }
            Button(action: onEditNote) {
                Text(item.note.isEmpty ? "（點此新增備註）" : item.note)
                    .font(.subheadline)
                    .foregroundStyle(item.note.isEmpty ? DS.textTertiary : DS.text)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Text(item.latestEvent.isEmpty ? "—" : item.latestEvent)
                .font(.subheadline)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(isExpanded ? nil : 2)
            HStack(spacing: 6) {
                Button(isExpanded ? "收合" : "軌跡", action: onToggle)
                    .buttonStyle(SmallPillStyle(isActive: isExpanded))
                Button {
                    Task { await store.refresh(item) }
                } label: {
                    if store.busy.contains(item.trackingNumber) { ProgressView().controlSize(.mini) } else { Text("刷新") }
                }
                .buttonStyle(SmallPillStyle())
                .disabled(store.busy.contains(item.trackingNumber))
                Menu {
                    if let url = store.trackingURL(for: item) {
                        Button { openURL(url) } label: { Label("\(item.courierName) 官方網站", systemImage: "safari") }
                    }
                    if let url = LogisticsLogic.track17URL(item.trackingNumber) {
                        Button { openURL(url) } label: { Label("17TRACK", systemImage: "globe") }
                    }
                } label: {
                    Text("查件")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DS.text)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(DS.control, in: Capsule(style: .continuous))
                }
                Button("結案") { Task { await store.update(item, archived: true) } }
                    .buttonStyle(SmallPillStyle())
                Spacer(minLength: 0)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .accessibilityLabel("刪除")
            }
            if isExpanded {
                timeline
            }
        }
        .card(padding: 14)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("物流歷程")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.textSecondary)
            if item.trackinfo.isEmpty {
                Text("尚無歷程明細")
                    .font(.footnote)
                    .foregroundStyle(DS.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(item.trackinfo.enumerated()), id: \.offset) { index, node in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(index == 0 ? statusColor : DS.textTertiary)
                                    .frame(width: 9, height: 9)
                                    .padding(.top, 4)
                                if index < item.trackinfo.count - 1 {
                                    Rectangle()
                                        .fill(DS.hairline)
                                        .frame(width: 2)
                                        .frame(maxHeight: .infinity)
                                }
                            }
                            .frame(width: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.checkpointDate)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(DS.textSecondary)
                                Text(node.trackingDetail)
                                    .font(.subheadline.weight(index == 0 ? .semibold : .regular))
                                    .foregroundStyle(index == 0 ? DS.text : DS.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.bottom, 12)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.control.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 狀態膠囊：狀態的顏色字、淡色底。
struct LogisticsStatusChip: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule(style: .continuous))
    }

    /// "#2563eb" → Color（無法解讀時灰色）。
    nonisolated static func color(_ hex: String?) -> Color {
        guard let hex, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return DS.textSecondary }
        return Color(hex: value)
    }
}

/// 卡片中的小膠囊按鈕。
struct SmallPillStyle: ButtonStyle {
    var isActive = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isActive ? DS.onPrimary : (destructive ? DS.danger : DS.text))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(isActive ? DS.primary : DS.control, in: Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
