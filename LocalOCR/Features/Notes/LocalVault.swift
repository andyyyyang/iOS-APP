import CryptoKit
import Foundation

/// 本機的一個檔案。
struct LocalFile: Hashable, Sendable {
    let path: String
    let size: Int
    let mtime: Date
}

/// 本機的 vault 鏡像：Documents/Obsidian（也會出現在「檔案」App 的「我的 iPad／LocalOCR」中）。
/// 每則筆記都是 .md 檔；與 Railway 空間（Remotely Save 同步的同一份 vault）的雙向同步見 VaultSyncEngine。
struct LocalVault: Sendable {
    let root: URL

    static let shared = LocalVault(root: URL.documentsDirectory.appending(path: "Obsidian", directoryHint: .isDirectory))

    /// 統一用 NFC：伺服器回傳的路徑是 NFC，比對時才不會因為組合字元不同而當成不同檔案。
    static func normalize(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    func url(for path: String) -> URL {
        root.appending(path: Self.normalize(path), directoryHint: .notDirectory)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path(percentEncoded: false))
    }

    func read(_ path: String) throws -> Data {
        try Data(contentsOf: url(for: path))
    }

    func readText(_ path: String) -> String? {
        (try? read(path)).map { String(decoding: $0, as: UTF8.self) }
    }

    func write(_ data: Data, to path: String) throws {
        let target = url(for: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    func writeText(_ text: String, to path: String) throws {
        try write(Data(text.utf8), to: path)
    }

    func delete(_ path: String) throws {
        let target = url(for: path)
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: target)
        }
    }

    func move(_ source: String, to destination: String) throws {
        let target = url(for: destination)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url(for: source), to: target)
    }

    /// 刪除檔案後，往上移除變成空的資料夾（不會移除 vault 本身）。
    func removeEmptyParents(of path: String) {
        var folder = (Self.normalize(path) as NSString).deletingLastPathComponent
        while !folder.isEmpty {
            let url = root.appending(path: folder, directoryHint: .isDirectory)
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false)), contents.isEmpty else { return }
            try? FileManager.default.removeItem(at: url)
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    func createFolder(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appending(path: Self.normalize(path), directoryHint: .isDirectory), withIntermediateDirectories: true)
    }

    /// 所有檔案（略過 . 開頭的檔案與資料夾，例如 .obsidian、.trash、.DS_Store）。
    func allFiles() -> [LocalFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var files: [LocalFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard components.count > rootComponents.count, Array(components.prefix(rootComponents.count)) == rootComponents else { continue }
            let path = Self.normalize(components.dropFirst(rootComponents.count).joined(separator: "/"))
            files.append(LocalFile(path: path, size: values.fileSize ?? 0, mtime: values.contentModificationDate ?? .distantPast))
        }
        return files
    }

    /// 所有子資料夾（相對路徑，不含結尾斜線）。
    func allFolders() -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var folders: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard components.count > rootComponents.count else { continue }
            folders.append(Self.normalize(components.dropFirst(rootComponents.count).joined(separator: "/")))
        }
        return folders.sorted()
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
