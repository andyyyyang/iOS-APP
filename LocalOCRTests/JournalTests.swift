import PencilKit
import XCTest
@testable import LocalOCR

final class JournalTests: XCTestCase {
    // MARK: 打開日誌筆記本

    func testOpensTheMostRecentJournal() {
        let folder = "06 日誌/手寫日誌"
        let older = NotesStore.summarize(path: "\(folder)/手寫日誌.md", mtime: Date(timeIntervalSince1970: 100), text: "---\nlocalocr-notebook: jn-old\n---\n")
        let newer = NotesStore.summarize(path: "工作/手寫日誌 2.md", mtime: Date(timeIntervalSince1970: 200), text: "---\nlocalocr-notebook: jn-new\n---\n")
        let handwriting = NotesStore.summarize(path: "工作/手寫.md", mtime: Date(timeIntervalSince1970: 300), text: "---\nlocalocr-notebook: nb-1\n---\n")
        let plain = NotesStore.summarize(path: "\(folder)/手寫日誌 說明.md", mtime: Date(timeIntervalSince1970: 400), text: "內容")
        XCTAssertEqual(Workspace.latestJournal(in: [older, newer, handwriting, plain], defaultFolder: folder), newer.path)
        // 還沒下載（不知道是不是日誌）：預設資料夾中「手寫日誌」開頭的也算
        let remote = NotesStore.remoteSummary(path: "\(folder)/手寫日誌 3.md", mtime: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(Workspace.latestJournal(in: [older, remote], defaultFolder: folder), remote.path)
        XCTAssertNil(Workspace.latestJournal(in: [handwriting, plain], defaultFolder: folder))
    }

    // MARK: 機種清單與模糊比對

    private let notes: [VaultIndex.Note] = [
        VaultIndex.Note(path: "05 客戶案件/02 正式開案 NPI/Amkor/T12608029 60016062 0851563HS 44.6x57.6 T3.038/0851563HS 主卡.md", mtime: 0),
        VaultIndex.Note(path: "05 客戶案件/02 正式開案 NPI/Qualcomm/CV90-A3316-X1 主卡.md", mtime: 0, aliases: ["A3316"],
                        properties: ["type": .text("model"), "code": .text("CV90-A3316-X1"), "customer": .text("Qualcomm"), "size": .text("24.6x44.6")]),
        VaultIndex.Note(path: "05 客戶案件/02 正式開案 NPI/Amkor/0851563SF 主卡.md", mtime: 0),
        VaultIndex.Note(path: "06 日誌/Daily/2026-10-15.md", mtime: 0),
    ]

    private var models: [ModelEntry] { ModelCatalog.entries(from: notes) }

    func testModelsComeFromMainCardsAndModelNotes() {
        XCTAssertEqual(Set(models.map(\.code)), ["0851563HS", "0851563SF", "CV90-A3316-X1"])
        let lid = models.first { $0.code == "0851563HS" }
        XCTAssertEqual(lid?.customer, "Amkor")
        XCTAssertEqual(Set(lid?.aliases ?? []), ["T12608029", "60016062"], "開案資料夾名稱中的開案單號與 SAP 料號也能比對")
        XCTAssertEqual(models.first { $0.code == "CV90-A3316-X1" }?.detail, "24.6x44.6")
    }

    func testFuzzyMatchingToleratesHandwritingMistakes() {
        XCTAssertEqual(ModelCatalog.match("0851563HS", in: models).first?.entry.code, "0851563HS")
        XCTAssertEqual(ModelCatalog.match("O85I563HS", in: models).first?.entry.code, "0851563HS", "O/0、I/1 認錯也找得到")
        XCTAssertEqual(ModelCatalog.match("cv90a3316x1", in: models).first?.entry.code, "CV90-A3316-X1", "大小寫、少了 - 也找得到")
        XCTAssertEqual(ModelCatalog.match("T12608029", in: models).first?.entry.code, "0851563HS", "開案單號")
        XCTAssertEqual(ModelCatalog.match("0851563H", in: models).first?.entry.code, "0851563HS", "少一個字")
        XCTAssertTrue(ModelCatalog.match("XYZ", in: models).isEmpty)
    }

    func testOnlyConfidentMatchesAreLinkedAutomatically() {
        XCTAssertEqual(ModelCatalog.confidentMatch(ModelCatalog.match("0851563HS", in: models))?.code, "0851563HS")
        // 0851563 同時像 0851563HS 與 0851563SF：不自動連結，讓使用者選
        let matches = ModelCatalog.match("0851563", in: models)
        XCTAssertEqual(Set(matches.prefix(2).map(\.entry.code)), ["0851563HS", "0851563SF"])
        XCTAssertNil(ModelCatalog.confidentMatch(matches))
    }

    // MARK: #機種

    func testHashTagsInRecognizedText() {
        XCTAssertEqual(JournalTags.tags(in: "今天跟 Amkor 討論 #0851563HS 的交期").map(\.text), ["0851563HS"])
        XCTAssertEqual(JournalTags.tags(in: "＃CV90-A3316-X1 樣品").map(\.text), ["CV90-A3316-X1"], "全形 ＃")
        XCTAssertEqual(JournalTags.tags(in: "井0851563 確認").map(\.text), ["0851563"], "手寫的 # 常被辨識成「井」")
        XCTAssertTrue(JournalTags.tags(in: "#1 重點").isEmpty, "太短的不算")
    }

    func testPageTagsAreLinkedAndPlacedNextToTheWriting() {
        let lines = [
            RecognizedLine(text: "#0851563HS 交期確認", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.04)),
            RecognizedLine(text: "#0851563 要問 Frank", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.04)),
            RecognizedLine(text: "CV90-A3316-X1 下週出貨", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.6, height: 0.04)),
        ]
        let tags = JournalTags.pageTags(lines: lines, pageSize: JournalLayout.pageSize, models: models)
        XCTAssertEqual(tags.count, 3)
        XCTAssertEqual(tags[0].modelCode, "0851563HS")
        XCTAssertEqual(tags[0].rect.minX, 0.1 * JournalLayout.pageSize.width, accuracy: 1)
        XCTAssertEqual(tags[0].rect.minY, 0.2 * JournalLayout.pageSize.height, accuracy: 1)
        XCTAssertNil(tags[1].modelPath, "不確定的不自動連結")
        XCTAssertEqual(tags[1].candidates.count, 2, "列出可能的機種讓使用者選")
        XCTAssertEqual(tags[2].modelCode, "CV90-A3316-X1", "沒寫 # 但完整寫出代號也算")
    }

    func testChoicesSurviveRecognizingAgain() {
        let line = RecognizedLine(text: "#0851563 要問 Frank", confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.04))
        var picked = JournalTags.pageTags(lines: [line], pageSize: JournalLayout.pageSize, models: models)[0]
        picked.modelPath = models.first { $0.code == "0851563SF" }?.path
        picked.modelCode = "0851563SF"
        picked.confirmed = true
        let again = JournalTags.pageTags(lines: [line], pageSize: JournalLayout.pageSize, models: models, previous: [picked])
        XCTAssertEqual(again.first?.modelCode, "0851563SF", "使用者選過的機種重新辨識後保留")
    }

    // MARK: 頁面

    private func stroke(at point: CGPoint) -> PKStroke {
        let points = [point, CGPoint(x: point.x + 20, y: point.y + 4)].map {
            PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    func testStrokesGoBackToThePageTheyWereWrittenOn() {
        let page1 = PKDrawing(strokes: [stroke(at: CGPoint(x: 100, y: 200))])
        let page2 = PKDrawing(strokes: [stroke(at: CGPoint(x: 300, y: 500))])
        let canvas = JournalLayout.combine([page1, page2, PKDrawing()])
        XCTAssertGreaterThan(canvas.strokes[1].renderBounds.minY, JournalLayout.pageRect(1).minY, "第二頁的筆跡在畫布上的第二頁")
        let pages = JournalLayout.split(canvas, pageCount: 3)
        XCTAssertEqual(pages.map(\.strokes.count), [1, 1, 0])
        XCTAssertEqual(pages[1].bounds.midY, page2.bounds.midY, accuracy: 0.5, "分回去後回到頁面座標")
        XCTAssertEqual(JournalLayout.pageIndex(atY: JournalLayout.pageRect(2).midY, pageCount: 3), 2)
    }

    func testEveryViewModeKeepsInkOnItsPage() {
        let pages = [
            PKDrawing(strokes: [stroke(at: CGPoint(x: 100, y: 200))]),
            PKDrawing(strokes: [stroke(at: CGPoint(x: 600, y: 900))]),
            PKDrawing(strokes: [stroke(at: CGPoint(x: 40, y: 1100))]),
        ]
        for mode in JournalViewMode.allCases {
            let canvas = JournalLayout.combine(pages, mode: mode)
            let split = JournalLayout.split(canvas, pageCount: 3, mode: mode)
            XCTAssertEqual(split.map(\.strokes.count), [1, 1, 1], "\(mode)")
            for (original, back) in zip(pages, split) {
                XCTAssertEqual(back.bounds.midX, original.bounds.midX, accuracy: 0.5, "\(mode)：換回頁面座標")
                XCTAssertEqual(back.bounds.midY, original.bounds.midY, accuracy: 0.5, "\(mode)：換回頁面座標")
            }
        }
        // 換顯示方式：依原本的排列分回每一頁，再依新的排列放回去，內容不變
        let spread = JournalLayout.combine(JournalLayout.split(JournalLayout.combine(pages, mode: .scroll), pageCount: 3, mode: .scroll), mode: .spread)
        XCTAssertEqual(JournalLayout.split(spread, pageCount: 3, mode: .spread).map(\.strokes.count), [1, 1, 1])
    }

    func testPagedModesLayPagesOutSideBySide() {
        let left = JournalLayout.pageRect(0, mode: .spread)
        let right = JournalLayout.pageRect(1, mode: .spread)
        let next = JournalLayout.pageRect(2, mode: .spread)
        XCTAssertEqual(left.minY, right.minY)
        XCTAssertLessThan(left.maxX, right.minX)
        XCTAssertGreaterThan(next.minX, right.maxX)
        XCTAssertEqual(JournalLayout.slotCount(pageCount: 3, mode: .spread), 2)
        XCTAssertEqual(JournalLayout.slot(ofPage: 3, mode: .spread), 1)
        XCTAssertEqual(JournalLayout.canvasSize(pageCount: 3, mode: .spread).width, JournalLayout.slotSize(.spread).width * 2)
        XCTAssertEqual(JournalLayout.pageIndex(at: CGPoint(x: right.midX, y: right.midY), pageCount: 3, mode: .spread), 1)
        XCTAssertEqual(JournalLayout.pageIndex(at: CGPoint(x: next.midX, y: 10), pageCount: 3, mode: .spread), 2)
        // 一頁一張：一頁一格，左右排列
        let second = JournalLayout.pageRect(1, mode: .single)
        XCTAssertEqual(second.minY, JournalLayout.pageRect(0, mode: .single).minY)
        XCTAssertEqual(JournalLayout.pageIndex(at: CGPoint(x: second.midX, y: second.midY), pageCount: 2, mode: .single), 1)
        XCTAssertEqual(JournalLayout.pageIndex(at: CGPoint(x: 99_999, y: 0), pageCount: 2, mode: .single), 1, "超過最後一頁算最後一頁")
    }

    // MARK: 月曆與國定假日

    func testTaiwanHolidaysComeFromTheOfficialCalendar() {
        XCTAssertEqual(TaiwanHolidays.holiday(on: "2026-10-10"), "國慶日")
        XCTAssertEqual(TaiwanHolidays.holiday(on: "2026-10-09"), "補假")
        XCTAssertEqual(TaiwanHolidays.holiday(on: "2027-02-08"), "春節")
        XCTAssertEqual(TaiwanHolidays.holiday(on: "2025-10-06"), "中秋節")
        XCTAssertNil(TaiwanHolidays.holiday(on: "2026-10-15"))
        XCTAssertTrue(TaiwanHolidays.isMakeupWorkday("2025-02-08"), "週六補班")
        XCTAssertTrue(TaiwanHolidays.hasData(forYear: 2027))
    }

    func testCalendarGridAndDaysOff() {
        let cells = JournalCalendar.cells(year: 2026, month: 10)
        XCTAssertEqual(cells.count % 7, 0)
        XCTAssertEqual(cells.prefix(4).compactMap { $0 }.count, 0, "2026-10-01 是週四：前面空四格")
        XCTAssertEqual(cells[4], "2026-10-01")
        XCTAssertEqual(cells.compactMap { $0 }.count, 31)
        XCTAssertTrue(JournalCalendar.isDayOff("2026-10-10"))
        XCTAssertTrue(JournalCalendar.isDayOff("2026-10-09"), "補假的週五")
        XCTAssertFalse(JournalCalendar.isDayOff("2026-10-12"))
        XCTAssertFalse(JournalCalendar.isDayOff("2025-02-08"), "補班的週六不是假日")
        XCTAssertTrue(JournalCalendar.shifted(year: 2026, month: 12, by: 1) == (2027, 1))
        XCTAssertTrue(JournalCalendar.shifted(year: 2026, month: 1, by: -1) == (2025, 12))
    }

    // MARK: 統整

    func testOverviewLinksBackToEachDay() {
        let model = JournalLinkedModel(code: "0851563HS", title: "0851563HS 主卡", path: "05/0851563HS 主卡.md")
        let days = [
            JournalOverview.Day(date: "2026-10-15", noteTitle: "手寫日誌", insights: JournalDay(textFingerprint: "a", summary: "和 Amkor 開會", keyPoints: ["確認尺寸"], actionItems: ["寄樣品"]), models: [model]),
            JournalOverview.Day(date: "2026-10-01", noteTitle: "手寫日誌", insights: JournalDay(textFingerprint: "b", summary: "整理報價", keyPoints: [], actionItems: []), models: [model]),
            JournalOverview.Day(date: "2026-09-20", noteTitle: "手寫日誌", insights: nil, models: []),
        ]
        let text = JournalOverview.markdown(days: days, weekly: nil, monthly: [("2026-10", "十月摘要")], engine: "裝置端", updated: Date())
        XCTAssertTrue(text.contains("- [ ] 寄樣品（[[手寫日誌#2026-10-15 週四|10/15]]）"))
        XCTAssertTrue(text.contains("- [[0851563HS 主卡|0851563HS]]：[[手寫日誌#2026-10-15 週四|10/15]]、[[手寫日誌#2026-10-01 週四|10/01]]"))
        XCTAssertTrue(text.contains("### 2026-10\n十月摘要"))
        XCTAssertTrue(text.contains("（尚未整理）"))
        // 最近一週只有 10/15（10/01 超過 7 天）
        let week = JournalOverview.weekPrompt(days)
        XCTAssertTrue(week.contains("和 Amkor 開會"))
        XCTAssertFalse(week.contains("整理報價"))
        XCTAssertEqual(JournalOverview.monthPrompts(days, limit: 6).map(\.month), ["2026-10"], "九月那天還沒整理，沒有內容")
        XCTAssertNotEqual(JournalOverview.fingerprint(days), JournalOverview.fingerprint(Array(days.dropFirst())))
        let replaced = JournalOverview.replacingSection(in: JournalOverview.newNote, with: text)
        XCTAssertTrue(replaced.hasPrefix("---\ntype: journal-overview"))
        XCTAssertEqual(replaced.components(separatedBy: JournalOverview.sectionStart).count, 2)
    }

    func testANewDayStartsANewPage() {
        var notebook = JournalNotebook(id: "jn-test", createdAt: Date(), updatedAt: Date(), paper: .lined, pages: [JournalPage(date: "2026-10-14")])
        XCTAssertTrue(notebook.ensurePage(for: "2026-10-15"))
        XCTAssertEqual(notebook.pages.map(\.date), ["2026-10-15"], "昨天的頁面還是空白：改成今天，不多一頁")
        notebook.pages[0].pkDrawing = PKDrawing(strokes: [stroke(at: CGPoint(x: 100, y: 200))])
        XCTAssertFalse(notebook.ensurePage(for: "2026-10-15"), "同一天不加頁")
        XCTAssertTrue(notebook.ensurePage(for: "2026-10-16"))
        XCTAssertEqual(notebook.pages.map(\.date), ["2026-10-15", "2026-10-16"])
    }

    // MARK: Markdown

    func testJournalMarkdownIsOrganizedByDay() throws {
        let model = try XCTUnwrap(models.first { $0.code == "0851563HS" })
        var older = JournalPage(id: "a1", date: "2026-10-14")
        older.pkDrawing = PKDrawing(strokes: [stroke(at: CGPoint(x: 100, y: 200))])
        older.recognizedText = "昨天的內容"
        var today = JournalPage(id: "b2", date: "2026-10-15")
        today.pkDrawing = PKDrawing(strokes: [stroke(at: CGPoint(x: 100, y: 200))])
        today.recognizedText = "#0851563HS 交期"
        today.tags = [JournalTag(text: "0851563HS", rect: .zero, modelPath: model.path, modelCode: model.code)]
        let notebook = JournalNotebook(
            id: "jn-test", createdAt: Date(), updatedAt: Date(), paper: .lined, pages: [older, today],
            days: ["2026-10-15": JournalDay(textFingerprint: "x", summary: "確認交期", keyPoints: ["交期提前"], actionItems: ["回覆客戶"])]
        )
        let section = JournalMarkdown.managedSection(notebook) { "jn-test-\($0.id).png" }
        let todayHeading = try XCTUnwrap(section.range(of: "## 2026-10-15 週四"))
        let olderHeading = try XCTUnwrap(section.range(of: "## 2026-10-14 週三"))
        XCTAssertLessThan(todayHeading.lowerBound, olderHeading.lowerBound, "新的日子在前")
        XCTAssertTrue(section.contains("**機種** [[0851563HS 主卡|0851563HS]]"))
        XCTAssertTrue(section.contains("**日誌** [[2026-10-15]]"))
        XCTAssertTrue(section.contains("![[jn-test-b2.png]]"))
        XCTAssertTrue(section.contains("> [!summary] 摘要\n> 確認交期"))
        XCTAssertTrue(section.contains("#0851563HS 交期\n\n![[jn-test-b2.png]]"), "辨識出來的文字在原稿前面，直接讀得到")
        XCTAssertFalse(section.contains("[!quote]"), "文字不再收在摺疊的區塊裡")
        XCTAssertFalse(section.contains("- [ ]"), "依 vault 規範，日誌不放待辦勾選框")

        let note = JournalMarkdown.newJournal(id: "jn-test", createdAt: Date())
        XCTAssertTrue(note.contains("localocr-notebook: jn-test"))
        let updated = JournalMarkdown.replacingManagedSection(in: note + "\n我自己寫的\n", with: section)
        XCTAssertTrue(updated.contains("我自己寫的"), "區段以外的內容不變")
        XCTAssertTrue(VaultSyncEngine.isRegenerated("06 日誌/手寫日誌/附件/jn-test-b2.png"), "頁面圖片是重新產生的，衝突時不另存")
    }
}
