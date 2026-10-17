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
                banner("電腦離線", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
            } else if store.unsentCount > 0 {
                banner("\(store.unsentCount) 個修改待送出", systemImage: "icloud.slash")
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
        .onAppear(perform: consumeRequest)
        .onChange(of: store.openRequest) { _, _ in consumeRequest() }
    }

    /// 從搜尋打開：切到那個分頁，打開案件、切到那一天，或帶入搜尋字。
    private func consumeRequest() {
        guard let request = store.openRequest else { return }
        store.openRequest = nil
        sectionRaw = request.section.rawValue
        if let text = request.query { query = text }
        if let date = request.date { store.focusDate = date }
        if let caseId = request.caseId, !caseId.isEmpty { openCase = JtCaseReference(id: caseId) }
    }

    private var subtitle: String {
        if let manifest = store.manifest, manifest.heartbeatAt > 0 {
            let date = Date(timeIntervalSince1970: manifest.heartbeatAt / 1000)
            return "更新於 \(date.formatted(date: .omitted, time: .shortened))"
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
            EmptyStateView(title: "還沒有與同步伺服器配對")
        } else if !store.hasData {
            if store.notPaired {
                EmptyStateView(title: "電腦的 JT 還沒連上")
            } else if let error = store.lastError {
                EmptyStateView(title: "讀不到 JT 的資料", message: error)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            }
        } else {
            switch section {
            case .gantt:
                JtGanttView(store: store, query: $query) { openCase = JtCaseReference(id: $0) }
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
