import PencilKit
import XCTest
@testable import LocalOCR

final class NotesTests: XCTestCase {
    // MARK: - 頁面配置

    func testPageLayoutAndIndexing() {
        let first = NotebookLayout.pageRect(0)
        let second = NotebookLayout.pageRect(1)
        XCTAssertEqual(first.minX, NotebookLayout.margin)
        XCTAssertEqual(second.minY - first.maxY, NotebookLayout.pageGap)
        XCTAssertEqual(NotebookLayout.canvasHeight(pageCount: 2), second.maxY + NotebookLayout.margin)
        XCTAssertEqual(NotebookLayout.pageIndex(atY: first.midY, pageCount: 3), 0)
        XCTAssertEqual(NotebookLayout.pageIndex(atY: second.midY, pageCount: 3), 1)
        XCTAssertEqual(NotebookLayout.pageIndex(atY: 100_000, pageCount: 3), 2, "超出範圍時歸到最後一頁")
        let ink = PageLayout.inkBlock(height: 520)
        XCTAssertEqual(ink.canvasHeight(pageCount: 1), 520 + ink.margin * 2)
    }

    private func stroke(onPage page: Int) -> PKStroke {
        let rect = NotebookLayout.pageRect(page)
        let points = [CGPoint(x: rect.midX - 40, y: rect.midY), CGPoint(x: rect.midX + 40, y: rect.midY + 10)].map {
            PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    func testRemovingAndInsertingPagesMovesStrokes() {
        let drawing = PKDrawing(strokes: [stroke(onPage: 0), stroke(onPage: 1), stroke(onPage: 2)])
        let removed = drawing.removingPage(1, pageCount: 3)
        XCTAssertEqual(removed.strokes.count, 2)
        XCTAssertTrue(removed.hasStrokes(onPage: 1, pageCount: 2), "第 3 頁的筆跡移到第 2 頁")
        let inserted = PKDrawing(strokes: [stroke(onPage: 0), stroke(onPage: 1)]).insertingPage(at: 1, pageCount: 2)
        XCTAssertFalse(inserted.hasStrokes(onPage: 1, pageCount: 3), "新插入的頁面是空白的")
        XCTAssertTrue(inserted.hasStrokes(onPage: 2, pageCount: 3))
    }

    // MARK: - 手寫筆記本的 Markdown

    func testManagedSectionKeepsUserText() {
        let note = "---\ncreated: 2026-10-13T14:05:00+08:00\nlocalocr-notebook: nb-1a2b3c4d\n---\n\n我自己寫的開頭\n\n<!-- localocr:notebook -->\n![[nb-1a2b3c4d-p1.png]]\n<!-- /localocr:notebook -->\n\n我寫的結尾\n"
        let insights = NoteInsights(title: "會議", summary: "確認時程。", keyPoints: ["十月上線"], actionItems: ["整理需求"], tags: ["會議"])
        let section = NotebookMarkdown.managedSection(id: "nb-1a2b3c4d", pageCount: 2, insights: insights, recognizedText: "第一頁")
        let updated = NotebookMarkdown.replacingManagedSection(in: note, with: section)
        XCTAssertTrue(updated.contains("我自己寫的開頭\n\n<!-- localocr:notebook -->\n> [!summary] AI 摘要\n> 確認時程。"))
        XCTAssertTrue(updated.contains("## 待辦\n- [ ] 整理需求"))
        XCTAssertTrue(updated.contains("## 手寫內容\n第一頁"))
        XCTAssertTrue(updated.contains("![[nb-1a2b3c4d-p1.png]]\n![[nb-1a2b3c4d-p2.png]]\n<!-- /localocr:notebook -->\n\n我寫的結尾\n"))

        let tagged = NoteMarkdownEditing.mergingTagsInto(markdown: updated, tags: ["會議", "規劃"])
        XCTAssertTrue(tagged.hasPrefix("---\ncreated: 2026-10-13T14:05:00+08:00\nlocalocr-notebook: nb-1a2b3c4d\ntags:\n  - 會議\n  - 規劃\n---"))
    }

    func testManagedSectionIsAppendedWhenMissing() {
        let section = NotebookMarkdown.managedSection(id: "nb-1", pageCount: 1, insights: nil, recognizedText: nil)
        XCTAssertEqual(NotebookMarkdown.replacingManagedSection(in: "使用者的筆記\n", with: section), "使用者的筆記\n\n\(section)\n")
        let fresh = NotebookMarkdown.newNotebook(id: "nb-1", createdAt: Date())
        let summary = NotesStore.summarize(path: "iPad 筆記/手寫.md", mtime: Date(), text: fresh)
        XCTAssertEqual(summary.notebookID, "nb-1")
        XCTAssertEqual(summary.firstEmbed, "nb-1-p1.png")
        XCTAssertEqual(summary.snippet, "", "區段標記不會出現在清單摘要")
    }

    func testNotebookArchiveRoundTrip() throws {
        let archive = NotebookArchive(
            id: "nb-1a2b3c4d",
            createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_760_000_100),
            paper: .grid,
            color: .teal,
            pageCount: 3,
            drawing: PKDrawing(strokes: [stroke(onPage: 2)]).dataRepresentation()
        )
        let decoded = try NotebookArchive.decoder.decode(NotebookArchive.self, from: NotebookArchive.encoder.encode(archive))
        XCTAssertEqual(decoded.paper, .grid)
        XCTAssertEqual(decoded.pkDrawing.strokes.count, 1)
        XCTAssertEqual(decoded.updatedAt, archive.updatedAt)
    }

    func testFileNameAndInkNames() {
        XCTAssertEqual(NotebookMarkdown.fileName(for: "會議: 10/13 #1?"), "會議 10 13 1")
        XCTAssertEqual(NotebookMarkdown.fileName(for: "  "), "未命名筆記")
        XCTAssertEqual(InkFiles.blockName(fromEmbed: "ink-1a2b3c4d.png"), "ink-1a2b3c4d")
        XCTAssertEqual(InkFiles.blockName(fromEmbed: "附件/ink-1a2b3c4d.png"), "ink-1a2b3c4d")
        XCTAssertNil(InkFiles.blockName(fromEmbed: "photo-1.jpg"))
        XCTAssertEqual(NotesSettings.attachmentsFolder(forNote: "a/b/筆記.md"), "a/b/附件")
        XCTAssertEqual(NotesSettings.attachmentsFolder(forNote: "筆記.md"), "附件")
    }

    // MARK: - 筆記編輯

    func testTogglingTasksSkipsFrontmatterAndCode() {
        let text = "---\ntags: [a]\n---\n- [ ] 第一\n```\n- [ ] 程式碼\n```\n> - [ ] 引用\n* [x] 第二\n"
        XCTAssertEqual(NoteMarkdownEditing.togglingTask(at: 0, in: text), text.replacingOccurrences(of: "- [ ] 第一", with: "- [x] 第一"))
        XCTAssertEqual(NoteMarkdownEditing.togglingTask(at: 1, in: text), text.replacingOccurrences(of: "* [x] 第二", with: "* [ ] 第二"))
        XCTAssertEqual(NoteMarkdownEditing.togglingTask(at: 5, in: text), text)
    }

    func testInsertingBlockAddsLineBreaks() {
        let result = NoteMarkdownEditing.inserting("![[ink-1.png]]", into: "前面後面", at: 2)
        XCTAssertEqual(result.text, "前面\n![[ink-1.png]]\n後面")
        XCTAssertEqual(result.cursor, ("前面\n![[ink-1.png]]\n" as NSString).length)
        XCTAssertEqual(NoteMarkdownEditing.inserting("x", into: "", at: 0).text, "x\n")
    }

    func testInsertingInsightsKeepsFrontmatterAndMergesTags() {
        let note = "---\ntitle: 會議\ntags:\n  - 工作\n---\n\n原本的內容\n"
        let insights = NoteInsights(title: "", summary: "重點摘要", keyPoints: ["A"], actionItems: [], tags: ["工作", "規劃"])
        XCTAssertEqual(
            NoteMarkdownEditing.insertingInsights(insights, into: note),
            "---\ntitle: 會議\ntags:\n  - 工作\n  - 規劃\n---\n\n> [!summary] AI 摘要\n> 重點摘要\n>\n> - A\n\n原本的內容\n"
        )
        XCTAssertEqual(NoteMarkdownEditing.mergingTags(["b"], into: ["---", "tags: [a, \"c\"]", "---"]), ["---", "tags:", "  - a", "  - c", "  - b", "---"])
    }

    func testNoteSummary() {
        let text = "---\ntags:\n  - 會議\n  - 規劃\n---\n# 標題\n第一段內容\n![[photo-1.jpg]]\n"
        let summary = NotesStore.summarize(path: "工作/會議紀錄.md", mtime: Date(), text: text)
        XCTAssertEqual(summary.title, "會議紀錄")
        XCTAssertEqual(summary.folder, "工作")
        XCTAssertEqual(summary.tags, ["會議", "規劃"])
        XCTAssertEqual(summary.snippet, "第一段內容")
        XCTAssertEqual(summary.firstEmbed, "photo-1.jpg")
        XCTAssertNil(summary.notebookID)
    }

    @MainActor
    func testHighlighterStylesHeadingsWithoutChangingText() {
        let storage = NSTextStorage(string: "# 標題\n**粗體** #標籤 - [x] 完成")
        MarkdownHighlighter.apply(to: storage)
        XCTAssertEqual(storage.string, "# 標題\n**粗體** #標籤 - [x] 完成")
        let headingFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? UIFont
        XCTAssertGreaterThan(headingFont?.pointSize ?? 0, MarkdownHighlighter.bodyFont.pointSize)
    }

    // MARK: - Markdown 顯示

    func testMarkdownParserBlocks() {
        let text = "---\ntitle: \"會議\"\ntags:\n  - 會議\n  - 規劃\n---\n# 標題\n一段文字\n第二行\n\n- 項目\n  - [ ] 子待辦\n1. 第一\n> [!summary] AI 摘要\n> 內容\n![[nb-1-p1.png]]\n```swift\nlet a = 1\n```\n---"
        let blocks = MarkdownParser.blocks(from: text)
        XCTAssertEqual(blocks[0], .properties([(key: "title", value: "會議"), (key: "tags", value: "會議, 規劃")]))
        XCTAssertEqual(blocks[1], .heading(level: 1, text: "標題"))
        XCTAssertEqual(blocks[2], .paragraph("一段文字\n第二行"))
        XCTAssertEqual(blocks[3], .listItem(marker: .bullet, indent: 0, text: "項目"))
        XCTAssertEqual(blocks[4], .listItem(marker: .task(false), indent: 1, text: "子待辦"))
        XCTAssertEqual(blocks[5], .listItem(marker: .number("1"), indent: 0, text: "第一"))
        XCTAssertEqual(blocks[6], .callout(kind: "summary", title: "AI 摘要", body: "內容"))
        XCTAssertEqual(blocks[7], .embed("nb-1-p1.png"))
        XCTAssertEqual(blocks[8], .code(language: "swift", code: "let a = 1"))
        XCTAssertEqual(blocks[9], .rule)
    }

    func testWikiLinksBecomeTappableLinks() {
        let attributed = MarkdownInline.attributed("見 [[專案計畫|計畫]] 與 [[會議紀錄#結論]]")
        XCTAssertEqual(String(attributed.characters), "見 計畫 與 會議紀錄#結論")
        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(MarkdownInline.wikiTarget(from: links[0]), "專案計畫")
        XCTAssertEqual(MarkdownInline.wikiTarget(from: links[1]), "會議紀錄")
    }

    // MARK: - 配對

    func testPairingLinkAndCode() throws {
        let url = try XCTUnwrap(URL(string: "localocr://pair?server=https%3A%2F%2Flocalocr.example.com&code=abcd-efgh"))
        let link = try XCTUnwrap(PairingClient.parse(url))
        XCTAssertEqual(link.server.absoluteString, "https://localocr.example.com")
        XCTAssertEqual(link.code, "ABCD-EFGH")
        XCTAssertEqual(PairingClient.normalizeCode(" abcd efgh "), "ABCD-EFGH")
        XCTAssertNil(PairingClient.parse(URL(string: "https://example.com/pair?code=x")!))
        XCTAssertNil(PairingClient.parse(URL(string: "localocr://pair?code=ABCD-EFGH")!), "沒有伺服器網址")
    }

    func testVaultURLEncodesPlusAndHiddenPaths() throws {
        let url = try XCTUnwrap(VaultClient.url(
            baseURL: URL(string: "https://example.com")!,
            path: "/v1/vault/file",
            query: [URLQueryItem(name: "path", value: "11 SOP/C++ 筆記.md")]
        ))
        XCTAssertTrue(url.absoluteString.contains("C%2B%2B"), url.absoluteString)
        XCTAssertTrue(LocalVault.isHidden(".obsidian/app.json"))
        XCTAssertFalse(LocalVault.isHidden("11 SOP/a.md"))
        XCTAssertEqual(VaultSyncEngine.normalizeETag("W/\"abc\""), "abc")
        XCTAssertEqual(NoteIntelligence.cleanTag(" #產品 規劃 "), "產品-規劃")
    }
}

// MARK: - 同步引擎

/// 記憶體中的假 Railway 空間（行為與伺服器相同：ETag、If-Match、If-None-Match）。
final class FakeVaultRemote: VaultRemote, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: (data: Data, etag: String)] = [:]
    private var counter = 0
    private(set) var writes: [String] = []

    func put(_ path: String, _ text: String) {
        lock.withLock {
            counter += 1
            files[path] = (Data(text.utf8), "e\(counter)")
        }
    }

    func remove(_ path: String) {
        lock.withLock { files[path] = nil }
    }

    func text(_ path: String) -> String? {
        lock.withLock { files[path].map { String(decoding: $0.data, as: UTF8.self) } }
    }

    var paths: [String] { lock.withLock { files.keys.sorted() } }

    func list(prefix: String, recursive: Bool) async throws -> VaultListing {
        lock.withLock {
            VaultListing(
                files: files.map { VaultEntry(path: $0.key, size: $0.value.data.count, mtime: Date(), etag: $0.value.etag) },
                folders: []
            )
        }
    }

    func read(_ path: String) async throws -> VaultFile {
        try lock.withLock {
            guard let file = files[path] else { throw VaultError.notFound }
            return VaultFile(data: file.data, etag: "\"\(file.etag)\"", mtime: Date())
        }
    }

    func write(_ path: String, data: Data, contentType: String, condition: VaultClient.WriteCondition, mtime: Date) async throws -> VaultEntry {
        try lock.withLock {
            switch condition {
            case .none: break
            case .ifMatch(let etag):
                guard let current = files[path], current.etag == etag else { throw VaultError.conflict(currentETag: files[path]?.etag) }
            case .createOnly:
                if let current = files[path] { throw VaultError.conflict(currentETag: current.etag) }
            }
            counter += 1
            files[path] = (data, "e\(counter)")
            writes.append(path)
            return VaultEntry(path: path, size: data.count, mtime: mtime, etag: "e\(counter)")
        }
    }

    func delete(_ path: String, ifMatch: String?) async throws {
        try lock.withLock {
            guard let current = files[path] else { throw VaultError.notFound }
            if let ifMatch, ifMatch != current.etag { throw VaultError.conflict(currentETag: current.etag) }
            files[path] = nil
        }
    }
}

final class VaultSyncEngineTests: XCTestCase {
    private var root: URL!
    private var vault: LocalVault!
    private var remote: FakeVaultRemote!
    private var engine: VaultSyncEngine!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "vault-tests-\(UUID().uuidString)")
        vault = LocalVault(root: root.appending(path: "Vault"))
        try FileManager.default.createDirectory(at: vault.root, withIntermediateDirectories: true)
        remote = FakeVaultRemote()
        engine = makeEngine()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEngine() -> VaultSyncEngine {
        VaultSyncEngine(vault: vault, stateURL: root.appending(path: "state.json"), now: { Date(timeIntervalSince1970: 1_760_000_000) })
    }

    func testFirstSyncDownloadsNotesButNotImages() async throws {
        remote.put("工作/會議.md", "# 會議")
        remote.put("工作/附件/photo.png", "PNG")
        remote.put(".obsidian/app.json", "{}")
        let report = try await engine.sync(remote: remote)
        XCTAssertEqual(report.downloaded, 1)
        XCTAssertEqual(vault.readText("工作/會議.md"), "# 會議")
        XCTAssertFalse(vault.exists("工作/附件/photo.png"), "圖片需要時才下載")
        XCTAssertFalse(vault.exists(".obsidian/app.json"), "隱藏資料夾不同步")

        _ = try await engine.ensureLocal("工作/附件/photo.png", remote: remote)
        XCTAssertEqual(vault.readText("工作/附件/photo.png"), "PNG")
        let again = try await engine.sync(remote: remote)
        XCTAssertTrue(again.isEmpty, "沒有變動時不做任何事")
    }

    func testLocalAndRemoteEditsFlowBothWays() async throws {
        remote.put("a.md", "v1")
        remote.put("b.md", "b1")
        _ = try await engine.sync(remote: remote)

        try vault.writeText("v2（iPad）", to: "a.md")
        remote.put("b.md", "b2（Obsidian）")
        try vault.writeText("新筆記", to: "c.md")
        let report = try await engine.sync(remote: remote)
        XCTAssertEqual(report.uploaded, 2)
        XCTAssertEqual(report.downloaded, 1)
        XCTAssertEqual(remote.text("a.md"), "v2（iPad）")
        XCTAssertEqual(remote.text("c.md"), "新筆記")
        XCTAssertEqual(vault.readText("b.md"), "b2（Obsidian）")
    }

    func testBothSidesEditedKeepsBothVersions() async throws {
        remote.put("a.md", "v1")
        _ = try await engine.sync(remote: remote)
        try vault.writeText("iPad 版本", to: "a.md")
        remote.put("a.md", "Obsidian 版本")

        let report = try await engine.sync(remote: remote)
        let copy = "a（iPad 衝突 \(conflictStamp)）.md"
        XCTAssertEqual(report.conflicts, [copy])
        XCTAssertEqual(vault.readText("a.md"), "Obsidian 版本")
        XCTAssertEqual(vault.readText(copy), "iPad 版本")
        XCTAssertEqual(remote.text(copy), "iPad 版本", "衝突的本機版本也會上傳")
        XCTAssertEqual(remote.text("a.md"), "Obsidian 版本")
    }

    func testDeletionsPropagateOnlyWhenUnchanged() async throws {
        remote.put("keep.md", "k")
        remote.put("deleted-remotely.md", "x")
        remote.put("deleted-locally.md", "y")
        _ = try await engine.sync(remote: remote)

        remote.remove("deleted-remotely.md")
        try vault.delete("deleted-locally.md")
        let report = try await engine.sync(remote: remote)
        XCTAssertEqual(report.deleted, 2)
        XCTAssertFalse(vault.exists("deleted-remotely.md"))
        XCTAssertNil(remote.text("deleted-locally.md"))
        XCTAssertEqual(remote.paths, ["keep.md"])
    }

    func testRemoteDeletionDoesNotLoseLocalEdits() async throws {
        remote.put("a.md", "v1")
        _ = try await engine.sync(remote: remote)
        try vault.writeText("改過", to: "a.md")
        remote.remove("a.md")
        _ = try await engine.sync(remote: remote)
        XCTAssertEqual(remote.text("a.md"), "改過", "本機改過的筆記重新上傳，不會被刪除")
    }

    func testFirstPairingAdoptsIdenticalFilesAndKeepsDifferentOnes() async throws {
        try vault.writeText("相同", to: "same.md")
        try vault.writeText("本機", to: "diff.md")
        remote.put("same.md", "相同")
        remote.put("diff.md", "遠端")
        let report = try await engine.sync(remote: remote)
        XCTAssertEqual(report.conflicts, ["diff（iPad 衝突 \(conflictStamp)）.md"])
        XCTAssertEqual(vault.readText("diff.md"), "遠端")
        XCTAssertFalse(remote.writes.contains("same.md"), "內容相同的檔案不會重新上傳")
    }

    func testSafetyStops() async throws {
        for index in 0..<20 { remote.put("n\(index).md", "\(index)") }
        _ = try await engine.sync(remote: remote)

        let empty = FakeVaultRemote()
        do {
            _ = try await engine.sync(remote: empty)
            XCTFail("遠端是空的時應該停止")
        } catch VaultSyncError.remoteLooksEmpty {}

        for index in 0..<15 { remote.remove("n\(index).md") }
        do {
            _ = try await engine.sync(remote: remote)
            XCTFail("一次刪除太多時應該停止")
        } catch VaultSyncError.tooManyDeletions(let local, _) {
            XCTAssertEqual(local, 15)
        }
        XCTAssertTrue(vault.exists("n0.md"), "停止時不刪任何檔案")
        let report = try await engine.sync(remote: remote, allowMassDeletion: true)
        XCTAssertEqual(report.deleted, 15)
    }

    func testStatePersistsAcrossLaunches() async throws {
        remote.put("a.md", "v1")
        _ = try await engine.sync(remote: remote)
        engine = makeEngine()
        try vault.writeText("v2", to: "a.md")
        let report = try await engine.sync(remote: remote)
        XCTAssertEqual(report.uploaded, 1)
        XCTAssertTrue(report.conflicts.isEmpty, "重新啟動後仍記得上次同步的版本")
    }

    private var conflictStamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: Date(timeIntervalSince1970: 1_760_000_000))
    }
}
