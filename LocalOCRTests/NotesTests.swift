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
        XCTAssertEqual(NotebookLayout.pageIndex(atY: -50, pageCount: 3), 0)
    }

    private func stroke(onPage page: Int) -> PKStroke {
        let rect = NotebookLayout.pageRect(page)
        let points = [CGPoint(x: rect.midX - 40, y: rect.midY), CGPoint(x: rect.midX + 40, y: rect.midY + 10)].map {
            PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    func testRemovingPageShiftsLaterPagesUp() {
        let drawing = PKDrawing(strokes: [stroke(onPage: 0), stroke(onPage: 1), stroke(onPage: 2)])
        let removed = drawing.removingPage(1, pageCount: 3)
        XCTAssertEqual(removed.strokes.count, 2)
        XCTAssertTrue(removed.hasStrokes(onPage: 0, pageCount: 2))
        XCTAssertTrue(removed.hasStrokes(onPage: 1, pageCount: 2), "第 3 頁的筆跡移到第 2 頁")
    }

    func testInsertingPageShiftsLaterPagesDown() {
        let drawing = PKDrawing(strokes: [stroke(onPage: 0), stroke(onPage: 1)])
        let inserted = drawing.insertingPage(at: 1, pageCount: 2)
        XCTAssertTrue(inserted.hasStrokes(onPage: 0, pageCount: 3))
        XCTAssertFalse(inserted.hasStrokes(onPage: 1, pageCount: 3), "新插入的頁面是空白的")
        XCTAssertTrue(inserted.hasStrokes(onPage: 2, pageCount: 3))
    }

    // MARK: - Obsidian Markdown

    func testNotebookMarkdownForObsidian() {
        let date = ISO8601DateFormatter().date(from: "2026-10-13T06:05:00Z")!
        let insights = NoteInsights(
            title: "專案會議",
            summary: "確認第四季時程。",
            keyPoints: ["十月底上線"],
            actionItems: ["整理需求"],
            tags: ["會議", "#產品 規劃"]
        )
        let markdown = NotebookMarkdown.render(
            title: "專案 \"會議\"",
            createdAt: date,
            updatedAt: date,
            shortID: "nb-1a2b3c4d",
            pageCount: 2,
            insights: insights,
            recognizedText: "第一頁\n\n第二頁"
        )
        XCTAssertTrue(markdown.hasPrefix("---\ntitle: \"專案 \\\"會議\\\"\"\n"))
        XCTAssertTrue(markdown.contains("tags:\n  - \"會議\"\n  - \"產品-規劃\"\n"))
        XCTAssertTrue(markdown.contains("notebook: nb-1a2b3c4d\n---\n"))
        XCTAssertTrue(markdown.contains("> [!summary] AI 摘要\n> 確認第四季時程。"))
        XCTAssertTrue(markdown.contains("## 待辦\n- [ ] 整理需求"))
        XCTAssertTrue(markdown.contains("## 手寫內容\n第一頁\n\n第二頁"))
        XCTAssertTrue(markdown.contains("![[nb-1a2b3c4d-p1.png]]\n![[nb-1a2b3c4d-p2.png]]"))
    }

    func testFileNameRemovesForbiddenCharacters() {
        XCTAssertEqual(NotebookMarkdown.fileName(for: "會議: 10/13 #1?"), "會議 10 13 1")
        XCTAssertEqual(NotebookMarkdown.fileName(for: "  "), "未命名筆記")
        XCTAssertEqual(NotebookMarkdown.fileName(for: String(repeating: "長", count: 200)).count, 80)
    }

    func testNotebookArchiveRoundTrip() throws {
        let archive = NotebookArchive(
            id: UUID(),
            title: "筆記",
            createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_760_000_100),
            paper: .grid,
            color: .teal,
            pageCount: 3,
            drawing: PKDrawing(strokes: [stroke(onPage: 2)]).dataRepresentation(),
            recognizedText: "文字",
            insights: nil,
            markdownPath: "iPad 筆記/筆記.md"
        )
        let data = try NotebookArchive.encoder.encode(archive)
        let decoded = try NotebookArchive.decoder.decode(NotebookArchive.self, from: data)
        XCTAssertEqual(decoded.id, archive.id)
        XCTAssertEqual(decoded.paper, .grid)
        XCTAssertEqual(decoded.pageCount, 3)
        XCTAssertEqual(try PKDrawing(data: decoded.drawing).strokes.count, 1)
        XCTAssertEqual(decoded.updatedAt, archive.updatedAt)
    }

    // MARK: - Markdown 顯示

    func testMarkdownParserBlocks() {
        let text = """
        ---
        title: "會議"
        tags:
          - 會議
          - 規劃
        ---
        # 標題
        一段文字
        第二行

        - 項目
          - [ ] 子待辦
        1. 第一
        > [!summary] AI 摘要
        > 內容
        > 第二行
        ![[nb-1-p1.png]]
        ```swift
        let a = 1
        ```
        ---
        """
        let blocks = MarkdownParser.blocks(from: text)
        XCTAssertEqual(blocks[0], .properties([(key: "title", value: "會議"), (key: "tags", value: "會議, 規劃")]))
        XCTAssertEqual(blocks[1], .heading(level: 1, text: "標題"))
        XCTAssertEqual(blocks[2], .paragraph("一段文字\n第二行"))
        XCTAssertEqual(blocks[3], .listItem(marker: .bullet, indent: 0, text: "項目"))
        XCTAssertEqual(blocks[4], .listItem(marker: .task(false), indent: 1, text: "子待辦"))
        XCTAssertEqual(blocks[5], .listItem(marker: .number("1"), indent: 0, text: "第一"))
        XCTAssertEqual(blocks[6], .callout(kind: "summary", title: "AI 摘要", body: "內容\n第二行"))
        XCTAssertEqual(blocks[7], .embed("nb-1-p1.png"))
        XCTAssertEqual(blocks[8], .code(language: "swift", code: "let a = 1"))
        XCTAssertEqual(blocks[9], .rule)
    }

    func testWikiLinksBecomeTappableLinks() throws {
        let attributed = MarkdownInline.attributed("見 [[專案計畫|計畫]] 與 [[會議紀錄#結論]]")
        XCTAssertEqual(String(attributed.characters), "見 計畫 與 會議紀錄#結論")
        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(MarkdownInline.wikiTarget(from: links[0]), "專案計畫")
        XCTAssertEqual(MarkdownInline.wikiTarget(from: links[1]), "會議紀錄")
    }

    func testInsertingInsightsKeepsFrontmatterAndMergesTags() {
        let note = "---\ntitle: 會議\ntags:\n  - 工作\n---\n\n原本的內容\n"
        let insights = NoteInsights(title: "", summary: "重點摘要", keyPoints: ["A"], actionItems: [], tags: ["工作", "規劃"])
        let result = NoteMarkdownEditing.insertingInsights(insights, into: note)
        XCTAssertEqual(result, "---\ntitle: 會議\ntags:\n  - 工作\n  - 規劃\n---\n\n> [!summary] AI 摘要\n> 重點摘要\n>\n> - A\n\n原本的內容\n")

        let plain = NoteMarkdownEditing.insertingInsights(
            NoteInsights(title: "", summary: "摘要", keyPoints: [], actionItems: [], tags: ["新"]),
            into: "內容"
        )
        XCTAssertEqual(plain, "---\ntags:\n  - 新\n---\n\n> [!summary] AI 摘要\n> 摘要\n\n內容\n")
    }

    func testInlineTagArrayIsMerged() {
        let merged = NoteMarkdownEditing.mergingTags(["b"], into: ["---", "tags: [a, \"c\"]", "---"])
        XCTAssertEqual(merged, ["---", "tags:", "  - a", "  - c", "  - b", "---"])
    }

    // MARK: - Vault 客戶端

    func testVaultURLEncodesPlusAndUnicode() throws {
        let url = try XCTUnwrap(VaultClient.url(
            baseURL: URL(string: "https://example.com")!,
            path: "/v1/vault/file",
            query: [URLQueryItem(name: "path", value: "11 SOP/C++ 筆記.md")]
        ))
        XCTAssertTrue(url.absoluteString.contains("C%2B%2B"), url.absoluteString)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first?.value?.replacingOccurrences(of: "%2B", with: "+"), "11 SOP/C++ 筆記.md")
    }

    func testVaultEntryParsing() throws {
        let value = try JSONValue.parse(#"{"path":"iPad 筆記/附件/nb-1-p1.png","size":2048,"mtime":1760000000000,"etag":"\"abc\""}"#)
        let entry = try XCTUnwrap(VaultClient.entry(from: value))
        XCTAssertEqual(entry.name, "nb-1-p1.png")
        XCTAssertTrue(entry.isImage)
        XCTAssertEqual(entry.mtime, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(entry.etag, "\"abc\"")
        XCTAssertTrue(VaultBrowserModel.isHidden(".obsidian/app.json"))
        XCTAssertFalse(VaultBrowserModel.isHidden("11 SOP/a.md"))
    }

    func testCleanTag() {
        XCTAssertEqual(NoteIntelligence.cleanTag(" #產品 規劃 "), "產品-規劃")
    }
}
