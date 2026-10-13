import SwiftUI
import UIKit

/// 筆記庫中的一個位置（側邊欄的項目）。
enum NotesSection: Hashable {
    case home
    case all
    case notebooks
    case tasks
    case folder(String)
    case tag(String)
}

/// 推入的頁面。
enum NoteRoute: Hashable {
    case note(String)
}

/// 筆記 App 的主畫面：左邊是筆記庫（首頁、所有筆記、資料夾樹／標籤與數量），右邊是首頁、資料夾或筆記。
/// 打開筆記時自動收起側邊欄，整個畫面用來書寫；iPhone 會變成一層層進入。
struct NotesHomeView: View {
    @Binding var selectedTab: AppTab

    @State private var store = NotesStore.shared
    @State private var sync = VaultSyncCenter.shared
    @State private var section: NotesSection? = .home
    @State private var path: [NoteRoute] = []
    @State private var sidebarMode = SidebarMode.folders
    @State private var searchText = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var compactColumn = NavigationSplitViewColumn.detail
    @State private var showsNewNotebook = false
    @State private var showsNewFolder = false
    @State private var newFolderName = ""
    @State private var showsPairing = false
    @State private var pendingDelete: NoteSummary?

    enum SidebarMode: String, CaseIterable, Identifiable {
        case folders = "資料夾"
        case tags = "標籤"

        var id: Self { self }
    }

    /// 新筆記放的位置：目前所在的資料夾，否則是設定中的位置（預設是 vault 最上層）。
    private var currentFolder: String {
        if case .folder(let folder) = section { return folder }
        return NotesSettings.defaultFolder
    }

    private var newFolderLocation: String {
        if case .folder(let folder) = section, !folder.isEmpty { return "建立在「\(folder)」中" }
        return "建立在最上層"
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            sidebar
        } detail: {
            NavigationStack(path: $path) {
                root
                    .navigationDestination(for: NoteRoute.self) { route in
                        switch route {
                        case .note(let notePath):
                            NoteDetailRouter(path: notePath, onPathChange: { replaceTop(with: $0) }, onOpenNote: openLinkedNote)
                        }
                    }
            }
        }
        .sheet(isPresented: $showsNewNotebook) {
            NewNotebookSheet { title, paper, color in
                if let notePath = try? NotebookFiles.create(in: currentFolder, title: title, paper: paper, color: color, store: store) {
                    open(notePath)
                }
            }
        }
        .sheet(isPresented: $showsPairing) {
            NavigationStack { PairingView() }
        }
        .alert("新增資料夾", isPresented: $showsNewFolder) {
            TextField("名稱", text: $newFolderName)
            Button("取消", role: .cancel) {}
            Button("建立") { createFolder() }
        } message: {
            Text(newFolderLocation)
        }
        .confirmationDialog(
            "刪除「\(pendingDelete?.title ?? "")」？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除筆記", role: .destructive) {
                if let note = pendingDelete { try? store.delete(note.path) }
                pendingDelete = nil
            }
        } message: {
            Text("同步後也會從 Obsidian 刪除。")
        }
        .onChange(of: section) { _, _ in
            path.removeAll()
            compactColumn = .detail
        }
        .onChange(of: path.isEmpty) { _, isEmpty in
            // 打開筆記時收起側邊欄，回到清單時再打開
            withAnimation { columnVisibility = isEmpty ? .all : .detailOnly }
        }
        .onChange(of: sync.revision) { _, _ in Task { await store.reload() } }
        .onChange(of: sync.pendingFiles) { _, _ in Task { await store.reload() } }
        .task {
            await store.reload()
            if sync.isConfigured { await sync.syncNow() }
        }
    }

    // MARK: - 側邊欄（筆記庫）

    private var sidebar: some View {
        List(selection: $section) {
            Section {
                sidebarRow("首頁", systemImage: "house", count: nil).tag(NotesSection.home)
                sidebarRow("所有筆記", systemImage: "note.text", count: store.notes.count).tag(NotesSection.all)
                sidebarRow("手寫筆記本", systemImage: "pencil.and.scribble", count: store.notebookCount).tag(NotesSection.notebooks)
                sidebarRow("待辦", systemImage: "checklist", count: store.openTasks.count).tag(NotesSection.tasks)
            }

            Section {
                Picker("顯示", selection: $sidebarMode) {
                    ForEach(SidebarMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))

                switch sidebarMode {
                case .folders:
                    // 整個 vault（最上層的筆記與檔案），下面是資料夾樹
                    sidebarRow(NotesStore.folderTitle(""), systemImage: "books.vertical", count: store.fileCount(inFolder: ""))
                        .tag(NotesSection.folder(""))
                    ForEach(store.childFolders(of: ""), id: \.self) { folder in
                        FolderTreeRow(folder: folder, store: store, rowBuilder: folderRow)
                    }
                case .tags:
                    ForEach(store.tagCounts, id: \.tag) { item in
                        sidebarRow("#\(item.tag)", systemImage: "number", count: item.count).tag(NotesSection.tag(item.tag))
                    }
                    if store.tagCounts.isEmpty {
                        Text("筆記的屬性中加入 tags 就會出現在這裡").font(.footnote).foregroundStyle(.tertiary)
                    }
                }
            }

            Section {
                syncStatus
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("筆記庫")
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜尋筆記")
        .onChange(of: searchText) { _, text in
            if !text.isEmpty { compactColumn = .detail }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { newTextNote() } label: { Label("新增筆記", systemImage: "square.and.pencil") }
                    Button { showsNewNotebook = true } label: { Label("新增手寫筆記本", systemImage: "pencil.and.scribble") }
                    Button { promptNewFolder() } label: { Label("新增資料夾", systemImage: "folder.badge.plus") }
                } label: {
                    Label("新增", systemImage: "plus")
                }
            }
        }
        .refreshable { await sync.syncNow() }
    }

    private func sidebarRow(_ title: String, systemImage: String, count: Int?) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if let count, count > 0 {
                CountBadge(count: count)
            }
        }
    }

    private func folderRow(_ folder: String) -> AnyView {
        AnyView(
            sidebarRow(NotesStore.folderTitle(folder), systemImage: "folder", count: store.fileCount(inFolder: folder))
                .tag(NotesSection.folder(folder))
        )
    }

    @ViewBuilder
    private var syncStatus: some View {
        if !sync.isConfigured {
            Button {
                showsPairing = true
            } label: {
                Label("與 Obsidian 配對", systemImage: "qrcode.viewfinder")
            }
        } else if sync.isSyncing {
            VStack(alignment: .leading, spacing: 6) {
                Label(sync.progress.map { "下載中 \($0.done)/\($0.total)" } ?? "同步中…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                if let progress = sync.progress, progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                }
            }
        } else if let error = sync.lastError {
            Button {
                Task { await sync.syncNow() }
            } label: {
                Label(error, systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        } else if let date = sync.lastSyncedAt {
            Label("已同步 \(date.formatted(.relative(presentation: .named)))", systemImage: "checkmark.icloud")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 右側內容

    @ViewBuilder
    private var root: some View {
        Group {
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                NotesListPage(title: "搜尋結果", notes: store.notes(inFolder: nil, query: searchText), onDelete: { pendingDelete = $0 })
            } else {
                switch section ?? .home {
                case .home:
                    NotesDashboardView(
                        store: store,
                        isPaired: sync.isConfigured,
                        onOpen: open,
                        onPair: { showsPairing = true }
                    )
                case .all:
                    NotesListPage(title: "所有筆記", notes: store.notes, onDelete: { pendingDelete = $0 })
                case .notebooks:
                    NotesListPage(title: "手寫筆記本", notes: store.notes(inFolder: nil, notebooksOnly: true), onDelete: { pendingDelete = $0 })
                case .tasks:
                    NotesTasksPage(store: store, onOpen: open)
                case .folder(let folder):
                    NotesFolderPage(
                        folder: folder,
                        store: store,
                        onSelectFolder: { section = .folder($0) },
                        onDelete: { pendingDelete = $0 }
                    )
                case .tag(let tag):
                    NotesListPage(title: "#\(tag)", notes: store.notes(inFolder: nil, tag: tag), onDelete: { pendingDelete = $0 })
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            NoteToolPalette(tools: paletteTools, more: moreTools)
                .padding(.bottom, 8)
        }
    }

    private var paletteTools: [NoteToolPalette.Tool] {
        [
            .init(id: "text", systemImage: "textformat", title: "新增筆記", color: .lavender) { newTextNote() },
            .init(id: "ink", systemImage: "pencil.and.scribble", title: "新增手寫筆記本", color: .sky) { showsNewNotebook = true },
            .init(id: "tasks", systemImage: "checklist", title: "新增待辦清單", color: .butter) { newTaskNote() },
            .init(id: "folder", systemImage: "folder.badge.plus", title: "新增資料夾", color: .blush) { promptNewFolder() },
            .init(id: "scan", systemImage: "doc.viewfinder", title: "掃描文件", color: .mint) { selectedTab = .scan },
        ]
    }

    private var moreTools: [NoteToolPalette.Tool] {
        var tools: [NoteToolPalette.Tool] = [
            .init(id: "sync", systemImage: "arrow.triangle.2.circlepath.icloud", title: "立即同步", color: .sky) {
                Task { await sync.syncNow() }
            },
        ]
        if !sync.isConfigured {
            tools.append(.init(id: "pair", systemImage: "qrcode.viewfinder", title: "與 Obsidian 配對", color: .mint) { showsPairing = true })
        }
        tools.append(.init(id: "records", systemImage: "clock.arrow.circlepath", title: "掃描紀錄", color: .butter) { selectedTab = .history })
        return tools
    }

    // MARK: - Actions

    private func open(_ notePath: String) {
        path = [.note(notePath)]
        compactColumn = .detail
    }

    private func replaceTop(with notePath: String) {
        guard !path.isEmpty else { return }
        path[path.count - 1] = .note(notePath)
    }

    private func newTextNote() {
        let title = "筆記 " + Date().formatted(.dateTime.month().day().hour().minute())
        if let notePath = try? store.createTextNote(in: currentFolder, title: title) {
            open(notePath)
        }
    }

    private func newTaskNote() {
        let title = "待辦 " + Date().formatted(.dateTime.month().day())
        if let notePath = try? store.createTextNote(in: currentFolder, title: title) {
            try? store.save("- [ ] ", to: notePath)
            open(notePath)
        }
    }

    private func promptNewFolder() {
        newFolderName = ""
        showsNewFolder = true
    }

    private func createFolder() {
        guard !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let name = NotebookMarkdown.fileName(for: newFolderName)
        let parent: String
        if case .folder(let folder) = section, !folder.isEmpty { parent = folder + "/" } else { parent = "" }
        try? store.createFolder(parent + name)
        section = .folder(parent + name)
    }

    private func openLinkedNote(_ target: String) {
        Task {
            let files = sync.vault.allFiles()
            if let notePath = await sync.engine.resolve(name: target, localFiles: files), notePath.lowercased().hasSuffix(".md") {
                path.append(.note(notePath))
            }
        }
    }
}

/// 側邊欄的資料夾樹（可展開子資料夾）。
private struct FolderTreeRow: View {
    let folder: String
    let store: NotesStore
    let rowBuilder: (String) -> AnyView

    var body: some View {
        let children = store.childFolders(of: folder)
        if children.isEmpty {
            rowBuilder(folder)
        } else {
            DisclosureGroup {
                ForEach(children, id: \.self) { child in
                    AnyView(FolderTreeRow(folder: child, store: store, rowBuilder: rowBuilder))
                }
            } label: {
                rowBuilder(folder)
            }
        }
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

/// 依筆記種類開啟：手寫筆記本或一般 Markdown 筆記。
struct NoteDetailRouter: View {
    let path: String
    var onPathChange: (String) -> Void
    var onOpenNote: (String) -> Void

    var body: some View {
        let summary = NotesStore.shared.notes.first { $0.path == path }
            ?? NotesStore.summarize(path: path, mtime: Date(), text: LocalVault.shared.readText(path) ?? "")
        if let id = summary.notebookID {
            NotebookEditorView(initialPath: path, notebookID: id, onPathChange: onPathChange)
        } else {
            NoteView(initialPath: path, onPathChange: onPathChange, onOpenNote: onOpenNote)
        }
    }
}

/// 新增手寫筆記本：名稱、紙張、顏色。
struct NewNotebookSheet: View {
    var onCreate: (String, PaperStyle, NotebookColor) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var paper: PaperStyle = .lined
    @State private var color: NotebookColor = .blue
    @FocusState private var titleFocused: Bool

    private var defaultTitle: String {
        "手寫 " + Date().formatted(.dateTime.month().day().hour().minute())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名稱") {
                    TextField(defaultTitle, text: $title)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit(create)
                }
                Section("紙張") {
                    HStack(spacing: 14) {
                        ForEach(PaperStyle.allCases) { style in
                            Button {
                                paper = style
                            } label: {
                                PaperPreview(style: style, isSelected: paper == style)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("顏色") {
                    HStack(spacing: 14) {
                        ForEach(NotebookColor.allCases) { option in
                            Button {
                                color = option
                            } label: {
                                Circle()
                                    .fill(option.color.gradient)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if color == option {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.rawValue)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("新增手寫筆記本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("建立", action: create)
                }
            }
            .onAppear { titleFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(name.isEmpty ? defaultTitle : name, paper, color)
        dismiss()
    }
}

private struct PaperPreview: View {
    let style: PaperStyle
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                let scale = size.width / NotebookLayout.pageSize.width
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                guard let pattern = PaperRenderer.patternPath(for: style, size: NotebookLayout.pageSize) else { return }
                let path = Path(pattern).applying(CGAffineTransform(scaleX: scale, y: scale))
                let color = Color(PaperRenderer.patternColor(for: style))
                if style == .dotted {
                    context.fill(path, with: .color(color))
                } else {
                    context.stroke(path, with: .color(color), lineWidth: 0.6)
                }
            }
            .aspectRatio(NotebookLayout.pageSize.width / NotebookLayout.pageSize.height, contentMode: .fit)
            .frame(width: 52)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.black.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
            }
            Text(style.title)
                .font(.caption)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
    }
}
