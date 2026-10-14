import SwiftUI

/// App 的主畫面，版面邏輯同 Obsidian：
/// 左邊是功能列＋檔案／搜尋／標籤，中間是分頁，右邊是目前筆記的大綱、反向連結、屬性、關聯圖與 Apple Intelligence。
/// iPad 的左右側欄可以收合、拖曳調整寬度；iPhone 從左右邊緣滑出。
struct WorkspaceView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var store = NotesStore.shared
    @State private var sync = VaultSyncCenter.shared

    var body: some View {
        @Bindable var workspace = workspace
        ZStack {
            MidnightBackground()
            if sizeClass == .compact {
                CompactWorkspace()
            } else {
                RegularWorkspace()
            }
            if workspace.showsPalette {
                CommandPalette()
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    .zIndex(10)
            }
        }
        .animation(.snappy(duration: 0.26), value: workspace.showsPalette)
        .background { KeyboardShortcuts() }
        .fullScreenCover(isPresented: $workspace.showsCamera) {
            LiveScanView(onClose: { workspace.showsCamera = false })
        }
        .sheet(isPresented: $workspace.showsPairing) {
            NavigationStack { PairingView() }
        }
        .sheet(item: newNotebookItem) { item in
            NewNotebookSheet { title, paper, color in
                if let path = try? NotebookFiles.create(in: item.path, title: title, paper: paper, color: color, store: store) {
                    workspace.reveal(path: path)
                    workspace.openNote(path)
                }
            }
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
        .task {
            await store.reload()
            if sync.isConfigured { await sync.syncNow() }
        }
    }

    private var newNotebookItem: Binding<FolderItem?> {
        Binding(
            get: { workspace.newNotebookFolder.map(FolderItem.init(path:)) },
            set: { workspace.newNotebookFolder = $0?.path }
        )
    }
}

private struct FolderItem: Identifiable {
    let path: String
    var id: String { path }
}

// MARK: - iPad：三欄

private struct RegularWorkspace: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 0) {
            Ribbon()
                .padding(.vertical, 12)
                .padding(.leading, 8)
                .padding(.trailing, 2)

            if workspace.isLeftOpen {
                LeftSidebar()
                    .frame(width: workspace.leftWidth)
                    .glass(cornerRadius: 22)
                    .padding(.vertical, 10)
                    .padding(.leading, 6)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                ResizeHandle(
                    width: workspace.leftWidth,
                    range: Workspace.leftWidthRange,
                    grows: .trailing,
                    onChange: { workspace.setLeftWidth($0, persist: $1) },
                    onCollapse: { workspace.setLeftOpen(false) }
                )
            }

            CenterPane(compact: false)
                .padding(.vertical, 10)
                .padding(.leading, workspace.isLeftOpen ? 0 : 6)
                .padding(.trailing, workspace.isRightOpen ? 0 : 10)

            if workspace.isRightOpen {
                ResizeHandle(
                    width: workspace.rightWidth,
                    range: Workspace.rightWidthRange,
                    grows: .leading,
                    onChange: { workspace.setRightWidth($0, persist: $1) },
                    onCollapse: { workspace.setRightOpen(false) }
                )
                RightSidebar()
                    .frame(width: workspace.rightWidth)
                    .glass(cornerRadius: 22)
                    .padding(.vertical, 10)
                    .padding(.trailing, 10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.34), value: workspace.isLeftOpen)
        .animation(.smooth(duration: 0.34), value: workspace.isRightOpen)
    }
}

/// 側欄之間的拖曳把手：拖曳調整寬度，往內拖過頭或點兩下收起。
private struct ResizeHandle: View {
    let width: CGFloat
    let range: ClosedRange<CGFloat>
    /// 側欄往哪個方向變寬：左側欄往右（trailing），右側欄往左（leading）。
    let grows: HorizontalEdge
    let onChange: (CGFloat, Bool) -> Void
    let onCollapse: () -> Void

    @State private var startWidth: CGFloat?
    @State private var isHovering = false

    private var isActive: Bool { startWidth != nil || isHovering }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 12)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(startWidth != nil ? AnyShapeStyle(Midnight.gradient) : AnyShapeStyle(Midnight.textTertiary.opacity(0.5)))
                    .frame(width: isActive ? 3 : 2, height: isActive ? 64 : 28)
                    .opacity(isActive ? 1 : 0.5)
                    .animation(.snappy(duration: 0.2), value: isActive)
            }
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
        grows == .trailing ? translation : -translation
    }

    private func proposed(_ translation: CGFloat) -> CGFloat {
        min(max((startWidth ?? width) + signed(translation), range.lowerBound), range.upperBound)
    }
}

// MARK: - iPhone：中間全螢幕，左右抽屜

private struct CompactWorkspace: View {
    @Environment(Workspace.self) private var workspace
    @State private var showsLeft = false
    @State private var showsRight = false
    @State private var showsTabs = false

    var body: some View {
        ZStack {
            CenterPane(compact: true)
                .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 64) }

            CompactDock(
                onLeft: { setDrawer(left: true) },
                onRight: { setDrawer(right: true) },
                onTabs: { showsTabs = true }
            )
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.keyboard, edges: .bottom)

            if showsLeft || showsRight {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { setDrawer() }
                    .transition(.opacity)
            }
            if showsLeft {
                drawer(edge: .leading) {
                    VStack(spacing: 0) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Ribbon(axis: .horizontal, onAction: { setDrawer() })
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                        Divider().overlay(Midnight.hairline)
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
        .animation(.smooth(duration: 0.32), value: showsLeft)
        .animation(.smooth(duration: 0.32), value: showsRight)
        .sheet(isPresented: $showsTabs) {
            TabSwitcher()
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .onChange(of: workspace.active) { _, _ in setDrawer() }
    }

    private func setDrawer(left: Bool = false, right: Bool = false) {
        showsLeft = left
        showsRight = right
    }

    private func drawer<Content: View>(edge: HorizontalEdge, @ViewBuilder content: () -> Content) -> some View {
        GeometryReader { proxy in
            content()
                .frame(width: min(proxy.size.width * 0.86, 360))
                .frame(maxHeight: .infinity)
                .glass(cornerRadius: 0)
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

    /// 從螢幕左右邊緣往內滑，打開抽屜。
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
            Button("指令面板") { workspace.showsPalette.toggle() }
                .keyboardShortcut("p", modifiers: .command)
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
            Button("搜尋") { workspace.showLeft(.search) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("關聯圖") { workspace.open(.graph) }
                .keyboardShortcut("g", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
