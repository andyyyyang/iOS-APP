import Foundation
import Observation

/// vault 遠端的操作（VaultClient 實作；測試用假的實作）。
protocol VaultRemote: Sendable {
    func list(prefix: String, recursive: Bool) async throws -> VaultListing
    func read(_ path: String) async throws -> VaultFile
    @discardableResult
    func write(_ path: String, data: Data, contentType: String, condition: VaultClient.WriteCondition, mtime: Date) async throws -> VaultEntry
    func delete(_ path: String, ifMatch: String?) async throws
}

extension VaultClient: VaultRemote {}

enum VaultSyncError: LocalizedError {
    case remoteLooksEmpty
    case tooManyDeletions(local: Int, remote: Int)

    var errorDescription: String? {
        switch self {
        case .remoteLooksEmpty:
            return "Railway 空間是空的，為了避免刪除這台裝置上的筆記，已停止同步。請確認 Obsidian 已上傳 vault。"
        case .tooManyDeletions(let local, let remote):
            return "這次同步會刪除 \(local + remote) 個檔案，為了安全已停止。請確認後在設定中按「仍要同步」。"
        }
    }
}

/// 本機 vault 與 Railway 空間的雙向同步（三方比對）：
/// 以上次同步時記下的 ETag（遠端）與內容雜湊（本機）判斷哪一邊改過；
/// 兩邊都改過時保留兩份（本機版本另存為「（iPad 衝突 …）」），不會覆蓋任何一邊的內容。
/// Markdown、筆記本與手寫資料一律下載；圖片、PDF 等附件需要時才下載。
actor VaultSyncEngine {
    struct FileState: Codable, Equatable {
        var etag: String
        var hash: String
    }

    struct Report: Equatable {
        var downloaded = 0
        var uploaded = 0
        var deleted = 0
        var conflicts: [String] = []

        var changedLocalFiles: Bool { downloaded + deleted + conflicts.count > 0 }
        var isEmpty: Bool { downloaded + uploaded + deleted + conflicts.count == 0 }
    }

    /// 一律下載的檔案類型（其他類型在需要時才下載）。
    static let eagerExtensions: Set<String> = ["md", "txt", "json", "canvas", NotebookArchive.fileExtension, InkFiles.fileExtension]
    /// 超過這個大小的遠端檔案不會自動下載。
    static let eagerSizeLimit = 5 * 1024 * 1024

    let vault: LocalVault
    private let stateURL: URL
    private var state: [String: FileState]
    /// 上次同步時遠端的檔案（包含尚未下載的附件），用來依檔名找附件。
    private(set) var remoteFiles: [String: VaultEntry] = [:]
    private let now: @Sendable () -> Date

    init(vault: LocalVault, stateURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.vault = vault
        self.stateURL = stateURL
        self.now = now
        state = (try? JSONDecoder().decode([String: FileState].self, from: Data(contentsOf: stateURL))) ?? [:]
    }

    var trackedPaths: Set<String> { Set(state.keys) }

    static func normalizeETag(_ etag: String) -> String {
        var value = etag.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("W/") { value.removeFirst(2) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    static func isEager(_ path: String) -> Bool {
        eagerExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "md": return "text/markdown; charset=utf-8"
        case "txt": return "text/plain; charset=utf-8"
        case "json", "canvas", NotebookArchive.fileExtension: return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }

    /// 衝突時本機版本另存的路徑：「筆記（iPad 衝突 2026-10-13 1405）.md」。
    static func conflictPath(for path: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let ext = (path as NSString).pathExtension
        let base = ext.isEmpty ? path : String(path.dropLast(ext.count + 1))
        let suffix = "（iPad 衝突 \(formatter.string(from: date))）"
        return ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)"
    }

    // MARK: - 同步

    func sync(remote: any VaultRemote, allowMassDeletion: Bool = false) async throws -> Report {
        let listing = try await remote.list(prefix: "", recursive: true)
        let remoteByPath = Dictionary(
            listing.files.filter { !LocalVault.isHidden($0.path) }.map { (LocalVault.normalize($0.path), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        if remoteByPath.isEmpty && state.count > 3 {
            throw VaultSyncError.remoteLooksEmpty
        }
        remoteFiles = remoteByPath
        let localByPath = Dictionary(vault.allFiles().map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        // 1. 規劃
        var downloads: [VaultEntry] = []
        var uploads: [(path: String, base: FileState?)] = []
        var conflicts: [(path: String, remote: VaultEntry)] = []
        var adoptions: [VaultEntry] = []
        var localDeletions: [String] = []
        var remoteDeletions: [(path: String, etag: String)] = []
        var droppedStates: [String] = []

        for path in Set(remoteByPath.keys).union(localByPath.keys).union(state.keys) {
            let remoteEntry = remoteByPath[path]
            let local = localByPath[path]
            let base = state[path]
            switch (remoteEntry, local, base) {
            case let (remoteEntry?, nil, nil):
                if Self.isEager(path) && remoteEntry.size <= Self.eagerSizeLimit { downloads.append(remoteEntry) }
            case let (remoteEntry?, _?, nil):
                adoptions.append(remoteEntry)
            case let (remoteEntry?, _?, base?):
                let remoteChanged = Self.normalizeETag(remoteEntry.etag) != base.etag
                let localChanged = localHash(path) != base.hash
                switch (remoteChanged, localChanged) {
                case (false, false): break
                case (true, false): downloads.append(remoteEntry)
                case (false, true): uploads.append((path, base))
                case (true, true): conflicts.append((path, remoteEntry))
                }
            case (nil, _?, let base?):
                if localHash(path) == base.hash {
                    localDeletions.append(path)
                } else {
                    uploads.append((path, nil))
                }
            case (nil, _?, nil):
                uploads.append((path, nil))
            case let (remoteEntry?, nil, base?):
                if Self.normalizeETag(remoteEntry.etag) == base.etag {
                    remoteDeletions.append((path, base.etag))
                } else {
                    downloads.append(remoteEntry)
                }
            case (nil, nil, _?):
                droppedStates.append(path)
            case (nil, nil, nil):
                break
            }
        }

        // 大量刪除保護
        let limit = max(10, state.count * 3 / 10)
        if !allowMassDeletion && (localDeletions.count > limit || remoteDeletions.count > limit) {
            throw VaultSyncError.tooManyDeletions(local: localDeletions.count, remote: remoteDeletions.count)
        }

        var report = Report()
        // 2. 執行
        for path in droppedStates {
            state[path] = nil
        }
        for path in localDeletions {
            try? vault.delete(path)
            state[path] = nil
            report.deleted += 1
        }
        for (path, etag) in remoteDeletions {
            do {
                try await remote.delete(path, ifMatch: etag)
                state[path] = nil
                report.deleted += 1
            } catch VaultError.notFound {
                state[path] = nil
            } catch VaultError.conflict {
                // 刪除前遠端剛好被修改：下次同步會重新下載
            }
        }
        // 衝突：先把本機版本另存，再下載遠端版本
        for (path, remoteEntry) in conflicts {
            let copy = Self.conflictPath(for: path, date: now())
            try vault.move(path, to: copy)
            uploads.append((copy, nil))
            downloads.append(remoteEntry)
            report.conflicts.append(copy)
        }
        // 兩邊都有、但沒有同步紀錄（例如第一次配對）：內容相同就記下，不同就當衝突處理
        for remoteEntry in adoptions {
            let path = LocalVault.normalize(remoteEntry.path)
            guard let file = try? await remote.read(remoteEntry.path) else { continue }
            let remoteHash = LocalVault.hash(file.data)
            if remoteHash == localHash(path) {
                state[path] = FileState(etag: Self.normalizeETag(remoteEntry.etag), hash: remoteHash)
            } else {
                let copy = Self.conflictPath(for: path, date: now())
                try vault.move(path, to: copy)
                try vault.write(file.data, to: path)
                state[path] = FileState(etag: Self.normalizeETag(file.etag ?? remoteEntry.etag), hash: remoteHash)
                uploads.append((copy, nil))
                report.conflicts.append(copy)
                report.downloaded += 1
            }
        }
        report.downloaded += try await download(downloads, from: remote)
        report.uploaded += try await upload(uploads, to: remote)
        saveState()
        return report
    }

    /// 需要時才下載的附件（圖片等）：回傳本機檔案位置。
    func ensureLocal(_ path: String, remote: any VaultRemote) async throws -> URL {
        let path = LocalVault.normalize(path)
        if vault.exists(path) { return vault.url(for: path) }
        let file = try await remote.read(path)
        try vault.write(file.data, to: path)
        if let etag = file.etag ?? remoteFiles[path]?.etag {
            state[path] = FileState(etag: Self.normalizeETag(etag), hash: LocalVault.hash(file.data))
            saveState()
        }
        return vault.url(for: path)
    }

    /// 依檔名（Obsidian 的 [[連結]]）找路徑：先找本機，再找遠端清單。
    func resolve(name: String, localFiles: [LocalFile]) -> String? {
        let key = name.lowercased()
        if name.contains("/") {
            let normalized = LocalVault.normalize(name)
            if vault.exists(normalized) || remoteFiles[normalized] != nil { return normalized }
        }
        let candidates = localFiles.map(\.path) + remoteFiles.keys.sorted()
        return candidates.first { ($0 as NSString).lastPathComponent.lowercased() == key }
            ?? candidates.first { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() == key }
    }

    // MARK: - Helpers

    private func localHash(_ path: String) -> String? {
        (try? vault.read(path)).map(LocalVault.hash)
    }

    private func download(_ entries: [VaultEntry], from remote: any VaultRemote) async throws -> Int {
        var count = 0
        var index = 0
        // 同時最多 6 個下載
        while index < entries.count {
            let batch = entries[index..<min(index + 6, entries.count)]
            index += batch.count
            let results = await withTaskGroup(of: (VaultEntry, VaultFile?).self) { group in
                for entry in batch {
                    group.addTask { (entry, try? await remote.read(entry.path)) }
                }
                var collected: [(VaultEntry, VaultFile?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (entry, file) in results {
                guard let file else { continue }
                let path = LocalVault.normalize(entry.path)
                try vault.write(file.data, to: path)
                state[path] = FileState(etag: Self.normalizeETag(file.etag ?? entry.etag), hash: LocalVault.hash(file.data))
                count += 1
            }
        }
        return count
    }

    private func upload(_ items: [(path: String, base: FileState?)], to remote: any VaultRemote) async throws -> Int {
        var count = 0
        for (path, base) in items {
            guard let data = try? vault.read(path) else { continue }
            let condition: VaultClient.WriteCondition = base.map { .ifMatch($0.etag) } ?? .createOnly
            do {
                let entry = try await remote.write(path, data: data, contentType: Self.contentType(for: path), condition: condition, mtime: now())
                state[path] = FileState(etag: Self.normalizeETag(entry.etag), hash: LocalVault.hash(data))
                count += 1
            } catch VaultError.conflict {
                // 上傳時遠端剛好也改了：清掉紀錄，下次同步會當成衝突處理，兩份都保留
                state[path] = nil
            }
        }
        return count
    }

    private func saveState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }
}

/// App 的同步中樞：自動同步（開啟 App、修改筆記後、定時）、狀態顯示、需要時下載附件。
@MainActor
@Observable
final class VaultSyncCenter {
    static let shared = VaultSyncCenter()

    var isSyncing = false
    var lastSyncedAt: Date?
    var lastError: String?
    var lastReport: VaultSyncEngine.Report?
    /// 本機檔案變動（同步下載或 App 編輯）時遞增，畫面據此重新整理。
    var revision = 0

    let vault: LocalVault
    let engine: VaultSyncEngine
    private var scheduled: Task<Void, Never>?
    private var periodic: Task<Void, Never>?

    init(vault: LocalVault = .shared) {
        self.vault = vault
        engine = VaultSyncEngine(
            vault: vault,
            stateURL: URL.applicationSupportDirectory.appending(path: "VaultSyncState.json")
        )
        try? FileManager.default.createDirectory(at: vault.root, withIntermediateDirectories: true)
    }

    var isConfigured: Bool { VaultClient.configured() != nil }

    func syncNow(allowMassDeletion: Bool = false) async {
        guard !isSyncing, let client = VaultClient.configured() else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let report = try await engine.sync(remote: client, allowMassDeletion: allowMassDeletion)
            lastReport = report
            lastSyncedAt = Date()
            lastError = nil
            if report.changedLocalFiles { revision += 1 }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 修改筆記後呼叫：更新畫面，幾秒後同步（連續修改只會同步一次）。
    func localDidChange() {
        revision += 1
        scheduleSync(after: 3)
    }

    func scheduleSync(after seconds: Double) {
        scheduled?.cancel()
        scheduled = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await syncNow()
        }
    }

    /// App 在前景時每 3 分鐘同步一次（抓 Obsidian 端的修改）。
    func startPeriodicSync() {
        periodic?.cancel()
        periodic = Task {
            while !Task.isCancelled {
                await syncNow()
                try? await Task.sleep(for: .seconds(180))
            }
        }
    }

    func stopPeriodicSync() {
        periodic?.cancel()
        periodic = nil
    }

    /// 依檔名或路徑取得本機檔案（附件需要時才下載）。
    func localURL(forEmbed name: String) async -> URL? {
        let files = vault.allFiles()
        guard let path = await engine.resolve(name: name, localFiles: files) else { return nil }
        if vault.exists(path) { return vault.url(for: path) }
        guard let client = VaultClient.configured() else { return nil }
        return try? await engine.ensureLocal(path, remote: client)
    }
}
