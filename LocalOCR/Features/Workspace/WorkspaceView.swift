import SwiftUI

/// App 的主畫面，版面邏輯同 Obsidian：
/// 黑色頂部列（左側欄開關與 vault 名稱｜分頁｜搜尋與右側欄開關）、黑色功能列，
/// 下面是左側欄（檔案、搜尋、標籤）、中間的分頁內容、右側欄（大綱、連結、屬性、AI；首頁時是待辦）。
/// iPad 的左右側欄可以收合、拖曳調整寬度；iPhone 從左右邊緣滑出。
struct WorkspaceView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var store = NotesStore.shared
    @State private var sync = VaultSyncCenter.shared

    var body: some View {
        @Bindable var workspace = workspace
        ZStack {
            DS.ink.ignoresSafeArea()
            Group {
                if sizeClass == .compact {
                    CompactWorkspace()
                } else {
                    RegularWorkspace()
                }
            }
            // 鍵盤出現時版面完全不動（頂部列、側欄、浮動工具列都不跟著跑）；
            // 筆記編輯器自己依鍵盤高度調整捲動範圍（MarkdownEditor）
            .ignoresSafeArea(.keyboard)
            if workspace.showsPalette {
                CommandPalette()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.18), value: workspace.showsPalette)
        .background { KeyboardShortcuts() }
        .fullScreenCover(isPresented: $workspace.showsCamera) {
            LiveScanView(onClose: { workspace.showsCamera = false })
        }
        .sheet(isPresented: $workspace.showsPairing) {
            NavigationStack { PairingView() }
        }
        .confirmationDialog(
            "刪除「\(workspace.pendingDelete?.title ?? "")」？",
            isPresented: Binding(get: { workspace.pendingDelete != nil }, set: { if !$0 { workspace.pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除筆記", role: .destructive) {
                if let note = workspace.pendingDelete { workspace.delete(note) }
                workspace.pendingDelete = nil
            }
        } message: {
            Text("同步後也會從 Obsidian 與其他裝置刪除。")
        }
        .onChange(of: sync.revision) { _, _ in Task { await store.reload() } }
        .onChange(of: sync.pendingFiles) { _, _ in Task { await store.reload() } }
        // 開著的筆記不會在按需模式整理空間時被移除
        .onChange(of: workspace.tabs, initial: true) { _, tabs in
            sync.openPaths = Set(tabs.compactMap { tab -> String? in
                if case .note(let path) = tab { return path }
                return nil
            })
        }
        .task {
            // 先用上次記下的遠端清單列出檔案，不必等同步完成
            await sync.prepare()
            await VaultIndexStore.shared.load()
            await store.reload()
            if VaultIndexStore.shared.isActive {
                Task { if await VaultIndexStore.shared.refresh() { await store.reload() } }
            }
            if sync.isConfigured { await sync.syncNow() }
        }
    }
}

// MARK: - iPad

private struct RegularWorkspace: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            HStack(spacing: 0) {
                Ribbon()
                    .frame(width: Workspace.railWidth)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                ContentPanel()
            }
        }
        .animation(.smooth(duration: 0.3), value: workspace.isLeftOpen)
        .animation(.smooth(duration: 0.3), value: workspace.isRightOpen)
    }
}

/// 內容面板：左側欄｜中間｜右側欄，上緣圓角接在頂部列下面。
private struct ContentPanel: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 0) {
            if workspace.isLeftOpen {
                LeftSidebar()
                    .frame(width: workspace.leftWidth)
                    .background(DS.sidebar)
                    .overlay(alignment: .trailing) {
                        ResizeHandle(
                            width: workspace.leftWidth,
                            range: Workspace.leftWidthRange,
                            growsTrailing: true,
                            onChange: { workspace.setLeftWidth($0, persist: $1) },
                            onCollapse: { workspace.setLeftOpen(false) }
                        )
                    }
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }
            CenterPane()
            if workspace.isRightOpen {
                RightSidebar()
                    .frame(width: workspace.rightWidth)
                    .background(DS.sidebar)
                    .overlay(alignment: .leading) {
                        ResizeHandle(
                            width: workspace.rightWidth,
                            range: Workspace.rightWidthRange,
                            growsTrailing: false,
                            onChange: { workspace.setRightWidth($0, persist: $1) },
                            onCollapse: { workspace.setRightOpen(false) }
                        )
                    }
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .background(DS.pane)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: DS.radius, topTrailingRadius: DS.radius, style: .continuous))
        .ignoresSafeArea(edges: .bottom)
    }
}

/// 側欄與中間的分隔線：拖曳調整寬度，往內拖過頭或點兩下收起。
private struct ResizeHandle: View {
    let width: CGFloat
    let range: ClosedRange<CGFloat>
    /// 左側欄往右變寬；右側欄往左變寬。
    let growsTrailing: Bool
    let onChange: (CGFloat, Bool) -> Void
    let onCollapse: () -> Void

    @State private var startWidth: CGFloat?
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(startWidth != nil || isHovering ? DS.textTertiary : DS.hairline)
                .frame(width: startWidth != nil ? 2 : 1)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        .offset(x: growsTrailing ? 6 : -6)
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if startWidth == nil { startWidth = width }
                    onChange(proposed(value.translation.width), false)
                }
                .onEnded { value in
                    let raw = (startWidth ?? width) + signed(value.translation.width)
                    startWidth = nil
                    if raw < range.lowerBound - 72 {
                        onCollapse()
                    } else {
                        onChange(proposed(value.translation.width), true)
                    }
                }
        )
        .onTapGesture(count: 2, perform: onCollapse)
        .accessibilityLabel("調整側欄寬度")
        .accessibilityHint("點兩下收起側欄")
    }

    private func signed(_ translation: CGFloat) -> CGFloat {
        growsTrailing ? translation : -translation
    }

    private func proposed(_ translation: CGFloat) -> CGFloat {
        min(max((startWidth ?? width) + signed(translation), range.lowerBound), range.upperBound)
    }
}

// MARK: - iPhone

private struct CompactWorkspace: View {
    @Environment(Workspace.self) private var workspace
    @State private var showsLeft = false
    @State private var showsRight = false
    @State private var showsTabs = false
    /// 拖曳中的側欄：往外拉出為正、往回推為負；nil 表示沒有在拖。
    @State private var leftDrag: CGFloat?
    @State private var rightDrag: CGFloat?

    /// 螢幕邊緣可以拉出側欄的寬度（往右滑回上一頁不從這裡開始）。
    static let edgeWidth: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.84, 330)
            let left = revealed(isOpen: showsLeft, drag: leftDrag, width: width)
            let right = revealed(isOpen: showsRight, drag: rightDrag, width: width)
            ZStack {
                VStack(spacing: 0) {
                    CompactTopBar(
                        onLeft: { setDrawer(left: true) },
                        onRight: { setDrawer(right: true) },
                        onTabs: { showsTabs = true }
                    )
                    CenterPane(allowsBackSwipe: left == 0 && right == 0, edgeExclusion: Self.edgeWidth)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous))
                        .ignoresSafeArea(edges: .bottom)
                }

                if left > 0 || right > 0 {
                    Color.black.opacity(0.4 * max(left, right) / width)
                        .ignoresSafeArea()
                        .onTapGesture { setDrawer() }
                        .transition(.opacity)
                }
                if left > 0 {
                    drawer(edge: .leading, width: width, revealed: left) {
                        VStack(spacing: 0) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                Ribbon(axis: .horizontal, onAction: { setDrawer() })
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 8)
                            }
                            .background(DS.ink.ignoresSafeArea(edges: .top))
                            LeftSidebar()
                        }
                    }
                }
                if right > 0 {
                    drawer(edge: .trailing, width: width, revealed: right) { RightSidebar() }
                }
            }
            .overlay(alignment: .leading) { edgeSwipe(opensLeft: true, width: width) }
            .overlay(alignment: .trailing) { edgeSwipe(opensLeft: false, width: width) }
        }
        .sheet(isPresented: $showsTabs) {
            TabSwitcher()
                .presentationDetents([.medium, .large])
        }
        .onChange(of: workspace.active) { _, _ in setDrawer() }
    }

    /// 側欄露出多少（0 = 收起，width = 完全打開）。
    private func revealed(isOpen: Bool, drag: CGFloat?, width: CGFloat) -> CGFloat {
        min(max((isOpen ? width : 0) + (drag ?? 0), 0), width)
    }

    private func setDrawer(left: Bool = false, right: Bool = false) {
        withAnimation(.smooth(duration: 0.3)) {
            showsLeft = left
            showsRight = right
            leftDrag = nil
            rightDrag = nil
        }
    }

    private func setDrag(_ value: CGFloat?, left: Bool) {
        if left { leftDrag = value } else { rightDrag = value }
    }

    /// 側欄跟著手指：打開時往外推回去就收起（推超過三成、或推得快）。
    private func drawer<Content: View>(edge: HorizontalEdge, width: CGFloat, revealed: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        let isLeft = edge == .leading
        return content()
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(DS.sidebar.ignoresSafeArea())
            .shadow(color: .black.opacity(0.2), radius: 20, x: isLeft ? 8 : -8)
            .offset(x: isLeft ? revealed - width : width - revealed)
            .frame(maxWidth: .infinity, alignment: isLeft ? .leading : .trailing)
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .onChanged { value in
                        // 上下捲動側欄的清單時不動
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        let inward = isLeft ? value.translation.width : -value.translation.width
                        setDrag(min(0, inward), left: isLeft)
                    }
                    .onEnded { value in
                        let inward = isLeft ? value.translation.width : -value.translation.width
                        let predicted = isLeft ? value.predictedEndTranslation.width : -value.predictedEndTranslation.width
                        let horizontal = abs(value.translation.width) > abs(value.translation.height)
                        if horizontal, inward < -width * 0.3 || predicted < -width * 0.5 {
                            setDrawer()
                        } else {
                            withAnimation(.smooth(duration: 0.25)) { setDrag(nil, left: isLeft) }
                        }
                    }
            )
            .transition(.move(edge: isLeft ? .leading : .trailing))
            .zIndex(5)
    }

    /// 從螢幕左右邊緣往內滑：側欄跟著手指拉出來，放開時拉超過三成（或滑得快）就打開。
    @ViewBuilder
    private func edgeSwipe(opensLeft: Bool, width: CGFloat) -> some View {
        if !showsLeft && !showsRight {
            Color.clear
                .frame(width: Self.edgeWidth)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .global)
                        .onChanged { value in
                            let outward = opensLeft ? value.translation.width : -value.translation.width
                            setDrag(max(0, outward), left: opensLeft)
                        }
                        .onEnded { value in
                            let outward = opensLeft ? value.translation.width : -value.translation.width
                            let predicted = opensLeft ? value.predictedEndTranslation.width : -value.predictedEndTranslation.width
                            if outward > width * 0.3 || predicted > width * 0.55 {
                                setDrawer(left: opensLeft, right: !opensLeft)
                            } else {
                                setDrawer()
                            }
                        }
                )
        }
    }
}

// MARK: - 鍵盤快速鍵（iPad 外接鍵盤；按住 ⌘ 會列出）

private struct KeyboardShortcuts: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack {
            Button("搜尋筆記或指令") { workspace.showsPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
            Button("快速開啟筆記") { workspace.showsPalette = true }
                .keyboardShortcut("o", modifiers: .command)
            Button("新增筆記") { workspace.newTextNote() }
                .keyboardShortcut("n", modifiers: .command)
            Button("新分頁") { workspace.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("關閉分頁") { workspace.closeActive() }
                .keyboardShortcut("w", modifiers: .command)
            Button("下一個分頁") { workspace.selectAdjacentTab(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("上一個分頁") { workspace.selectAdjacentTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("切換左側欄") { workspace.toggleLeft() }
                .keyboardShortcut("[", modifiers: .command)
            Button("切換右側欄") { workspace.toggleRight() }
                .keyboardShortcut("]", modifiers: .command)
            Button("搜尋內文") { workspace.showLeft(.search) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
