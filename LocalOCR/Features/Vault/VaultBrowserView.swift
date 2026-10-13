import SwiftUI
import UIKit

/// Obsidian vault 的資料夾、搜尋與檔名索引（內嵌圖片、[[連結]] 依檔名找到檔案）。
@MainActor
@Observable
final class VaultBrowserModel {
    var listings: [String: VaultListing] = [:]
    var searchResults: [VaultSearchHit] = []
    var isSearching = false
    var errorMessage: String?
    var notConfigured = false
    /// 小寫檔名（含與不含副檔名）→ 路徑。
    private var nameIndex: [String: String] = [:]
    private var indexTask: Task<Void, Never>?
    private var imageCache: [String: UIImage] = [:]

    var client: VaultClient? { VaultClient.configured() }

    func load(_ prefix: String, force: Bool = false) async {
        guard force || listings[prefix] == nil else { return }
        guard let client else {
            notConfigured = true
            return
        }
        do {
            var listing = try await client.list(prefix: prefix, recursive: false)
            listing.folders = listing.folders.filter { !Self.isHidden($0) }
            listing.files = listing.files.filter { !Self.isHidden($0.path) }
            listings[prefix] = listing
            errorMessage = nil
            notConfigured = false
        } catch VaultError.notConfigured {
            notConfigured = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reload() async {
        let prefixes = Array(listings.keys)
        listings.removeAll()
        nameIndex.removeAll()
        for prefix in prefixes.isEmpty ? [""] : prefixes {
            await load(prefix, force: true)
        }
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client else {
            searchResults = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        searchResults = (try? await client.search(trimmed)) ?? []
    }

    /// [[連結]] 或內嵌檔名 → vault 路徑。
    func resolve(_ name: String) async -> String? {
        if name.contains("/") { return name.hasSuffix(".md") || (name as NSString).pathExtension.count > 0 ? name : name + ".md" }
        await buildIndexIfNeeded()
        let key = name.lowercased()
        return nameIndex[key] ?? nameIndex[key + ".md"]
    }

    func image(named name: String) async -> UIImage? {
        if let cached = imageCache[name] { return cached }
        guard let path = await resolve(name), let client,
              let file = try? await client.read(path), let image = UIImage(data: file.data) else { return nil }
        imageCache[name] = image
        return image
    }

    private func buildIndexIfNeeded() async {
        if !nameIndex.isEmpty { return }
        if let indexTask { return await indexTask.value }
        let task = Task { [weak self] in
            guard let self, let client = self.client,
                  let listing = try? await client.list(prefix: "", recursive: true) else { return }
            var index: [String: String] = [:]
            for file in listing.files where !Self.isHidden(file.path) {
                let name = file.name.lowercased()
                if index[name] == nil { index[name] = file.path }
            }
            self.nameIndex = index
        }
        indexTask = task
        await task.value
        indexTask = nil
    }

    func createNote(in folder: String, title: String) async throws -> String {
        guard let client else { throw VaultError.notConfigured }
        let base = (folder.isEmpty ? "" : folder) + NotebookMarkdown.fileName(for: title)
        for attempt in 1...20 {
            let path = attempt == 1 ? "\(base).md" : "\(base) \(attempt).md"
            do {
                try await client.writeText(path, "", condition: .createOnly)
                await load(folder, force: true)
                nameIndex.removeAll()
                return path
            } catch VaultError.conflict {
                continue
            }
        }
        throw VaultError.conflict(currentETag: nil)
    }

    static func isHidden(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

/// Obsidian 分頁：iPad 左側資料夾樹、右側筆記；iPhone 自動變成一層層進入。
struct VaultBrowserView: View {
    @State private var model = VaultBrowserModel()
    @State private var selection: String?
    @State private var searchText = ""
    @State private var showsNewNote = false
    @State private var newNoteTitle = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                if let selection {
                    VaultFileView(path: selection, model: model) { target in
                        Task { if let path = await model.resolve(target) { self.selection = path } }
                    }
                    .id(selection)
                } else {
                    ContentUnavailableView("選擇一則筆記", systemImage: "doc.text", description: Text("從左側的資料夾選擇 Obsidian 筆記，或搜尋內容。"))
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            if model.notConfigured {
                notConfiguredSection
            } else if !searchText.isEmpty {
                Section(model.isSearching ? "搜尋中…" : "搜尋結果") {
                    ForEach(model.searchResults) { hit in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.name).font(.body.weight(.medium))
                            if !hit.snippet.isEmpty {
                                Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text(hit.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        .tag(hit.path)
                    }
                }
            } else {
                VaultFolderContents(prefix: "", model: model)
            }
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Obsidian")
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜尋筆記內容")
        .onSubmit(of: .search) { Task { await model.search(searchText) } }
        .onChange(of: searchText) { _, text in
            if text.isEmpty { model.searchResults = [] }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newNoteTitle = ""
                    showsNewNote = true
                } label: {
                    Label("新增筆記", systemImage: "square.and.pencil")
                }
                .disabled(model.notConfigured)
            }
        }
        .refreshable { await model.reload() }
        .alert("新增筆記", isPresented: $showsNewNote) {
            TextField("標題", text: $newNoteTitle)
            Button("取消", role: .cancel) {}
            Button("建立") { Task { await createNote() } }
        } message: {
            Text("會建立在\(currentFolder.isEmpty ? " vault 最上層" : "「\(currentFolder)」")。")
        }
    }

    private var notConfiguredSection: some View {
        Section {
            Label("尚未連接 Obsidian 空間", systemImage: "externaldrive.badge.xmark")
            Text("在「設定」連接伺服器，並依照說明在 Obsidian 安裝 Remotely Save，就能在這裡看到所有筆記。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// 新筆記建立的位置：目前選取筆記所在的資料夾。
    private var currentFolder: String {
        guard let selection, let slash = selection.lastIndex(of: "/") else { return "" }
        return String(selection[...slash])
    }

    private func createNote() async {
        let title = newNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if let path = try? await model.createNote(in: currentFolder, title: title) {
            selection = path
        }
    }
}

/// 一個資料夾的內容（子資料夾可展開）。
private struct VaultFolderContents: View {
    let prefix: String
    let model: VaultBrowserModel

    var body: some View {
        if let listing = model.listings[prefix] {
            ForEach(listing.folders, id: \.self) { folder in
                VaultFolderRow(path: folder, model: model)
            }
            ForEach(listing.files) { file in
                Label(file.displayName, systemImage: icon(for: file))
                    .lineLimit(1)
                    .tag(file.path)
            }
            if listing.folders.isEmpty && listing.files.isEmpty {
                Text("（空資料夾）").font(.footnote).foregroundStyle(.tertiary)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .task { await model.load(prefix) }
        }
    }

    private func icon(for file: VaultEntry) -> String {
        if file.isMarkdown { return "doc.text" }
        if file.isImage { return "photo" }
        if file.pathExtension == "pdf" { return "doc.richtext" }
        if file.pathExtension == NotebookArchive.fileExtension { return "pencil.and.scribble" }
        return "doc"
    }
}

private struct VaultFolderRow: View {
    let path: String
    let model: VaultBrowserModel
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isExpanded {
                AnyView(VaultFolderContents(prefix: path, model: model))
            }
        } label: {
            Label(String(path.dropLast().split(separator: "/").last ?? Substring(path)), systemImage: "folder")
        }
    }
}

/// 一個 vault 檔案：Markdown 可閱讀與編輯（含 Apple Intelligence 整理），圖片直接顯示。
struct VaultFileView: View {
    let path: String
    let model: VaultBrowserModel
    var onOpenLink: (String) -> Void

    @Environment(\.openURL) private var openURL
    @State private var file: VaultFile?
    @State private var errorMessage: String?
    @State private var isEditing = false
    @State private var draft = ""
    @State private var isSaving = false
    @State private var conflict = false
    @State private var showsInspector = false
    @State private var insights: NoteInsights?
    @State private var aiMessage: String?
    @State private var isThinking = false
    @State private var toast: String?

    private var isMarkdown: Bool { path.lowercased().hasSuffix(".md") }
    private var title: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .inspector(isPresented: $showsInspector) {
                inspector.inspectorColumnWidth(min: 300, ideal: 340, max: 440)
            }
            .alert("筆記在別處被修改過", isPresented: $conflict) {
                Button("重新載入（放棄我的修改）", role: .destructive) { Task { await load() } }
                Button("用我的版本覆蓋") { Task { await save(force: true) } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("Obsidian 中的版本比你開始編輯時新。")
            }
            .toast($toast)
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ContentUnavailableView("無法開啟", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else if let file {
            if isMarkdown {
                if isEditing {
                    TextEditor(text: $draft)
                        .font(.body)
                        .writingToolsBehavior(.complete)
                        .padding(.horizontal)
                } else {
                    ScrollView {
                        MarkdownView(
                            text: file.text,
                            loadEmbed: { name in await model.image(named: name) },
                            onOpenLink: onOpenLink
                        )
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .frame(maxWidth: 820)
                        .frame(maxWidth: .infinity)
                    }
                }
            } else if let image = UIImage(data: file.data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit().padding()
                }
            } else {
                ContentUnavailableView("無法預覽這個檔案", systemImage: "doc", description: Text(path))
            }
        } else {
            ProgressView()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isMarkdown {
            ToolbarItemGroup(placement: .primaryAction) {
                if isEditing {
                    Button {
                        Task { await save(force: false) }
                    } label: {
                        if isSaving { ProgressView() } else { Text("完成").bold() }
                    }
                    .disabled(isSaving)
                } else {
                    Button {
                        draft = file?.text ?? ""
                        isEditing = true
                    } label: {
                        Label("編輯", systemImage: "pencil")
                    }
                    .disabled(file == nil)
                }
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Apple Intelligence", systemImage: "sparkles")
                }
                if let url = NotesSettings.obsidianURL(for: path) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app")
                    }
                }
            }
        }
    }

    private var inspector: some View {
        Form {
            Section {
                Button {
                    Task { await analyze() }
                } label: {
                    HStack {
                        Label(insights == nil ? "整理這則筆記" : "重新整理", systemImage: "sparkles")
                        Spacer()
                        if isThinking { ProgressView() }
                    }
                }
                .disabled(isThinking || file == nil)
                if let aiMessage {
                    Label(aiMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text("在裝置上整理摘要、重點、待辦與標籤；編輯時也可以使用系統的「書寫工具」。")
            }
            if let insights {
                Section("摘要") {
                    Text(insights.summary).font(.callout).textSelection(.enabled)
                }
                if !insights.keyPoints.isEmpty {
                    Section("重點") {
                        ForEach(insights.keyPoints, id: \.self) { Text("• \($0)") }
                    }
                }
                if !insights.actionItems.isEmpty {
                    Section("待辦") {
                        ForEach(insights.actionItems, id: \.self) { Label($0, systemImage: "circle") }
                    }
                }
                if !insights.tags.isEmpty {
                    Section("標籤") {
                        Text(insights.tags.map { "#\($0)" }.joined(separator: "  ")).foregroundStyle(.tint)
                    }
                }
                Section {
                    Button {
                        Task { await insert(insights) }
                    } label: {
                        Label("把摘要與重點加到筆記開頭", systemImage: "text.insert")
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        guard let client = model.client else {
            errorMessage = VaultError.notConfigured.localizedDescription
            return
        }
        do {
            file = try await client.read(path)
            errorMessage = nil
            isEditing = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(force: Bool) async {
        guard let client = model.client else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            var condition = VaultClient.WriteCondition.none
            if !force, let etag = file?.etag {
                condition = .ifMatch(etag)
            }
            let entry = try await client.writeText(path, draft, condition: condition)
            file = VaultFile(data: Data(draft.utf8), etag: entry.etag, mtime: entry.mtime)
            isEditing = false
            toast = "已儲存，Obsidian 下次同步時會更新"
        } catch VaultError.conflict {
            conflict = true
        } catch {
            toast = "儲存失敗：\(error.localizedDescription)"
        }
    }

    private func analyze() async {
        isThinking = true
        defer { isThinking = false }
        do {
            insights = try await NoteIntelligence.insights(for: isEditing ? draft : (file?.text ?? ""))
            aiMessage = nil
        } catch {
            aiMessage = error.localizedDescription
        }
    }

    private func insert(_ insights: NoteInsights) async {
        let source = isEditing ? draft : (file?.text ?? "")
        draft = NoteMarkdownEditing.insertingInsights(insights, into: source)
        await save(force: false)
    }
}

/// 在既有筆記中插入 AI 整理的內容（放在屬性之後），並把標籤合併到屬性。
enum NoteMarkdownEditing {
    static func insertingInsights(_ insights: NoteInsights, into text: String) -> String {
        var block = ["> [!summary] AI 摘要"]
        block.append(contentsOf: insights.summary.split(whereSeparator: \.isNewline).map { "> \($0)" })
        if !insights.keyPoints.isEmpty {
            block.append(">")
            block.append(contentsOf: insights.keyPoints.map { "> - \($0)" })
        }
        let callout = block.joined(separator: "\n") + "\n\n"

        var lines = text.components(separatedBy: "\n")
        var frontmatter: [String] = []
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            frontmatter = Array(lines[0...end])
            lines = Array(lines[(end + 1)...])
        }
        let tags = insights.tags.map(NoteIntelligence.cleanTag).filter { !$0.isEmpty }
        frontmatter = mergingTags(tags, into: frontmatter)
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        let head = frontmatter.isEmpty ? "" : frontmatter.joined(separator: "\n") + "\n\n"
        return head + callout + body + (body.isEmpty ? "" : "\n")
    }

    /// 合併標籤到 YAML 屬性（沒有屬性時建立）。只處理清單或單行陣列格式的 tags。
    static func mergingTags(_ tags: [String], into frontmatter: [String]) -> [String] {
        guard !tags.isEmpty else { return frontmatter }
        var lines = frontmatter.isEmpty ? ["---", "---"] : frontmatter
        let closing = lines.count - 1
        if let index = lines.firstIndex(where: { $0.hasPrefix("tags:") }) {
            let inline = lines[index].dropFirst(5).trimmingCharacters(in: .whitespaces)
            var existing: [String] = []
            var end = index + 1
            if inline.hasPrefix("[") {
                existing = inline.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            } else if !inline.isEmpty {
                existing = [inline]
            }
            while end < closing, lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                existing.append(lines[end].trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))
                end += 1
            }
            let merged = existing + tags.filter { !existing.contains($0) }
            lines.replaceSubrange(index..<end, with: ["tags:"] + merged.map { "  - \($0)" })
        } else {
            lines.insert(contentsOf: ["tags:"] + tags.map { "  - \($0)" }, at: closing)
        }
        return lines
    }
}
