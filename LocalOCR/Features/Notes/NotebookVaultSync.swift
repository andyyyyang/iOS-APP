import Foundation
import PencilKit
import SwiftData
import UIKit

/// 筆記相關設定。
enum NotesSettings {
    enum Key {
        static let vaultFolder = "notes.vaultFolder"
        static let vaultName = "notes.vaultName"
        static let autoSync = "notes.autoSync"
    }

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Key.vaultFolder: "iPad 筆記",
            Key.vaultName: "",
            Key.autoSync: true,
        ])
    }

    /// 手寫筆記存放的 vault 資料夾（不含結尾斜線）。
    static var vaultFolder: String {
        let raw = UserDefaults.standard.string(forKey: Key.vaultFolder) ?? ""
        let cleaned = raw.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "/")
        return cleaned.isEmpty ? "iPad 筆記" : cleaned
    }

    static var attachmentsFolder: String { vaultFolder + "/附件" }

    /// 用 obsidian:// 開啟 vault 中的檔案；需要在設定中填入 vault 名稱。
    static func obsidianURL(for path: String) -> URL? {
        let vault = (UserDefaults.standard.string(forKey: Key.vaultName) ?? "").trimmingCharacters(in: .whitespaces)
        guard !vault.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "vault", value: vault), URLQueryItem(name: "file", value: path)]
        return components.url
    }
}

/// 存進 vault 的筆記本原始資料（其他裝置可以匯入並繼續編輯）。
struct NotebookArchive: Codable {
    var version = 1
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var paper: PaperStyle
    var color: NotebookColor
    var pageCount: Int
    var drawing: Data
    var recognizedText: String?
    var insights: NoteInsights?
    var markdownPath: String?

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
}

/// 筆記本轉成 Obsidian Markdown（純函式，方便測試）。
enum NotebookMarkdown {
    static func render(
        title: String,
        createdAt: Date,
        updatedAt: Date,
        shortID: String,
        pageCount: Int,
        insights: NoteInsights?,
        recognizedText: String?
    ) -> String {
        var lines = ["---"]
        lines.append("title: \(yamlString(title))")
        lines.append("created: \(dateFormatter.string(from: createdAt))")
        lines.append("updated: \(dateFormatter.string(from: updatedAt))")
        let tags = (insights?.tags ?? []).map(NoteIntelligence.cleanTag).filter { !$0.isEmpty }
        if !tags.isEmpty {
            lines.append("tags:")
            lines.append(contentsOf: tags.map { "  - \(yamlString($0))" })
        }
        lines.append("source: LocalOCR")
        lines.append("notebook: \(shortID)")
        lines.append("---")
        lines.append("")

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
        lines.append("## 頁面")
        for page in 1...max(pageCount, 1) {
            lines.append("![[\(pageImageName(shortID: shortID, page: page))]]")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func pageImageName(shortID: String, page: Int) -> String {
        "\(shortID)-p\(page).png"
    }

    /// 可當檔名的標題：移除 Obsidian 與檔案系統不允許的字元。
    static func fileName(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
        let cleaned = title.components(separatedBy: forbidden).joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let trimmed = String(cleaned.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? "未命名筆記" : trimmed
    }

    static func yamlString(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()
}

/// 筆記本與 Obsidian vault 的同步。
/// 寫入：每頁一張 PNG、筆記本原始資料、Markdown（Markdown 用 ETag 偵測在 Obsidian 中的修改，不會覆蓋）。
/// 讀取：匯入其他裝置建立或更新的筆記本。
@MainActor
enum NotebookVaultSync {
    /// 寫入 vault，回傳給使用者看的訊息。
    @discardableResult
    static func push(_ notebook: Notebook, client: VaultClient) async throws -> String {
        let shortID = notebook.shortID
        let attachments = NotesSettings.attachmentsFolder
        let drawing = notebook.drawing
        let pageCount = max(notebook.pageCount, 1)
        let paper = notebook.paper

        // 1. 頁面圖片（在背景產生）
        let images = await Task.detached(priority: .userInitiated) {
            (0..<pageCount).compactMap { PaperRenderer.pageImage(drawing: drawing, page: $0, paper: paper, scale: 2).pngData() }
        }.value
        for (index, data) in images.enumerated() {
            let name = NotebookMarkdown.pageImageName(shortID: shortID, page: index + 1)
            try await client.write("\(attachments)/\(name)", data: data, contentType: "image/png")
        }
        // 頁數變少時移除多出來的頁面圖片
        if let listing = try? await client.list(prefix: attachments + "/", recursive: false) {
            let current = Set((1...pageCount).map { NotebookMarkdown.pageImageName(shortID: shortID, page: $0) })
            for entry in listing.files where entry.name.hasPrefix("\(shortID)-p") && entry.pathExtension == "png" && !current.contains(entry.name) {
                try? await client.delete(entry.path)
            }
        }

        // 2. Markdown
        let markdown = NotebookMarkdown.render(
            title: notebook.title,
            createdAt: notebook.createdAt,
            updatedAt: notebook.updatedAt,
            shortID: shortID,
            pageCount: pageCount,
            insights: notebook.insights,
            recognizedText: notebook.recognizedText
        )
        let folder = NotesSettings.vaultFolder
        let desiredPath = "\(folder)/\(NotebookMarkdown.fileName(for: notebook.title)).md"
        var message = "已同步到 Obsidian"
        let entry: VaultEntry
        if let path = notebook.vaultPath, let etag = notebook.vaultETag, path == desiredPath {
            do {
                entry = try await client.writeText(path, markdown, condition: .ifMatch(etag))
            } catch VaultError.conflict, VaultError.notFound {
                // 在 Obsidian 中被修改或刪除：不覆蓋，另存一份
                entry = try await createUnique(base: "\(folder)/\(NotebookMarkdown.fileName(for: notebook.title))（iPad 版本）", markdown: markdown, client: client)
                message = "Obsidian 中的筆記被修改過，這次另存為「\(entry.displayName)」"
            }
        } else {
            entry = try await createUnique(base: "\(folder)/\(NotebookMarkdown.fileName(for: notebook.title))", markdown: markdown, client: client)
            // 改名：移除舊檔（只在 Obsidian 中沒有修改時）
            if let oldPath = notebook.vaultPath, oldPath != entry.path, let etag = notebook.vaultETag {
                try? await client.delete(oldPath, ifMatch: etag)
            }
        }

        // 3. 筆記本原始資料
        let archive = NotebookArchive(
            id: notebook.id,
            title: notebook.title,
            createdAt: notebook.createdAt,
            updatedAt: notebook.updatedAt,
            paper: paper,
            color: notebook.color,
            pageCount: pageCount,
            drawing: notebook.drawingData,
            recognizedText: notebook.recognizedText,
            insights: notebook.insights,
            markdownPath: entry.path
        )
        let archiveData = try NotebookArchive.encoder.encode(archive)
        try await client.write("\(attachments)/\(shortID).\(NotebookArchive.fileExtension)", data: archiveData, contentType: "application/json")

        notebook.vaultPath = entry.path
        notebook.vaultETag = entry.etag
        notebook.syncedAt = max(Date(), notebook.updatedAt)
        return message
    }

    /// 建立新檔；同名已存在時加上編號。
    private static func createUnique(base: String, markdown: String, client: VaultClient) async throws -> VaultEntry {
        for attempt in 1...20 {
            let path = attempt == 1 ? "\(base).md" : "\(base) \(attempt).md"
            do {
                return try await client.writeText(path, markdown, condition: .createOnly)
            } catch VaultError.conflict {
                continue
            }
        }
        throw VaultError.conflict(currentETag: nil)
    }

    /// 匯入其他裝置建立或更新的筆記本；本機有未同步的修改時不覆蓋。回傳匯入／更新的數量。
    static func pull(into context: ModelContext, client: VaultClient) async throws -> Int {
        let attachments = NotesSettings.attachmentsFolder
        let listing = try await client.list(prefix: attachments + "/", recursive: false)
        let archives = listing.files.filter { $0.pathExtension == NotebookArchive.fileExtension }
        guard !archives.isEmpty else { return 0 }
        let local = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        var changed = 0
        for entry in archives {
            let existing = local.first { "\($0.shortID).\(NotebookArchive.fileExtension)" == entry.name }
            if let existing, let syncedAt = existing.syncedAt, entry.mtime <= syncedAt.addingTimeInterval(2) { continue }
            if let existing, existing.needsSync, existing.syncedAt != nil { continue }
            guard let file = try? await client.read(entry.path),
                  let archive = try? NotebookArchive.decoder.decode(NotebookArchive.self, from: file.data) else { continue }
            let notebook: Notebook
            if let existing {
                guard archive.updatedAt > existing.updatedAt else {
                    existing.syncedAt = max(existing.syncedAt ?? .distantPast, existing.updatedAt)
                    continue
                }
                notebook = existing
            } else {
                notebook = Notebook(title: archive.title)
                notebook.id = archive.id
                notebook.createdAt = archive.createdAt
                context.insert(notebook)
            }
            notebook.title = archive.title
            notebook.paper = archive.paper
            notebook.color = archive.color
            notebook.pageCount = archive.pageCount
            notebook.drawingData = archive.drawing
            notebook.recognizedText = archive.recognizedText
            notebook.insights = archive.insights
            notebook.updatedAt = archive.updatedAt
            notebook.vaultPath = archive.markdownPath
            if let path = archive.markdownPath {
                notebook.vaultETag = (try? await client.read(path))?.etag
            }
            notebook.syncedAt = max(Date(), archive.updatedAt)
            NotebookCovers.update(notebook)
            changed += 1
        }
        try? context.save()
        return changed
    }
}

/// 封面（第一頁縮圖）。
enum NotebookCovers {
    @MainActor
    static func update(_ notebook: Notebook) {
        let image = PaperRenderer.pageImage(drawing: notebook.drawing, page: 0, paper: notebook.paper, scale: 0.5)
        notebook.coverData = image.jpegData(compressionQuality: 0.75)
    }
}
