import Foundation
import Observation

/// 伺服器的 vault 索引（GET /v1/vault/index）：每則筆記的標題、別名、標籤、連結、待辦與摘要。
/// 關聯圖、反向連結、標籤與待辦因此涵蓋整個 vault，不只是這台裝置上已下載的筆記；索引只有幾百 KB，不必下載筆記本身。
struct VaultIndex: Codable, Sendable, Equatable {
    struct TaskItem: Codable, Sendable, Equatable {
        var text: String
        var done: Bool
    }

    /// 屬性（frontmatter）的一個值：文字、文字清單，或空值（空白或巢狀）。
    enum Property: Codable, Sendable, Equatable {
        case text(String)
        case list([String])
        case empty

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .empty
            } else if let text = try? container.decode(String.self) {
                self = .text(text)
            } else if let list = try? container.decode([String].self) {
                self = .list(list)
            } else {
                self = .empty
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .list(let list): try container.encode(list)
            case .empty: try container.encodeNil()
            }
        }

        /// JSONSerialization 用的值。
        var jsonObject: Any {
            switch self {
            case .text(let text): return text
            case .list(let list): return list
            case .empty: return NSNull()
            }
        }
    }

    struct Note: Codable, Sendable, Equatable {
        var path: String
        /// 毫秒。
        var mtime: Double
        var size: Int
        var etag: String
        var title: String
        var aliases: [String]
        var tags: [String]
        var links: [String]
        var firstEmbed: String?
        var tasks: [TaskItem]
        var snippet: String
        var notebook: String?
        /// 屬性（frontmatter），DataviewJS 的頁面欄位。
        var properties: [String: Property]
        /// 內文中的 Dataview 欄位（Key:: value、[key:: value]）。
        var fields: [String: Property]

        init(path: String, mtime: Double, size: Int = 0, etag: String = "", title: String? = nil, aliases: [String] = [], tags: [String] = [],
             links: [String] = [], firstEmbed: String? = nil, tasks: [TaskItem] = [], snippet: String = "", notebook: String? = nil,
             properties: [String: Property] = [:], fields: [String: Property] = [:]) {
            self.path = path
            self.mtime = mtime
            self.size = size
            self.etag = etag
            self.title = title ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            self.aliases = aliases
            self.tags = tags
            self.links = links
            self.firstEmbed = firstEmbed
            self.tasks = tasks
            self.snippet = snippet
            self.notebook = notebook
            self.properties = properties
            self.fields = fields
        }

        // 欄位缺少時用預設值（伺服器之後加欄位或省略空欄位都能解析）
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let path = try container.decode(String.self, forKey: .path)
            self.init(
                path: path,
                mtime: try container.decodeIfPresent(Double.self, forKey: .mtime) ?? 0,
                size: try container.decodeIfPresent(Int.self, forKey: .size) ?? 0,
                etag: try container.decodeIfPresent(String.self, forKey: .etag) ?? "",
                title: try container.decodeIfPresent(String.self, forKey: .title),
                aliases: try container.decodeIfPresent([String].self, forKey: .aliases) ?? [],
                tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? [],
                links: try container.decodeIfPresent([String].self, forKey: .links) ?? [],
                firstEmbed: try container.decodeIfPresent(String.self, forKey: .firstEmbed),
                tasks: try container.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? [],
                snippet: try container.decodeIfPresent(String.self, forKey: .snippet) ?? "",
                notebook: try container.decodeIfPresent(String.self, forKey: .notebook),
                properties: (try? container.decodeIfPresent([String: Property].self, forKey: .properties)) ?? [:],
                fields: (try? container.decodeIfPresent([String: Property].self, forKey: .fields)) ?? [:]
            )
        }

        var modified: Date { Date(timeIntervalSince1970: mtime / 1000) }

        /// 轉成筆記清單用的摘要（還沒下載的筆記）。
        func summary() -> NoteSummary {
            let modified = modified
            let tasks = tasks.enumerated().map { index, task in
                NoteTask(notePath: path, noteTitle: title, text: task.text, index: index, done: task.done, mtime: modified)
            }
            return NoteSummary(
                path: path,
                title: title,
                folder: (path as NSString).deletingLastPathComponent,
                mtime: modified,
                snippet: snippet,
                tags: tags,
                notebookID: notebook?.isEmpty == false ? notebook : nil,
                firstEmbed: firstEmbed,
                tasks: tasks,
                links: links,
                isLocal: false,
                aliases: aliases
            )
        }
    }

    struct File: Codable, Sendable, Equatable {
        var path: String
        var mtime: Double
        var size: Int
    }

    var version: Int
    var notes: [Note]
    var files: [File]

    init(version: Int = 1, notes: [Note], files: [File] = []) {
        self.version = version
        self.notes = notes
        self.files = files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        notes = try container.decodeIfPresent([Note].self, forKey: .notes) ?? []
        files = try container.decodeIfPresent([File].self, forKey: .files) ?? []
    }
}

/// 索引的快取與更新：存在這台裝置上（下次打開 App 立刻可用），伺服器有變動時重新取得（用 ETag，沒變時不重傳）。
/// 只用在 vault 放在 LocalOCR 伺服器時（WebDAV 的內容伺服器看不到）。
@MainActor
@Observable
final class VaultIndexStore {
    static let shared = VaultIndexStore()

    private(set) var notes: [String: VaultIndex.Note] = [:]
    private(set) var files: [VaultIndex.File] = []
    private(set) var updatedAt: Date?
    /// 伺服器還沒有索引（舊版）：用本機的資料。
    private(set) var isSupported = true

    @ObservationIgnored private var etag: String?
    /// 目前的索引屬於哪個伺服器。
    @ObservationIgnored private var server: String?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL

    private struct Saved: Codable {
        var etag: String?
        /// 索引所屬的伺服器（重新配對到別的伺服器時不使用）。
        var server: String?
        var index: VaultIndex
    }

    private static var currentServer: String? { ServerSettings.baseURL?.absoluteString }

    init(fileURL: URL = .applicationSupportDirectory.appending(path: "vault-index.json")) {
        self.fileURL = fileURL
    }

    var isActive: Bool { VaultBackend.storage == .server && VaultClient.configured() != nil }

    /// 讀取上次存下的索引。
    func load() async {
        guard !loaded else { return }
        loaded = true
        let url = fileURL
        let saved = await Task.detached(priority: .utility) {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        }.value
        guard let saved, notes.isEmpty, saved.server == Self.currentServer else { return }
        etag = saved.etag
        apply(saved.index)
        server = saved.server
    }

    /// 從伺服器取得最新的索引（同時只有一個請求）。有變動時回傳 true。
    @discardableResult
    func refresh() async -> Bool {
        if let refreshTask {
            return await refreshTask.value
        }
        let task = Task { await fetch() }
        refreshTask = task
        let changed = await task.value
        refreshTask = nil
        return changed
    }

    /// 稍後更新（連續的變動合併成一次）。
    func scheduleRefresh(after seconds: Double = 1.5) {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if await self.refresh() { await NotesStore.shared.reload() }
        }
    }

    /// 切換了還沒下載的筆記中的待辦：先更新畫面，伺服器的索引稍後跟上。
    func setTask(in path: String, index: Int, done: Bool) {
        let key = LocalVault.normalize(path)
        guard var note = notes[key], note.tasks.indices.contains(index) else { return }
        note.tasks[index].done = done
        notes[key] = note
    }

    /// 換了伺服器或同步空間：清掉舊的索引。
    func reset() {
        server = nil
        notes = [:]
        files = []
        etag = nil
        updatedAt = nil
        isSupported = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func fetch() async -> Bool {
        await load()
        guard isActive, let client = VaultClient.configured() else { return false }
        if server != Self.currentServer, !notes.isEmpty {
            // 重新配對到別的伺服器
            notes = [:]
            files = []
            etag = nil
        }
        do {
            guard let result = try await client.index(etag: notes.isEmpty ? nil : etag) else {
                updatedAt = Date()
                return false
            }
            isSupported = true
            etag = result.etag
            apply(result.index)
            server = Self.currentServer
            let saved = Saved(etag: result.etag, server: Self.currentServer, index: result.index)
            let url = fileURL
            Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
            }
            return true
        } catch VaultError.notFound {
            isSupported = false
            return false
        } catch {
            return false
        }
    }

    private func apply(_ index: VaultIndex) {
        notes = Dictionary(index.notes.map { (LocalVault.normalize($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        files = index.files
        updatedAt = Date()
    }
}
