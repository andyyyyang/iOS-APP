import QuickLook
import SwiftUI

/// 左側欄：檔案樹、搜尋、標籤。
struct LeftSidebar: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            switch workspace.leftMode {
            case .files: FileExplorer()
            case .search: SearchPanel()
            case .tags: TagsPanel()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// 側欄標題列：大標題＋右側按鈕。
struct PanelHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Midnight.text)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Midnight.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
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
    @State private var previewURL: URL?
    @State private var folderPrompt: String?
    @State private var folderName = ""

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: NotesStore.folderTitle(""), subtitle: "\(store.notes.count) 則筆記 · \(store.folders.count) 個資料夾") {
                Menu {
                    Button { workspace.newTextNote(in: "") } label: { Label("新增筆記", systemImage: "square.and.pencil") }
                    Button { workspace.requestNewNotebook(in: "") } label: { Label("新增手寫筆記本", systemImage: "pencil.and.scribble") }
                    Button { promptFolder(in: "") } label: { Label("新增資料夾", systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(GlassIconButtonStyle(size: 32))
                .accessibilityLabel("新增")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                    if store.notes.isEmpty && store.folders.isEmpty {
                        Text(VaultSyncCenter.shared.isConfigured ? "vault 是空的" : "與 Obsidian 配對後，整個 vault 會出現在這裡。")
                            .font(.footnote)
                            .foregroundStyle(Midnight.textTertiary)
                            .padding(16)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .refreshable { await VaultSyncCenter.shared.syncNow() }
        }
        .quickLookPreview($previewURL)
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
                    .foregroundStyle(Midnight.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                Image(systemName: expanded ? "folder.fill" : "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Midnight.hue(for: folder))
                Text(NotesStore.folderTitle(folder))
                    .foregroundStyle(Midnight.text)
                Spacer(minLength: 4)
                Text("\(store.fileCount(inFolder: folder))")
                    .font(.system(.caption2, design: .rounded).monospacedDigit())
                    .foregroundStyle(Midnight.textTertiary)
            } action: {
                withAnimation(.snappy(duration: 0.22)) { workspace.toggleFolder(folder) }
            }
            .contextMenu {
                Button { workspace.newTextNote(in: folder) } label: { Label("新增筆記", systemImage: "square.and.pencil") }
                Button { workspace.requestNewNotebook(in: folder) } label: { Label("新增手寫筆記本", systemImage: "pencil.and.scribble") }
                Button { promptFolder(in: folder) } label: { Label("新增資料夾", systemImage: "folder.badge.plus") }
                Divider()
                Button { workspace.open(.folder(folder)) } label: { Label("在分頁中開啟", systemImage: "rectangle.on.rectangle") }
            }
        case .note(let note):
            TreeRow(depth: row.depth, isSelected: workspace.activeNotePath == note.path) {
                Color.clear.frame(width: 12)
                Image(systemName: note.isNotebook ? "pencil.and.scribble" : "doc.text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(workspace.activeNotePath == note.path ? AnyShapeStyle(Midnight.textGradient) : AnyShapeStyle(Midnight.textSecondary))
                Text(note.title)
                    .foregroundStyle(Midnight.text)
                Spacer(minLength: 0)
            } action: {
                workspace.openNote(note.path)
            }
            .contextMenu {
                if let url = NotesSettings.obsidianURL(for: note.path) {
                    Link(destination: url) { Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app") }
                }
                Button(role: .destructive) { workspace.pendingDelete = note } label: { Label("刪除", systemImage: "trash") }
            }
        case .file(let file):
            TreeRow(depth: row.depth, isSelected: false) {
                Color.clear.frame(width: 12)
                Image(systemName: file.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Midnight.textTertiary)
                Text(file.name)
                    .foregroundStyle(Midnight.textSecondary)
                Spacer(minLength: 0)
                if !file.isLocal {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.caption2)
                        .foregroundStyle(Midnight.textTertiary)
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

/// 檔案樹的一列：縮排導引線、選取時的漸層光條。
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
            .font(.system(.subheadline, design: .rounded).weight(isSelected ? .semibold : .regular))
            .lineLimit(1)
            .padding(.leading, CGFloat(depth) * 16 + 8)
            .padding(.trailing, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Midnight.raised : (isHovering ? Midnight.raised.opacity(0.6) : Color.clear))
                    if isSelected {
                        Capsule()
                            .fill(Midnight.gradient)
                            .frame(width: 3, height: 16)
                            .glow(radius: 6)
                            .padding(.leading, 2)
                    }
                    // 縮排導引線
                    ForEach(0..<depth, id: \.self) { level in
                        Rectangle()
                            .fill(Midnight.hairline)
                            .frame(width: 1)
                            .padding(.leading, CGFloat(level) * 16 + 14)
                    }
                }
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
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "搜尋", subtitle: "標題、標籤與內文") { EmptyView() }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Midnight.textTertiary)
                TextField("搜尋整個 vault", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Midnight.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除")
                }
            }
            .font(.system(.body, design: .rounded))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Midnight.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? AnyShapeStyle(Midnight.gradient) : AnyShapeStyle(Midnight.hairline), lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            let trimmed = query.trimmingCharacters(in: .whitespaces)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !trimmed.isEmpty {
                        let results = Array(store.notes(inFolder: nil, query: trimmed).prefix(80))
                        SectionLabel("結果", trailing: "\(results.count)")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        ForEach(results) { note in
                            Button {
                                workspace.openNote(note.path)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(note.title)
                                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                        .foregroundStyle(Midnight.text)
                                    Text(excerpt(for: note, query: trimmed))
                                        .font(.caption)
                                        .foregroundStyle(Midnight.textSecondary)
                                        .lineLimit(2)
                                    if !note.folder.isEmpty {
                                        Text(note.folder)
                                            .font(.system(.caption2, design: .rounded))
                                            .foregroundStyle(Midnight.textTertiary)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(workspace.activeNotePath == note.path ? Midnight.raised : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if results.isEmpty {
                            Text("找不到「\(trimmed)」")
                                .font(.footnote)
                                .foregroundStyle(Midnight.textTertiary)
                                .padding(10)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear { focused = true }
    }

    /// 內文中第一個符合處的前後文，符合的字以強調色標出。
    private func excerpt(for note: NoteSummary, query: String) -> AttributedString {
        let text = (store.text(of: note.path) ?? note.snippet).replacingOccurrences(of: "\n", with: " ")
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return AttributedString(note.snippet)
        }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        var result = AttributedString((start > text.startIndex ? "…" : "") + String(text[start..<range.lowerBound]))
        var match = AttributedString(String(text[range]))
        match.foregroundColor = Midnight.accent
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
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.tagCounts, id: \.tag) { item in
                        Button {
                            withAnimation(.snappy(duration: 0.22)) { expanded = expanded == item.tag ? nil : item.tag }
                        } label: {
                            HStack(spacing: 8) {
                                Text("#")
                                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                                    .foregroundStyle(Midnight.hue(for: item.tag))
                                Text(item.tag)
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(Midnight.text)
                                Spacer()
                                Text("\(item.count)")
                                    .font(.system(.caption, design: .rounded).monospacedDigit())
                                    .foregroundStyle(Midnight.textTertiary)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(expanded == item.tag ? Midnight.raised : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if expanded == item.tag {
                            ForEach(store.notes(inFolder: nil, tag: item.tag)) { note in
                                Button {
                                    workspace.openNote(note.path)
                                } label: {
                                    Label(note.title, systemImage: note.isNotebook ? "pencil.and.scribble" : "doc.text")
                                        .font(.system(.subheadline, design: .rounded))
                                        .foregroundStyle(Midnight.textSecondary)
                                        .lineLimit(1)
                                        .padding(.leading, 28)
                                        .frame(height: 28)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if store.tagCounts.isEmpty {
                        Text("在筆記的屬性加入 tags，或在內文寫 #標籤，就會出現在這裡。")
                            .font(.footnote)
                            .foregroundStyle(Midnight.textTertiary)
                            .padding(16)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
    }
}
