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

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                CompactTopBar(
                    onLeft: { setDrawer(left: true) },
                    onRight: { setDrawer(right: true) },
                    onTabs: { showsTabs = true }
                )
                CenterPane()
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous))
                    .ignoresSafeArea(edges: .bottom)
            }

            if showsLeft || showsRight {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { setDrawer() }
                    .transition(.opacity)
            }
            if showsLeft {
                drawer(edge: .leading) {
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
            if showsRight {
                drawer(edge: .trailing) { RightSidebar() }
            }
        }
        .overlay(alignment: .leading) { edgeSwipe(opensLeft: true) }
        .overlay(alignment: .trailing) { edgeSwipe(opensLeft: false) }
        .animation(.smooth(duration: 0.3), value: showsLeft)
        .animation(.smooth(duration: 0.3), value: showsRight)
        .sheet(isPresented: $showsTabs) {
            TabSwitcher()
                .presentationDetents([.medium, .large])
        }
        .onChange(of: workspace.active) { _, _ in setDrawer() }
    }

    private func setDrawer(left: Bool = false, right: Bool = false) {
        showsLeft = left
        showsRight = right
    }

    private func drawer<Content: View>(edge: HorizontalEdge, @ViewBuilder content: () -> Content) -> some View {
        let panel = content()
        return GeometryReader { proxy in
            panel
                .frame(width: min(proxy.size.width * 0.84, 330))
                .frame(maxHeight: .infinity)
                .background(DS.sidebar.ignoresSafeArea())
                .shadow(color: .black.opacity(0.2), radius: 20, x: edge == .leading ? 8 : -8)
                .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
                .gesture(
                    DragGesture(minimumDistance: 16).onEnded { value in
                        let closing = edge == .leading ? value.translation.width < -60 : value.translation.width > 60
                        if closing { setDrawer() }
                    }
                )
        }
        .transition(.move(edge: edge == .leading ? .leading : .trailing))
        .zIndex(5)
    }

    /// 從螢幕左右邊緣往內滑，打開側欄。
    @ViewBuilder
    private func edgeSwipe(opensLeft: Bool) -> some View {
        if !showsLeft && !showsRight {
            Color.clear
                .frame(width: 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 12).onEnded { value in
                        if opensLeft && value.translation.width > 50 { setDrawer(left: true) }
                        if !opensLeft && value.translation.width < -50 { setDrawer(right: true) }
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
