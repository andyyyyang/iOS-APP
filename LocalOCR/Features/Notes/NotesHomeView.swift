import SwiftUI
import UIKit

/// 筆記 App 的主畫面：iPad 三欄（資料夾｜筆記清單｜筆記），iPhone 一層層進入。
/// 所有筆記都是 Obsidian vault 中的 Markdown 檔，存在這台裝置上，並與 Railway 空間雙向同步。
struct NotesHomeView: View {
    enum SidebarItem: Hashable {
        case all
        case notebooks
        case folder(String)
    }

    @State private var store = NotesStore.shared
    @State private var sync = VaultSyncCenter.shared
    @State private var sidebarSelection: SidebarItem? = .all
    @State private var selectedNote: String?
    @State private var searchText = ""
    @State private var showsNewNotebook = false
    @State private var showsNewFolder = false
    @State private var newFolderName = ""
    @State private var showsPairing = false
    @State private var pendingDelete: NoteSummary?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var currentFolder: String {
        if case .folder(let folder) = sidebarSelection { return folder }
        return NotesSettings.defaultFolder
    }

    private var visibleNotes: [NoteSummary] {
        switch sidebarSelection ?? .all {
        case .all: return store.notes(inFolder: nil, query: searchText)
        case .notebooks: return store.notes(inFolder: nil, notebooksOnly: true, query: searchText)
        case .folder(let folder): return store.notes(inFolder: folder, query: searchText)
        }
    }

    private var listTitle: String {
        switch sidebarSelection ?? .all {
        case .all: return "所有筆記"
        case .notebooks: return "手寫筆記本"
        case .folder(let folder): return (folder as NSString).lastPathComponent
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            noteList
        } detail: {
            NavigationStack {
                if let selectedNote, let note = store.notes.first(where: { $0.path == selectedNote }) ?? summary(for: selectedNote) {
                    NoteDetailRouter(note: note, onPathChange: { self.selectedNote = $0 }, onOpenNote: openLinkedNote)
                        .id(note.path)
                } else {
                    ContentUnavailableView("選擇或新增一則筆記", systemImage: "note.text", description: Text("筆記都是 Markdown，會同步到 Obsidian。"))
                }
            }
        }
        .sheet(isPresented: $showsNewNotebook) {
            NewNotebookSheet { title, paper, color in
                if let path = try? NotebookFiles.create(in: currentFolder, title: title, paper: paper, color: color, store: store) {
                    selectedNote = path
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
        }
        .confirmationDialog(
            "刪除「\(pendingDelete?.title ?? "")」？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除筆記", role: .destructive) {
                if let note = pendingDelete {
                    if selectedNote == note.path { selectedNote = nil }
                    try? store.delete(note.path)
                }
                pendingDelete = nil
            }
        } message: {
            Text("同步後也會從 Obsidian 刪除（Obsidian 的回收桶設定不影響這裡）。")
        }
        .onChange(of: sync.revision) { _, _ in Task { await store.reload() } }
        .task {
            await store.reload()
            if sync.isConfigured { await sync.syncNow() }
        }
    }

    // MARK: - 側邊欄

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section {
                Label("所有筆記", systemImage: "note.text").tag(SidebarItem.all)
                Label("手寫筆記本", systemImage: "pencil.and.scribble").tag(SidebarItem.notebooks)
            }
            Section("資料夾") {
                ForEach(store.folders, id: \.self) { folder in
                    Label((folder as NSString).lastPathComponent, systemImage: "folder")
                        .padding(.leading, CGFloat(folder.split(separator: "/").count - 1) * 14)
                        .tag(SidebarItem.folder(folder))
                }
            }
            Section {
                syncStatus
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("筆記")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newFolderName = ""
                    showsNewFolder = true
                } label: {
                    Label("新增資料夾", systemImage: "folder.badge.plus")
                }
            }
        }
        .refreshable { await sync.syncNow() }
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
            Label("同步中…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        } else if let error = sync.lastError {
            Button {
                Task { await sync.syncNow() }
            } label: {
                Label(error, systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        } else if let date = sync.lastSyncedAt {
            Label {
                Text("已同步 \(date.formatted(.relative(presentation: .named)))")
            } icon: {
                Image(systemName: "checkmark.icloud")
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 筆記清單

    private var noteList: some View {
        List(selection: $selectedNote) {
            if !sync.isConfigured && store.notes.isEmpty {
                PairingPromptCard { showsPairing = true }
                    .listRowSeparator(.hidden)
            }
            ForEach(visibleNotes) { note in
                NoteRow(note: note)
                    .tag(note.path)
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDelete = note
                        } label: {
                            Label("刪除", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        if let url = NotesSettings.obsidianURL(for: note.path) {
                            Link(destination: url) {
                                Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app")
                            }
                        }
                        Button(role: .destructive) {
                            pendingDelete = note
                        } label: {
                            Label("刪除", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if visibleNotes.isEmpty && !store.isLoading {
                if searchText.isEmpty {
                    ContentUnavailableView("沒有筆記", systemImage: "note.text", description: Text("點右上角新增筆記或手寫筆記本。"))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .navigationTitle(listTitle)
        .searchable(text: $searchText, prompt: "搜尋筆記")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button {
                        newTextNote()
                    } label: {
                        Label("新增筆記", systemImage: "square.and.pencil")
                    }
                    Button {
                        showsNewNotebook = true
                    } label: {
                        Label("新增手寫筆記本", systemImage: "pencil.and.scribble")
                    }
                } label: {
                    Label("新增", systemImage: "square.and.pencil")
                } primaryAction: {
                    newTextNote()
                }
            }
        }
        .refreshable { await sync.syncNow() }
    }

    // MARK: - Actions

    private func newTextNote() {
        let title = "筆記 " + Date().formatted(.dateTime.month().day().hour().minute())
        if let path = try? store.createTextNote(in: currentFolder, title: title) {
            selectedNote = path
        }
    }

    private func createFolder() {
        let name = NotebookMarkdown.fileName(for: newFolderName)
        guard !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let parent: String
        if case .folder(let folder) = sidebarSelection { parent = folder + "/" } else { parent = "" }
        try? store.createFolder(parent + name)
        sidebarSelection = .folder(parent + name)
    }

    private func openLinkedNote(_ target: String) {
        Task {
            let files = sync.vault.allFiles()
            if let path = await sync.engine.resolve(name: target, localFiles: files), path.lowercased().hasSuffix(".md") {
                selectedNote = path
            }
        }
    }

    /// 剛建立、還沒出現在索引中的筆記。
    private func summary(for path: String) -> NoteSummary? {
        guard sync.vault.exists(path) else { return nil }
        return NotesStore.summarize(path: path, mtime: Date(), text: sync.vault.readText(path) ?? "")
    }
}

/// 依筆記種類開啟：手寫筆記本或一般 Markdown 筆記。
private struct NoteDetailRouter: View {
    let note: NoteSummary
    var onPathChange: (String) -> Void
    var onOpenNote: (String) -> Void

    var body: some View {
        if let id = note.notebookID {
            NotebookEditorView(initialPath: note.path, notebookID: id, onPathChange: onPathChange)
        } else {
            NoteView(initialPath: note.path, onPathChange: onPathChange, onOpenNote: onOpenNote)
        }
    }
}

private struct NoteRow: View {
    let note: NoteSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if note.isNotebook {
                        Image(systemName: "pencil.and.scribble")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    Text(note.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(note.mtime, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                    Text(note.snippet.isEmpty ? "沒有其他文字" : note.snippet)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .font(.subheadline)
                if !note.folder.isEmpty {
                    Label(note.folder, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let embed = note.firstEmbed {
                NoteThumbnail(embed: embed)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NoteThumbnail: View {
    let embed: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.1)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: embed) {
            // 只用本機已有的圖片當縮圖，不為了清單下載附件
            let files = VaultSyncCenter.shared.vault.allFiles()
            guard let path = await VaultSyncCenter.shared.engine.resolve(name: embed, localFiles: files),
                  VaultSyncCenter.shared.vault.exists(path) else { return }
            let url = VaultSyncCenter.shared.vault.url(for: path)
            image = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path(percentEncoded: false))?.preparingThumbnail(of: CGSize(width: 156, height: 156))
            }.value
        }
    }
}

private struct PairingPromptCard: View {
    var onPair: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("與 Obsidian 配對", systemImage: "link.badge.plus")
                .font(.headline)
            Text("在 Mac 的 Obsidian 執行「LocalOCR：配對 iPhone／iPad」，用這台裝置掃描 QR Code，筆記就會雙向同步。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("開始配對", action: onPair)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.vertical, 6)
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
