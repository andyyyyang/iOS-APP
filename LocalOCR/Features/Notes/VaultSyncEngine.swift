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

/// 這台裝置上保留哪些 vault 檔案。
enum VaultDownloadPolicy: String, CaseIterable, Identifiable, Sendable {
    /// 只同步檔案清單，打開時才下載、編輯當下上傳；最近沒打開的檔案自動從這台裝置移除（預設，最省空間）。
    case onDemand
    /// 筆記等文字檔全部下載，圖片、PDF 等打開時才下載。
    case notes
    /// 全部下載（超過 `VaultSyncEngine.autoDownloadLimit` 的檔案除外）。
    case everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDemand: return "打開時才下載"
        case .notes: return "下載所有筆記"
        case .everything: return "下載所有檔案"
        }
    }
}

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
/// 整個 vault 都會同步（. 開頭的 .obsidian、.trash 除外）；哪些檔案下載到這台裝置依 `VaultDownloadPolicy`。
/// 按需模式下這台裝置只是快取：遠端清單記在檔案中（離線也能瀏覽），移除快取的檔案只刪本機、不會刪到遠端。
actor VaultSyncEngine {
    struct FileState: Codable, Equatable {
        var etag: String
        var hash: String
        /// 記錄時本機檔案的修改時間（秒）與大小：兩者都沒變就不必重新計算雜湊，大型 vault 每次同步不用讀遍所有檔案。
        var mtime: Double?
        var size: Int?
        /// 上次在這台裝置上打開或編輯的時間（秒）；按需模式依此決定保留哪些檔案。
        var opened: Double?
    }

    /// 遠端清單存檔用的格式。
    private struct IndexEntry: Codable {
        let path: String
        let size: Int
        let mtime: Double
        let etag: String
    }

    typealias ProgressHandler = @Sendable (_ done: Int, _ total: Int) -> Void

    struct Report: Equatable {
        var downloaded = 0
        var uploaded = 0
        var deleted = 0
        var conflicts: [String] = []

        var changedLocalFiles: Bool { downloaded + deleted + conflicts.count > 0 }
        var isEmpty: Bool { downloaded + uploaded + deleted + conflicts.count == 0 }
    }

    /// 不下載所有檔案時，仍一律下載的類型（其他類型在需要時才下載）。
    static let essentialExtensions: Set<String> = ["md", "txt", "json", "canvas", NotebookArchive.fileExtension, InkFiles.fileExtension]
    /// 超過這個大小的檔案不會自動下載（打開時才下載）。
    static let autoDownloadLimit = 100 * 1024 * 1024
    /// 超過這個大小的檔案一次下載一個，避免同時佔用太多記憶體。
    static let parallelDownloadLimit = 8 * 1024 * 1024

    let vault: LocalVault
    private let stateURL: URL
    private let indexURL: URL
    private var state: [String: FileState]
    /// 遠端的檔案（上次同步時的清單，之後上傳、刪除時更新；包含尚未下載的檔案），存在檔案中，啟動時就能顯示。
    private(set) var remoteFiles: [String: VaultEntry] = [:]
    private let now: @Sendable () -> Date

    init(vault: LocalVault, stateURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.vault = vault
        self.stateURL = stateURL
        indexURL = stateURL.deletingLastPathComponent().appending(path: stateURL.deletingPathExtension().lastPathComponent + "-remote.json")
        self.now = now
        state = (try? JSONDecoder().decode([String: FileState].self, from: Data(contentsOf: stateURL))) ?? [:]
        let index = (try? JSONDecoder().decode([IndexEntry].self, from: Data(contentsOf: indexURL))) ?? []
        remoteFiles = Dictionary(
            index.map { (LocalVault.normalize($0.path), VaultEntry(path: $0.path, size: $0.size, mtime: Date(timeIntervalSince1970: $0.mtime), etag: $0.etag)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var trackedPaths: Set<String> { Set(state.keys) }

    static func normalizeETag(_ etag: String) -> String {
        var value = etag.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("W/") { value.removeFirst(2) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// 遠端新出現的檔案是否在同步時直接下載。
    static func shouldDownload(_ entry: VaultEntry, policy: VaultDownloadPolicy) -> Bool {
        guard entry.size <= autoDownloadLimit else { return false }
        switch policy {
        case .onDemand: return false
        case .notes: return essentialExtensions.contains((entry.path as NSString).pathExtension.lowercased())
        case .everything: return true
        }
    }

    static func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "md": return "text/markdown; charset=utf-8"
        case "txt": return "text/plain; charset=utf-8"
        case "json", "canvas", NotebookArchive.fileExtension: return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "csv": return "text/csv; charset=utf-8"
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
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

    /// - Parameters:
    ///   - policy: 遠端新出現的檔案是否下載（這台裝置上已有的檔案一律保持最新）。
    ///   - progress: 下載進度（已完成、總數）。
    func sync(
        remote: any VaultRemote,
        allowMassDeletion: Bool = false,
        policy: VaultDownloadPolicy = .everything,
        progress: ProgressHandler? = nil
    ) async throws -> Report {
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
                if Self.shouldDownload(remoteEntry, policy: policy) { downloads.append(remoteEntry) }
            case let (remoteEntry?, _?, nil):
                adoptions.append(remoteEntry)
            case let (remoteEntry?, local?, base?):
                let remoteChanged = Self.normalizeETag(remoteEntry.etag) != base.etag
                let localChanged = hasLocalChanges(local, since: base)
                switch (remoteChanged, localChanged) {
                case (false, false): break
                case (true, false): downloads.append(remoteEntry)
                case (false, true): uploads.append((path, base))
                case (true, true): conflicts.append((path, remoteEntry))
                }
            case (nil, let local?, let base?):
                if !hasLocalChanges(local, since: base) {
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
                remoteFiles[path] = nil
                report.deleted += 1
            } catch VaultError.notFound {
                state[path] = nil
                remoteFiles[path] = nil
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
            let before = stamp(path)
            if remoteHash == localHash(path) {
                record(path, etag: remoteEntry.etag, hash: remoteHash, stamp: before)
            } else {
                let copy = Self.conflictPath(for: path, date: now())
                try vault.move(path, to: copy)
                try vault.write(file.data, to: path)
                record(path, etag: file.etag ?? remoteEntry.etag, hash: remoteHash)
                uploads.append((copy, nil))
                report.conflicts.append(copy)
                report.downloaded += 1
            }
        }
        report.downloaded += try await download(downloads, from: remote, progress: progress)
        report.uploaded += try await upload(uploads, to: remote)
        saveState()
        saveIndex()
        return report
    }

    /// 打開時才下載的檔案：回傳本機檔案位置，並記下打開的時間。
    func ensureLocal(_ path: String, remote: any VaultRemote) async throws -> URL {
        let path = LocalVault.normalize(path)
        if vault.exists(path) {
            markOpened(path)
            return vault.url(for: path)
        }
        let file = try await remote.read(path)
        try vault.write(file.data, to: path)
        if let etag = file.etag ?? remoteFiles[path]?.etag {
            record(path, etag: etag, hash: LocalVault.hash(file.data), opened: true)
            saveState()
        }
        return vault.url(for: path)
    }

    /// 記下在這台裝置上打開了這個檔案（按需模式最近打開的檔案會保留）。
    func markOpened(_ path: String) {
        let path = LocalVault.normalize(path)
        guard state[path] != nil else { return }
        state[path]?.opened = now().timeIntervalSince1970
        saveState()
    }

    // MARK: - 編輯當下同步

    /// 編輯中的檔案立即上傳（不必列出整個遠端）。遠端同時也改過時上傳會被拒絕，交給下次完整同步（兩份都保留）。
    @discardableResult
    func push(_ paths: [String], remote: any VaultRemote) async throws -> Int {
        var items: [(path: String, base: FileState?)] = []
        for path in Set(paths.map(LocalVault.normalize)) {
            guard let local = localFile(path) else { continue }
            let base = state[path]
            if let base, !hasLocalChanges(local, since: base) { continue }
            // 遠端已有同名檔案但沒有同步紀錄：交給完整同步比對內容
            if base == nil, remoteFiles[path] != nil { continue }
            items.append((path, base))
        }
        guard !items.isEmpty else { return 0 }
        let count = try await upload(items, to: remote)
        saveState()
        saveIndex()
        return count
    }

    /// 打開中的檔案：遠端有新版本、這台裝置上沒有未上傳的修改時下載新版本（只列出它所在的資料夾）。
    /// 回傳是否更新了本機檔案。
    func refresh(_ path: String, remote: any VaultRemote) async throws -> Bool {
        let path = LocalVault.normalize(path)
        let folder = (path as NSString).deletingLastPathComponent
        let listing = try await remote.list(prefix: folder.isEmpty ? "" : folder + "/", recursive: false)
        guard let entry = listing.files.first(where: { LocalVault.normalize($0.path) == path }) else { return false }
        remoteFiles[path] = entry
        guard let base = state[path], Self.normalizeETag(entry.etag) != base.etag else { return false }
        if let local = localFile(path), hasLocalChanges(local, since: base) { return false }
        let file = try await remote.read(path)
        try vault.write(file.data, to: path)
        record(path, etag: file.etag ?? entry.etag, hash: LocalVault.hash(file.data))
        saveState()
        saveIndex()
        return true
    }

    /// App 要整個重新產生的檔案（例如手寫筆記的圖片），這台裝置上可能沒有：先記下遠端目前的版本，
    /// 之後寫入的內容會當成修改上傳，不會當成衝突另存一份；這台裝置上沒有這個檔案時，同步會把遠端的刪除。
    func prepareOverwrite(_ path: String) {
        let path = LocalVault.normalize(path)
        guard state[path] == nil, !vault.exists(path), let entry = remoteFiles[path] else { return }
        state[path] = FileState(etag: Self.normalizeETag(entry.etag), hash: "", opened: now().timeIntervalSince1970)
        saveState()
    }

    // MARK: - 切換同步空間

    /// 這台裝置上有沒有還沒上傳的修改（新檔案或改過的檔案）。
    func hasUnsyncedChanges() -> Bool {
        vault.allFiles().contains { file in
            guard let base = state[file.path] else { return true }
            return hasLocalChanges(file, since: base)
        }
    }

    /// 清掉同步紀錄與遠端清單（切換到另一個同步空間時）。
    func resetAll() {
        state = [:]
        remoteFiles = [:]
        saveState()
        saveIndex()
    }

    // MARK: - 按需模式的空間

    /// 移除這台裝置上最近沒打開、也沒有未上傳修改的檔案（`keeping` 中的除外）。只刪本機，遠端不受影響，之後打開時重新下載。
    /// 筆記與筆跡資料保留 `textRetention` 秒，圖片、PDF 等保留 `fileRetention` 秒。回傳移除的檔案數。
    @discardableResult
    func evictUnused(keeping: Set<String>, textRetention: TimeInterval = 7 * 86_400, fileRetention: TimeInterval = 86_400) -> Int {
        let current = now().timeIntervalSince1970
        let keeping = Set(keeping.map(LocalVault.normalize))
        let localByPath = Dictionary(vault.allFiles().map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var evicted = 0
        for (path, base) in state {
            guard !keeping.contains(path), let local = localByPath[path] else { continue }
            let retention = Self.essentialExtensions.contains((path as NSString).pathExtension.lowercased()) ? textRetention : fileRetention
            if let opened = base.opened, current - opened < retention { continue }
            guard !hasLocalChanges(local, since: base) else { continue }
            try? vault.delete(path)
            vault.removeEmptyParents(of: path)
            state[path] = nil
            evicted += 1
        }
        if evicted > 0 { saveState() }
        return evicted
    }

    /// 遠端有、這台裝置還沒下載的檔案（關閉「下載所有檔案」或檔案太大時），路徑已正規化。
    func pendingRemoteFiles() -> [VaultEntry] {
        remoteFiles
            .filter { !vault.exists($0.key) }
            .map { VaultEntry(path: $0.key, size: $0.value.size, mtime: $0.value.mtime, etag: $0.value.etag) }
            .sorted { $0.path < $1.path }
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

    private func localFile(_ path: String) -> LocalFile? {
        let values = try? vault.url(for: path).resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return nil }
        return LocalFile(path: path, size: values?.fileSize ?? 0, mtime: values?.contentModificationDate ?? .distantPast)
    }

    private func localHash(_ path: String) -> String? {
        (try? vault.read(path)).map(LocalVault.hash)
    }

    /// 本機檔案在上次同步後是否改過：修改時間與大小都沒變就視為沒改；否則比對內容雜湊
    /// （內容其實沒變時更新記下的時間，下次就不必再算）。
    private func hasLocalChanges(_ file: LocalFile, since base: FileState) -> Bool {
        if let mtime = base.mtime, let size = base.size, size == file.size,
           abs(mtime - file.mtime.timeIntervalSince1970) < 0.000_001 {
            return false
        }
        guard localHash(file.path) == base.hash else { return true }
        state[file.path]?.mtime = file.mtime.timeIntervalSince1970
        state[file.path]?.size = file.size
        return false
    }

    /// 本機檔案目前的修改時間與大小（與 LocalVault.allFiles() 用同樣的方式讀取，數值才會完全一致）。
    private func stamp(_ path: String) -> (mtime: Double?, size: Int?) {
        let values = try? vault.url(for: path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (values?.contentModificationDate?.timeIntervalSince1970, values?.fileSize)
    }

    /// 記下同步後的版本（遠端 ETag、內容雜湊與本機檔案的修改時間、大小）。
    /// `stamp` 要在讀取內容「之前」取得：讀取後檔案又被修改時，記下的時間比較舊，下次同步會重新比對而不會漏掉。
    /// `opened`：這次是在這台裝置上打開或編輯（否則沿用先前記下的時間）。
    private func record(_ path: String, etag: String, hash: String, stamp: (mtime: Double?, size: Int?)? = nil, opened: Bool = false) {
        let current = stamp ?? self.stamp(path)
        let openedAt = opened ? now().timeIntervalSince1970 : state[path]?.opened
        state[path] = FileState(etag: Self.normalizeETag(etag), hash: hash, mtime: current.mtime, size: current.size, opened: openedAt)
    }

    private func download(_ entries: [VaultEntry], from remote: any VaultRemote, progress: ProgressHandler?) async throws -> Int {
        guard !entries.isEmpty else { return 0 }
        // 小檔案同時 6 個；大檔案一次一個
        let small = entries.filter { $0.size <= Self.parallelDownloadLimit }
        let large = entries.filter { $0.size > Self.parallelDownloadLimit }
        let batches = stride(from: 0, to: small.count, by: 6).map { Array(small[$0..<min($0 + 6, small.count)]) } + large.map { [$0] }
        var count = 0
        var done = 0
        var unsaved = 0
        progress?(0, entries.count)
        for batch in batches {
            let results = await withTaskGroup(of: (VaultEntry, VaultFile?).self) { group in
                for entry in batch {
                    group.addTask { (entry, try? await remote.read(entry.path)) }
                }
                var collected: [(VaultEntry, VaultFile?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (entry, file) in results {
                done += 1
                guard let file else { continue }
                let path = LocalVault.normalize(entry.path)
                try vault.write(file.data, to: path)
                record(path, etag: file.etag ?? entry.etag, hash: LocalVault.hash(file.data))
                count += 1
                unsaved += 1
            }
            progress?(done, entries.count)
            // 定期記下進度：第一次下載大型 vault 中途被中斷時，下次不必重新比對已下載的檔案
            if unsaved >= 50 {
                saveState()
                unsaved = 0
            }
        }
        return count
    }

    private func upload(_ items: [(path: String, base: FileState?)], to remote: any VaultRemote) async throws -> Int {
        var count = 0
        for (path, base) in items {
            let before = stamp(path)
            guard let data = try? vault.read(path) else { continue }
            let condition: VaultClient.WriteCondition = base.map { .ifMatch($0.etag) } ?? .createOnly
            do {
                let entry = try await remote.write(path, data: data, contentType: Self.contentType(for: path), condition: condition, mtime: now())
                record(path, etag: entry.etag, hash: LocalVault.hash(data), stamp: before, opened: true)
                remoteFiles[path] = entry
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

    private func saveIndex() {
        let index = remoteFiles.map { IndexEntry(path: $0.key, size: $0.value.size, mtime: $0.value.mtime.timeIntervalSince1970, etag: $0.value.etag) }
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }
}

/// App 的同步中樞：自動同步（開啟 App、定時）、編輯當下上傳、打開中的筆記取得遠端修改、打開時下載、狀態顯示。
@MainActor
@Observable
final class VaultSyncCenter {
    struct Progress: Equatable {
        var done: Int
        var total: Int
    }

    static let shared = VaultSyncCenter()

    var isSyncing = false
    var lastSyncedAt: Date?
    var lastError: String?
    var lastReport: VaultSyncEngine.Report?
    /// 正在下載的檔案數（第一次同步大型 vault 時顯示進度）。
    var progress: Progress?
    /// 遠端有、還沒下載到這台裝置的檔案（列在檔案樹與資料夾中，打開時下載）。
    var pendingFiles: [VaultEntry] = []
    /// 本機檔案變動（同步下載或 App 編輯）時遞增，畫面據此重新整理。
    var revision = 0
    /// 工作區中開著的筆記：按需模式移除檔案時不會移除。
    var openPaths: Set<String> = []
    /// 與伺服器的即時推送連線中。
    private(set) var isLive = false

    let vault: LocalVault
    let engine: VaultSyncEngine
    private var scheduled: Task<Void, Never>?
    private var live: Task<Void, Never>?
    private var pushCursor: String?
    private var pushes: [String: Task<Void, Never>] = [:]

    init(vault: LocalVault = .shared) {
        self.vault = vault
        engine = VaultSyncEngine(
            vault: vault,
            stateURL: URL.applicationSupportDirectory.appending(path: "VaultSyncState.json")
        )
        try? FileManager.default.createDirectory(at: vault.root, withIntermediateDirectories: true)
    }

    /// 目前的同步空間（LocalOCR 伺服器或 WebDAV）已設定。
    var isConfigured: Bool { VaultBackend.current() != nil }

    /// 啟動時先用上次記下的遠端清單列出檔案（按需模式下大部分檔案不在這台裝置上），不必等同步完成。
    func prepare() async {
        pendingFiles = await engine.pendingRemoteFiles()
    }

    func syncNow(allowMassDeletion: Bool = false) async {
        guard !isSyncing, let client = VaultBackend.current() else { return }
        isSyncing = true
        defer {
            isSyncing = false
            progress = nil
        }
        do {
            let policy = NotesSettings.downloadPolicy
            let report = try await engine.sync(
                remote: client,
                allowMassDeletion: allowMassDeletion,
                policy: policy
            ) { done, total in
                Task { @MainActor in self.updateProgress(done: done, total: total) }
            }
            lastReport = report
            lastSyncedAt = Date()
            lastError = nil
            var changed = report.changedLocalFiles
            if policy == .onDemand, await engine.evictUnused(keeping: openPaths) > 0 { changed = true }
            if changed { revision += 1 }
            if report.uploaded + report.deleted > 0 { reportToServer([]) }
        } catch {
            lastError = error.localizedDescription
        }
        pendingFiles = await engine.pendingRemoteFiles()
    }

    private func updateProgress(done: Int, total: Int) {
        guard isSyncing, total > 0 else { return }
        let previous = progress?.done ?? 0
        progress = Progress(done: done, total: total)
        // 下載很多檔案時，每 200 個先更新一次畫面，不用等全部下載完才看到筆記
        if done / 200 > previous / 200 { revision += 1 }
    }

    /// 下載一個還沒在這台裝置上的檔案，回傳本機位置。
    func download(_ path: String) async throws -> URL {
        if vault.exists(path) {
            touch(path)
            return vault.url(for: path)
        }
        guard let client = VaultBackend.current() else { throw VaultError.notConfigured }
        let url = try await engine.ensureLocal(path, remote: client)
        pendingFiles.removeAll { $0.path == LocalVault.normalize(path) }
        revision += 1
        return url
    }

    /// 新增、改名、刪除檔案後呼叫：更新畫面，稍後完整同步一次（連續修改只會同步一次）。
    func localDidChange() {
        revision += 1
        scheduleSync(after: 1.5)
    }

    /// 編輯中的檔案存檔後呼叫：直接上傳這個檔案（編輯當下同步，不必等完整同步）。
    func fileDidChange(_ path: String) {
        revision += 1
        let path = LocalVault.normalize(path)
        pushes[path]?.cancel()
        pushes[path] = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let client = VaultBackend.current() else { return }
            pushes[path] = nil
            do {
                if try await engine.push([path], remote: client) > 0 {
                    reportToServer([path])
                }
            } catch {
                // 網路中斷等：下次完整同步會再上傳
                scheduleSync(after: 30)
            }
        }
    }

    /// 打開中的筆記：遠端（Obsidian）改過、這台裝置沒有未上傳的修改時，下載新版本並更新畫面。
    func refreshOpenFile(_ path: String) async {
        guard !isSyncing, let client = VaultBackend.current() else { return }
        if (try? await engine.refresh(path, remote: client)) == true {
            revision += 1
        }
    }

    /// 記下打開了這個檔案（按需模式最近打開的檔案會保留在這台裝置上）。
    func touch(_ path: String) {
        Task { await engine.markOpened(path) }
    }

    /// App 要整個重新產生、這台裝置上可能沒有的檔案（手寫筆記的圖片等）：寫入前呼叫，上傳時直接取代遠端版本。
    func prepareOverwrite(_ paths: [String]) async {
        for path in paths {
            await engine.prepareOverwrite(path)
        }
    }

    /// 刪除只在遠端的檔案（這台裝置上沒有）：下次同步時從遠端刪除。
    func deleteRemoteOnly(_ path: String) async {
        await engine.prepareOverwrite(path)
        pendingFiles.removeAll { $0.path == LocalVault.normalize(path) }
        localDidChange()
    }

    /// 移除這台裝置上所有已同步的檔案（開著的筆記與未上傳的修改除外），回傳移除的檔案數。
    func clearDownloads() async -> Int {
        guard !isSyncing else { return 0 }
        let count = await engine.evictUnused(keeping: openPaths, textRetention: 0, fileRetention: 0)
        pendingFiles = await engine.pendingRemoteFiles()
        revision += 1
        return count
    }

    /// 這台裝置上 vault 檔案佔用的空間（位元組）。
    func localUsage() async -> Int {
        let vault = vault
        return await Task.detached(priority: .utility) { vault.allFiles().reduce(0) { $0 + $1.size } }.value
    }

    func scheduleSync(after seconds: Double) {
        scheduled?.cancel()
        scheduled = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await syncNow()
        }
    }

    /// App 在前景時：同步一次，並與伺服器保持即時推送的連線（其他裝置修改後立即同步，不輪詢）。
    func startLiveSync() {
        Task { await syncNow() }
        startLiveUpdates()
    }

    /// vault 存在 WebDAV 時，自己上傳或刪除了檔案就通知 LocalOCR 伺服器（有配對時），電腦的 Obsidian 會立即同步。
    /// 存在 LocalOCR 伺服器時不必：伺服器自己知道。
    private func reportToServer(_ paths: [String]) {
        guard VaultBackend.storage == .webdav, let client = VaultClient.configured() else { return }
        Task { try? await client.reportChanges(paths: paths) }
    }

    /// 換到另一個同步空間：先把這台裝置上的修改上傳到原本的空間，再清掉快取與同步紀錄，從新的空間重新取得（兩個空間的檔案不會混在一起）。
    /// 回傳錯誤訊息；成功時是 nil。
    /// `applySettings` 在原本的空間同步完、清掉快取之前執行（例如儲存新的 WebDAV 網址）。
    func switchStorage(to storage: VaultStorage, force: Bool = false, applySettings: () -> Void = {}) async -> String? {
        guard force || storage != VaultBackend.storage else { return nil }
        if VaultBackend.current() != nil {
            await syncNow()
            if let lastError { return "還有修改沒上傳到原本的空間（\(lastError)）。請連上網路後再切換。" }
            if await engine.hasUnsyncedChanges() { return "還有修改沒上傳到原本的空間，請稍後再切換。" }
        }
        stopLiveSync()
        applySettings()
        await engine.resetAll()
        vault.removeAll()
        pendingFiles = []
        pushCursor = nil
        lastSyncedAt = nil
        lastReport = nil
        VaultBackend.storage = storage
        revision += 1
        startLiveSync()
        return nil
    }

    /// 進入背景時關閉連線（回到前景時重新連線並同步一次）。
    func stopLiveSync() {
        live?.cancel()
        live = nil
        isLive = false
    }

    /// 即時推送（WebSocket）：連線建立或重新建立時同步一次補上漏掉的變動，之後只在伺服器送來變動時動作。
    /// 舊版伺服器沒有推送、或金鑰與儲存空間有問題時，每 5 分鐘同步一次作為備援。
    private func startLiveUpdates() {
        live?.cancel()
        live = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                guard let client = VaultClient.configured() else {
                    // 沒有配對 LocalOCR 伺服器（只用 WebDAV）：WebDAV 沒有推送，每分鐘同步一次
                    try? await Task.sleep(for: .seconds(60))
                    await self.syncNow()
                    continue
                }
                let outcome = await VaultPush.run(client: client, since: self.pushCursor) { [weak self] event in
                    await self?.handlePush(event)
                }
                let wasLive = self.isLive
                self.isLive = false
                guard !Task.isCancelled else { return }
                switch outcome {
                case .unsupported, .unauthorized, .notConfigured:
                    failures = 0
                    try? await Task.sleep(for: .seconds(300))
                    await self.syncNow()
                case .disconnected:
                    // 剛才連線正常（例如伺服器重新部署）：馬上重連；連不上時逐漸拉長間隔
                    failures = wasLive ? 1 : failures + 1
                    let delays = [1, 2, 5, 15, 60]
                    try? await Task.sleep(for: .seconds(delays[min(failures - 1, delays.count - 1)]))
                }
            }
        }
    }

    private func handlePush(_ event: VaultPushEvent) async {
        switch event {
        case .ready(let cursor, _):
            let reconnected = pushCursor != nil
            pushCursor = cursor
            isLive = true
            // 重新連線：補上斷線期間的變動（第一次連線時 startLiveSync 已經同步過）
            if reconnected { await syncNow() }
        case .changes(let changes):
            pushCursor = changes.cursor
            await applyRemoteChanges(changes)
        }
    }

    /// 其他裝置的修改：開著的筆記直接下載新版本；其他檔案、刪除或不知道是哪些檔案時完整同步一次。
    private func applyRemoteChanges(_ result: VaultChanges) async {
        let paths = Set(result.changes.compactMap(\.path).map(LocalVault.normalize))
        let open = paths.intersection(openPaths)
        for path in open {
            await refreshOpenFile(path)
        }
        let needsFullSync = result.reset
            || result.changes.contains { $0.path == nil || $0.op != "write" }
            || !paths.subtracting(open).isEmpty
        guard needsFullSync else { return }
        if isSyncing {
            scheduleSync(after: 2)
        } else {
            await syncNow()
        }
    }

    /// 依檔名或路徑取得本機檔案（附件需要時才下載）。
    func localURL(forEmbed name: String) async -> URL? {
        let files = vault.allFiles()
        guard let path = await engine.resolve(name: name, localFiles: files) else { return nil }
        if vault.exists(path) {
            touch(path)
            return vault.url(for: path)
        }
        guard let client = VaultBackend.current() else { return nil }
        let url = try? await engine.ensureLocal(path, remote: client)
        if url != nil { pendingFiles.removeAll { $0.path == path } }
        return url
    }
}
