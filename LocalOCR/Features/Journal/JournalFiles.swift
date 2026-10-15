import PencilKit
import UIKit

/// 日誌筆記本的檔案：「標題.md」（frontmatter `localocr-notebook: jn-xxxx`）＋附件資料夾中的筆記本資料與每頁圖片（jn-xxxx-頁代碼.png）。
@MainActor
enum JournalFiles {
    /// 新的日誌筆記本放的位置：vault 有「06 日誌」就放那裡（依 vault 規範），否則是目前的資料夾。
    static func defaultFolder(store: NotesStore, fallback: String) -> String {
        store.folders.contains("06 日誌") ? "06 日誌/手寫日誌" : fallback
    }

    static func archivePath(notePath: String, id: String) -> String {
        AttachmentLocator.locate("\(NotesSettings.attachmentsFolder(forNote: notePath))/\(id).\(JournalNotebook.fileExtension)")
    }

    static func pageImageName(id: String, page: JournalPage) -> String {
        "\(id)-\(page.id).png"
    }

    static func pageImagePath(notePath: String, id: String, page: JournalPage) -> String {
        let folder = (archivePath(notePath: notePath, id: id) as NSString).deletingLastPathComponent
        return "\(folder)/\(pageImageName(id: id, page: page))"
    }

    /// 建立新的日誌筆記本（第一頁是今天），回傳 Markdown 路徑。
    static func create(in folder: String, title: String, paper: PaperStyle, store: NotesStore) throws -> String {
        let path = store.uniquePath(folder: folder, title: title)
        let id = JournalNotebook.newID()
        let now = Date()
        let notebook = JournalNotebook(id: id, createdAt: now, updatedAt: now, paper: paper, pages: [JournalPage(date: JournalLayout.day(now))])
        try store.vault.write(try JournalNotebook.encoder.encode(notebook), to: archivePath(notePath: path, id: id))
        try store.vault.writeText(JournalMarkdown.newJournal(id: id, createdAt: now), to: path)
        VaultSyncCenter.shared.localDidChange()
        Task { await store.reload() }
        return path
    }

    /// 讀取筆記本資料；還沒同步下來時先下載。
    static func load(notePath: String, id: String) async -> JournalNotebook? {
        let sync = VaultSyncCenter.shared
        let path = archivePath(notePath: notePath, id: id)
        if sync.vault.exists(path) {
            sync.touch(path)
        } else if let client = VaultBackend.current() {
            _ = try? await sync.engine.ensureLocal(path, remote: client)
        }
        guard let data = try? sync.vault.read(path) else { return nil }
        return try? JournalNotebook.decoder.decode(JournalNotebook.self, from: data)
    }

    /// 儲存筆跡（書寫中隨時呼叫，很快），停筆後上傳。
    static func save(_ notebook: JournalNotebook, notePath: String) throws {
        let path = archivePath(notePath: notePath, id: notebook.id)
        try VaultSyncCenter.shared.vault.write(try JournalNotebook.encoder.encode(notebook), to: path)
        VaultSyncCenter.shared.fileDidChange(path)
    }

    /// 完整儲存（離開、整理後）：改過的頁面重新產生圖片，更新 Markdown 中 App 管理的區段。回傳更新後的筆記本（記下產生圖片時的筆跡）。
    static func publish(_ notebook: JournalNotebook, notePath: String, store: NotesStore) async throws -> JournalNotebook {
        var notebook = notebook
        let sync = VaultSyncCenter.shared
        let vault = store.vault
        let changed = notebook.pages.indices.filter { !notebook.pages[$0].isBlank && notebook.pages[$0].publishedFingerprint != notebook.pages[$0].fingerprint }
        if !changed.isEmpty {
            let paper = notebook.paper
            let jobs = changed.map { (index: $0, page: notebook.pages[$0]) }
            let images = await Task.detached(priority: .userInitiated) {
                jobs.map { ($0.index, JournalRenderer.pageImage($0.page, number: $0.index + 1, paper: paper).pngData()) }
            }.value
            let paths = changed.map { pageImagePath(notePath: notePath, id: notebook.id, page: notebook.pages[$0]) }
            // 圖片每次整個重新產生：直接取代遠端版本
            await sync.prepareOverwrite(paths)
            for (index, data) in images {
                guard let data else { continue }
                try vault.write(data, to: pageImagePath(notePath: notePath, id: notebook.id, page: notebook.pages[index]))
                notebook.pages[index].publishedFingerprint = notebook.pages[index].fingerprint
            }
            for path in paths { sync.fileDidChange(path) }
        }
        try save(notebook, notePath: notePath)
        let text = vault.readText(notePath) ?? JournalMarkdown.newJournal(id: notebook.id, createdAt: notebook.createdAt)
        let section = JournalMarkdown.managedSection(notebook) { pageImageName(id: notebook.id, page: $0) }
        try store.save(JournalMarkdown.replacingManagedSection(in: text, with: section), to: notePath)
        sync.localDidChange()
        return notebook
    }

    /// 目前 vault 中的機種清單（伺服器索引；沒有索引時依這台裝置上「代號 主卡」的檔名）。
    static func models() -> [ModelEntry] {
        let index = VaultIndexStore.shared
        if index.isActive, !index.notes.isEmpty {
            return ModelCatalog.entries(from: Array(index.notes.values))
        }
        return ModelCatalog.entries(fromNotePaths: NotesStore.shared.notes.map(\.path))
    }
}

/// 頁面圖片：白紙、紙張圖樣、頁首日期、頁碼與筆跡（匯出給 Obsidian）；手寫辨識用只有筆跡的白底圖片。
enum JournalRenderer {
    static func pageImage(_ page: JournalPage, number: Int, paper: PaperStyle, scale: CGFloat = 2) -> UIImage {
        let size = JournalLayout.pageSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = page.pkDrawing.image(from: CGRect(origin: .zero, size: size), scale: scale)
        }
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            if let path = PaperRenderer.canvasPatternPath(for: paper, rect: CGRect(origin: .zero, size: size)) {
                cg.addPath(path)
                if paper == .dotted {
                    cg.setFillColor(PaperRenderer.patternColor(for: paper).cgColor)
                    cg.fillPath()
                } else {
                    cg.setStrokeColor(PaperRenderer.patternColor(for: paper).cgColor)
                    cg.setLineWidth(1)
                    cg.strokePath()
                }
            }
            header(for: page.date, number: number).forEach { $0.text.draw(at: $0.point, withAttributes: $0.attributes) }
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 只有筆跡的白底圖片（手寫辨識用）。
    static func inkImage(_ page: JournalPage, scale: CGFloat = 2) -> UIImage {
        let size = JournalLayout.pageSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = page.pkDrawing.image(from: CGRect(origin: .zero, size: size), scale: scale)
        }
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 頁首日期與頁尾頁碼（畫面上的紙張與匯出的圖片共用）。
    static func header(for day: String, number: Int) -> [(text: NSString, point: CGPoint, attributes: [NSAttributedString.Key: Any])] {
        let size = JournalLayout.pageSize
        let dateAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: UIColor(white: 0.35, alpha: 1),
        ]
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular),
            .foregroundColor: UIColor(white: 0.55, alpha: 1),
        ]
        let numberText = "\(number)" as NSString
        let numberWidth = numberText.size(withAttributes: numberAttributes).width
        return [
            (JournalLayout.title(for: day) as NSString, CGPoint(x: 36, y: 26), dateAttributes),
            (numberText, CGPoint(x: (size.width - numberWidth) / 2, y: size.height - 40), numberAttributes),
        ]
    }
}

/// 日誌筆記本的手寫辨識（Vision）與每天的整理（裝置端 Apple Intelligence）。
enum JournalIntelligence {
    /// 辨識改過的頁面：文字與 #機種。回傳更新後的筆記本與辨識了幾頁。
    @MainActor
    static func recognizeChangedPages(_ notebook: JournalNotebook, models: [ModelEntry]) async -> (JournalNotebook, Int) {
        var notebook = notebook
        var count = 0
        let service = OCRService()
        for index in notebook.pages.indices where notebook.pages[index].needsRecognition {
            let page = notebook.pages[index]
            let image = JournalRenderer.inkImage(page)
            guard let result = try? await service.recognize(image) else { continue }
            // 辨識期間又改過的頁面不更新（下次再辨識）
            guard notebook.pages.indices.contains(index), notebook.pages[index].fingerprint == page.fingerprint else { continue }
            notebook.pages[index].recognizedText = result.text
            notebook.pages[index].tags = JournalTags.pageTags(lines: result.lines, pageSize: JournalLayout.pageSize, models: models, previous: page.tags)
            notebook.pages[index].recognizedFingerprint = page.fingerprint
            count += 1
        }
        return (notebook, count)
    }

    /// 內容有變的日子請 Apple Intelligence 整理（摘要、重點、待跟進）；不能用時略過，不影響其他整理。
    static func summarizeChangedDays(_ notebook: JournalNotebook) async -> JournalNotebook {
        var notebook = notebook
        for day in notebook.pagesByDay.map(\.date) {
            let text = JournalMarkdown.text(for: day, in: notebook)
            guard !text.isEmpty else { continue }
            let fingerprint = JournalMarkdown.fingerprint(text)
            guard notebook.days[day]?.textFingerprint != fingerprint else { continue }
            guard let insights = try? await NoteIntelligence.insights(for: text) else { continue }
            notebook.days[day] = JournalDay(textFingerprint: fingerprint, summary: insights.summary, keyPoints: insights.keyPoints, actionItems: insights.actionItems)
        }
        return notebook
    }
}
