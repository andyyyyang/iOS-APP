import QuickLook
import SwiftUI

/// 左側欄：檔案樹、搜尋、標籤、業務快查。
struct LeftSidebar: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            switch workspace.leftMode {
            case .files: FileExplorer()
            case .search: SearchPanel()
            case .tags: TagsPanel()
            case .tools: ToolsPanel()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// 側欄標題列：標題、說明與右側按鈕。
struct PanelHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var showsSyncDot = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                if let subtitle {
                    HStack(spacing: 6) {
                        if showsSyncDot {
                            Circle().fill(DS.success).frame(width: 7, height: 7)
                        }
                        Text(subtitle)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

/// 側欄標題列右側的小按鈕（白底細框）。
private struct SmallBoxButtonLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DS.text)
            .frame(width: 30, height: 30)
            .background(DS.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1))
    }
}

// MARK: - 檔案樹

private struct ExplorerRow: Identifiable {
    enum Kind {
        case folder(String)
        case note(NoteSummary)
        case file(VaultItem)
    }

    let id: String
    let depth: Int
    let kind: Kind
}

struct FileExplorer: View {
    @Environment(Workspace.self) private var workspace
    @State private var store = NotesStore.shared
    @State private var sync = VaultSyncCenter.shared
    @State private var previewURL: URL?
    @State private var folderPrompt: String?
    @State private var folderName = ""
    @State private var moving: NoteSummary?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "檔案", subtitle: subtitle, showsSyncDot: sync.isConfigured && sync.lastError == nil) {
                Menu {
                    Button { workspace.newTextNote(in: "") } label: { Label("新增筆記", systemImage: "square.and.pencil") }
                    Button { workspace.newNotebook(in: "") } label: { Label("新增手寫筆記", systemImage: "pencil") }
                    Button { promptFolder(in: "") } label: { Label("新增資料夾", systemImage: "folder.badge.plus") }
                } label: {
                    SmallBoxButtonLabel(systemImage: "plus")
                }
                .accessibilityLabel("新增")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                    if store.notes.isEmpty && store.folders.isEmpty {
                        Text(sync.isConfigured ? "vault 是空的" : "與 Obsidian 配對後，整個 vault 會出現在這裡。")
                            .font(.footnote)
                            .foregroundStyle(DS.textTertiary)
                            .padding(14)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .refreshable { await sync.pullToRefresh() }
        }
        .quickLookPreview($previewURL)
        .sheet(item: $moving) { note in
            MoveToFolderSheet(note: note) { folder in workspace.moveNote(note.path, toFolder: folder) }
                .presentationDetents([.medium, .large])
        }
        .alert("新增資料夾", isPresented: Binding(get: { folderPrompt != nil }, set: { if !$0 { folderPrompt = nil } })) {
            TextField("名稱", text: $folderName)
            Button("取消", role: .cancel) {}
            Button("建立") {
                if let parent = folderPrompt { workspace.createFolder(named: folderName, in: parent) }
            }
        } message: {
            Text(folderPrompt.map { $0.isEmpty ? "建立在最上層" : "建立在「\($0)」中" } ?? "")
        }
    }

    private var subtitle: String {
        if !sync.isConfigured { return "尚未配對 · \(store.notes.count) 則筆記" }
        if sync.isSyncing { return sync.progress.map { "下載中 \($0.done)/\($0.total)" } ?? "同步中…" }
        if sync.blockedDeletion != nil { return "等待確認 · \(store.notes.count) 則筆記" }
        if sync.lastError != nil { return "同步失敗 · \(store.notes.count) 則筆記" }
        if !sync.failedFiles.isEmpty { return "\(sync.failedFiles.count) 個檔案沒有同步 · \(store.notes.count) 則筆記" }
        return "已同步 · \(store.notes.count) 則筆記"
    }

    /// 展開中的資料夾樹攤平成一列列（資料夾在前，再來是筆記與其他檔案）。
    private var rows: [ExplorerRow] {
        let notesByFolder = Dictionary(grouping: store.notes, by: \.folder)
        let filesByFolder = Dictionary(grouping: store.files, by: \.folder)
        var result: [ExplorerRow] = []
        func walk(_ folder: String, depth: Int) {
            for child in store.childFolders(of: folder) {
                result.append(ExplorerRow(id: "d:" + child, depth: depth, kind: .folder(child)))
                if workspace.isExpanded(child) { walk(child, depth: depth + 1) }
            }
            let notes = (notesByFolder[folder] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            for note in notes {
                result.append(ExplorerRow(id: "n:" + note.path, depth: depth, kind: .note(note)))
            }
            let files = (filesByFolder[folder] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for file in files {
                result.append(ExplorerRow(id: "f:" + file.path, depth: depth, kind: .file(file)))
            }
        }
        walk("", depth: 0)
        return result
    }

    @ViewBuilder
    private func rowView(_ row: ExplorerRow) -> some View {
        switch row.kind {
        case .folder(let folder):
            let expanded = workspace.isExpanded(folder)
            TreeRow(depth: row.depth, isSelected: workspace.active == .folder(folder)) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.textSecondary)
                Text(NotesStore.folderTitle(folder))
                    .foregroundStyle(DS.text)
                Spacer(minLength: 4)
                Text("\(store.fileCount(inFolder: folder))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DS.textTertiary)
            } action: {
                withAnimation(.snappy(duration: 0.2)) { workspace.toggleFolder(folder) }
            }
            .contextMenu {
                Button { workspace.newTextNote(in: folder) } label: { Label("新增筆記", systemImage: "square.and.pencil") }
                Button { workspace.newNotebook(in: folder) } label: { Label("新增手寫筆記", systemImage: "pencil") }
                Button { promptFolder(in: folder) } label: { Label("新增資料夾", systemImage: "folder.badge.plus") }
                Divider()
                Button { workspace.open(.folder(folder)) } label: { Label("在分頁中開啟", systemImage: "rectangle.on.rectangle") }
            }
        case .note(let note):
            let selected = workspace.activeNotePath == note.path
            TreeRow(depth: row.depth, isSelected: selected) {
                Color.clear.frame(width: 10)
                Image(systemName: note.isNotebook ? "pencil" : "doc")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? DS.text : DS.textTertiary)
                Text(note.title)
                    .foregroundStyle(DS.text)
                Spacer(minLength: 0)
            } action: {
                workspace.openNote(note.path)
            }
            .contextMenu {
                if let url = NotesSettings.obsidianURL(for: note.path) {
                    Link(destination: url) { Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app") }
                }
                if note.isLocal {
                    Button { moving = note } label: { Label("搬移到…", systemImage: "folder") }
                }
                Button(role: .destructive) { workspace.pendingDelete = note } label: { Label("刪除", systemImage: "trash") }
            }
        case .file(let file):
            TreeRow(depth: row.depth, isSelected: false) {
                Color.clear.frame(width: 10)
                Image(systemName: file.systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.textTertiary)
                Text(file.name)
                    .foregroundStyle(DS.textSecondary)
                Spacer(minLength: 0)
                if !file.isLocal {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.caption2)
                        .foregroundStyle(DS.textTertiary)
                }
            } action: {
                Task {
                    if file.isLocal {
                        previewURL = LocalVault.shared.url(for: file.path)
                    } else {
                        previewURL = try? await VaultSyncCenter.shared.download(file.path)
                    }
                }
            }
            .contextMenu {
                if file.isLocal {
                    ShareLink(item: LocalVault.shared.url(for: file.path)) { Label("分享", systemImage: "square.and.arrow.up") }
                }
                if let url = NotesSettings.obsidianURL(for: file.path) {
                    Link(destination: url) { Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app") }
                }
            }
        }
    }

    private func promptFolder(in parent: String) {
        folderName = ""
        folderPrompt = parent
    }
}

/// 「搬移到」：選一個資料夾（可以搜尋）。
private struct MoveToFolderSheet: View {
    let note: NoteSummary
    var onMove: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let store = NotesStore.shared

    var body: some View {
        NavigationStack {
            List(folders, id: \.self) { folder in
                Button {
                    onMove(folder)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: folder.isEmpty ? "tray" : "folder")
                            .foregroundStyle(DS.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.isEmpty ? "\(NotesStore.folderTitle(""))（最上層）" : NotesStore.folderTitle(folder))
                                .foregroundStyle(DS.text)
                            let parent = (folder as NSString).deletingLastPathComponent
                            if !parent.isEmpty {
                                Text(parent).font(.caption).foregroundStyle(DS.textTertiary)
                            }
                        }
                        Spacer(minLength: 4)
                        if folder == note.folder {
                            Text("目前位置").font(.caption).foregroundStyle(DS.textTertiary)
                        }
                    }
                }
                .disabled(folder == note.folder)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜尋資料夾")
            .navigationTitle("搬移「\(note.title)」")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var folders: [String] {
        let all = [""] + store.folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(text) }
    }
}

/// 檔案樹的一列：選取時是白底。
private struct TreeRow<Content: View>: View {
    let depth: Int
    let isSelected: Bool
    @ViewBuilder var content: () -> Content
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                content()
            }
            .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
            .lineLimit(1)
            .padding(.leading, CGFloat(depth) * 14 + 8)
            .padding(.trailing, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? DS.card : (isHovering ? DS.card.opacity(0.6) : Color.clear))
                    .shadow(color: .black.opacity(isSelected ? 0.06 : 0), radius: 1, y: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - 搜尋

struct SearchPanel: View {
    @Environment(Workspace.self) private var workspace
    @State private var store = NotesStore.shared
    @State private var query = ""
    /// 伺服器的內文搜尋結果（包含還沒下載的筆記）。
    @State private var remoteHits: [VaultSearchHit] = []

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "搜尋", subtitle: "標題、標籤與內文") { EmptyView() }
            SearchField(placeholder: "搜尋整個 vault", text: $query, autofocus: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            let trimmed = query.trimmingCharacters(in: .whitespaces)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !trimmed.isEmpty {
                        let results = Array(store.notes(inFolder: nil, query: trimmed).prefix(80))
                        let found = Set(results.map(\.path))
                        let extra = remoteHits.filter { !found.contains($0.path) }
                        Text("\(results.count + extra.count) 個結果")
                            .font(.caption)
                            .foregroundStyle(DS.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                        ForEach(results) { note in
                            resultRow(path: note.path, title: note.title, excerpt: excerpt(for: note, query: trimmed), folder: note.folder)
                        }
                        ForEach(extra) { hit in
                            resultRow(path: hit.path, title: hit.name, excerpt: Self.highlight(hit.snippet.replacingOccurrences(of: "\n", with: " "), query: trimmed), folder: (hit.path as NSString).deletingLastPathComponent)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
        .task(id: query) {
            // 伺服器上的內文搜尋（還沒下載的筆記也找得到），輸入停下來再查
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, VaultBackend.storage == .server, let client = VaultClient.configured() else {
                remoteHits = []
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let hits = try? await client.search(trimmed, limit: 40), !Task.isCancelled else { return }
            remoteHits = hits
        }
    }

    private func resultRow(path: String, title: String, excerpt: AttributedString, folder: String) -> some View {
        Button {
            workspace.openNote(path)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text(excerpt)
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(2)
                if !folder.isEmpty {
                    Text(folder)
                        .font(.caption2)
                        .foregroundStyle(DS.textTertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(workspace.activeNotePath == path ? DS.card : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 內文中第一個符合處的前後文，符合的字加粗。
    private func excerpt(for note: NoteSummary, query: String) -> AttributedString {
        let text = (store.text(of: note.path) ?? note.snippet).replacingOccurrences(of: "\n", with: " ")
        return Self.highlight(text, query: query, fallback: note.snippet)
    }

    static func highlight(_ text: String, query: String, fallback: String? = nil) -> AttributedString {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return AttributedString(fallback ?? text)
        }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        var result = AttributedString((start > text.startIndex ? "…" : "") + String(text[start..<range.lowerBound]))
        var match = AttributedString(String(text[range]))
        match.foregroundColor = DS.text
        match.inlinePresentationIntent = .stronglyEmphasized
        result += match
        result += AttributedString(String(text[range.upperBound..<end]) + (end < text.endIndex ? "…" : ""))
        return result
    }
}

// MARK: - 標籤

struct TagsPanel: View {
    @Environment(Workspace.self) private var workspace
    @State private var store = NotesStore.shared
    @State private var expanded: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "標籤", subtitle: "\(store.tagCounts.count) 個標籤") { EmptyView() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(store.tagCounts, id: \.tag) { item in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { expanded = expanded == item.tag ? nil : item.tag }
                        } label: {
                            HStack(spacing: 8) {
                                Chip(text: item.tag, pastel: DS.Pastel.stable(for: item.tag))
                                Spacer()
                                Text("\(item.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(DS.textTertiary)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 34)
                            .background(expanded == item.tag ? DS.card : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if expanded == item.tag {
                            ForEach(store.notes(inFolder: nil, tag: item.tag)) { note in
                                Button {
                                    workspace.openNote(note.path)
                                } label: {
                                    Text(note.title)
                                        .font(.system(size: 13.5))
                                        .foregroundStyle(DS.text)
                                        .lineLimit(1)
                                        .padding(.leading, 20)
                                        .frame(height: 28)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if store.tagCounts.isEmpty {
                        Text("在筆記的屬性加入 tags，就會出現在這裡。")
                            .font(.footnote)
                            .foregroundStyle(DS.textTertiary)
                            .padding(14)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
    }
}
