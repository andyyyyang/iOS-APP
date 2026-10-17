import CryptoKit
import Foundation
import Observation

/// 掃描結果（一次讀進所有客戶，合併成一個池子；切換範圍只是換篩選條件）。
struct DrawingsSnapshot: Sendable {
    var models: [DrawingModel] = []
    /// 大寫圖號 -> PO LIST 產能
    var capacity: [String: CapacityItem] = [:]
    /// PO LIST 最新的那一份檔頭
    var capacityMeta: CapacityMeta?
    var capacityItemCount = 0
    /// 大寫圖號 -> 理論產能
    var theory: [String: TheoryItem] = [:]
    var theorySourceMtime: String?
    /// 出貨客戶（資料夾）
    var ships: [String] = []
    /// 圖面檔的實際路徑（正規化後 -> vault 中的寫法）
    var files: [String: String] = [:]
}

/// 從 vault 讀取圖面資料：只讀檔案清單與幾個 JSON，圖面本身打開時才取得。
enum DrawingsLoader {
    static func load(remote: any VaultRemote, dataRoot: String, assetRoot: String) async throws -> DrawingsSnapshot {
        async let dataListing = remote.list(prefix: dataRoot + "/", recursive: false)
        async let assetListing = remote.list(prefix: assetRoot + "/", recursive: true)
        let data = try await dataListing
        let assets = (try? await assetListing) ?? VaultListing(files: [], folders: [])

        // 客戶＝兩個根目錄子資料夾的聯集（底線、點開頭的是內部資料夾）
        func customerID(_ folder: String) -> String? {
            let id = DrawingPaths.baseName(folder.hasSuffix("/") ? String(folder.dropLast()) : folder)
            return id.isEmpty || id.hasPrefix("_") || id.hasPrefix(".") ? nil : id
        }
        let dataCustomers = Set(data.folders.compactMap(customerID))

        // 圖面：<assetRoot>/<客戶>/<機種>/<檔案> 與 <assetRoot>/<客戶>/<檔案>
        var folderFiles: [String: [String: [String]]] = [:]
        var flatFiles: [String: [String]] = [:]
        var files: [String: String] = [:]
        let prefix = assetRoot + "/"
        for entry in assets.files where entry.path.hasPrefix(prefix) {
            let parts = entry.path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, let customer = customerID(parts[0]), !parts.contains(where: { $0.hasPrefix(".") }) else { continue }
            files[LocalVault.normalize(entry.path)] = entry.path
            if parts.count == 2 {
                flatFiles[customer, default: []].append(entry.path)
            } else if parts.count == 3 {
                folderFiles[customer, default: [:]][parts[1], default: []].append(entry.path)
            }
        }
        let assetCustomers = Set(folderFiles.keys).union(flatFiles.keys)

        var snapshot = DrawingsSnapshot()
        snapshot.files = files
        let candidates = dataCustomers.union(assetCustomers).sorted { DrawingPaths.prettyCustomer($0).localizedStandardCompare(DrawingPaths.prettyCustomer($1)) == .orderedAscending }

        for customer in candidates {
            async let catalogData = readData(remote, "\(dataRoot)/\(customer)/catalog.json")
            async let capacityData = readData(remote, "\(dataRoot)/\(customer)/capacity.json")
            async let theoryData = readData(remote, "\(dataRoot)/\(customer)/theory_capacity.json")
            let catalog = json(await catalogData) as? [[String: Any]] ?? []
            // 沒有圖面資料夾時，至少要有非空的 catalog.json 才算客戶
            guard assetCustomers.contains(customer) || !catalog.isEmpty else { continue }
            snapshot.ships.append(customer)

            // 產能
            var capacity: [String: CapacityItem] = [:]
            if let object = json(await capacityData) as? [String: Any] {
                let meta = CapacityMeta(object: object)
                let items = (object["items"] as? [[String: Any]] ?? []).compactMap(CapacityItem.init(object:))
                for item in items { capacity[item.dwg.uppercased()] = item }
                if snapshot.capacityMeta == nil || meta.sourceMtime > (snapshot.capacityMeta?.sourceMtime ?? "") {
                    snapshot.capacityMeta = meta
                    snapshot.capacityItemCount = items.count
                }
            }
            if let object = json(await theoryData) as? [String: Any] {
                let items = (object["items"] as? [[String: Any]] ?? []).compactMap(TheoryItem.init(object:))
                snapshot.theory.merge(DrawingTheory.index(items)) { current, new in new.dailyQty > current.dailyQty ? new : current }
                if snapshot.theorySourceMtime == nil { snapshot.theorySourceMtime = DrawingJSON.string(object["source_mtime"]) }
            }

            // 機種：catalog 為主，再併機種資料夾（含 meta.json）與平鋪檔
            var models: [String: DrawingModel] = [:]
            var order: [String] = []
            for object in catalog {
                guard let model = DrawingModel(catalog: object) else { continue }
                if models[model.dwg] == nil { order.append(model.dwg) }
                models[model.dwg] = model
            }
            func ensure(_ dwg: String) {
                if models[dwg] == nil {
                    models[dwg] = DrawingModel(dwg: dwg)
                    order.append(dwg)
                }
            }
            let folders = folderFiles[customer] ?? [:]
            let metas = await readMetas(remote, folders: folders)
            for dwg in folders.keys.sorted() {
                ensure(dwg)
                guard var model = models[dwg] else { continue }
                if let meta = metas[dwg] {
                    model.apply(meta, onlyMissing: true)
                    for object in meta["drawings"] as? [[String: Any]] ?? [] {
                        let drawing = DrawingRef(object: object, source: .meta)
                        let key = DrawingPaths.drawingKey(drawing.png.isEmpty ? drawing.pdf : drawing.png, dwg: dwg)
                        if model.drawings.contains(where: { DrawingPaths.drawingKey($0.png.isEmpty ? $0.pdf : $0.png, dwg: dwg) == key }) { continue }
                        model.drawings.append(drawing)
                    }
                }
                DrawingScanner.mergeDiskFiles(&model.drawings, files: folders[dwg] ?? [], dwg: dwg)
                models[dwg] = model
            }
            var flat: [String: [String]] = [:]
            for file in flatFiles[customer] ?? [] {
                if let dwg = DrawingScanner.flatFileModel(file) { flat[dwg, default: []].append(file) }
            }
            for dwg in flat.keys.sorted() {
                ensure(dwg)
                DrawingScanner.mergeDiskFiles(&models[dwg]!.drawings, files: flat[dwg] ?? [], dwg: dwg)
            }

            for dwg in order {
                guard var model = models[dwg] else { continue }
                model.customer = customer
                if model.type.isEmpty { model.type = model.spec.type }
                // 檔案路徑換成 vault 中的寫法，不存在的格式拿掉
                model.drawings = DrawingScanner.finalize(model.drawings.map { resolve($0, files: files) }, existing: Set(files.values))
                let item = capacity[dwg.uppercased()]
                if model.endUser.isEmpty {
                    let (endUser, guessed) = DrawingCustomers.endUser(of: model, capacity: item)
                    model.endUser = endUser
                    model.endUserGuessed = guessed && !endUser.isEmpty
                }
                snapshot.models.append(model)
            }
            snapshot.capacity.merge(capacity) { _, new in new }
        }
        return snapshot
    }

    private static func resolve(_ drawing: DrawingRef, files: [String: String]) -> DrawingRef {
        var drawing = drawing
        drawing.png = files[LocalVault.normalize(drawing.png)] ?? drawing.png
        drawing.pdf = files[LocalVault.normalize(drawing.pdf)] ?? drawing.pdf
        drawing.cad = files[LocalVault.normalize(drawing.cad)] ?? drawing.cad
        return drawing
    }

    private static func readData(_ remote: any VaultRemote, _ path: String) async -> Data? {
        try? await remote.read(path).data
    }

    private static func json(_ data: Data?) -> Any? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// 機種資料夾的 meta.json（同時最多 6 個請求）。
    private static func readMetas(_ remote: any VaultRemote, folders: [String: [String]]) async -> [String: [String: Any]] {
        let targets = folders.compactMap { dwg, files in
            files.first { DrawingPaths.baseName($0).lowercased() == "meta.json" }.map { (dwg, $0) }
        }
        var result: [String: [String: Any]] = [:]
        var index = 0
        while index < targets.count {
            let batch = targets[index..<min(index + 6, targets.count)]
            index += 6
            await withTaskGroup(of: (String, Data?).self) { group in
                for (dwg, path) in batch {
                    group.addTask { (dwg, try? await remote.read(path).data) }
                }
                for await (dwg, data) in group {
                    if let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { result[dwg] = object }
                }
            }
        }
        return result
    }
}

/// 圖面瀏覽器的狀態：所有客戶的機種、產能、理論產能，目前的範圍與選取的機種。
@MainActor
@Observable
final class DrawingsLibrary {
    static let shared = DrawingsLibrary()

    static let dataRootKey = "drawings.dataRoot"
    static let assetRootKey = "drawings.assetRoot"
    static let scopeKey = "drawings.scope"
    static let lastModelKey = "drawings.lastModel"
    static let notesFile = "spec_notes.json"

    static var dataRoot: String { setting(dataRootKey, default: "assets/data") }
    static var assetRoot: String { setting(assetRootKey, default: "assets/drawings") }

    private static func setting(_ key: String, default value: String) -> String {
        let text = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) ?? ""
        return text.isEmpty ? value : text
    }

    private(set) var snapshot = DrawingsSnapshot()
    private(set) var scopes: [DrawingScope] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?
    /// 規格筆記：「出貨客戶/圖號」-> 內容（存在 vault 的 assets/data/spec_notes.json）
    private(set) var notes: [String: String] = [:]
    private var notesETag: String?
    private var loadTask: Task<Void, Never>?

    /// 目前的範圍：all｜ship:<資料夾>｜end:<終端客戶>
    var scope: String = UserDefaults.standard.string(forKey: DrawingsLibrary.scopeKey) ?? "all" {
        didSet { UserDefaults.standard.set(scope, forKey: Self.scopeKey) }
    }

    func ensureLoaded() async {
        if loadedAt == nil { await reload() }
    }

    /// 重新掃描（同時只有一個）。
    func reload() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await fetch() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func fetch() async {
        guard let remote = VaultBackend.current() else {
            error = "尚未配對"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let dataRoot = Self.dataRoot
            let result = try await DrawingsLoader.load(remote: remote, dataRoot: dataRoot, assetRoot: Self.assetRoot)
            snapshot = result
            scopes = Self.scopes(for: result)
            if !scopes.contains(where: { $0.id == scope }) {
                // 舊版存的是資料夾 id
                let legacy = "ship:" + scope
                scope = scopes.contains(where: { $0.id == legacy }) ? legacy : "all"
            }
            error = result.models.isEmpty ? "找不到客戶資料" : nil
            loadedAt = Date()
            await loadNotes(remote: remote)
        } catch {
            self.error = "讀取失敗：\(error.localizedDescription)"
        }
    }

    /// 選單：全部 → 出貨客戶（資料夾）→ 終端客戶（依款數排）。
    static func scopes(for snapshot: DrawingsSnapshot) -> [DrawingScope] {
        var result = [DrawingScope(id: "all", label: "全部", kind: .all, count: snapshot.models.count)]
        for ship in snapshot.ships {
            result.append(DrawingScope(id: "ship:" + ship, label: DrawingPaths.prettyCustomer(ship), kind: .ship, count: snapshot.models.filter { $0.customer == ship }.count))
        }
        var byEnd: [String: Int] = [:]
        for model in snapshot.models {
            let endUser = model.endUser.trimmingCharacters(in: .whitespaces)
            if !endUser.isEmpty { byEnd[endUser, default: 0] += 1 }
        }
        for (endUser, count) in byEnd.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            result.append(DrawingScope(id: "end:" + endUser, label: endUser, kind: .end, count: count))
        }
        return result
    }

    /// 目前範圍中的機種。
    var models: [DrawingModel] { models(in: scope) }

    func models(in scope: String) -> [DrawingModel] {
        if scope.hasPrefix("ship:") {
            let id = String(scope.dropFirst(5))
            return snapshot.models.filter { $0.customer == id }
        }
        if scope.hasPrefix("end:") {
            let endUser = scope.dropFirst(4).lowercased()
            return snapshot.models.filter { $0.endUser.trimmingCharacters(in: .whitespaces).lowercased() == endUser }
        }
        return snapshot.models
    }

    func capacity(for model: DrawingModel) -> CapacityItem? {
        snapshot.capacity[model.dwg.uppercased()]
    }

    func theory(for model: DrawingModel) -> TheoryItem? {
        snapshot.theory[model.dwg.uppercased()]
    }

    var scopeLabel: String {
        scopes.first { $0.id == scope }?.label ?? "全部"
    }

    // MARK: 上次看的機種

    func lastModel(in scope: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: Self.lastModelKey) as? [String: String])?[scope]
    }

    func setLastModel(_ dwg: String, in scope: String) {
        var saved = UserDefaults.standard.dictionary(forKey: Self.lastModelKey) as? [String: String] ?? [:]
        saved[scope] = dwg
        UserDefaults.standard.set(saved, forKey: Self.lastModelKey)
    }

    // MARK: 規格筆記

    private var notesPath: String { Self.dataRoot + "/" + Self.notesFile }

    static func noteKey(_ model: DrawingModel) -> String {
        "\(model.customer)/\(model.dwg)"
    }

    func note(for model: DrawingModel) -> String {
        notes[Self.noteKey(model)] ?? ""
    }

    private func loadNotes(remote: any VaultRemote) async {
        guard let file = try? await remote.read(notesPath),
              let object = (try? JSONSerialization.jsonObject(with: file.data)) as? [String: Any] else { return }
        notes = (object["notes"] as? [String: Any] ?? object).compactMapValues { $0 as? String }
        notesETag = file.etag
    }

    /// 儲存筆記到 vault（其他裝置也看得到）；檔案在別處被改過時重新讀取合併再寫。
    func saveNote(_ text: String, for model: DrawingModel) async throws {
        guard let remote = VaultBackend.current() else { throw VaultError.notConfigured }
        let key = Self.noteKey(model)
        for attempt in 0..<2 {
            var merged = notes
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                merged[key] = nil
            } else {
                merged[key] = text
            }
            let body: [String: Any] = [
                "note": "圖面瀏覽器的規格筆記（記得 App），鍵是「出貨客戶/圖號」",
                "notes": merged,
            ]
            let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
            do {
                let entry = try await remote.write(
                    notesPath,
                    data: data,
                    contentType: "application/json; charset=utf-8",
                    condition: notesETag.map { VaultClient.WriteCondition.ifMatch($0) } ?? .createOnly,
                    mtime: .now
                )
                notes = merged
                notesETag = entry.etag
                return
            } catch VaultError.conflict(_) where attempt == 0 {
                await loadNotes(remote: remote)
            }
        }
    }
}

/// 圖面檔的暫存：打開時才從 vault 取得，存在系統的快取資料夾（空間不夠時系統會清掉），超過上限就移除最久沒看的。
actor DrawingFileCache {
    static let shared = DrawingFileCache()
    /// 暫存上限（位元組）
    static let limit = 150 * 1024 * 1024

    private let directory: URL = {
        let url = URL.cachesDirectory.appending(path: "Drawings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var inFlight: [String: Task<URL, Error>] = [:]

    func url(for path: String) async throws -> URL {
        let target = location(for: path)
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path(percentEncoded: false))
            return target
        }
        if let task = inFlight[path] { return try await task.value }
        let task = Task<URL, Error> {
            guard let remote = VaultBackend.current() else { throw VaultError.notConfigured }
            let file = try await remote.read(path)
            try file.data.write(to: target, options: .atomic)
            return target
        }
        inFlight[path] = task
        defer { inFlight[path] = nil }
        let url = try await task.value
        trim()
        return url
    }

    /// 檔案換了（重新掃描）時清掉。
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func location(for path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        let ext = DrawingPaths.ext(of: path)
        return directory.appending(path: ext.isEmpty ? String(digest) : "\(digest).\(ext)")
    }

    private func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > Self.limit else { return }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > Self.limit {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}
