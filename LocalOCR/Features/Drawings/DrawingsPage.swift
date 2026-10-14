import SwiftUI

/// 圖面瀏覽器（移植自 Obsidian 插件「Jentech 圖面瀏覽器」）：依客戶瀏覽機種工程圖與各站產能。
/// 圖面可縮放／平移／旋轉與多版本切換；產能清單以 PO LIST 為準並標出與 catalog 的差異。
/// 所有資料在線上讀取，圖面打開時才取得。
struct DrawingsPage: View {
    enum Mode: String, CaseIterable, Identifiable {
        case drawings = "圖面瀏覽"
        case capacity = "產能清單"

        var id: String { rawValue }

        var shortTitle: String {
            switch self {
            case .drawings: return "瀏覽"
            case .capacity: return "產能"
            }
        }
    }

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var library = DrawingsLibrary.shared
    @State private var mode: Mode = .drawings
    @State private var selectedID: String?
    @State private var filter = DrawingListFilter()
    @State private var specModel: DrawingModel?
    @State private var compactPath: [String] = []
    @State private var capacity = CapacityTableModel()

    private var isCompact: Bool { sizeClass == .compact }
    private var selected: DrawingModel? { library.models.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
        .background(DS.pane)
        .task {
            await library.ensureLoaded()
            selectInitial()
        }
        .onChange(of: library.scope) {
            selectInitial()
        }
        .sheet(item: $specModel) { model in
            DrawingSpecSheet(model: model)
        }
    }

    // MARK: 上方（最多兩列：標題列＋膠囊列，搜尋按放大鏡才出現）

    private var subtitle: String {
        if library.isLoading { return library.loadedAt == nil ? "掃描中…" : "重新掃描中…" }
        if let error = library.error, library.models.isEmpty { return error }
        let models = library.models
        guard !models.isEmpty else { return "" }
        switch mode {
        case .drawings:
            let visible = filter.apply(to: models, library: library).count
            return visible == models.count ? "\(models.count) 款 · \(models.reduce(0) { $0 + $1.drawings.count }) 張" : "\(visible)/\(models.count) 款"
        case .capacity:
            return capacity.summary(compact: isCompact)
        }
    }

    private var topBar: some View {
        PageToolbar(
            "圖面",
            subtitle: subtitle,
            query: mode == .drawings ? $filter.query : $capacity.query,
            searchPlaceholder: mode == .drawings ? "搜尋機種、SID、SAP、原廠圖號、PO 號" : "搜尋圖號、SID、PO 號、機台、站別產能"
        ) {
            SegmentedPills(options: Mode.allCases.map { (value: $0, title: isCompact ? $0.shortTitle : $0.rawValue) }, selection: $mode)
        } chips: {
            scopeMenu
            switch mode {
            case .drawings:
                DrawingFilterChips(filter: $filter)
            case .capacity:
                ToggleChip(title: "僅不一致", isOn: $capacity.onlyDiff)
                ToggleChip(title: "歷史機種", isOn: $capacity.showArchived)
                ToggleChip(title: "CNC 產能", isOn: $capacity.showCNC)
                Menu {
                    Button { capacity.export(toVault: false) } label: { Label("分享 CSV（Excel 可開）", systemImage: "square.and.arrow.up") }
                    Button { capacity.export(toVault: true) } label: { Label("存到 vault 的 scratch 資料夾", systemImage: "tray.and.arrow.down") }
                    Divider()
                    if let meta = library.snapshot.capacityMeta {
                        Section("資料來源") {
                            Text(capacity.sourceDescription(meta))
                        }
                    }
                    Text("「重新抽取」「寫回 catalog」要在電腦的 Obsidian 執行（需要 Python）")
                } label: {
                    FilterChip(title: "匯出", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func rescan() async {
        await DrawingFileCache.shared.removeAll()
        await library.reload()
        selectInitial()
    }

    private var scopeMenu: some View {
        Menu {
            let all = library.scopes.filter { $0.kind == .all }
            let ships = library.scopes.filter { $0.kind == .ship }
            let ends = library.scopes.filter { $0.kind == .end }
            ForEach(all) { scope in scopeButton(scope) }
            if !ships.isEmpty {
                Section("OSAT（PO 開給我們的封裝廠）") {
                    ForEach(ships) { scope in scopeButton(scope) }
                }
            }
            if !ends.isEmpty {
                Section("END USER（晶片端）") {
                    ForEach(ends) { scope in scopeButton(scope) }
                }
            }
            Divider()
            Button {
                Task { await rescan() }
            } label: {
                Label("重新掃描", systemImage: "arrow.clockwise")
            }
            .disabled(library.isLoading)
        } label: {
            FilterChip(title: library.scopeLabel, isActive: library.scope != "all", systemImage: "building.2")
        }
        .accessibilityLabel("客戶")
    }

    private func scopeButton(_ scope: DrawingScope) -> some View {
        Button {
            library.scope = scope.id
        } label: {
            if library.scope == scope.id {
                Label("\(scope.label)（\(scope.count)）", systemImage: "checkmark")
            } else {
                Text("\(scope.label)（\(scope.count)）")
            }
        }
    }

    // MARK: 內容

    @ViewBuilder
    private var content: some View {
        if library.loadedAt == nil && library.isLoading {
            ProgressView("掃描中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch mode {
            case .drawings:
                if isCompact { compactBrowser } else { regularBrowser }
            case .capacity:
                CapacityTableView(model: capacity) { model in
                    focus(model)
                }
            }
        }
    }

    private var regularBrowser: some View {
        HStack(spacing: 12) {
            DrawingModelList(models: library.models, selectedID: selectedID, filter: filter, onSelect: select, onSpec: { specModel = $0 }, onRefresh: rescan)
                .frame(width: 340)
            DrawingViewer(model: selected) { specModel = $0 }
                .clipShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1))
        }
        .padding(.leading, 12)
        .padding(.trailing, 24)
        .padding(.bottom, 16)
    }

    private var compactBrowser: some View {
        NavigationStack(path: $compactPath) {
            DrawingModelList(models: library.models, selectedID: selectedID, filter: filter, onSelect: { model in
                select(model)
                compactPath = [model.id]
            }, onSpec: { specModel = $0 }, onRefresh: rescan)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                DrawingViewer(model: library.models.first { $0.id == id }) { specModel = $0 }
                    .navigationTitle(library.models.first { $0.id == id }?.dwg ?? "")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(DS.pane, for: .navigationBar)
            }
        }
    }

    // MARK: 選取

    private func select(_ model: DrawingModel) {
        selectedID = model.id
        library.setLastModel(model.dwg, in: library.scope)
    }

    /// 產能清單點圖號：切到圖面瀏覽並選取這個機種。
    private func focus(_ model: DrawingModel) {
        if !library.models.contains(where: { $0.id == model.id }) {
            library.scope = "all"
        }
        mode = .drawings
        select(model)
        if isCompact { compactPath = [model.id] }
    }

    /// 打開或換範圍時：上次看的機種，其次第一個有圖面的機種。
    private func selectInitial() {
        let models = library.models
        if let selectedID, models.contains(where: { $0.id == selectedID }) { return }
        let withDrawings = models.filter { !$0.drawings.isEmpty }
        if let last = library.lastModel(in: library.scope), let model = withDrawings.first(where: { $0.dwg == last }) {
            selectedID = model.id
        } else {
            selectedID = (withDrawings.first ?? models.first)?.id
        }
    }
}
