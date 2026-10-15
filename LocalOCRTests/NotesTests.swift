import PencilKit
import UIKit
import XCTest
@testable import LocalOCR

final class NotesTests: XCTestCase {
    // MARK: - 手寫畫布

    func testLegacyPagedLayoutAndIndexing() {
        let old = PageLayout.notebook
        let first = old.pageRect(0)
        let second = old.pageRect(1)
        XCTAssertEqual(first.minX, old.margin)
        XCTAssertEqual(second.minY - first.maxY, old.pageGap)
        XCTAssertEqual(old.canvasHeight(pageCount: 2), second.maxY + old.margin)
        XCTAssertEqual(old.pageIndex(atY: first.midY, pageCount: 3), 0)
        XCTAssertEqual(old.pageIndex(atY: second.midY, pageCount: 3), 1)
        XCTAssertEqual(old.pageIndex(atY: 100_000, pageCount: 3), 2, "超出範圍時歸到最後一頁")
        XCTAssertEqual(old.pageSize.height, CanvasLayout.segmentHeight, "舊版每頁對應畫布上的一段")
        let ink = PageLayout.inkBlock(height: 520)
        XCTAssertEqual(ink.canvasHeight(pageCount: 1), 520 + ink.margin * 2)
    }

    private func stroke(at center: CGPoint) -> PKStroke {
        let points = [CGPoint(x: center.x - 40, y: center.y), CGPoint(x: center.x + 40, y: center.y + 10)].map {
            PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    /// 2.3 以前分頁筆記本第 `page` 頁中間的一筆。
    private func stroke(onPage page: Int) -> PKStroke {
        let rect = PageLayout.notebook.pageRect(page)
        return stroke(at: CGPoint(x: rect.midX, y: rect.midY))
    }

    func testMigratingPagedNotebookKeepsPositionWithinEachPage() {
        let drawing = PKDrawing(strokes: [stroke(onPage: 0), stroke(onPage: 2)])
        let migrated = drawing.migratedFromPagedNotebook(pageCount: 3)
        for (index, page) in [0, 2].enumerated() {
            let rect = PageLayout.notebook.pageRect(page)
            let before = drawing.strokes[index].renderBounds
            let after = migrated.strokes[index].renderBounds
            XCTAssertEqual(after.minX, before.minX - rect.minX, accuracy: 0.5)
            XCTAssertEqual(after.minY, before.minY - rect.minY + CGFloat(page) * CanvasLayout.segmentHeight, accuracy: 0.5)
        }

        var archive = NotebookArchive(id: "nb-1", createdAt: Date(), updatedAt: Date(), paper: .lined, color: .blue, pageCount: 3, drawing: drawing.dataRepresentation())
        XCTAssertEqual(archive.version, NotebookArchive.canvasVersion, "新筆記一開始就是連續畫布")
        archive.version = 1
        archive.migrateToCanvas()
        XCTAssertEqual(archive.version, NotebookArchive.canvasVersion)
        XCTAssertEqual(archive.pkDrawing.strokes.count, 2)
        let converted = archive
        archive.migrateToCanvas()
        XCTAssertEqual(archive, converted, "已轉換的筆記不會再移動")
    }

    func testCanvasHeightGrowsWithWriting() {
        XCTAssertEqual(CanvasLayout.height(for: PKDrawing(), minimum: 0), CanvasLayout.segmentHeight)
        XCTAssertEqual(CanvasLayout.height(for: PKDrawing(), minimum: 1500), CanvasLayout.segmentHeight * 2, "至少填滿畫面")
        let low = PKDrawing(strokes: [stroke(at: CGPoint(x: 400, y: 1000))])
        XCTAssertEqual(CanvasLayout.height(for: low, minimum: 0), CanvasLayout.segmentHeight * 2, "最低的筆跡下方保留書寫空間")
    }

    func testExportBandsAvoidCuttingThroughStrokes() {
        XCTAssertEqual(CanvasLayout.bands(for: PKDrawing()), [CGRect(x: 0, y: 0, width: CanvasLayout.width, height: CanvasLayout.segmentHeight)])
        let short = PKDrawing(strokes: [stroke(at: CGPoint(x: 400, y: 300))])
        let single = CanvasLayout.bands(for: short)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].maxY, short.bounds.maxY + CanvasLayout.exportPadding, accuracy: 0.5)

        // 中間那一筆剛好跨過第一段的底部：切點往上移到它的上面
        let drawing = PKDrawing(strokes: [
            stroke(at: CGPoint(x: 400, y: 200)),
            stroke(at: CGPoint(x: 400, y: CanvasLayout.segmentHeight)),
            stroke(at: CGPoint(x: 400, y: 2000)),
        ])
        let bands = CanvasLayout.bands(for: drawing)
        XCTAssertEqual(bands.count, 2)
        XCTAssertEqual(bands[0].minY, 0)
        XCTAssertEqual(bands[0].maxY, bands[1].minY, "各段相連")
        XCTAssertLessThanOrEqual(bands[0].maxY, drawing.strokes[1].renderBounds.minY, "不把跨界的那一筆切成兩半")
        XCTAssertTrue(bands.allSatisfy { $0.height <= CanvasLayout.segmentHeight })
        XCTAssertEqual(bands[1].maxY, drawing.bounds.maxY + CanvasLayout.exportPadding, accuracy: 0.5)
        XCTAssertTrue(drawing.hasStrokes(in: bands[1]))
        XCTAssertFalse(short.hasStrokes(in: CGRect(x: 0, y: 1000, width: CanvasLayout.width, height: 100)))
    }

    func testCanvasPaperPatternContinuesAcrossSegments() {
        let spacing = PaperRenderer.spacing
        XCTAssertEqual(PaperRenderer.positions(first: spacing, from: 0, to: spacing * 3.5), [spacing, spacing * 2, spacing * 3])
        // 第二段的第一條橫線接在第一段最後一條的下一格
        let firstSegment = PaperRenderer.positions(first: PaperRenderer.linedTopMargin, from: 0, to: CanvasLayout.segmentHeight)
        let secondSegment = PaperRenderer.positions(first: PaperRenderer.linedTopMargin, from: CanvasLayout.segmentHeight, to: CanvasLayout.segmentHeight * 2)
        XCTAssertEqual(firstSegment.first, PaperRenderer.linedTopMargin)
        XCTAssertEqual(secondSegment.first, firstSegment.last.map { $0 + spacing })
        XCTAssertNil(PaperRenderer.canvasPatternPath(for: .blank, rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
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
        XCTAssertEqual(decoded.version, NotebookArchive.canvasVersion)
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

    // MARK: - 即時預覽

    private func styled(_ text: String, selection: NSRange? = nil, images: [String: UIImage] = [:], resolves: @escaping (String) -> Bool = { _ in true }) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        LiveMarkdown.apply(to: storage, options: LiveMarkdown.Options(selection: selection, width: 600, images: images, resolvesLink: resolves))
        return storage
    }

    private func isHidden(_ storage: NSTextStorage, at index: Int) -> Bool {
        (storage.attribute(.font, at: index, effectiveRange: nil) as? UIFont)?.pointSize ?? 17 < 1
    }

    func testLivePreviewHidesSyntaxExceptOnTheActiveLine() {
        let text = "# 標題\n**粗體** 與 *斜體*"
        let storage = styled(text)
        XCTAssertEqual(storage.string, text, "只改顯示，不改文字")
        XCTAssertTrue(isHidden(storage, at: 0), "沒在編輯的行藏起 #")
        let headingFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? UIFont
        XCTAssertGreaterThan(headingFont?.pointSize ?? 0, LiveMarkdown.Theme.bodyFont.pointSize)
        let boldStart = (text as NSString).range(of: "**").location
        XCTAssertTrue(isHidden(storage, at: boldStart))
        let bold = storage.attribute(.font, at: boldStart + 2, effectiveRange: nil) as? UIFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)

        // 游標在標題行：顯示 #（淡色），其他行照樣藏起來
        let editing = styled(text, selection: NSRange(location: 3, length: 0))
        XCTAssertFalse(isHidden(editing, at: 0))
        XCTAssertTrue(isHidden(editing, at: boldStart))
    }

    func testLivePreviewTasksLinksAndImages() {
        let text = "- [ ] 待辦\n- [x] 完成\n見 [[專案計畫|計畫]] 與 [[不存在]]\n![[photo.png]]\n| a | b |\n| - | - |\n| 1 | 2 |"
        let ns = text as NSString
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 600)).image { _ in }
        let storage = styled(text, images: ["photo.png": image], resolves: { $0 == "專案計畫" })
        XCTAssertEqual(storage.string, text)
        XCTAssertEqual(storage.attribute(.mdCheckbox, at: ns.range(of: "[ ]").location, effectiveRange: nil) as? Bool, false)
        XCTAssertEqual(storage.attribute(.mdCheckbox, at: ns.range(of: "[x]").location, effectiveRange: nil) as? Bool, true)
        let alias = ns.range(of: "計畫]]").location
        XCTAssertEqual(storage.attribute(.mdWikiLink, at: alias, effectiveRange: nil) as? String, "專案計畫")
        XCTAssertTrue(isHidden(storage, at: ns.range(of: "專案計畫|").location), "有別名時只顯示別名")
        let missing = ns.range(of: "不存在").location
        XCTAssertEqual(storage.attribute(.foregroundColor, at: missing, effectiveRange: nil) as? UIColor, LiveMarkdown.Theme.unresolved)
        let info = storage.attribute(.mdImage, at: ns.range(of: "![[photo").location, effectiveRange: nil) as? MarkdownImageInfo
        XCTAssertEqual(info?.name, "photo.png")
        XCTAssertEqual(info?.size, CGSize(width: 600, height: 300), "圖片縮到文字欄寬")
        let table = storage.attribute(.mdTable, at: ns.range(of: "| a").location, effectiveRange: nil) as? MarkdownTableInfo
        XCTAssertEqual(table?.cells.count, 2, "分隔列不算一列")
        XCTAssertEqual(table?.hasHeader, true)
        XCTAssertTrue(isHidden(storage, at: ns.range(of: "| 1").location), "原始的表格文字藏起來，改畫格線表")

        // 還沒載入的圖片：回報要載入
        let pending = NSTextStorage(string: "![[scan.jpg|300]]")
        let needed = LiveMarkdown.apply(to: pending, options: LiveMarkdown.Options(selection: nil, width: 600))
        XCTAssertEqual(needed, ["scan.jpg"])
        XCTAssertEqual(LiveMarkdown.embed(in: "![[scan.jpg|300]]")?.width, 300)
    }

    func testLivePreviewTables() {
        // 沒有外框的 GFM 表格；儲存格裡的粗體、程式碼、跳脫的 | 與 <br>
        let text = "名稱 | 說明\n:--- | ---:\n**K3** | `x` \\| y<br>z\n\n後面的段落"
        let ns = text as NSString
        let storage = styled(text)
        let table = storage.attribute(.mdTable, at: 0, effectiveRange: nil) as? MarkdownTableInfo
        XCTAssertNotNil(table)
        XCTAssertEqual(table?.cells.count, 2)
        XCTAssertEqual(table?.cells.first?.map(\.string), ["名稱", "說明"])
        let first = table?.cells[1][0]
        XCTAssertEqual(first?.string, "**K3**")
        let bold = first?.attribute(.font, at: 2, effectiveRange: nil) as? UIFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false, "儲存格內的 **粗體** 有套用")
        XCTAssertLessThan((first?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize ?? 17, 1, "** 藏起來")
        XCTAssertEqual(table?.cells[1][1].string, "`x` | y\nz")
        let alignment = (table?.cells[1][1].attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        XCTAssertEqual(alignment, .right, "---: 靠右")
        XCTAssertLessThanOrEqual(table?.size.width ?? 999, 600)
        XCTAssertNil(storage.attribute(.mdTable, at: ns.range(of: "後面").location, effectiveRange: nil))
        XCTAssertFalse(isHidden(storage, at: ns.range(of: "後面").location))

        // 游標在表格裡：顯示原始文字方便編輯
        let editing = styled(text, selection: NSRange(location: 1, length: 0))
        XCTAssertNil(editing.attribute(.mdTable, at: 0, effectiveRange: nil))
        XCTAssertFalse(isHidden(editing, at: ns.range(of: "K3").location))

        XCTAssertEqual(table?.stacked, false, "放得下的表格畫成格線表")

        // 四欄、內容長：縮小字級後放得下，仍是格線表，儲存格換行
        let four = styled("| 名稱 | 部門 | 職稱 | 備註 |\n|---|---|---|---|\n| " + Array(repeating: String(repeating: "很長的內容", count: 8), count: 4).joined(separator: " | ") + " |")
        let fourTable = four.attribute(.mdTable, at: 0, effectiveRange: nil) as? MarkdownTableInfo
        XCTAssertEqual(fourTable?.stacked, false)
        XCTAssertLessThanOrEqual(fourTable?.size.width ?? 999, 600)
        XCTAssertGreaterThan(fourTable?.rowHeights.last ?? 0, 40, "放不下的儲存格換行")

        // 手機上的寬表格（像聯絡人清單）：每一列改成卡片，第一欄是標題，其他欄是「欄名　內容」
        let contacts = "| 姓名 | 部門 / 單位 | 職稱 / 角色 | 分機 / MVPN | Email | 評估職掌重點 |\n|---|---|---|---|---|---|\n"
            + "| **[[黃暐庭 - 研發一課\\|黃暐庭]]** | 研發一處 研發一課 | 工程師 | — / **25787** | `weitinghuang@jentech.com.tw` | **Amkor CNC 案主責**、樣品試作與開案排程對接 |\n"
            + "| **簡禕蓀** | 研發一處 研發一課 | 課長 | **5524** / — | — | 黃暐庭直屬主管 |"
        let narrow = NSTextStorage(string: contacts)
        LiveMarkdown.apply(to: narrow, options: LiveMarkdown.Options(selection: nil, width: 330))
        let cards = narrow.attribute(.mdTable, at: 0, effectiveRange: nil) as? MarkdownTableInfo
        XCTAssertEqual(cards?.stacked, true)
        XCTAssertEqual(cards?.cards.count, 2, "兩列資料兩張卡片")
        XCTAssertLessThanOrEqual(cards?.size.width ?? 999, 330)
        let texts = cards?.pieces.map(\.text.string) ?? []
        XCTAssertTrue(texts.contains("Email"), "欄名當標籤")
        XCTAssertTrue(texts.contains("**[[黃暐庭 - 研發一課|黃暐庭]]**"), "第一欄當卡片標題（跳脫的 | 還原）")
        if let title = cards?.pieces.first {
            XCTAssertEqual(cards?.link(at: CGPoint(x: title.frame.minX + 6, y: title.frame.midY)), .wikiLink("黃暐庭 - 研發一課"), "卡片標題的連結點得到")
        }
        // 同一張表在平板寬度：格線表
        let wideScreen = NSTextStorage(string: contacts)
        LiveMarkdown.apply(to: wideScreen, options: LiveMarkdown.Options(selection: nil, width: 900))
        XCTAssertEqual((wideScreen.attribute(.mdTable, at: 0, effectiveRange: nil) as? MarkdownTableInfo)?.stacked, false)

        // 儲存格裡的連結點得到
        let linked = styled("| 筆記 |\n| --- |\n| [[專案]] |")
        let linkTable = linked.attribute(.mdTable, at: 0, effectiveRange: nil) as? MarkdownTableInfo
        let bodyTop = (linkTable?.rowHeights.first ?? 0) + MarkdownTableInfo.verticalPadding
        XCTAssertEqual(linkTable?.link(at: CGPoint(x: MarkdownTableInfo.horizontalPadding + 4, y: bodyTop + 6)), .wikiLink("專案"))
        XCTAssertNil(linkTable?.link(at: CGPoint(x: 4, y: 4)), "標題列沒有連結")

        // 「a | b」下一行只有 ---：不是表格（GFM 要有直線），是 Setext 標題
        let notTable = styled("a | b\n---")
        XCTAssertNil(notTable.attribute(.mdTable, at: 0, effectiveRange: nil))
    }

    func testLivePreviewMoreSyntax() {
        // Setext 標題
        let setext = styled("標題\n===\n內文")
        XCTAssertGreaterThan((setext.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize ?? 0, LiveMarkdown.Theme.bodyFont.pointSize)
        XCTAssertTrue(isHidden(setext, at: 3), "=== 藏起來")
        XCTAssertFalse(isHidden(setext, at: ("標題\n===\n" as NSString).length))

        // ***粗斜體***
        let both = styled("***key*** word")
        let font = both.attribute(.font, at: 3, effectiveRange: nil) as? UIFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitItalic) ?? false)
        XCTAssertTrue(isHidden(both, at: 0))
        XCTAssertTrue(isHidden(both, at: 6))
        XCTAssertFalse(isHidden(both, at: 10))

        // 跳脫字元：藏起反斜線，不當成斜體
        let escaped = styled("\\*不是斜體\\*")
        XCTAssertTrue(isHidden(escaped, at: 0))
        XCTAssertFalse(isHidden(escaped, at: 1))
        let plain = escaped.attribute(.font, at: 2, effectiveRange: nil) as? UIFont
        XCTAssertFalse(plain?.fontDescriptor.symbolicTraits.contains(.traitItalic) ?? true)

        // # 標題 # 結尾的 # 也藏起來
        let closed = styled("## 標題 ##")
        XCTAssertTrue(isHidden(closed, at: ("## 標題 " as NSString).length))
        XCTAssertFalse(isHidden(closed, at: 3))

        // $$ 數學區塊
        let math = styled("$$\nE = mc^2\n$$")
        XCTAssertNotNil(math.attribute(.mdBlockBackground, at: 3, effectiveRange: nil))
        XCTAssertTrue(isHidden(math, at: 0))
    }

    func testDataviewBlocksAreReservedForTheRunner() {
        let text = "前言\n```dataviewjs\ndv.paragraph(\"hi\")\n```\n後記"
        let ns = text as NSString
        let fence = ns.range(of: "```dataviewjs").location
        let storage = NSTextStorage(string: text)
        LiveMarkdown.apply(to: storage, options: LiveMarkdown.Options(selection: nil, width: 600, rendersDataview: true))
        let info = storage.attribute(.mdDataview, at: fence, effectiveRange: nil) as? DataviewBlockInfo
        XCTAssertEqual(info?.code, "dv.paragraph(\"hi\")")
        XCTAssertEqual(info?.height, DataviewBlockInfo.defaultContentHeight + DataviewBlockInfo.headerHeight)
        XCTAssertTrue(isHidden(storage, at: ns.range(of: "dv.paragraph").location), "程式碼藏起來，疊上執行畫面")
        XCTAssertFalse(isHidden(storage, at: ns.range(of: "後記").location))

        // 回報內容高度後保留對應的空間
        let sized = NSTextStorage(string: text)
        LiveMarkdown.apply(to: sized, options: LiveMarkdown.Options(selection: nil, width: 600, dataviewHeights: [info?.key ?? "": 420], rendersDataview: true))
        XCTAssertEqual((sized.attribute(.mdDataview, at: fence, effectiveRange: nil) as? DataviewBlockInfo)?.height, 420 + DataviewBlockInfo.headerHeight)

        // 游標在區塊裡：顯示程式碼
        let editing = NSTextStorage(string: text)
        LiveMarkdown.apply(to: editing, options: LiveMarkdown.Options(selection: NSRange(location: ns.range(of: "dv.").location, length: 0), width: 600, rendersDataview: true))
        XCTAssertNil(editing.attribute(.mdDataview, at: fence, effectiveRange: nil))
        XCTAssertFalse(isHidden(editing, at: ns.range(of: "dv.paragraph").location))

        // 沒有結尾的區塊、或編輯器沒有執行畫面時：一般程式碼
        let open = NSTextStorage(string: "```dataviewjs\ndv.paragraph(1)")
        LiveMarkdown.apply(to: open, options: LiveMarkdown.Options(selection: nil, width: 600, rendersDataview: true))
        XCTAssertNil(open.attribute(.mdDataview, at: 0, effectiveRange: nil))
        XCTAssertNil(styled(text).attribute(.mdDataview, at: fence, effectiveRange: nil))

        // 程式碼裡的 </script> 不會提早結束網頁中的 <script>
        let html = DataviewShim.html(code: "dv.paragraph('</script><b>x</b>')", sourcePath: "a.md", vaultName: "v")
        XCTAssertFalse(html.contains("</script><b>"))
        XCTAssertTrue(html.contains("<\\/script><b>"))
    }

    func testPropertiesCollapseUnlessEditing() {
        let text = "---\ntags: [a, b]\nstatus: open\n---\n# 標題"
        let ns = text as NSString
        let collapsed = NSTextStorage(string: text)
        LiveMarkdown.apply(to: collapsed, options: LiveMarkdown.Options(selection: nil, width: 600, collapsesProperties: true))
        XCTAssertTrue(isHidden(collapsed, at: ns.range(of: "status").location), "屬性收起來，從上方的按鈕查看")
        XCTAssertFalse(isHidden(collapsed, at: ns.range(of: "標題").location))

        let editing = NSTextStorage(string: text)
        LiveMarkdown.apply(to: editing, options: LiveMarkdown.Options(selection: NSRange(location: ns.range(of: "status").location, length: 0), width: 600, collapsesProperties: true))
        XCTAssertFalse(isHidden(editing, at: ns.range(of: "status").location), "游標在屬性裡：顯示原始 YAML")
        XCTAssertFalse(isHidden(styled(text), at: ns.range(of: "status").location))

        XCTAssertEqual(NoteProperties.parse(text).map { $0.key }, ["tags", "status"])
        XCTAssertEqual(NoteProperties.values("[a, b]"), ["a", "b"])
        XCTAssertEqual(NoteProperties.values("x, y"), ["x", "y"])
        XCTAssertTrue(NoteProperties.parse("# 沒有屬性\n---\na: b\n---").isEmpty)
    }

    func testDataviewQueriesAndInlineQueries() {
        // ```dataview（DQL）區塊也換成執行畫面
        let text = "```dataview\nLIST FROM #sop\n```\n名稱：`= this.file.name`，數量：`$= dv.pages().length`，程式碼 `x = 1`"
        let ns = text as NSString
        let storage = NSTextStorage(string: text)
        LiveMarkdown.apply(to: storage, options: LiveMarkdown.Options(selection: nil, width: 600, rendersDataview: true))
        let info = storage.attribute(.mdDataview, at: 0, effectiveRange: nil) as? DataviewBlockInfo
        XCTAssertEqual(info?.language, "dataview")
        XCTAssertEqual(info?.code, "LIST FROM #sop")

        let queries = LiveMarkdown.inlineQueries(in: text)
        XCTAssertEqual(queries, [LiveMarkdown.InlineQuery(kind: "dql", code: "this.file.name"), LiveMarkdown.InlineQuery(kind: "js", code: "dv.pages().length")])
        XCTAssertNil(LiveMarkdown.inlineQuery("x = 1"), "一般的程式碼不是查詢")
        XCTAssertTrue(LiveMarkdown.inlineQueries(in: "```\n`= a`\n```").isEmpty, "程式碼區塊裡的不算")

        // 有結果：藏起原始文字，第一個反引號保留結果的寬度
        let results = [queries[0].key: "我的筆記"]
        let shown = NSTextStorage(string: text)
        LiveMarkdown.apply(to: shown, options: LiveMarkdown.Options(selection: nil, width: 600, inlineQueryResults: results))
        let tick = ns.range(of: "`= this").location
        let query = shown.attribute(.mdInlineQuery, at: tick, effectiveRange: nil) as? InlineQueryInfo
        XCTAssertEqual(query?.text.string, "我的筆記")
        XCTAssertGreaterThan(shown.attribute(.kern, at: tick, effectiveRange: nil) as? CGFloat ?? 0, 0)
        XCTAssertTrue(isHidden(shown, at: ns.range(of: "this.file").location))
        // 還沒有結果：照一般程式碼顯示
        XCTAssertNil(shown.attribute(.mdInlineQuery, at: ns.range(of: "`$=").location, effectiveRange: nil))
        // 正在編輯這一行：顯示原始文字
        let editing = NSTextStorage(string: text)
        LiveMarkdown.apply(to: editing, options: LiveMarkdown.Options(selection: NSRange(location: tick + 3, length: 0), width: 600, inlineQueryResults: results))
        XCTAssertNil(editing.attribute(.mdInlineQuery, at: tick, effectiveRange: nil))
    }

    func testAssistantTableText() {
        let table = MarkdownTableText(rows: ["| 機種 | 數量 |", "|:---:|---:|", "| **K3** | 1 \\| 2 |", "| A<br>B |"])
        XCTAssertTrue(table.hasHeader)
        XCTAssertEqual(table.rows.count, 3, "分隔列不算一列")
        XCTAssertEqual(table.rows[0], ["機種", "數量"])
        XCTAssertEqual(table.rows[1], ["**K3**", "1 | 2"])
        XCTAssertEqual(table.rows[2], ["A\nB"])
        XCTAssertEqual(table.columns, 2)
        XCTAssertEqual(table.alignment(of: 0), .center)
        XCTAssertEqual(table.alignment(of: 1), .trailing)
        XCTAssertEqual(table.alignment(of: 5), .leading)
        XCTAssertEqual(MarkdownTableText.cells("a | `x|y` | c"), ["a", "`x|y`", "c"], "程式碼裡的 | 不算分隔")
        XCTAssertFalse(MarkdownTableText(rows: ["| a |", "| b |"]).hasHeader)
    }

    func testOpenLinkQueryAndAIHelpers() {
        let text = "見 [[專案"
        XCTAssertEqual(MarkdownEditing.openLinkQuery(in: text, cursor: NSRange(location: (text as NSString).length, length: 0))?.text, "專案")
        XCTAssertNil(MarkdownEditing.openLinkQuery(in: "見 [[專案]] 後", cursor: NSRange(location: 9, length: 0)))

        let note = "---\ntags: [a]\n---\n\n內文"
        let body = NoteMarkdownEditing.bodyRange(in: note)
        XCTAssertEqual((note as NSString).substring(with: body), "內文", "AI 修改整則筆記時不動屬性")
        XCTAssertEqual(NoteMarkdownEditing.bodyRange(in: "沒有屬性").location, 0)
        XCTAssertEqual(NoteMarkdownEditing.cleanAIOutput("以下是修改後的內容：\n```markdown\n- 一\n```"), "- 一")
        XCTAssertEqual(NoteMarkdownEditing.cleanAIOutput("```\n# 標題\n```"), "# 標題")
        XCTAssertEqual(NoteMarkdownEditing.preservingSurroundingWhitespace(original: "\n舊的文字 \n", edited: "新的"), "\n新的 \n")
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

    func testObsidianLinkRules() {
        XCTAssertEqual(NoteLinks.parse("會議紀錄#結論|看結論").name, "會議紀錄")
        XCTAssertEqual(NoteLinks.parse("會議紀錄#結論|看結論").anchor, "結論")
        XCTAssertEqual(NoteLinks.parse("#^abc").anchor, "^abc")
        XCTAssertEqual(NoteLinks.parse("#^abc").name, "")

        var withAlias = NotesStore.summarize(path: "工作/專案計畫.md", mtime: Date(), text: "---\naliases:\n  - 計畫書\n  - Plan\n---\n")
        XCTAssertEqual(withAlias.aliases, ["計畫書", "Plan"])
        withAlias.isLocal = true
        let index = NoteLinks.index([withAlias, NotesStore.summarize(path: "計畫書.md", mtime: Date(), text: "")])
        XCTAssertEqual(NoteLinks.resolve("plan", in: index), "工作/專案計畫.md", "別名也能連到筆記")
        XCTAssertEqual(NoteLinks.resolve("計畫書", in: index), "計畫書.md", "同名的筆記優先於別名")
        XCTAssertEqual(NoteLinks.resolve("專案計畫#目標", in: index), "工作/專案計畫.md")

        let text = "# 目標\n內容 ^abc123\n## 時程"
        XCTAssertEqual(NoteLinks.line(forAnchor: "時程", in: text), 2)
        XCTAssertEqual(NoteLinks.line(forAnchor: "目標#時程", in: text), 2)
        XCTAssertEqual(NoteLinks.line(forAnchor: "^abc123", in: text), 1)

        let source = "見 [[專案計畫]]、[[專案計畫#目標|目標]]、![[工作/專案計畫]] 與 [[別的]]"
        let renamed = NoteLinks.retargeting(source, from: "工作/專案計畫.md", to: "工作/新計畫.md", index: index)
        XCTAssertEqual(renamed, "見 [[新計畫]]、[[新計畫#目標|目標]]、![[工作/新計畫]] 與 [[別的]]")
    }

    // MARK: - WebDAV

    func testWebDAVMultistatusParsing() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response><D:href>/My%20Vault/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype><D:getlastmodified>Tue, 14 Oct 2026 08:00:00 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
          <D:response><D:href>/My%20Vault/%E5%B7%A5%E4%BD%9C/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
          <D:response><D:href>https://dav.example.com/My%20Vault/%E5%B7%A5%E4%BD%9C/%E6%9C%83%E8%AD%B0.md</D:href><D:propstat><D:prop><D:resourcetype/><D:getetag>"abc123"</D:getetag><D:getcontentlength>42</D:getcontentlength><D:getlastmodified>Tue, 14 Oct 2026 08:00:00 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat><D:propstat><D:prop><D:quota/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
          <D:response><D:href>/My%20Vault/a.png</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>7</D:getcontentlength><D:getlastmodified>Tue, 14 Oct 2026 08:00:00 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        </D:multistatus>
        """
        let items = try XCTUnwrap(WebDAVMultistatus.parse(Data(xml.utf8), basePath: "/My Vault/"))
        XCTAssertEqual(items.map(\.path), ["", "工作", "工作/會議.md", "a.png"])
        let note = try XCTUnwrap(items.first { $0.path == "工作/會議.md" })
        XCTAssertEqual(note.etag, "\"abc123\"")
        XCTAssertEqual(note.size, 42)
        XCTAssertFalse(note.isFolder)
        XCTAssertTrue(items[1].isFolder)
        XCTAssertEqual(items[3].etag, WebDAVClient.syntheticETag(mtime: WebDAVClient.parseDate("Tue, 14 Oct 2026 08:00:00 GMT"), size: 7), "沒有 ETag 時用修改時間與大小")

        XCTAssertEqual(WebDAVSettings.vaultURL(server: "webdav-x.up.railway.app/", folder: "My Vault")?.absoluteString, "https://webdav-x.up.railway.app/My%20Vault/")
        XCTAssertNil(WebDAVSettings.vaultURL(server: "", folder: ""))
        let client = WebDAVClient(baseURL: try XCTUnwrap(URL(string: "https://dav.example.com/My%20Vault/")), username: "u", password: "p")
        XCTAssertEqual(client.url(for: "工作/會議 1.md").absoluteString, "https://dav.example.com/My%20Vault/%E5%B7%A5%E4%BD%9C/%E6%9C%83%E8%AD%B0%201.md")
        XCTAssertEqual(client.url(for: "工作/", folder: true).absoluteString, "https://dav.example.com/My%20Vault/%E5%B7%A5%E4%BD%9C/")
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

    // MARK: - 連結、大綱、指令面板

    func testWikiLinksAreExtractedAndResolved() {
        let text = "見 [[會議紀錄]] 與 [[專案/規格書|規格]]、[[週報#決議]]，圖片 ![[photo.png]] 不算，[[會議紀錄]] 重複只算一次"
        XCTAssertEqual(NoteLinks.targets(in: text), ["會議紀錄", "專案/規格書", "週報"])
        let notes = [
            NotesStore.summarize(path: "工作/會議紀錄.md", mtime: Date(), text: ""),
            NotesStore.summarize(path: "專案/規格書.md", mtime: Date(), text: ""),
            NotesStore.summarize(path: "封存/專案/規格書.md", mtime: Date(), text: ""),
        ]
        let index = NoteLinks.index(notes)
        XCTAssertEqual(NoteLinks.resolve("會議紀錄", in: index), "工作/會議紀錄.md")
        XCTAssertEqual(NoteLinks.resolve("規格書", in: index), "專案/規格書.md", "同名時取路徑較短的")
        XCTAssertEqual(NoteLinks.resolve("封存/專案/規格書", in: index), "封存/專案/規格書.md")
        XCTAssertNil(NoteLinks.resolve("不存在", in: index))
    }

    func testOutlineMatchesParserBlocksAndLines() {
        let text = """
        ---
        tags: a
        ---
        # 標題一
        內文
        ```
        # 程式碼不是標題
        ```
        ## 小節
        """
        let headings = NoteOutline.headings(in: text)
        XCTAssertEqual(headings.map(\.title), ["標題一", "小節"])
        XCTAssertEqual(headings.map(\.level), [1, 2])
        XCTAssertEqual(headings.map(\.line), [3, 8])
        let blocks = MarkdownParser.blocks(from: text)
        for heading in headings {
            guard case .heading(_, let title) = blocks[heading.block] else { return XCTFail("區塊序號要指到標題") }
            XCTAssertEqual(title, heading.title)
        }
    }

    func testCommandPaletteFuzzyScore() {
        XCTAssertNotNil(CommandPalette.score("會議紀錄 2026", query: "會紀"))
        XCTAssertNil(CommandPalette.score("會議紀錄", query: "紀會"), "字要依序出現")
        let exact = CommandPalette.score("週報", query: "週報") ?? 0
        let scattered = CommandPalette.score("週一的報告", query: "週報") ?? 0
        XCTAssertGreaterThan(exact, scattered, "連續且較短的標題排前面")
    }

    // MARK: - 整個 vault

    func testFolderContainment() {
        XCTAssertTrue(NotesStore.isInside("", ""), "最上層屬於整個 vault")
        XCTAssertTrue(NotesStore.isInside("工作/會議", ""))
        XCTAssertTrue(NotesStore.isInside("工作/會議", "工作"))
        XCTAssertTrue(NotesStore.isInside("工作", "工作"))
        XCTAssertFalse(NotesStore.isInside("工作室", "工作"))
        XCTAssertFalse(NotesStore.isInside("", "工作"))
    }

    func testDefaultFolderIsVaultRootAndOldFixedFolderIsDropped() throws {
        let suite = "notes-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("iPad 筆記", forKey: NotesSettings.Key.defaultFolder)
        NotesSettings.registerDefaults(in: defaults)
        XCTAssertEqual(defaults.string(forKey: NotesSettings.Key.defaultFolder), "", "2.0 配對時固定的「iPad 筆記」改回最上層")

        defaults.set("iPad 筆記", forKey: NotesSettings.Key.defaultFolder)
        NotesSettings.registerDefaults(in: defaults)
        XCTAssertEqual(defaults.string(forKey: NotesSettings.Key.defaultFolder), "iPad 筆記", "只轉換一次，之後使用者自己設定的會保留")
    }
}

// MARK: - 同步引擎

/// 記憶體中的假 Railway 空間（行為與伺服器相同：ETag、If-Match、If-None-Match）。
final class FakeVaultRemote: VaultRemote, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: (data: Data, etag: String)] = [:]
    /// 清單中回報的大小（模擬很大的檔案）。
    private var reportedSizes: [String: Int] = [:]
    /// 列出時回報的修改時間（沒有指定時是現在）。
    private var mtimes: [String: Date] = [:]
    private var counter = 0
    private(set) var writes: [String] = []

    func put(_ path: String, _ text: String, reportedSize: Int? = nil, mtime: Date? = nil) {
        lock.withLock {
            counter += 1
            files[path] = (Data(text.utf8), "e\(counter)")
            reportedSizes[path] = reportedSize
            mtimes[path] = mtime
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
                files: files.map { VaultEntry(path: $0.key, size: reportedSizes[$0.key] ?? $0.value.data.count, mtime: mtimes[$0.key] ?? Date(), etag: $0.value.etag) },
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
            mtimes[path] = nil
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

    func testFirstSyncDownloadsWholeVault() async throws {
        remote.put("工作/會議.md", "# 會議")
        remote.put("工作/附件/photo.png", "PNG")
        remote.put("Inbox.md", "最上層")
        remote.put("專案/2026/規格.pdf", "PDF")
        remote.put("白板.canvas", "{}")
        remote.put(".obsidian/app.json", "{}")
        let report = try await engine.sync(remote: remote)
        XCTAssertEqual(report.downloaded, 5)
        XCTAssertEqual(vault.readText("工作/會議.md"), "# 會議")
        XCTAssertEqual(vault.readText("Inbox.md"), "最上層")
        XCTAssertEqual(vault.readText("工作/附件/photo.png"), "PNG", "圖片等所有檔案都會下載")
        XCTAssertEqual(vault.readText("專案/2026/規格.pdf"), "PDF")
        XCTAssertFalse(vault.exists(".obsidian/app.json"), "隱藏資料夾不同步")
        let pending = await engine.pendingRemoteFiles()
        XCTAssertTrue(pending.isEmpty)
        let again = try await engine.sync(remote: remote)
        XCTAssertTrue(again.isEmpty, "沒有變動時不做任何事")
    }

    func testNotesOnlyModeDownloadsAttachmentsOnDemand() async throws {
        remote.put("工作/會議.md", "# 會議")
        remote.put("工作/附件/photo.png", "PNG")
        let report = try await engine.sync(remote: remote, policy: .notes)
        XCTAssertEqual(report.downloaded, 1)
        XCTAssertFalse(vault.exists("工作/附件/photo.png"), "只下載筆記時，圖片打開才下載")
        let pending = await engine.pendingRemoteFiles()
        XCTAssertEqual(pending.map(\.path), ["工作/附件/photo.png"])

        _ = try await engine.ensureLocal("工作/附件/photo.png", remote: remote)
        XCTAssertEqual(vault.readText("工作/附件/photo.png"), "PNG")
        let again = try await engine.sync(remote: remote, policy: .notes)
        XCTAssertTrue(again.isEmpty)

        // 之後開啟「下載所有檔案」：補下載先前略過的檔案
        remote.put("工作/附件/scan.jpg", "JPG")
        _ = try await engine.sync(remote: remote, policy: .notes)
        XCTAssertFalse(vault.exists("工作/附件/scan.jpg"))
        let all = try await engine.sync(remote: remote)
        XCTAssertEqual(all.downloaded, 1)
        XCTAssertEqual(vault.readText("工作/附件/scan.jpg"), "JPG")
    }

    func testOnDemandModeOnlyListsFilesAndKeepsOpenedOnesUpToDate() async throws {
        remote.put("工作/會議.md", "# 會議")
        remote.put("工作/附件/photo.png", "PNG")
        let report = try await engine.sync(remote: remote, policy: .onDemand)
        XCTAssertEqual(report.downloaded, 0, "按需模式不下載任何檔案")
        XCTAssertTrue(vault.allFiles().isEmpty)
        let pending = await engine.pendingRemoteFiles()
        XCTAssertEqual(pending.map(\.path), ["工作/會議.md", "工作/附件/photo.png"])

        // 遠端清單記在檔案中：重新開啟 App 後不必等同步就能列出
        engine = makeEngine()
        let restored = await engine.pendingRemoteFiles()
        XCTAssertEqual(restored.map(\.path), ["工作/會議.md", "工作/附件/photo.png"])

        // 打開過的筆記之後保持最新
        _ = try await engine.ensureLocal("工作/會議.md", remote: remote)
        remote.put("工作/會議.md", "# 會議 v2")
        let again = try await engine.sync(remote: remote, policy: .onDemand)
        XCTAssertEqual(again.downloaded, 1)
        XCTAssertEqual(vault.readText("工作/會議.md"), "# 會議 v2")
        XCTAssertFalse(vault.exists("工作/附件/photo.png"))
    }

    func testEvictingUnusedFilesFreesSpaceWithoutTouchingRemote() async throws {
        for (path, text) in [("a.md", "a"), ("b.md", "b"), ("c.md", "c"), ("edited.md", "e"), ("img.png", "PNG")] {
            remote.put(path, text)
        }
        _ = try await engine.sync(remote: remote)
        _ = try await engine.ensureLocal("b.md", remote: remote)
        try vault.writeText("改過", to: "edited.md")

        let evicted = await engine.evictUnused(keeping: ["c.md"])
        XCTAssertEqual(evicted, 2, "沒打開過、沒修改、不是開著的檔案才移除")
        XCTAssertFalse(vault.exists("a.md"))
        XCTAssertFalse(vault.exists("img.png"))
        XCTAssertTrue(vault.exists("b.md"), "剛打開的保留")
        XCTAssertTrue(vault.exists("c.md"), "開著的筆記保留")
        XCTAssertEqual(vault.readText("edited.md"), "改過", "未上傳的修改保留")

        let report = try await engine.sync(remote: remote, policy: .onDemand)
        XCTAssertEqual(report.deleted, 0, "只移除這台裝置上的檔案，不會刪到遠端")
        XCTAssertEqual(report.downloaded, 0)
        XCTAssertEqual(report.uploaded, 1)
        XCTAssertEqual(remote.paths, ["a.md", "b.md", "c.md", "edited.md", "img.png"])
        XCTAssertEqual(remote.text("edited.md"), "改過")
        let pending = await engine.pendingRemoteFiles()
        XCTAssertEqual(pending.map(\.path), ["a.md", "img.png"])

        // 超過保留天數後，最近打開過的也會移除
        let later = VaultSyncEngine(vault: vault, stateURL: root.appending(path: "state.json"), now: { Date(timeIntervalSince1970: 1_760_000_000 + 8 * 86_400) })
        let laterEvicted = await later.evictUnused(keeping: [])
        XCTAssertEqual(laterEvicted, 3)
        XCTAssertTrue(vault.allFiles().isEmpty)
        XCTAssertEqual(remote.paths.count, 5)
    }

    func testPushUploadsTheEditedFileRightAway() async throws {
        remote.put("a.md", "v1")
        _ = try await engine.sync(remote: remote)
        try vault.writeText("v2", to: "a.md")
        let pushed = try await engine.push(["a.md"], remote: remote)
        XCTAssertEqual(pushed, 1)
        XCTAssertEqual(remote.text("a.md"), "v2")
        let nothing = try await engine.push(["a.md"], remote: remote)
        XCTAssertEqual(nothing, 0, "沒有新的修改時不上傳")

        try vault.writeText("新筆記", to: "new.md")
        let created = try await engine.push(["new.md"], remote: remote)
        XCTAssertEqual(created, 1)
        XCTAssertEqual(remote.text("new.md"), "新筆記")

        // 遠端同時也改了：不覆蓋，完整同步時兩份都保留
        remote.put("a.md", "Obsidian")
        try vault.writeText("iPad", to: "a.md")
        let rejected = try await engine.push(["a.md"], remote: remote)
        XCTAssertEqual(rejected, 0)
        XCTAssertEqual(remote.text("a.md"), "Obsidian")
        let report = try await engine.sync(remote: remote)
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertEqual(vault.readText("a.md"), "Obsidian")
    }

    func testRefreshPullsRemoteEditsOfTheOpenFile() async throws {
        remote.put("工作/a.md", "v1")
        _ = try await engine.sync(remote: remote)
        remote.put("工作/a.md", "v2")
        let updated = try await engine.refresh("工作/a.md", remote: remote)
        XCTAssertTrue(updated)
        XCTAssertEqual(vault.readText("工作/a.md"), "v2")
        let unchanged = try await engine.refresh("工作/a.md", remote: remote)
        XCTAssertFalse(unchanged)

        remote.put("工作/a.md", "v3")
        try vault.writeText("本機修改", to: "工作/a.md")
        let blocked = try await engine.refresh("工作/a.md", remote: remote)
        XCTAssertFalse(blocked, "有未上傳的修改時不覆蓋")
        XCTAssertEqual(vault.readText("工作/a.md"), "本機修改")
    }

    func testPrepareOverwriteReplacesOrDeletesFilesNotOnThisDevice() async throws {
        remote.put("附件/nb-1-p1.png", "old1")
        remote.put("附件/nb-1-p2.png", "old2")
        _ = try await engine.sync(remote: remote, policy: .onDemand)

        await engine.prepareOverwrite("附件/nb-1-p1.png")
        try vault.writeText("new1", to: "附件/nb-1-p1.png")
        await engine.prepareOverwrite("附件/nb-1-p2.png")
        let report = try await engine.sync(remote: remote, policy: .onDemand)
        XCTAssertTrue(report.conflicts.isEmpty, "重新產生的圖片直接取代，不另存衝突版本")
        XCTAssertEqual(remote.text("附件/nb-1-p1.png"), "new1")
        XCTAssertNil(remote.text("附件/nb-1-p2.png"), "這台裝置上沒有寫入的會從遠端刪除")
    }

    func testVeryLargeFilesDownloadOnlyWhenOpened() async throws {
        remote.put("影片/錄影.mov", "MOV", reportedSize: VaultSyncEngine.autoDownloadLimit + 1)
        remote.put("a.md", "a")
        let report = try await engine.sync(remote: remote)
        XCTAssertEqual(report.downloaded, 1)
        XCTAssertFalse(vault.exists("影片/錄影.mov"))
        let pending = await engine.pendingRemoteFiles()
        XCTAssertEqual(pending.map(\.path), ["影片/錄影.mov"])
    }

    func testUnchangedTimestampAndSizeSkipReadingFiles() async throws {
        remote.put("a.md", "v1")
        _ = try await engine.sync(remote: remote)
        let url = vault.url(for: "a.md")
        let original = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date)

        // 同樣大小、修改時間也還原：視為沒改（不重新讀取與計算雜湊）
        try vault.writeText("v9", to: "a.md")
        try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: url.path(percentEncoded: false))
        let skipped = try await engine.sync(remote: remote)
        XCTAssertEqual(skipped.uploaded, 0)

        // 修改時間不同：比對內容後上傳
        try FileManager.default.setAttributes([.modificationDate: original.addingTimeInterval(5)], ofItemAtPath: url.path(percentEncoded: false))
        let report = try await engine.sync(remote: remote)
        XCTAssertEqual(report.uploaded, 1)
        XCTAssertEqual(remote.text("a.md"), "v9")
    }

    func testStateFromOlderVersionWithoutTimestamps() async throws {
        remote.put("a.md", "v1")
        try vault.writeText("v1", to: "a.md")
        let old = ["a.md": ["etag": "e1", "hash": LocalVault.hash(Data("v1".utf8))]]
        try JSONSerialization.data(withJSONObject: old).write(to: root.appending(path: "state.json"))
        engine = makeEngine()
        let unchanged = try await engine.sync(remote: remote)
        XCTAssertTrue(unchanged.isEmpty, "舊版的同步紀錄仍可使用")
        try vault.writeText("v2", to: "a.md")
        let report = try await engine.sync(remote: remote)
        XCTAssertEqual(report.uploaded, 1)
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

    func testNewerLocalVersionWinsAConflict() async throws {
        remote.put("a.md", "v1")
        _ = try await engine.sync(remote: remote)
        // Obsidian 一小時前改過（這台裝置還沒同步到），之後在 iPad 上又改了：iPad 的版本比較新
        remote.put("a.md", "Obsidian 舊版本", mtime: Date().addingTimeInterval(-3600))
        try vault.writeText("iPad 最新版本", to: "a.md")

        let report = try await engine.sync(remote: remote)
        let copy = "a（較舊版本 \(conflictStamp)）.md"
        XCTAssertEqual(report.conflicts, [copy])
        XCTAssertEqual(vault.readText("a.md"), "iPad 最新版本")
        XCTAssertEqual(remote.text("a.md"), "iPad 最新版本", "最新的版本留在原本的筆記")
        XCTAssertEqual(vault.readText(copy), "Obsidian 舊版本")
        XCTAssertEqual(remote.text(copy), "Obsidian 舊版本", "較舊的版本另存，不會遺失")
        let again = try await engine.sync(remote: remote)
        XCTAssertTrue(again.isEmpty)
    }

    func testIdenticalEditsOnBothSidesAreNotAConflict() async throws {
        remote.put("a.md", "v1")
        _ = try await engine.sync(remote: remote)
        remote.put("a.md", "同樣的內容")
        try vault.writeText("同樣的內容", to: "a.md")
        let report = try await engine.sync(remote: remote)
        XCTAssertTrue(report.conflicts.isEmpty)
        XCTAssertEqual(report.uploaded, 0)
        let again = try await engine.sync(remote: remote)
        XCTAssertTrue(again.isEmpty)
    }

    func testRegeneratedImagesKeepOnlyTheNewerVersion() async throws {
        remote.put("附件/ink-1.png", "old")
        remote.put("附件/nb-1-p1.png", "old")
        _ = try await engine.sync(remote: remote)
        remote.put("附件/ink-1.png", "遠端較新")
        try vault.writeText("本機較舊", to: "附件/ink-1.png")
        remote.put("附件/nb-1-p1.png", "遠端較舊", mtime: Date().addingTimeInterval(-3600))
        try vault.writeText("本機較新", to: "附件/nb-1-p1.png")
        let report = try await engine.sync(remote: remote)
        XCTAssertTrue(report.conflicts.isEmpty, "依筆跡產生的圖片不另存衝突版本")
        XCTAssertEqual(vault.readText("附件/ink-1.png"), "遠端較新")
        XCTAssertEqual(remote.text("附件/nb-1-p1.png"), "本機較新")
        XCTAssertTrue(VaultSyncEngine.isRegenerated("附件/nb-ab12-p3.png"))
        XCTAssertFalse(VaultSyncEngine.isRegenerated("附件/照片.png"))
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
