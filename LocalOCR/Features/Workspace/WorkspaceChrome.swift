import SwiftUI

// MARK: - 頂部列（iPad）

/// 黑色頂部列：上方三段與下面的欄位對齊——功能列＋左側欄（開關與 vault 名稱）｜分頁｜右側欄（搜尋與開關）。
struct TopBar: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    workspace.toggleLeft()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(InkIconButtonStyle(size: 36, isActive: workspace.isLeftOpen))
                .frame(width: Workspace.railWidth)
                .help("切換左側欄")
                .accessibilityLabel("切換左側欄")
                if workspace.isLeftOpen {
                    Text(NotesStore.folderTitle(""))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(DS.onInk)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
            }
            .frame(width: Workspace.railWidth + (workspace.isLeftOpen ? workspace.leftWidth : 0), alignment: .leading)

            TabStrip()
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if workspace.isRightOpen {
                    Button {
                        workspace.showsPalette = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                            Text("搜尋筆記或指令")
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.subheadline)
                        .foregroundStyle(DS.onInkDim)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(DS.inkField, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        workspace.showsPalette = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(InkIconButtonStyle(size: 36))
                    .accessibilityLabel("搜尋筆記或指令")
                }
                Button {
                    workspace.toggleRight()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(InkIconButtonStyle(size: 36, isActive: workspace.isRightOpen))
                .help("切換右側欄")
                .accessibilityLabel("切換右側欄")
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(width: workspace.isRightOpen ? workspace.rightWidth : 96, alignment: .trailing)
        }
        .frame(height: 52)
    }
}

/// 分頁：目前的分頁是白色，下緣以弧角接進下面的內容；其他分頁是黑底上的灰字。
struct TabStrip: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        TabPill(tab: tab, isActive: tab == workspace.active)
                            .id(tab.id)
                    }
                    Button {
                        workspace.newTab()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(InkIconButtonStyle(size: 32))
                    .padding(.bottom, 6)
                    .help("新分頁")
                    .accessibilityLabel("新分頁")
                }
                .padding(.horizontal, 16)
                .frame(height: 52, alignment: .bottom)
            }
            .onChange(of: workspace.active) { _, tab in
                withAnimation(.snappy) { proxy.scrollTo(tab.id, anchor: .center) }
            }
        }
    }
}

private struct TabPill: View {
    let tab: WorkspaceTab
    let isActive: Bool

    @Environment(Workspace.self) private var workspace
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(tab.title)
                .font(.subheadline.weight(isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? DS.text : DS.onInkDim)
                .lineLimit(1)
            if isActive || isHovering {
                Button {
                    workspace.close(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isActive ? DS.textSecondary : DS.onInkDim)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("關閉 \(tab.title)")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, isActive || isHovering ? 8 : 14)
        .frame(height: isActive ? 40 : 32)
        .frame(maxWidth: 220)
        .background {
            if isActive {
                UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous)
                    .fill(DS.pane)
                    .overlay(alignment: .bottomLeading) {
                        TabCorner(isLeading: true).fill(DS.pane).frame(width: 10, height: 10).offset(x: -10)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        TabCorner(isLeading: false).fill(DS.pane).frame(width: 10, height: 10).offset(x: 10)
                    }
            } else if isHovering {
                RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous).fill(DS.inkRaised)
            }
        }
        .padding(.bottom, isActive ? 0 : 6)
        .contentShape(Rectangle())
        .onTapGesture { workspace.select(tab) }
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
}

/// 分頁下緣的反向圓角：方塊扣掉以角落為圓心的四分之一圓。
struct TabCorner: Shape {
    let isLeading: Bool

    func path(in rect: CGRect) -> Path {
        let centerX = isLeading ? rect.minX : rect.maxX
        let circle = CGRect(x: centerX - rect.width, y: rect.minY - rect.height, width: rect.width * 2, height: rect.height * 2)
        return Path(rect).subtracting(Path(ellipseIn: circle))
    }
}

// MARK: - 功能列

/// 黑色功能列（iPad 左邊的直條；iPhone 在左側欄上方橫排）。目前的面板是白底黑色圖示。
struct Ribbon: View {
    var axis: Axis = .vertical
    /// iPhone：按了之後關閉側欄。
    var onAction: (() -> Void)?

    @Environment(Workspace.self) private var workspace

    private var isVertical: Bool { axis == .vertical }

    var body: some View {
        let layout = isVertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ForEach(LeftPanelMode.allCases) { mode in
                button(mode.title, mode.systemImage, highlighted: isPanelActive(mode)) {
                    if isVertical {
                        workspace.showLeft(mode)
                    } else {
                        workspace.leftMode = mode
                    }
                }
            }
            separator
            button("關聯圖", WorkspaceTab.graph.systemImage, isActive: workspace.active == .graph) { run { workspace.open(.graph) } }
            button("待辦", WorkspaceTab.tasks.systemImage, isActive: workspace.active == .tasks) { run { workspace.open(.tasks) } }
            button("圖面", WorkspaceTab.drawings.systemImage, isActive: workspace.active == .drawings) { run { workspace.open(.drawings) } }
            separator
            button("掃描文件", WorkspaceTab.scan.systemImage, isActive: workspace.active == .scan) { run { workspace.open(.scan) } }
            button("相機", "camera") { run { workspace.showsCamera = true } }
            button("掃描紀錄", WorkspaceTab.history.systemImage, isActive: workspace.active == .history) { run { workspace.open(.history) } }
            if isVertical {
                Spacer(minLength: 16)
            } else {
                separator
            }
            SyncIndicator()
            button("設定", WorkspaceTab.settings.systemImage, isActive: workspace.active == .settings) { run { workspace.open(.settings) } }
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
            Rectangle().fill(Color.white.opacity(0.14)).frame(width: 20, height: 1).padding(.vertical, 6)
        } else {
            Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 20).padding(.horizontal, 4)
        }
    }

    private func button(_ title: String, _ systemImage: String, isActive: Bool = false, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(InkIconButtonStyle(size: 38, isActive: isActive, highlighted: highlighted))
        .help(title)
        .accessibilityLabel(title)
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
            if sync.isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(sync.lastError == nil ? DS.onInkDim : DS.warning)
            }
        }
        .buttonStyle(InkIconButtonStyle(size: 38))
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var symbol: String {
        if !sync.isConfigured { return "icloud.slash" }
        if sync.lastError != nil { return "exclamationmark.icloud" }
        return "checkmark.icloud"
    }

    private var helpText: String {
        if !sync.isConfigured { return "與 Obsidian 配對" }
        if sync.isSyncing { return sync.progress.map { "下載中 \($0.done)/\($0.total)" } ?? "同步中" }
        if let error = sync.lastError { return error }
        if let date = sync.lastSyncedAt { return "已同步 \(date.formatted(.relative(presentation: .named)))，點一下立即同步" }
        return "立即同步"
    }
}

// MARK: - 中間

struct CenterPane: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack {
            DS.pane
            WorkspaceTabContent(tab: workspace.active)
                .id(workspace.active.id)
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
            AssistantHome()
        case .note(let path):
            NavigationStack {
                NoteDetailRouter(path: path)
                    .background(DS.pane)
                    .toolbarBackground(DS.pane, for: .navigationBar)
            }
        case .folder(let path):
            FolderPage(folder: path)
        case .graph:
            GraphPage()
        case .tasks:
            TasksPage()
        case .drawings:
            DrawingsPage()
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

/// 依筆記種類開啟：手寫筆記或一般 Markdown 筆記。還沒下載的筆記先下載（按需模式），才知道是哪一種。
struct NoteDetailRouter: View {
    let path: String

    @Environment(Workspace.self) private var workspace
    @State private var isDownloaded = false
    @State private var downloadError: String?

    var body: some View {
        if isDownloaded || LocalVault.shared.exists(path) {
            let summary = NotesStore.shared.notes.first { $0.path == path && $0.isLocal }
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
        } else if let downloadError {
            ContentUnavailableView {
                Label("無法下載筆記", systemImage: "icloud.slash")
            } description: {
                Text(downloadError)
            } actions: {
                Button("再試一次") {
                    self.downloadError = nil
                }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            }
        } else {
            ProgressView("下載中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await download() }
        }
    }

    private func download() async {
        do {
            _ = try await VaultSyncCenter.shared.download(path)
            isDownloaded = true
            await NotesStore.shared.reload()
        } catch {
            downloadError = error.localizedDescription
        }
    }
}

// MARK: - iPhone 頂部列與分頁總覽

struct CompactTopBar: View {
    var onLeft: () -> Void
    var onRight: () -> Void
    var onTabs: () -> Void

    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onLeft) {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(InkIconButtonStyle(size: 40, isActive: true))
            .accessibilityLabel("左側欄")
            Text(NotesStore.folderTitle(""))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DS.onInk)
                .lineLimit(1)
                .padding(.leading, 4)
            Spacer(minLength: 8)
            Button {
                workspace.showsPalette = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(InkIconButtonStyle(size: 40, isActive: true))
            .accessibilityLabel("搜尋筆記或指令")
            Button(action: onTabs) {
                Text("\(workspace.tabs.count)")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(DS.onInk)
                    .frame(width: 21, height: 21)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.onInk, lineWidth: 1.6))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("分頁（\(workspace.tabs.count) 個）")
            Button(action: onRight) {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(InkIconButtonStyle(size: 40, isActive: true))
            .accessibilityLabel("右側欄")
        }
        .padding(.horizontal, 6)
        .frame(height: 52)
    }
}

/// iPhone 的分頁總覽。
struct TabSwitcher: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(workspace.tabs) { tab in
                        Button {
                            workspace.select(tab)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: tab.systemImage)
                                        .foregroundStyle(DS.textSecondary)
                                    Spacer()
                                    Button {
                                        workspace.close(tab)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(DS.textSecondary)
                                            .frame(width: 26, height: 26)
                                            .background(DS.control, in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("關閉 \(tab.title)")
                                }
                                Text(tab.title)
                                    .font(.headline)
                                    .foregroundStyle(DS.text)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                            }
                            .card(padding: 14, fill: tab == workspace.active ? DS.Pastel.lavender.color : DS.card, bordered: tab != workspace.active)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(DS.sidebar)
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
