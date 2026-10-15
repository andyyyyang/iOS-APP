import PencilKit
import XCTest
@testable import LocalOCR

final class JournalTests: XCTestCase {
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
        XCTAssertTrue(section.contains("> [!quote]- 手寫內容（第 2 頁）\n> #0851563HS 交期"))
        XCTAssertFalse(section.contains("- [ ]"), "依 vault 規範，日誌不放待辦勾選框")

        let note = JournalMarkdown.newJournal(id: "jn-test", createdAt: Date())
        XCTAssertTrue(note.contains("localocr-notebook: jn-test"))
        let updated = JournalMarkdown.replacingManagedSection(in: note + "\n我自己寫的\n", with: section)
        XCTAssertTrue(updated.contains("我自己寫的"), "區段以外的內容不變")
        XCTAssertTrue(VaultSyncEngine.isRegenerated("06 日誌/手寫日誌/附件/jn-test-b2.png"), "頁面圖片是重新產生的，衝突時不另存")
    }
}
