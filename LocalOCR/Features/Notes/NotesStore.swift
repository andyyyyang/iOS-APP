import Foundation
import Observation

/// 筆記中的一個待辦。
struct NoteTask: Identifiable, Hashable, Sendable {
    let notePath: String
    let noteTitle: String
    let text: String
    /// 在這則筆記中是第幾個待辦（含已完成的），切換時用。
    let index: Int
    let done: Bool
    let mtime: Date

    var id: String { "\(notePath)#\(index)" }
}

/// 筆記清單中的一則（一個 .md 檔）。
struct NoteSummary: Identifiable, Hashable, Sendable {
    let path: String
    let title: String
    let folder: String
    let mtime: Date
    let snippet: String
    let tags: [String]
    /// 手寫筆記本（frontmatter 有 localocr-notebook）的代碼。
    let notebookID: String?
    /// 第一張內嵌圖片（清單縮圖）。
    let firstEmbed: String?
    let tasks: [NoteTask]
    /// [[連結]] 的目標名稱（關聯圖、反向連結）。
    let links: [String]

    var id: String { path }
    var isNotebook: Bool { notebookID != nil }
}

/// vault 中筆記以外的檔案（圖片、PDF、Canvas…）。
struct VaultItem: Identifiable, Hashable, Sendable {
    let path: String
    let size: Int
    let mtime: Date
    /// false：還在 Railway 空間，尚未下載到這台裝置（打開時下載）。
    let isLocal: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var pathExtension: String { (path as NSString).pathExtension.lowercased() }

    var systemImage: String {
        switch pathExtension {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "canvas": return "rectangle.3.group"
        case "mp3", "m4a", "wav", "ogg", "flac", "webm": return "waveform"
        case "mp4", "mov", "mkv", "ogv": return "film"
        case "zip": return "doc.zipper"
        case "csv", "xlsx", "xls": return "tablecells"
        default: return "doc"
        }
    }

    /// App 自己的筆跡資料（手寫筆記本、手寫區塊）：會同步，但不在檔案清單中顯示。
    var isInternal: Bool {
        pathExtension == NotebookArchive.fileExtension || pathExtension == InkFiles.fileExtension
    }
}

/// 筆記的索引與操作。檔案是唯一的資料來源（本機 vault 鏡像），這裡只是方便查詢的快取。
/// 筆記可以放在 vault 的任何資料夾；筆記以外的檔案也會列在資料夾中。
@MainActor
@Observable
final class NotesStore {
    static let shared = NotesStore()

    private(set) var notes: [NoteSummary] = []
    /// 筆記以外的檔案（本機的，加上尚未下載的雲端檔案）。
    private(set) var files: [VaultItem] = []
    private(set) var folders: [String] = []
    /// 名稱（小寫）→ 筆記路徑，用來解析 [[連結]]。
    private(set) var linkIndex: [String: String] = [:]
    private(set) var isLoading = false
    private var cache: [String: NoteSummary] = [:]
    /// 每則筆記的內容（搜尋用，不必每次輸入都讀檔）。
    private var contents: [String: String] = [:]

    let vault: LocalVault

    init(vault: LocalVault = .shared) {
        self.vault = vault
    }

    /// 重新掃描本機 vault（只重新讀取修改過的筆記）。
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let vault = vault
        let previous = cache
        let previousContents = contents
        let (summaries, contents, localFiles, localFolders) = await Task.detached(priority: .userInitiated) {
            var summaries: [NoteSummary] = []
            var contents: [String: String] = [:]
            var others: [VaultItem] = []
            for file in vault.allFiles() {
                guard file.path.lowercased().hasSuffix(".md") else {
                    others.append(VaultItem(path: file.path, size: file.size, mtime: file.mtime, isLocal: true))
                    continue
                }
                if let cached = previous[file.path], cached.mtime == file.mtime, let text = previousContents[file.path] {
                    summaries.append(cached)
                    contents[file.path] = text
                } else {
                    let text = vault.readText(file.path) ?? ""
                    summaries.append(NotesStore.summarize(path: file.path, mtime: file.mtime, text: text))
                    contents[file.path] = text
                }
            }
            return (summaries, contents, others, vault.allFolders())
        }.value
        cache = Dictionary(summaries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        self.contents = contents
        notes = summaries.sorted { $0.mtime > $1.mtime }
        linkIndex = NoteLinks.index(notes)

        // 尚未下載的雲端檔案也列出來（以及它們所在的資料夾）
        let localPaths = Set(localFiles.map(\.path))
        let pending = VaultSyncCenter.shared.pendingFiles
            .filter { !localPaths.contains($0.path) && !$0.path.lowercased().hasSuffix(".md") }
            .map { VaultItem(path: $0.path, size: $0.size, mtime: $0.mtime, isLocal: false) }
        files = (localFiles + pending).filter { !$0.isInternal }
        var allFolders = Set(localFolders)
        for item in pending {
            var folder = item.folder
            while !folder.isEmpty && allFolders.insert(folder).inserted {
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        folders = allFolders.filter { !LocalVault.isHidden($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated static func summarize(path: String, mtime: Date, text: String) -> NoteSummary {
        let blocks = MarkdownParser.blocks(from: text)
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var tasks: [NoteTask] = []
        var tags: [String] = []
        var notebookID: String?
        var snippet = ""
        var firstEmbed: String?
        for block in blocks {
            switch block {
            case .properties(let items):
                for item in items {
                    if item.key == "tags" {
                        tags = item.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                    if item.key == NotebookFiles.frontmatterKey { notebookID = item.value }
                }
            case .paragraph(let value) where snippet.isEmpty:
                snippet = String(value.prefix(160))
            case .listItem(_, _, let value) where snippet.isEmpty:
                snippet = value
            case .callout(_, _, let body) where snippet.isEmpty:
                snippet = String(body.prefix(160))
            case .embed(let embed) where firstEmbed == nil:
                firstEmbed = embed
            default:
                break
            }
            if case .listItem(.task(let done), _, let value) = block {
                tasks.append(NoteTask(notePath: path, noteTitle: name, text: value, index: tasks.count, done: done, mtime: mtime))
            }
        }
        let folder = (path as NSString).deletingLastPathComponent
        return NoteSummary(
            path: path,
            title: name,
            folder: folder,
            mtime: mtime,
            snippet: snippet.replacingOccurrences(of: "\n", with: " "),
            tags: tags,
            notebookID: notebookID?.isEmpty == false ? notebookID : nil,
            firstEmbed: firstEmbed,
            tasks: tasks,
            links: NoteLinks.targets(in: text)
        )
    }

    // MARK: - 查詢

    /// 尚未完成的待辦，最近編輯的筆記在前。
    var openTasks: [NoteTask] {
        notes.flatMap { $0.tasks.filter { !$0.done } }
    }

    var notebookCount: Int { notes.filter(\.isNotebook).count }

    var editedTodayCount: Int { notes.filter { Calendar.current.isDateInToday($0.mtime) }.count }

    /// 資料夾（含子資料夾）中的筆記數；空字串是整個 vault。
    func noteCount(inFolder folder: String) -> Int {
        notes.filter { Self.isInside($0.folder, folder) }.count
    }

    /// 資料夾（含子資料夾）中的檔案數（筆記加上其他檔案）。
    func fileCount(inFolder folder: String) -> Int {
        noteCount(inFolder: folder) + files.filter { Self.isInside($0.folder, folder) }.count
    }

    /// 資料夾本身（不含子資料夾）中筆記以外的檔案，依名稱排序。
    func files(inFolder folder: String) -> [VaultItem] {
        files.filter { $0.folder == folder }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `folder` 是否在 `ancestor` 之中（或就是它）；`ancestor` 為空字串時是整個 vault。
    nonisolated static func isInside(_ folder: String, _ ancestor: String) -> Bool {
        ancestor.isEmpty || folder == ancestor || folder.hasPrefix(ancestor + "/")
    }

    /// 筆記目前的內容（快取，沒有時讀檔）。
    func text(of path: String) -> String? {
        contents[path] ?? vault.readText(path)
    }

    /// 這則筆記連到的其他筆記（路徑，不重複）。
    func outgoingLinks(of note: NoteSummary) -> [String] {
        var seen = Set<String>()
        return note.links.compactMap { NoteLinks.resolve($0, in: linkIndex) }.filter { $0 != note.path && seen.insert($0).inserted }
    }

    /// 連到這則筆記的其他筆記（反向連結），最近編輯的在前。
    func backlinks(to path: String) -> [NoteSummary] {
        notes.filter { note in
            note.path != path && note.links.contains { NoteLinks.resolve($0, in: linkIndex) == path }
        }
    }

    /// 資料夾的顯示名稱；最上層（空字串）顯示 vault 名稱。
    static func folderTitle(_ folder: String) -> String {
        guard !folder.isEmpty else { return NotesSettings.vaultName.isEmpty ? "Vault" : NotesSettings.vaultName }
        return (folder as NSString).lastPathComponent
    }

    /// 直接的子資料夾（依名稱排序）；`parent` 為空字串時是最上層。
    func childFolders(of parent: String) -> [String] {
        folders.filter { folder in
            let folderParent = (folder as NSString).deletingLastPathComponent
            return folderParent == parent
        }
    }

    /// 標籤與使用的筆記數，依數量排序。
    var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for note in notes {
            for tag in Set(note.tags) { counts[tag, default: 0] += 1 }
        }
        return counts.map { (tag: $0.key, count: $0.value) }.sorted { $0.count == $1.count ? $0.tag < $1.tag : $0.count > $1.count }
    }

    /// 切換某則筆記的待辦（儀表板上直接打勾）。
    func toggle(_ task: NoteTask) {
        guard let text = vault.readText(task.notePath) else { return }
        try? save(NoteMarkdownEditing.togglingTask(at: task.index, in: text), to: task.notePath)
    }

    /// `recursive: false` 只列出這個資料夾本身的筆記（資料夾頁面中子資料夾另外顯示）。
    func notes(inFolder folder: String?, recursive: Bool = true, notebooksOnly: Bool = false, tag: String? = nil, query: String = "") -> [NoteSummary] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.filter { note in
            if notebooksOnly && !note.isNotebook { return false }
            if let tag, !note.tags.contains(tag) { return false }
            if let folder {
                if recursive {
                    if !Self.isInside(note.folder, folder) { return false }
                } else if note.folder != folder {
                    return false
                }
            }
            guard !query.isEmpty else { return true }
            if note.title.localizedCaseInsensitiveContains(query) || note.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
                return true
            }
            return (contents[note.path] ?? vault.readText(note.path))?.localizedCaseInsensitiveContains(query) ?? false
        }
    }

    // MARK: - 操作

    /// 不重複的路徑：「資料夾/標題.md」，同名時加上編號。
    func uniquePath(folder: String, title: String, extension ext: String = "md") -> String {
        let base = (folder.isEmpty ? "" : folder + "/") + NotebookMarkdown.fileName(for: title)
        var candidate = "\(base).\(ext)"
        var number = 2
        while vault.exists(candidate) {
            candidate = "\(base) \(number).\(ext)"
            number += 1
        }
        return candidate
    }

    func createTextNote(in folder: String, title: String) throws -> String {
        let path = uniquePath(folder: folder, title: title)
        try vault.writeText("", to: path)
        changed()
        return path
    }

    func save(_ text: String, to path: String) throws {
        guard vault.readText(path) != text else { return }
        try vault.writeText(text, to: path)
        changed()
    }

    /// 改名：同步時舊檔會從 Railway 空間刪除、新檔上傳。
    func rename(_ path: String, to title: String) throws -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let current = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard NotebookMarkdown.fileName(for: title) != current else { return path }
        let target = uniquePath(folder: folder, title: title)
        try vault.move(path, to: target)
        changed()
        return target
    }

    func delete(_ path: String) throws {
        try vault.delete(path)
        changed()
    }

    func createFolder(_ path: String) throws {
        try vault.createFolder(path)
        Task { await reload() }
    }

    private func changed() {
        VaultSyncCenter.shared.localDidChange()
        Task { await reload() }
    }
}

extension LocalVault {
    /// . 開頭的檔案或資料夾（.obsidian、.trash 等）不顯示也不同步。
    static func isHidden(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

/// Obsidian 的 [[連結]]：從筆記中找出目標，並依檔名或路徑解析成筆記。
enum NoteLinks {
    private static let pattern = try! NSRegularExpression(pattern: #"(!?)\[\[([^\]\|#\^]+)[^\]]*\]\]"#)
    /// 內嵌圖片、PDF 等附件不算筆記之間的連結。
    private static let attachmentExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "svg", "pdf", "mp3", "m4a", "wav", "ogg", "mp4", "mov", "webm", "canvas", "ink",
    ]

    /// 筆記中連到的目標名稱（不含 #標題與 |別名，不重複）。
    static func targets(in text: String) -> [String] {
        let ns = text as NSString
        var seen = Set<String>()
        var result: [String] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let target = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, !attachmentExtensions.contains((target as NSString).pathExtension.lowercased()) else { continue }
            if seen.insert(target.lowercased()).inserted { result.append(target) }
        }
        return result
    }

    /// 名稱（小寫）→ 路徑：檔名與不含副檔名的完整路徑都能找到筆記；同名時取路徑較短的。
    static func index(_ notes: [NoteSummary]) -> [String: String] {
        var index: [String: String] = [:]
        for note in notes.sorted(by: { $0.path.count < $1.path.count }) {
            let withoutExtension = String(note.path.dropLast(3)).lowercased()
            index[withoutExtension] = index[withoutExtension] ?? note.path
            index[note.title.lowercased()] = index[note.title.lowercased()] ?? note.path
        }
        return index
    }

    static func resolve(_ target: String, in index: [String: String]) -> String? {
        var key = target.lowercased()
        if key.hasSuffix(".md") { key = String(key.dropLast(3)) }
        return index[key] ?? index[(key as NSString).lastPathComponent]
    }
}

/// 筆記中的一個標題（右側大綱）。
struct NoteHeading: Identifiable, Hashable {
    let level: Int
    let title: String
    /// 原始文字中的行號（編輯模式跳轉）。
    let line: Int
    /// MarkdownParser 的區塊序號（閱讀模式跳轉）。
    let block: Int

    var id: Int { block }
}

enum NoteOutline {
    static func headings(in text: String) -> [NoteHeading] {
        let blocks = MarkdownParser.blocks(from: text)
        var parsed: [(block: Int, level: Int, title: String)] = []
        for (offset, block) in blocks.enumerated() {
            if case .heading(let level, let title) = block { parsed.append((offset, level, title)) }
        }
        // 對應的行號：與 MarkdownParser 相同，略過屬性區與程式碼區塊
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var start = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            start = end + 1
        }
        var headingLines: [Int] = []
        var inCode = false
        for (index, line) in lines.enumerated() where index >= start {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if !inCode, (1...6).contains(hashes), trimmed.dropFirst(hashes).hasPrefix(" ") { headingLines.append(index) }
        }
        return parsed.enumerated().map { index, item in
            NoteHeading(level: item.level, title: item.title, line: index < headingLines.count ? headingLines[index] : 0, block: item.block)
        }
    }
}
