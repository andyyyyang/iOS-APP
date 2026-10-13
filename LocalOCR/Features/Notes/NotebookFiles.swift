import Foundation
import PencilKit
import UIKit

/// 筆記相關設定。
enum NotesSettings {
    enum Key {
        static let defaultFolder = "notes.vaultFolder"
        static let vaultName = "notes.vaultName"
        static let downloadAllFiles = "notes.downloadAllFiles"
        static let migratedDefaultFolder = "notes.migratedDefaultFolder"
    }

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Key.defaultFolder: "",
            Key.vaultName: "",
            Key.downloadAllFiles: true,
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

    /// 同步時下載 vault 中的所有檔案（關閉時只下載筆記，圖片等附件打開時才下載）。
    static var downloadAllFiles: Bool {
        UserDefaults.standard.object(forKey: Key.downloadAllFiles) as? Bool ?? true
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

/// 手寫筆記本的資料（存在附件資料夾，其他裝置可以接著編輯）。
struct NotebookArchive: Codable, Equatable {
    var version = 1
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

    static func archivePath(notePath: String, id: String) -> String {
        "\(NotesSettings.attachmentsFolder(forNote: notePath))/\(id).\(NotebookArchive.fileExtension)"
    }

    static func pageImagePath(notePath: String, id: String, page: Int) -> String {
        "\(NotesSettings.attachmentsFolder(forNote: notePath))/\(NotebookMarkdown.pageImageName(id: id, page: page))"
    }

    /// 建立新的手寫筆記本，回傳 Markdown 路徑。
    static func create(in folder: String, title: String, paper: PaperStyle, color: NotebookColor, store: NotesStore) throws -> String {
        let path = store.uniquePath(folder: folder, title: title)
        let id = newID()
        let now = Date()
        let archive = NotebookArchive(id: id, createdAt: now, updatedAt: now, paper: paper, color: color, pageCount: 1, drawing: PKDrawing().dataRepresentation())
        try store.vault.write(try NotebookArchive.encoder.encode(archive), to: archivePath(notePath: path, id: id))
        try writePageImages(archive, notePath: path, vault: store.vault)
        try store.vault.writeText(NotebookMarkdown.newNotebook(id: id, createdAt: now), to: path)
        VaultSyncCenter.shared.localDidChange()
        Task { await store.reload() }
        return path
    }

    /// 讀取筆記本資料；檔案還沒同步下來時先下載。
    static func load(notePath: String, id: String) async -> NotebookArchive? {
        let vault = VaultSyncCenter.shared.vault
        let path = archivePath(notePath: notePath, id: id)
        if !vault.exists(path), let client = VaultClient.configured() {
            _ = try? await VaultSyncCenter.shared.engine.ensureLocal(path, remote: client)
        }
        guard let data = try? vault.read(path) else { return nil }
        return try? NotebookArchive.decoder.decode(NotebookArchive.self, from: data)
    }

    /// 儲存筆跡（書寫中隨時呼叫，很快）。
    static func saveArchive(_ archive: NotebookArchive, notePath: String) throws {
        try VaultSyncCenter.shared.vault.write(try NotebookArchive.encoder.encode(archive), to: archivePath(notePath: notePath, id: archive.id))
    }

    /// 完整儲存（離開筆記本、AI 整理後）：筆跡、每頁圖片、更新 Markdown 中 App 管理的區段與標籤。
    static func publish(_ archive: NotebookArchive, notePath: String, store: NotesStore) async throws {
        try saveArchive(archive, notePath: notePath)
        let vault = store.vault
        let drawing = archive.pkDrawing
        let paper = archive.paper
        let pageCount = max(archive.pageCount, 1)
        let images = await Task.detached(priority: .userInitiated) {
            (0..<pageCount).compactMap { PaperRenderer.pageImage(drawing: drawing, page: $0, paper: paper, scale: 2).pngData() }
        }.value
        for (index, data) in images.enumerated() {
            try vault.write(data, to: pageImagePath(notePath: notePath, id: archive.id, page: index + 1))
        }
        // 頁數變少時刪掉多出來的頁面圖片
        var page = pageCount + 1
        while vault.exists(pageImagePath(notePath: notePath, id: archive.id, page: page)) {
            try? vault.delete(pageImagePath(notePath: notePath, id: archive.id, page: page))
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
        for page in 0..<max(archive.pageCount, 1) {
            if let data = PaperRenderer.pageImage(drawing: archive.pkDrawing, page: page, paper: archive.paper, scale: 2).pngData() {
                try vault.write(data, to: pageImagePath(notePath: notePath, id: archive.id, page: page + 1))
            }
        }
    }
}

/// 筆記中的手寫區塊：「附件/ink-xxxx.png」（Obsidian 顯示用）＋「附件/ink-xxxx.ink」（可再編輯的筆跡）。
struct InkBlock: Codable, Equatable {
    var version = 1
    var height: CGFloat
    var paper: PaperStyle
    var drawing: Data

    static let defaultHeight: CGFloat = 520

    var layout: PageLayout { .inkBlock(height: height) }
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

    static func dataPath(notePath: String, name: String) -> String {
        "\(NotesSettings.attachmentsFolder(forNote: notePath))/\(name).\(fileExtension)"
    }

    static func imagePath(notePath: String, name: String) -> String {
        "\(NotesSettings.attachmentsFolder(forNote: notePath))/\(name).png"
    }

    static func image(for block: InkBlock) -> UIImage {
        PaperRenderer.pageImage(drawing: (try? PKDrawing(data: block.drawing)) ?? PKDrawing(), page: 0, paper: block.paper, scale: 2, layout: block.layout)
    }
}
