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

    var id: String { path }
    var isNotebook: Bool { notebookID != nil }
}

/// 筆記的索引與操作。檔案是唯一的資料來源（本機 vault 鏡像中的 .md），這裡只是方便查詢的快取。
@MainActor
@Observable
final class NotesStore {
    static let shared = NotesStore()

    private(set) var notes: [NoteSummary] = []
    private(set) var folders: [String] = []
    private(set) var isLoading = false
    private var cache: [String: NoteSummary] = [:]

    let vault: LocalVault

    init(vault: LocalVault = .shared) {
        self.vault = vault
    }

    /// 重新掃描本機 vault（只重新讀取修改過的檔案）。
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let vault = vault
        let previous = cache
        let (summaries, folders) = await Task.detached(priority: .userInitiated) {
            let files = vault.allFiles().filter { $0.path.lowercased().hasSuffix(".md") }
            let summaries = files.map { file -> NoteSummary in
                if let cached = previous[file.path], cached.mtime == file.mtime { return cached }
                return NotesStore.summarize(path: file.path, mtime: file.mtime, text: vault.readText(file.path) ?? "")
            }
            return (summaries, vault.allFolders())
        }.value
        cache = Dictionary(summaries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        notes = summaries.sorted { $0.mtime > $1.mtime }
        self.folders = folders.filter { !LocalVault.isHidden($0) && !$0.hasSuffix("附件") && !$0.contains("/附件/") }
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
            tasks: tasks
        )
    }

    // MARK: - 查詢

    /// 尚未完成的待辦，最近編輯的筆記在前。
    var openTasks: [NoteTask] {
        notes.flatMap { $0.tasks.filter { !$0.done } }
    }

    var notebookCount: Int { notes.filter(\.isNotebook).count }

    var editedTodayCount: Int { notes.filter { Calendar.current.isDateInToday($0.mtime) }.count }

    /// 資料夾（含子資料夾）中的筆記數。
    func noteCount(inFolder folder: String) -> Int {
        notes.filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }.count
    }

    /// 直接的子資料夾；`parent` 為空字串時是最上層。
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
                    if note.folder != folder && !note.folder.hasPrefix(folder + "/") { return false }
                } else if note.folder != folder {
                    return false
                }
            }
            guard !query.isEmpty else { return true }
            if note.title.localizedCaseInsensitiveContains(query) || note.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
                return true
            }
            return vault.readText(note.path)?.localizedCaseInsensitiveContains(query) ?? false
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
