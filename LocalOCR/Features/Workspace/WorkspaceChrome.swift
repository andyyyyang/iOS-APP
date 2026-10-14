import SwiftUI

// MARK: - 功能列（最左邊的直條；iPhone 在抽屜上方橫排）

struct Ribbon: View {
    var axis: Axis = .vertical
    /// iPhone：按了之後關閉抽屜。
    var onAction: (() -> Void)?

    @Environment(Workspace.self) private var workspace

    private var isVertical: Bool { axis == .vertical }

    var body: some View {
        let layout = isVertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            if isVertical {
                BrandMark()
                    .padding(.bottom, 12)
            }
            ForEach(LeftPanelMode.allCases) { mode in
                button(mode.title, mode.systemImage, isActive: isPanelActive(mode)) {
                    if isVertical {
                        workspace.showLeft(mode)
                    } else {
                        workspace.leftMode = mode
                    }
                }
            }
            separator
            button("關聯圖", "circle.hexagongrid", isActive: workspace.active == .graph) { run { workspace.open(.graph) } }
            button("待辦", "checklist", isActive: workspace.active == .tasks) { run { workspace.open(.tasks) } }
            button("指令面板", "command") { run { workspace.showsPalette = true } }
            separator
            button("掃描文件", "doc.viewfinder", isActive: workspace.active == .scan) { run { workspace.open(.scan) } }
            button("相機", "camera") { run { workspace.showsCamera = true } }
            button("掃描紀錄", "clock.arrow.circlepath", isActive: workspace.active == .history) { run { workspace.open(.history) } }
            if isVertical {
                Spacer(minLength: 16)
            } else {
                separator
            }
            SyncIndicator()
            button("設定", "gearshape", isActive: workspace.active == .settings) { run { workspace.open(.settings) } }
        }
    }

    private func isPanelActive(_ mode: LeftPanelMode) -> Bool {
        isVertical ? workspace.isLeftOpen && workspace.leftMode == mode : workspace.leftMode == mode
    }

    private func run(_ action: () -> Void) {
        action()
        onAction?()
    }

    @ViewBuilder
    private var separator: some View {
        if isVertical {
            Capsule().fill(Midnight.hairline).frame(width: 18, height: 1).padding(.vertical, 6)
        } else {
            Capsule().fill(Midnight.hairline).frame(width: 1, height: 18).padding(.horizontal, 4)
        }
    }

    private func button(_ title: String, _ systemImage: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .overlay(alignment: .leading) {
                    if isActive && isVertical {
                        Capsule()
                            .fill(Midnight.gradient)
                            .frame(width: 3, height: 18)
                            .glow(radius: 6)
                            .offset(x: -14)
                    }
                }
        }
        .buttonStyle(GlassIconButtonStyle(size: 38, isActive: isActive))
        .hoverEffect(.highlight)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// 品牌標誌：漸層方塊中的光點。
struct BrandMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(Midnight.gradient)
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
        .glow(radius: 14, opacity: 0.6)
        .accessibilityLabel("LocalOCR")
    }
}

/// 同步狀態：同步中、錯誤、已同步、尚未配對（點一下配對或立即同步）。
struct SyncIndicator: View {
    @Environment(Workspace.self) private var workspace
    @State private var sync = VaultSyncCenter.shared

    var body: some View {
        Button {
            if sync.isConfigured {
                Task { await sync.syncNow() }
            } else {
                workspace.showsPairing = true
            }
        } label: {
            ZStack {
                if let progress = sync.progress, progress.total > 0 {
                    Circle()
                        .trim(from: 0, to: CGFloat(progress.done) / CGFloat(progress.total))
                        .stroke(Midnight.gradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 30, height: 30)
                }
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .symbolEffect(.pulse, isActive: sync.isSyncing)
            }
        }
        .buttonStyle(GlassIconButtonStyle(size: 38))
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var symbol: String {
        if !sync.isConfigured { return "qrcode.viewfinder" }
        if sync.isSyncing { return "arrow.triangle.2.circlepath" }
        if sync.lastError != nil { return "exclamationmark.icloud" }
        return "checkmark.icloud"
    }

    private var color: Color {
        if sync.lastError != nil && !sync.isSyncing { return Midnight.warning }
        if sync.isSyncing { return Midnight.accent }
        return Midnight.textSecondary
    }

    private var helpText: String {
        if !sync.isConfigured { return "與 Obsidian 配對" }
        if sync.isSyncing { return sync.progress.map { "下載中 \($0.done)/\($0.total)" } ?? "同步中" }
        if let error = sync.lastError { return error }
        if let date = sync.lastSyncedAt { return "已同步 \(date.formatted(.relative(presentation: .named)))，點一下立即同步" }
        return "立即同步"
    }
}

// MARK: - 分頁列

struct TabStrip: View {
    @Environment(Workspace.self) private var workspace
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 6) {
            Button {
                workspace.toggleLeft()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(GlassIconButtonStyle(size: 34, isActive: workspace.isLeftOpen))
            .help("切換左側欄（⌘[）")
            .accessibilityLabel("切換左側欄")

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(workspace.tabs) { tab in
                            TabPill(tab: tab, isActive: tab == workspace.active, namespace: selection)
                                .id(tab.id)
                        }
                        Button {
                            workspace.newTab()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(GlassIconButtonStyle(size: 30))
                        .help("新分頁（⌘T）")
                        .accessibilityLabel("新分頁")
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: workspace.active) { _, tab in
                    withAnimation(.snappy) { proxy.scrollTo(tab.id, anchor: .center) }
                }
            }

            Button {
                workspace.showsPalette = true
            } label: {
                Image(systemName: "command")
            }
            .buttonStyle(GlassIconButtonStyle(size: 34))
            .help("指令面板（⌘P）")
            .accessibilityLabel("指令面板")

            Button {
                workspace.toggleRight()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(GlassIconButtonStyle(size: 34, isActive: workspace.isRightOpen))
            .help("切換右側欄（⌘]）")
            .accessibilityLabel("切換右側欄")
        }
        .frame(height: 38)
    }
}

private struct TabPill: View {
    let tab: WorkspaceTab
    let isActive: Bool
    let namespace: Namespace.ID

    @Environment(Workspace.self) private var workspace
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? AnyShapeStyle(Midnight.textGradient) : AnyShapeStyle(Midnight.textTertiary))
            Text(tab.title)
                .font(.system(.subheadline, design: .rounded).weight(isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? Midnight.text : Midnight.textSecondary)
                .lineLimit(1)
            Button {
                workspace.close(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Midnight.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(Midnight.raised, in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(isActive || isHovering ? 1 : 0)
            .accessibilityLabel("關閉 \(tab.title)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 32)
        .frame(maxWidth: 230)
        .background {
            if isActive {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule(style: .continuous).fill(Midnight.surface))
                    .overlay(Capsule(style: .continuous).strokeBorder(Midnight.gradient, lineWidth: 1).opacity(0.55))
                    .matchedGeometryEffect(id: "active-tab", in: namespace)
            } else if isHovering {
                Capsule(style: .continuous).fill(Midnight.raised)
            }
        }
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.snappy(duration: 0.3)) { workspace.select(tab) } }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button {
                workspace.close(tab)
            } label: {
                Label("關閉分頁", systemImage: "xmark")
            }
            if let path = tab.notePath, let url = NotesSettings.obsidianURL(for: path) {
                Link(destination: url) {
                    Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private var icon: String {
        guard let path = tab.notePath else { return tab.systemImage }
        return NotesStore.shared.notes.first(where: { $0.path == path })?.isNotebook == true ? "pencil.and.scribble" : tab.systemImage
    }
}

// MARK: - 中間

struct CenterPane: View {
    let compact: Bool

    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 8) {
            if !compact {
                TabStrip()
            }
            ZStack {
                PaneBackdrop()
                WorkspaceTabContent(tab: workspace.active)
                    .id(workspace.active.id)
                    .transition(.opacity)
            }
            .clipShape(RoundedRectangle(cornerRadius: compact ? 0 : 22, style: .continuous))
            .overlay {
                if !compact {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Midnight.hairline, lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(compact ? 0 : 0.35), radius: 30, y: 16)
            .animation(.easeOut(duration: 0.18), value: workspace.active)
        }
    }
}

/// 分頁的內容。
struct WorkspaceTabContent: View {
    let tab: WorkspaceTab

    @Environment(Workspace.self) private var workspace

    var body: some View {
        switch tab {
        case .start:
            StartPage()
        case .note(let path):
            NavigationStack {
                NoteDetailRouter(path: path)
                    .background(PaneBackdrop())
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
        case .folder(let path):
            FolderPage(folder: path)
        case .graph:
            GraphPage()
        case .tasks:
            TasksPage()
        case .scan:
            ScanView(selectedTab: toolSelection)
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        }
    }

    /// 掃描畫面的「切換到其他工具」改為在工作區開啟。
    private var toolSelection: Binding<AppTab> {
        Binding(
            get: { .scan },
            set: { tab in
                switch tab {
                case .live: workspace.showsCamera = true
                case .history: workspace.open(.history)
                case .settings: workspace.open(.settings)
                case .notes: workspace.newTab()
                case .scan: break
                }
            }
        )
    }
}

/// 依筆記種類開啟：手寫筆記本或一般 Markdown 筆記。
struct NoteDetailRouter: View {
    let path: String

    @Environment(Workspace.self) private var workspace

    var body: some View {
        let summary = NotesStore.shared.notes.first { $0.path == path }
            ?? NotesStore.summarize(path: path, mtime: Date(), text: LocalVault.shared.readText(path) ?? "")
        if let id = summary.notebookID {
            NotebookEditorView(initialPath: path, notebookID: id, onPathChange: { workspace.renameNote(from: path, to: $0) })
        } else {
            NoteView(
                initialPath: path,
                onPathChange: { workspace.renameNote(from: path, to: $0) },
                onOpenNote: { workspace.openLink($0) }
            )
        }
    }
}

// MARK: - iPhone 底部的浮動列

struct CompactDock: View {
    var onLeft: () -> Void
    var onRight: () -> Void
    var onTabs: () -> Void

    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 4) {
            dockButton("檔案", "sidebar.left", action: onLeft)
            dockButton("搜尋與指令", "magnifyingglass") { workspace.showsPalette = true }
            Button {
                workspace.newTextNote()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(Midnight.gradient, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
                    .glow(radius: 14, opacity: 0.55)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新增筆記")
            .contextMenu {
                Button { workspace.newTextNote() } label: { Label("新增筆記", systemImage: "square.and.pencil") }
                Button { workspace.requestNewNotebook() } label: { Label("新增手寫筆記本", systemImage: "pencil.and.scribble") }
                Button { workspace.newTaskNote() } label: { Label("新增待辦清單", systemImage: "checklist") }
                Button { workspace.open(.scan) } label: { Label("掃描文件", systemImage: "doc.viewfinder") }
            }
            Button(action: onTabs) {
                Text("\(workspace.tabs.count)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Midnight.text)
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Midnight.text, lineWidth: 1.6))
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("分頁（\(workspace.tabs.count) 個）")
            dockButton("大綱與資訊", "sidebar.right", action: onRight)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glass(cornerRadius: 34)
        .padding(.bottom, 6)
    }

    private func dockButton(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(GlassIconButtonStyle(size: 46))
        .accessibilityLabel(title)
    }
}

/// iPhone 的分頁總覽。
struct TabSwitcher: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(workspace.tabs) { tab in
                        Button {
                            workspace.select(tab)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: tab.systemImage)
                                        .gradientForeground()
                                    Spacer()
                                    Button {
                                        workspace.close(tab)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(Midnight.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("關閉 \(tab.title)")
                                }
                                Text(tab.title)
                                    .font(.system(.headline, design: .rounded))
                                    .foregroundStyle(Midnight.text)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                            }
                            .glassCard(padding: 14, cornerRadius: Midnight.radiusM + 2)
                            .overlay {
                                if tab == workspace.active {
                                    RoundedRectangle(cornerRadius: Midnight.radiusM + 2, style: .continuous)
                                        .strokeBorder(Midnight.gradient, lineWidth: 1.5)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("分頁")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("新分頁") {
                        workspace.newTab()
                        dismiss()
                    }
                }
            }
        }
    }
}
