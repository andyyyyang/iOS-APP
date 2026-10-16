import SwiftUI

/// App 的主畫面外框（ContentView 與鍵盤版面測試共用）：鍵盤出現時整個工作區不動。
struct WorkspaceRoot: View {
    var body: some View {
        WorkspaceView()
            .ignoresSafeArea(.keyboard)
    }
}

/// App 的主畫面，版面邏輯同 Obsidian：
/// 黑色頂部列（左側欄開關與 vault 名稱｜分頁｜搜尋與右側欄開關）、黑色功能列，
/// 下面是左側欄（檔案、搜尋、標籤）、中間的分頁內容、右側欄（大綱、連結、屬性、AI；首頁時是待辦）。
/// iPad 的左右側欄可以收合、拖曳調整寬度；iPhone 從左右邊緣滑出。
struct WorkspaceView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var store = NotesStore.shared
    @State private var sync = VaultSyncCenter.shared
    @AppStorage(KeyboardDiagnosticsLabel.key) private var showsKeyboardDiagnostics = false
    @Environment(\.scenePhase) private var scenePhase

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
            if workspace.isFullScreen {
                FullScreenExitHandle()
                    .zIndex(15)
                    .transition(.opacity)
            }
            if showsKeyboardDiagnostics {
                KeyboardDiagnosticsOverlay()
                    .frame(width: 290, height: 190)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 64)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
            if workspace.showsPalette {
                CommandPalette()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .ignoresSafeArea(.keyboard)
        .toast($workspace.toast)
        .persistentSystemOverlays(workspace.isFullScreen ? .hidden : .automatic)
        .animation(.easeOut(duration: 0.18), value: workspace.showsPalette)
        .animation(.smooth(duration: 0.3), value: workspace.isFullScreen)
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
        // 同步會刪除很多檔案時先停下來問（以前要到設定按「仍要同步」，同步會一直失敗）
        .alert(
            "這次同步會刪除 \(sync.blockedDeletion?.total ?? 0) 個檔案",
            isPresented: Binding(get: { sync.asksAboutDeletion }, set: { if !$0 { sync.asksAboutDeletion = false } })
        ) {
            Button("取消", role: .cancel) { sync.resolveMassDeletion(proceed: false) }
            Button("仍要同步", role: .destructive) { sync.resolveMassDeletion(proceed: true) }
        } message: {
            Text(massDeletionMessage)
        }
        // 在其他地方（Obsidian）搬移或改名的筆記：開著的分頁跟著換到新位置
        .onChange(of: sync.lastReport?.moves ?? []) { _, moves in
            for move in moves { workspace.renameNote(from: move.from, to: move.to) }
        }
        .onChange(of: sync.revision) { _, _ in
            Task {
                await store.reload()
                workspace.followMovedNotes()
            }
        }
        .onChange(of: sync.pendingFiles) { _, _ in
            Task {
                await store.reload()
                workspace.followMovedNotes()
            }
        }
        // 開啟日誌筆記本時右側欄切到「日誌」；開啟 Markdown 筆記時切到這則筆記的手寫備忘（手寫筆記本身不必）
        .onChange(of: workspace.activeNotePath, initial: true) { _, path in
            guard let path else { return }
            let summary = summary(of: path)
            if summary?.isJournal == true {
                workspace.rightMode = .journal
                return
            }
            if workspace.rightMode == .journal { workspace.rightMode = .outline }
            guard NotesSettings.autoInkMemo, summary?.isNotebook != true else { return }
            workspace.rightMode = .memo
        }
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
            // 背景整理其他日誌與統整（一件一件做，寫字時暫停）
            JournalOrganizer.shared.sweep()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { JournalOrganizer.shared.sweep() }
        }
    }

    private func summary(of path: String) -> NoteSummary? {
        if let note = store.notes.first(where: { $0.path == path }) { return note }
        guard let text = LocalVault.shared.readText(path) else { return nil }
        return NotesStore.summarize(path: path, mtime: Date(), text: text)
    }

    private var massDeletionMessage: String {
        guard let deletion = sync.blockedDeletion else { return "" }
        var parts: [String] = []
        if deletion.local > 0 { parts.append("這台裝置上 \(deletion.local) 個（Obsidian 或其他裝置已經刪除）") }
        if deletion.remote > 0 { parts.append("雲端 \(deletion.remote) 個（這台裝置上已經刪除）") }
        return parts.joined(separator: "、") + "。為了安全先停下來了；確定是你刪除的就按「仍要同步」。搬移到其他資料夾的檔案不算刪除。"
    }
}

// MARK: - iPad

private struct RegularWorkspace: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            // 全螢幕：只留內容（側欄可以從內容或指令打開）
            if !workspace.isFullScreen {
                TopBar()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(spacing: 0) {
                if !workspace.isFullScreen {
                    Ribbon()
                        .frame(width: Workspace.railWidth)
                        .padding(.top, 6)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
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
                    if !workspace.isFullScreen {
                        CompactTopBar(
                            onLeft: { setDrawer(left: true) },
                            onRight: { setDrawer(right: true) },
                            onTabs: { showsTabs = true }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
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
        // 內容要求打開右側欄（例如日誌的「日誌」按鈕）
        .onChange(of: workspace.rightDrawerRequest) { _, _ in setDrawer(right: true) }
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
            Button(workspace.isFullScreen ? "結束全螢幕" : "全螢幕") { workspace.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [.command, .control])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - 全螢幕

/// 全螢幕時畫面最上方的小橫條：點一下（或往下拉）離開全螢幕。放在狀態列或動態島下方，不蓋住內容的按鈕。
private struct FullScreenExitHandle: View {
    @Environment(Workspace.self) private var workspace
    @State private var windowTop: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            Button {
                workspace.setFullScreen(false)
            } label: {
                Capsule()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 44, height: 5)
                    .frame(width: 88, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(x: proxy.size.width / 2, y: handleY)
            .simultaneousGesture(DragGesture(minimumDistance: 8).onEnded { value in
                if value.translation.height > 12 { workspace.setFullScreen(false) }
            })
            .accessibilityLabel("結束全螢幕")
        }
        .ignoresSafeArea()
        .background(WindowInsetsReader { windowTop = $0.top })
    }

    /// 有動態島或瀏海的 iPhone：在它下方；有狀態列（iPad）：在狀態列中間；沒有（台前調度的小視窗）：視窗頂端。
    private var handleY: CGFloat {
        if windowTop > 40 { return windowTop - 6 }
        if windowTop > 10 { return windowTop / 2 }
        return 10
    }
}
