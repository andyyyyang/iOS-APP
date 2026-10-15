import SwiftUI

// 業務快查與物流中心的各頁（移植自 Obsidian 插件 jentech-tools 的頁籤）：
// 看板首頁、通訊錄、代碼查詢、案件查詢、BPM 追蹤、SOP 導覽（編輯卡片在 JentechCardsPage.swift）。

/// 工具頁的捲動內容：卡片清單、iPad 上限寬。
struct ToolScroll<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.horizontal, sizeClass == .compact ? 16 : 24)
            .padding(.bottom, 90)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// 複製按鈕：點一下複製並顯示勾。
struct CopyButton: View {
    let value: String
    var label: String?
    var onCopied: (String) -> Void = { _ in }
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            copied = true
            onCopied(value)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                if let label { Text(label) }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(copied ? DS.success : DS.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(DS.control, in: Capsule(style: .continuous))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(value.isEmpty)
        .accessibilityLabel("複製 \(value)")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

// MARK: - 看板首頁

/// 業務快查與物流中心：七個工具的入口與即時摘要，上方的搜尋同時找通訊錄、客戶與代碼、案件、SOP 與物流單號。
struct JentechHubPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var store = JentechStore.shared
    @State private var logistics = LogisticsStore.shared
    @State private var query = ""
    @State private var toast: String?

    private struct Tool: Identifiable {
        let tab: WorkspaceTab
        let detail: String
        let pastel: DS.Pastel
        var id: String { tab.id }
    }

    private var tools: [Tool] {
        let codes = store.codes
        let customers = codes.filter { $0.kind == .customer }.count
        let cards = store.cards
        let exceptions = logistics.active.filter { $0.status == "exception" }.count
        return [
            Tool(tab: .logistics, detail: "追蹤中 \(logistics.active.count)" + (exceptions > 0 ? " · 異常 \(exceptions)" : ""), pastel: .sky),
            Tool(tab: .contacts, detail: store.contacts.isEmpty ? "四大廠區分機與 MVPN" : "\(store.contacts.count) 筆 · 四大廠區", pastel: .mint),
            Tool(tab: .codes, detail: "客戶 \(customers) · TCode \(codes.count - customers)", pastel: .butter),
            Tool(tab: .cases, detail: "開案 \(store.cases.count) 件", pastel: .lavender),
            Tool(tab: .bpm, detail: store.bpm.map { "進行中 \($0.total) · 要催 \($0.stuck.count)" } ?? "流程簽核進度", pastel: .blush),
            Tool(tab: .cards, detail: "人員 \(cards.filter { $0.kind == .person }.count) · 客戶 \(cards.filter { $0.kind == .customer }.count)", pastel: .sky),
            Tool(tab: .sop, detail: "\(JentechLogic.sops.count) 個流程", pastel: .mint),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar("業務快查", subtitle: "業務快查與物流中心", query: $query, searchPlaceholder: "搜尋人名、分機、客戶、代碼、案件、單號", pinnedSearch: true) {
                EmptyView()
            } chips: {
                ForEach([WorkspaceTab.contacts, .logistics, .codes, .cases], id: \.id) { tab in
                    Button { workspace.open(tab) } label: { FilterChip(title: tab.title, systemImage: tab.systemImage) }
                        .buttonStyle(.plain)
                }
            }
            ToolScroll {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    grid
                } else {
                    searchResults
                }
            }
            .refreshable { await reload() }
        }
        .background(DS.pane)
        .task { await reload() }
        .toast($toast)
    }

    private func reload() async {
        async let index: Void = store.ensureIndex()
        async let contacts: Void = store.loadContacts()
        async let bpm: Void = store.loadBpm()
        async let shipments: Void = logistics.ensureLoaded()
        _ = await (index, contacts, bpm, shipments)
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .compact ? 150 : 220), spacing: 10)], spacing: 10) {
            ForEach(tools) { tool in
                Button {
                    workspace.open(tool.tab)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: tool.tab.systemImage)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(DS.text)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DS.onPastelSecondary)
                        }
                        Text(tool.tab.title)
                            .font(.headline)
                            .foregroundStyle(DS.text)
                        Text(tool.detail)
                            .font(.caption)
                            .foregroundStyle(DS.onPastelSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                    .pastelCard(tool.pastel, padding: 14)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let text = query
        let contacts = store.contacts.filter { JentechLogic.matches(text, [$0.plant, $0.dept, $0.name, $0.ext, $0.mvpn]) }.prefix(8)
        let codes = store.codes.filter { JentechLogic.matches(text, [$0.code, $0.alias, $0.name, $0.fullName, $0.detail]) }.prefix(6)
        let cases = store.cases.filter { JentechLogic.matches(text, [$0.caseNo, $0.sapNo, $0.product, $0.customer, $0.bpmRdmn, $0.file]) }.prefix(6)
        let sops = JentechLogic.sops.filter { JentechLogic.sopMatches($0, text) }.prefix(4)
        let parcels = logistics.items.filter { JentechLogic.matches(text, [$0.trackingNumber, $0.note, $0.latestEvent]) }.prefix(4)
        if contacts.isEmpty && codes.isEmpty && cases.isEmpty && sops.isEmpty && parcels.isEmpty {
            EmptyStateView(title: "沒有符合的結果", message: store.isLoadingContacts ? "通訊錄讀取中…" : nil)
        }
        if !contacts.isEmpty {
            SectionHeader("通訊錄", trailing: "\(contacts.count) 筆")
            ForEach(Array(contacts)) { contact in
                ContactRow(contact: contact, onCopied: { toast = "已複製：\(contact.name) \($0)"; store.remember(text) })
            }
        }
        if !codes.isEmpty {
            SectionHeader("客戶與代碼")
            ForEach(Array(codes)) { code in CodeRow(code: code, onCopied: { toast = "已複製代碼：\($0)" }) }
        }
        if !cases.isEmpty {
            SectionHeader("開案案件")
            ForEach(Array(cases)) { item in CaseRow(item: item) }
        }
        if !sops.isEmpty {
            SectionHeader("SOP")
            ForEach(Array(sops)) { sop in SopRow(sop: sop, onTag: { query = $0 }) }
        }
        if !parcels.isEmpty {
            SectionHeader("物流單號")
            ForEach(Array(parcels)) { item in
                Button { workspace.open(.logistics) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(item.courierName) · \(item.trackingNumber)").font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
                        Text(item.latestEvent.isEmpty ? item.note : item.latestEvent).font(.caption).foregroundStyle(DS.textSecondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(padding: 12)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 通訊錄

/// 通訊錄：全公司完整通訊錄（四大廠區約 990 筆）的即時搜尋，依廠區篩選，點一下複製分機或撥打 MVPN。
struct JentechContactsPage: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var store = JentechStore.shared
    @State private var query = ""
    @State private var plant = "all"
    @State private var toast: String?
    private let limit = 100

    private var rows: [JentechContact] {
        store.contacts.filter { contact in
            (plant == "all" || contact.plant == plant) && JentechLogic.matches(query, [contact.plant, contact.dept, contact.name, contact.ext, contact.mvpn])
        }
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            PageToolbar("通訊錄", subtitle: store.isLoadingContacts && store.contacts.isEmpty ? "讀取中…" : "共 \(rows.count) 筆", query: $query, searchPlaceholder: "姓名、部門、分機、MVPN", pinnedSearch: true) {
                Menu {
                    if store.contactHistory.isEmpty {
                        Text("尚無搜尋紀錄")
                    } else {
                        ForEach(store.contactHistory, id: \.self) { term in
                            Button(term) { query = term }
                        }
                        Divider()
                        Button("清除紀錄", role: .destructive) { store.clearHistory() }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.text)
                        .frame(width: 34, height: 34)
                        .background(DS.control, in: Circle())
                }
                .accessibilityLabel("最近搜尋")
            } chips: {
                SegmentedPills(options: [(value: "all", title: sizeClass == .compact ? "全部" : "全部廠區")] + JentechLogic.plants.map { (value: $0, title: $0) }, selection: $plant)
            }
            ToolScroll {
                if let error = store.contactsError, store.contacts.isEmpty {
                    EmptyStateView(title: "讀不到通訊錄", message: error)
                } else if rows.isEmpty, !store.isLoadingContacts {
                    EmptyStateView(title: "沒有符合的聯絡人")
                } else {
                    ForEach(rows.prefix(limit)) { contact in
                        ContactRow(contact: contact, onCopied: { value in
                            toast = "已複製：\(contact.name) \(value)"
                            store.remember(query)
                        })
                    }
                    if rows.count > limit {
                        Text("只顯示前 \(limit) 筆，請輸入更多關鍵字縮小範圍。")
                            .font(.footnote)
                            .foregroundStyle(DS.textSecondary)
                    }
                }
            }
            .refreshable { await store.loadContacts(force: true) }
        }
        .background(DS.pane)
        .task { await store.loadContacts() }
        .toast($toast)
    }
}

/// 一位聯絡人：姓名（有筆記時可開啟）、部門與廠區、分機與 MVPN（複製、撥打）。
struct ContactRow: View {
    let contact: JentechContact
    var onCopied: (String) -> Void = { _ in }

    @Environment(Workspace.self) private var workspace
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let target = contact.linkTarget {
                    Button {
                        workspace.openLink(target)
                    } label: {
                        HStack(spacing: 4) {
                            Text(contact.name).font(.subheadline.weight(.semibold)).foregroundStyle(DS.link)
                            Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(DS.link)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(contact.name).font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
                }
                Text("\(contact.dept) · \(contact.plant)")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    Label(contact.ext.isEmpty ? "—" : contact.ext, systemImage: "phone")
                    Label(contact.mvpn.isEmpty ? "—" : contact.mvpn, systemImage: "iphone")
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(DS.text)
                .labelStyle(.titleAndIcon)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let number = JentechLogic.dialable(contact.mvpn), let url = URL(string: "tel:\(number)") {
                Button {
                    onCopied(contact.mvpn)
                    openURL(url)
                } label: {
                    Image(systemName: "phone.fill")
                }
                .buttonStyle(CircleIconButtonStyle(size: 34))
                .accessibilityLabel("撥打 MVPN \(contact.mvpn)")
            }
            CopyButton(value: contact.copyValue, onCopied: onCopied)
        }
        .card(padding: 12)
    }
}

// MARK: - 代碼查詢

/// 代碼查詢：客戶（客代、別稱、產業、地區）與 SAP T-Code，點一下複製代碼。
struct JentechCodesPage: View {
    @State private var store = JentechStore.shared
    @State private var query = ""
    @State private var kind = "all"
    @State private var toast: String?

    var body: some View {
        let rows = store.codes.filter { code in
            (kind == "all" || code.kind.rawValue == kind) && JentechLogic.matches(query, [code.code, code.alias, code.name, code.fullName, code.detail])
        }
        VStack(spacing: 0) {
            PageToolbar("代碼查詢", subtitle: "共 \(rows.count) 筆", query: $query, searchPlaceholder: "客戶名稱、客代、別稱、T-Code、說明", pinnedSearch: true) {
                EmptyView()
            } chips: {
                SegmentedPills(options: [(value: "all", title: "全部"), (value: JentechCode.Kind.customer.rawValue, title: "客戶"), (value: JentechCode.Kind.tcode.rawValue, title: "TCode")], selection: $kind)
            }
            ToolScroll {
                if rows.isEmpty {
                    EmptyStateView(title: store.codes.isEmpty ? "還沒有客戶或代碼資料" : "沒有符合的結果", message: store.codes.isEmpty ? "客戶筆記（04 客戶，type: customer）與 T-Code 筆記（11 SOP/常用代碼/代碼紀錄/TCode，type: code）會出現在這裡。" : nil)
                } else {
                    ForEach(rows) { code in CodeRow(code: code, onCopied: { toast = "已複製代碼：\($0)" }) }
                }
            }
            .refreshable { await VaultIndexStore.shared.refresh() }
        }
        .background(DS.pane)
        .task { await store.ensureIndex() }
        .toast($toast)
    }
}

struct CodeRow: View {
    let code: JentechCode
    var onCopied: (String) -> Void = { _ in }
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                workspace.open(.note(code.path))
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Chip(text: code.kind.rawValue, pastel: code.kind == .customer ? .sky : .butter)
                        Text(code.displayCode)
                            .font(.system(.subheadline, design: .monospaced).weight(.bold))
                            .foregroundStyle(DS.text)
                    }
                    Text(code.kind == .customer ? code.fullName : code.name)
                        .font(.subheadline)
                        .foregroundStyle(DS.text)
                    if !code.detail.isEmpty {
                        Text(code.detail).font(.caption).foregroundStyle(DS.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            CopyButton(value: code.code, onCopied: onCopied)
        }
        .card(padding: 12)
    }
}

// MARK: - 案件查詢

/// 案件查詢：開案 Checklist（模具開案號、SAP 品號、產品、客戶、RDMN），依客戶篩選，點一下開啟。
struct JentechCasesPage: View {
    @Environment(Workspace.self) private var workspace
    @State private var store = JentechStore.shared
    @State private var query = ""
    @State private var customer: String?

    var body: some View {
        let all = store.cases
        let customers = Array(Set(all.map(\.customer).filter { !$0.isEmpty })).sorted()
        let rows = all.filter { item in
            (customer == nil || item.customer == customer) && JentechLogic.matches(query, [item.caseNo, item.sapNo, item.product, item.customer, item.bpmRdmn, item.file])
        }
        VStack(spacing: 0) {
            PageToolbar("案件查詢", subtitle: "共 \(rows.count) 筆", query: $query, searchPlaceholder: "開案號（T/S 號）、SAP 品號、產品、客戶、RDMN", pinnedSearch: true) {
                Button {
                    workspace.openLink("開案 Dashboard")
                } label: {
                    Image(systemName: "chart.bar.doc.horizontal")
                }
                .buttonStyle(CircleIconButtonStyle())
                .accessibilityLabel("開案 Dashboard")
            } chips: {
                Button { customer = nil } label: { FilterChip(title: "全部", isActive: customer == nil) }
                    .buttonStyle(.plain)
                ForEach(customers, id: \.self) { name in
                    Button { customer = customer == name ? nil : name } label: { FilterChip(title: name, isActive: customer == name) }
                        .buttonStyle(.plain)
                }
            }
            ToolScroll {
                if rows.isEmpty {
                    EmptyStateView(title: all.isEmpty ? "還沒有開案 Checklist" : "沒有符合的案件", message: all.isEmpty ? "05 客戶案件/開案 Checklist 中 type: checklist 的筆記會出現在這裡。" : nil)
                } else {
                    ForEach(rows) { item in CaseRow(item: item) }
                }
            }
            .refreshable { await VaultIndexStore.shared.refresh() }
        }
        .background(DS.pane)
        .task { await store.ensureIndex() }
    }
}

struct CaseRow: View {
    let item: JentechCase
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button {
            workspace.open(.note(item.path))
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.caseNo.isEmpty ? "—" : item.caseNo)
                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                        .foregroundStyle(DS.text)
                    if !item.sapNo.isEmpty {
                        Text(item.sapNo).font(.system(.caption, design: .monospaced)).foregroundStyle(DS.textSecondary)
                    }
                    Spacer()
                    Text(item.created.isEmpty ? "—" : item.created)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(DS.textSecondary)
                }
                Text(item.product.isEmpty ? item.file : item.product)
                    .font(.subheadline)
                    .foregroundStyle(DS.text)
                    .multilineTextAlignment(.leading)
                Text([item.customer, item.osat, item.bpmRdmn].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - BPM 追蹤

/// BPM 追蹤：06 日誌/BPM 追蹤/latest.json（公司電腦的排程每天 08:30、14:00 抓取）的流程狀態、要催案件與卡關天數。
struct JentechBpmPage: View {
    @Environment(Workspace.self) private var workspace
    @State private var store = JentechStore.shared
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar("BPM 追蹤", subtitle: store.bpm.map { "抓取於 \($0.fetchedAt)" } ?? (store.isLoadingBpm ? "讀取中…" : ""), query: $query, searchPlaceholder: "流程、主旨、執行中活動") {
                Button {
                    Task { await store.loadBpm() }
                } label: {
                    if store.isLoadingBpm { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(CircleIconButtonStyle())
                .accessibilityLabel("重新讀取")
            } chips: {
                Button { workspace.open(.folder("06 日誌/BPM 追蹤")) } label: { FilterChip(title: "每日快照", systemImage: "calendar") }
                    .buttonStyle(.plain)
                Button { workspace.openLink("BPM 追蹤") } label: { FilterChip(title: "BPM 追蹤筆記", systemImage: "doc.text") }
                    .buttonStyle(.plain)
            }
            ToolScroll {
                if let bpm = store.bpm {
                    content(bpm)
                } else if let error = store.bpmError {
                    EmptyStateView(title: "讀不到 BPM 資料", message: error)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(30)
                }
                Text("BPM 在公司內網，資料由公司電腦的 Windows 排程（Jentech-BpmTracking，每天 08:30 與 14:00）抓取後同步到 vault；要立即重新抓取請在電腦的 Obsidian 執行。")
                    .font(.footnote)
                    .foregroundStyle(DS.textSecondary)
                    .padding(.top, 6)
            }
            .refreshable { await store.loadBpm() }
        }
        .background(DS.pane)
        .task { await store.loadBpm() }
    }

    @ViewBuilder
    private func content(_ bpm: JentechBpm) -> some View {
        HStack(spacing: 8) {
            MetricTile(title: "處理中案件", value: "\(bpm.total)", pastel: .sky)
            MetricTile(title: "要催（卡 ≥ \(bpm.stuckThreshold) 天）", value: "\(bpm.stuck.count)", pastel: .blush, valueColor: bpm.stuck.isEmpty ? DS.text : DS.danger)
            MetricTile(title: "正常工作中", value: "\(bpm.working.count)", pastel: .mint)
        }
        if !bpm.stuck.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("卡 ≥ \(bpm.stuckThreshold) 天需追蹤（\(bpm.stuck.count) 件）")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.danger)
                ForEach(bpm.stuck) { item in
                    Text("\(item.processName) 卡在「\(item.currentStep)」\(item.daysStuck ?? 0) 天（\(item.subject)）")
                        .font(.footnote)
                        .foregroundStyle(DS.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pastelCard(.blush, padding: 12)
        }
        let items = bpm.items.filter { JentechLogic.matches(query, [$0.processName, $0.subject, $0.currentStep, $0.status]) }
        if items.isEmpty {
            EmptyStateView(title: bpm.items.isEmpty ? "目前沒有進行中的 BPM 流程" : "沒有符合的流程")
        } else {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("#\(item.idx) \(item.processName)").font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
                        Spacer()
                        stuckLabel(item, threshold: bpm.stuckThreshold)
                    }
                    if !item.subject.isEmpty {
                        Text(item.subject).font(.footnote).foregroundStyle(DS.text)
                    }
                    Text([item.status, item.currentStep, item.signTime].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                }
                .card(padding: 12)
            }
        }
    }

    private func stuckLabel(_ item: JentechBpm.Item, threshold: Int) -> some View {
        let days = item.daysStuck
        let text: String
        let color: Color
        switch days {
        case nil: text = "—"; color = DS.textSecondary
        case let d? where item.isWorking: text = d >= 1 ? "工作中 \(d) 天" : "今天"; color = DS.textSecondary
        case let d? where d >= threshold: text = "卡 \(d) 天"; color = DS.danger
        case let d? where d >= 1: text = "\(d) 天"; color = DS.text
        default: text = "今天"; color = DS.textSecondary
        }
        return Text(text).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(color)
    }
}

// MARK: - SOP 導覽

/// SOP 導覽：業務流程的 SOP 筆記（前置作業、客戶訂單、出貨作業、立帳請款），可依階段與標籤篩選。
struct JentechSopPage: View {
    @State private var store = JentechStore.shared
    @State private var query = ""
    @State private var stage = "all"

    var body: some View {
        let rows = JentechLogic.sops.filter { (stage == "all" || $0.stage == stage) && JentechLogic.sopMatches($0, query) }
        VStack(spacing: 0) {
            PageToolbar("SOP 導覽", subtitle: "共 \(rows.count) 個", query: $query, searchPlaceholder: "SOP 名稱或標籤（#billing、#va01、#dhl…）", pinnedSearch: true) {
                EmptyView()
            } chips: {
                SegmentedPills(options: [(value: "all", title: "全部")] + JentechLogic.sopStages.map { (value: $0, title: $0) }, selection: $stage)
            }
            ToolScroll {
                FlowLayout(spacing: 6) {
                    ForEach(JentechLogic.sopQuickTags, id: \.self) { tag in
                        Button { query = query == tag ? "" : tag } label: { FilterChip(title: tag, isActive: query == tag) }
                            .buttonStyle(.plain)
                    }
                }
                if rows.isEmpty {
                    EmptyStateView(title: "沒有符合的 SOP")
                } else {
                    ForEach(rows) { sop in SopRow(sop: sop, onTag: { query = $0 }) }
                }
            }
        }
        .background(DS.pane)
        .task { await store.ensureIndex() }
    }
}

struct SopRow: View {
    let sop: JentechSop
    var onTag: (String) -> Void
    @Environment(Workspace.self) private var workspace
    @State private var store = JentechStore.shared

    var body: some View {
        let path = store.path(forNote: sop.file)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if let path { workspace.open(.note(path)) } else { workspace.openLink(sop.file) }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sop.stage).font(.caption).foregroundStyle(DS.textSecondary)
                    Text(sop.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(path == nil ? DS.textSecondary : DS.text)
                        .multilineTextAlignment(.leading)
                    if path == nil {
                        Text("vault 中找不到「\(sop.file)」").font(.caption2).foregroundStyle(DS.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            FlowLayout(spacing: 4) {
                ForEach(sop.tags, id: \.self) { tag in
                    Button { onTag(tag) } label: {
                        Text(tag).font(.caption2.weight(.medium)).foregroundStyle(DS.link)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(DS.control, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .card(padding: 12)
    }
}
