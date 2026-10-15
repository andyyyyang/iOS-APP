import Foundation
import PencilKit
import UIKit

/// 筆記相關設定。
enum NotesSettings {
    enum Key {
        static let defaultFolder = "notes.vaultFolder"
        static let vaultName = "notes.vaultName"
        static let downloadPolicy = "notes.downloadPolicy"
        static let migratedDefaultFolder = "notes.migratedDefaultFolder"
        static let lastPaper = "notes.lastPaper"
        static let limitsLineWidth = "notes.limitsLineWidth"
        static let autoInkMemo = "notes.autoInkMemo"
    }

    /// 開啟 Markdown 筆記時右側欄自動切到手寫備忘；預設開啟。
    static var autoInkMemo: Bool {
        UserDefaults.standard.object(forKey: Key.autoInkMemo) as? Bool ?? true
    }

    /// 筆記內容限制在易讀的行寬（760）；預設關閉：跟著畫面全寬自適應。
    static var limitsLineWidth: Bool {
        UserDefaults.standard.bool(forKey: Key.limitsLineWidth)
    }

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Key.defaultFolder: "",
            Key.vaultName: "",
        ])
        // 2.0 配對時會把新筆記固定放到「iPad 筆記」；筆記可以在 vault 任何地方，改回最上層
        if !defaults.bool(forKey: Key.migratedDefaultFolder) {
            if defaults.string(forKey: Key.defaultFolder) == "iPad 筆記" {
                defaults.removeObject(forKey: Key.defaultFolder)
            }
            defaults.set(true, forKey: Key.migratedDefaultFolder)
        }
    }

    /// 從首頁新增筆記時放的資料夾（不含結尾斜線）；空字串代表 vault 最上層。在資料夾中新增時放在那個資料夾。
    static var defaultFolder: String {
        let raw = UserDefaults.standard.string(forKey: Key.defaultFolder) ?? ""
        return raw.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// 這台裝置上保留哪些檔案；預設打開時才下載（平板空間有限）。
    static var downloadPolicy: VaultDownloadPolicy {
        get { UserDefaults.standard.string(forKey: Key.downloadPolicy).flatMap(VaultDownloadPolicy.init(rawValue:)) ?? .onDemand }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.downloadPolicy) }
    }

    /// 新手寫筆記的紙張：上次在筆記中選的紙張，預設空白。
    static var lastPaper: PaperStyle {
        get { UserDefaults.standard.string(forKey: Key.lastPaper).flatMap(PaperStyle.init(rawValue:)) ?? .blank }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.lastPaper) }
    }

    static var vaultName: String {
        (UserDefaults.standard.string(forKey: Key.vaultName) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// 用 obsidian:// 開啟 vault 中的檔案；需要知道 vault 名稱（配對時自動取得）。
    static func obsidianURL(for path: String) -> URL? {
        guard !vaultName.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "vault", value: vaultName), URLQueryItem(name: "file", value: path)]
        return components.url
    }

    /// 某則筆記的附件資料夾：同一層的「附件」。
    static func attachmentsFolder(forNote path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "附件" : folder + "/附件"
    }
}

/// 手寫筆記的資料（存在附件資料夾，其他裝置可以接著編輯）。
/// 版本 1 是 2.3 以前的 A4 分頁筆記本；版本 2 起是連續畫布（`CanvasLayout`），`pageCount` 是匯出的圖片數。
struct NotebookArchive: Codable, Equatable {
    static let canvasVersion = 2

    var version = NotebookArchive.canvasVersion
    var id: String
    var createdAt: Date
    var updatedAt: Date
    var paper: PaperStyle
    var color: NotebookColor
    var pageCount: Int
    var drawing: Data
    var recognizedText: String?
    var insights: NoteInsights?

    static let fileExtension = "localocr-notebook"

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    var pkDrawing: PKDrawing {
        get { (try? PKDrawing(data: drawing)) ?? PKDrawing() }
        set { drawing = newValue.dataRepresentation() }
    }

    /// 舊版的分頁筆記本轉成連續畫布（筆跡移到對應位置）；已是新版時不變。
    mutating func migrateToCanvas() {
        guard version < Self.canvasVersion else { return }
        pkDrawing = pkDrawing.migratedFromPagedNotebook(pageCount: pageCount)
        version = Self.canvasVersion
    }
}

/// Markdown 的小工具（純函式，方便測試）。
enum NotebookMarkdown {
    static let sectionStart = "<!-- localocr:notebook -->"
    static let sectionEnd = "<!-- /localocr:notebook -->"

    static func pageImageName(id: String, page: Int) -> String {
        "\(id)-p\(page).png"
    }

    /// App 管理的區段：AI 摘要、重點、待辦、手寫內容、每頁圖片。筆記中其他的文字由使用者自由編輯。
    static func managedSection(id: String, pageCount: Int, insights: NoteInsights?, recognizedText: String?) -> String {
        var lines = [sectionStart]
        if let insights {
            if !insights.summary.isEmpty {
                lines.append("> [!summary] AI 摘要")
                lines.append(contentsOf: insights.summary.split(whereSeparator: \.isNewline).map { "> \($0)" })
                lines.append("")
            }
            if !insights.keyPoints.isEmpty {
                lines.append("## 重點")
                lines.append(contentsOf: insights.keyPoints.map { "- \($0)" })
                lines.append("")
            }
            if !insights.actionItems.isEmpty {
                lines.append("## 待辦")
                lines.append(contentsOf: insights.actionItems.map { "- [ ] \($0)" })
                lines.append("")
            }
        }
        if let recognizedText, !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("## 手寫內容")
            lines.append(recognizedText.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        for page in 1...max(pageCount, 1) {
            lines.append("![[\(pageImageName(id: id, page: page))]]")
        }
        lines.append(sectionEnd)
        return lines.joined(separator: "\n")
    }

    /// 換掉筆記中 App 管理的區段（沒有就加在最後），其他內容不變。
    static func replacingManagedSection(in text: String, with section: String) -> String {
        if let start = text.range(of: sectionStart), let end = text.range(of: sectionEnd, range: start.upperBound..<text.endIndex) {
            return text.replacingCharacters(in: start.lowerBound..<end.upperBound, with: section)
        }
        let trimmed = text.trimmingCharacters(in: .newlines)
        return (trimmed.isEmpty ? "" : trimmed + "\n\n") + section + "\n"
    }

    /// 新筆記本的 Markdown：屬性＋管理區段。
    static func newNotebook(id: String, createdAt: Date) -> String {
        let frontmatter = [
            "---",
            "created: \(dateFormatter.string(from: createdAt))",
            "\(NotebookFiles.frontmatterKey): \(id)",
            "---",
            "",
        ].joined(separator: "\n")
        return frontmatter + "\n" + managedSection(id: id, pageCount: 1, insights: nil, recognizedText: nil) + "\n"
    }

    /// 可當檔名的標題：移除 Obsidian 與檔案系統不允許的字元。
    static func fileName(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
        let cleaned = title.components(separatedBy: forbidden).joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let trimmed = String(cleaned.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? "未命名筆記" : trimmed
    }

    static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()
}

/// 手寫筆記本的檔案：「標題.md」（frontmatter `localocr-notebook: nb-xxxx`）＋附件資料夾中的筆記本資料與每頁圖片。
@MainActor
enum NotebookFiles {
    nonisolated static let frontmatterKey = "localocr-notebook"

    static func newID() -> String {
        "nb-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// 筆跡資料的位置：通常在筆記旁邊的「附件」；筆記被搬到別的資料夾後依檔名找到原本的位置，之後也存回那裡。
    static func archivePath(notePath: String, id: String) -> String {
        AttachmentLocator.locate("\(NotesSettings.attachmentsFolder(forNote: notePath))/\(id).\(NotebookArchive.fileExtension)")
    }

    /// 每頁圖片放在筆跡資料旁邊（筆記搬走後也不會在新資料夾多出一份同名的圖片）。
    static func pageImagePath(notePath: String, id: String, page: Int) -> String {
        let folder = (archivePath(notePath: notePath, id: id) as NSString).deletingLastPathComponent
        return "\(folder)/\(NotebookMarkdown.pageImageName(id: id, page: page))"
    }

    /// 建立新的手寫筆記（空白畫布），回傳 Markdown 路徑。
    static func create(in folder: String, title: String, paper: PaperStyle, store: NotesStore) throws -> String {
        let path = store.uniquePath(folder: folder, title: title)
        let id = newID()
        let now = Date()
        let archive = NotebookArchive(id: id, createdAt: now, updatedAt: now, paper: paper, color: .blue, pageCount: 1, drawing: PKDrawing().dataRepresentation())
        try store.vault.write(try NotebookArchive.encoder.encode(archive), to: archivePath(notePath: path, id: id))
        try writePageImages(archive, notePath: path, vault: store.vault)
        try store.vault.writeText(NotebookMarkdown.newNotebook(id: id, createdAt: now), to: path)
        VaultSyncCenter.shared.localDidChange()
        Task { await store.reload() }
        return path
    }

    /// 讀取筆記資料（舊版的分頁筆記本轉成連續畫布）；檔案還沒同步下來時先下載。
    static func load(notePath: String, id: String) async -> NotebookArchive? {
        let vault = VaultSyncCenter.shared.vault
        let path = archivePath(notePath: notePath, id: id)
        if vault.exists(path) {
            VaultSyncCenter.shared.touch(path)
        } else if let client = VaultBackend.current() {
            _ = try? await VaultSyncCenter.shared.engine.ensureLocal(path, remote: client)
        }
        guard let data = try? vault.read(path), var archive = try? NotebookArchive.decoder.decode(NotebookArchive.self, from: data) else { return nil }
        archive.migrateToCanvas()
        return archive
    }

    /// 儲存筆跡（書寫中隨時呼叫，很快），停筆後上傳（其他裝置可以接著寫；Obsidian 中的圖片離開筆記時更新）。
    static func saveArchive(_ archive: NotebookArchive, notePath: String) throws {
        let path = archivePath(notePath: notePath, id: archive.id)
        try VaultSyncCenter.shared.vault.write(try NotebookArchive.encoder.encode(archive), to: path)
        VaultSyncCenter.shared.fileDidChange(path)
    }

    /// 完整儲存（離開筆記、AI 整理後）：筆跡、畫布圖片（依筆跡之間的空白分段）、更新 Markdown 中 App 管理的區段與標籤。
    static func publish(_ archive: NotebookArchive, notePath: String, store: NotesStore) async throws {
        var archive = archive
        let drawing = archive.pkDrawing
        let paper = archive.paper
        let bands = CanvasLayout.bands(for: drawing)
        archive.pageCount = bands.count
        try saveArchive(archive, notePath: notePath)
        let vault = store.vault
        let pageCount = bands.count
        let images = await Task.detached(priority: .userInitiated) {
            bands.compactMap { PaperRenderer.canvasImage(drawing: drawing, rect: $0, paper: paper, scale: 2).pngData() }
        }.value
        // 圖片每次整個重新產生；按需模式下這台裝置上可能沒有舊的圖片，直接取代遠端版本
        let sync = VaultSyncCenter.shared
        let imagePaths = images.indices.map { pageImagePath(notePath: notePath, id: archive.id, page: $0 + 1) }
        await sync.prepareOverwrite(imagePaths)
        for (path, data) in zip(imagePaths, images) {
            try vault.write(data, to: path)
        }
        // 圖片變少時刪掉多出來的（這台裝置上沒有的，同步時從遠端刪除）
        let remotePaths = Set(sync.pendingFiles.map(\.path))
        var page = images.count + 1
        while true {
            let path = pageImagePath(notePath: notePath, id: archive.id, page: page)
            if vault.exists(path) {
                try? vault.delete(path)
            } else if remotePaths.contains(LocalVault.normalize(path)) {
                await sync.deleteRemoteOnly(path)
            } else {
                break
            }
            page += 1
        }
        let text = vault.readText(notePath) ?? NotebookMarkdown.newNotebook(id: archive.id, createdAt: archive.createdAt)
        let section = NotebookMarkdown.managedSection(id: archive.id, pageCount: pageCount, insights: archive.insights, recognizedText: archive.recognizedText)
        var updated = NotebookMarkdown.replacingManagedSection(in: text, with: section)
        let tags = (archive.insights?.tags ?? []).map(NoteIntelligence.cleanTag).filter { !$0.isEmpty }
        if !tags.isEmpty {
            updated = NoteMarkdownEditing.mergingTagsInto(markdown: updated, tags: tags)
        }
        try store.save(updated, to: notePath)
        VaultSyncCenter.shared.localDidChange()
    }

    private static func writePageImages(_ archive: NotebookArchive, notePath: String, vault: LocalVault) throws {
        let drawing = archive.pkDrawing
        for (index, band) in CanvasLayout.bands(for: drawing).enumerated() {
            if let data = PaperRenderer.canvasImage(drawing: drawing, rect: band, paper: archive.paper, scale: 2).pngData() {
                try vault.write(data, to: pageImagePath(notePath: notePath, id: archive.id, page: index + 1))
            }
        }
    }
}

/// 筆記中的手寫區塊：「附件/ink-xxxx.png」（Obsidian 顯示用）＋「附件/ink-xxxx.ink」（可再編輯的筆跡）。
/// 版本 2 起與手寫筆記相同是連續畫布（寬 `CanvasLayout.width`），`height` 是圖片高度（依筆跡自動決定）；
/// 版本 1 的筆跡外圍有 16 的頁邊。
struct InkBlock: Codable, Equatable {
    static let canvasVersion = 2
    /// 區塊圖片的最小高度，最低的筆跡下面留的空白。
    static let minimumHeight: CGFloat = 240
    static let bottomPadding: CGFloat = 32

    var version = InkBlock.canvasVersion
    var height: CGFloat
    var paper: PaperStyle
    var drawing: Data
    /// 畫布寬度；沒有記錄時是手寫筆記的寬度（`CanvasLayout.width`）。側欄的手寫備忘比較窄。
    var width: CGFloat?

    var canvasWidth: CGFloat { width ?? CanvasLayout.width }

    var pkDrawing: PKDrawing {
        get { (try? PKDrawing(data: drawing)) ?? PKDrawing() }
        set { drawing = newValue.dataRepresentation() }
    }

    /// 舊版的區塊（有頁邊）轉成連續畫布；已是新版時不變。
    mutating func migrateToCanvas() {
        guard version < Self.canvasVersion else { return }
        let margin = PageLayout.inkBlock(height: height).margin
        pkDrawing = PKDrawing(strokes: pkDrawing.strokes.map { stroke in
            var stroke = stroke
            stroke.transform = stroke.transform.concatenating(CGAffineTransform(translationX: -margin, y: -margin))
            return stroke
        })
        version = Self.canvasVersion
    }

    /// 圖片高度剛好包住筆跡（下面留一點空白），至少 `minimumHeight`。
    static func fittedHeight(for drawing: PKDrawing) -> CGFloat {
        guard !drawing.strokes.isEmpty else { return minimumHeight }
        return max(minimumHeight, ceil(drawing.bounds.maxY + bottomPadding))
    }
}

enum InkFiles {
    static let fileExtension = "ink"

    static func newName() -> String {
        "ink-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// 內嵌名稱（ink-xxxx.png）是否為 App 建立的手寫區塊。
    static func blockName(fromEmbed embed: String) -> String? {
        let name = (embed as NSString).lastPathComponent
        guard name.hasPrefix("ink-"), name.lowercased().hasSuffix(".png") else { return nil }
        return String(name.dropLast(4))
    }

    /// 筆記旁邊「附件」資料夾中的位置（新的區塊存在這裡）。
    static func expectedDataPath(notePath: String, name: String) -> String {
        "\(NotesSettings.attachmentsFolder(forNote: notePath))/\(name).\(fileExtension)"
    }

    static func expectedImagePath(notePath: String, name: String) -> String {
        "\(NotesSettings.attachmentsFolder(forNote: notePath))/\(name).png"
    }

    /// 筆跡資料實際的位置：筆記被搬到別的資料夾後（附件留在原處），依檔名找到它。
    /// 手寫備忘的名稱跟著筆記名稱，同名筆記各有一份：找到的備忘旁邊還有它自己的筆記時不算。
    @MainActor
    static func dataPath(notePath: String, name: String) -> String {
        AttachmentLocator.locate(expectedDataPath(notePath: notePath, name: name)) { found in
            guard name.hasPrefix(InkMemo.prefix) else { return true }
            let attachments = (found as NSString).deletingLastPathComponent
            let folder = (attachments as NSString).deletingLastPathComponent
            let stem = String(name.dropFirst(InkMemo.prefix.count))
            return !AttachmentLocator.exists((folder.isEmpty ? "" : folder + "/") + stem + ".md")
        }
    }

    /// 圖片放在筆跡資料旁邊。
    @MainActor
    static func imagePath(notePath: String, name: String) -> String {
        let folder = (dataPath(notePath: notePath, name: name) as NSString).deletingLastPathComponent
        return "\(folder)/\(name).png"
    }

    static func image(for block: InkBlock) -> UIImage {
        PaperRenderer.canvasImage(drawing: block.pkDrawing, rect: CGRect(x: 0, y: 0, width: block.canvasWidth, height: block.height), paper: block.paper, scale: 2)
    }
}

/// 依檔名在整個 vault（這台裝置上的檔案與遠端清單）找附件：筆記被搬到別的資料夾時附件通常留在原處（Obsidian 也不會搬附件）。
@MainActor
enum AttachmentLocator {
    /// 檔名 → 上次找到的位置（避免每次都列出整個 vault）。
    private static var found: [String: String] = [:]

    /// `expected` 存在（這台裝置上或遠端）就是它；否則依檔名找，只有一個符合 `accept` 的檔案時才用它。
    static func locate(_ expected: String, accept: (String) -> Bool = { _ in true }) -> String {
        let expected = LocalVault.normalize(expected)
        if exists(expected) { return expected }
        let name = (expected as NSString).lastPathComponent
        if let cached = found[name], exists(cached), accept(cached) { return cached }
        let sync = VaultSyncCenter.shared
        var matches = Set(sync.pendingFiles.map(\.path).filter { ($0 as NSString).lastPathComponent == name })
        for file in sync.vault.allFiles() where (file.path as NSString).lastPathComponent == name {
            matches.insert(file.path)
        }
        let candidates = matches.filter(accept)
        guard candidates.count == 1, let match = candidates.first else { return expected }
        found[name] = match
        return match
    }

    /// 檔案在這台裝置上或遠端（還沒下載）。
    static func exists(_ path: String) -> Bool {
        let path = LocalVault.normalize(path)
        let sync = VaultSyncCenter.shared
        return sync.vault.exists(path) || sync.pendingFiles.contains { $0.path == path }
    }
}
