import PencilKit
import XCTest
@testable import LocalOCR

final class InkMemoTests: XCTestCase {
    private var root: URL!
    private var vault: LocalVault!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ink-memo-\(UUID().uuidString)")
        vault = LocalVault(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMemoIsNamedAfterTheNote() {
        XCTAssertEqual(InkMemo.name(forNote: "工作/會議 記錄.md", text: "# 會議"), "ink-memo-會議 記錄")
        XCTAssertEqual(InkFiles.dataPath(notePath: "工作/會議 記錄.md", name: "ink-memo-會議 記錄"), "工作/附件/ink-memo-會議 記錄.ink")
        XCTAssertTrue(VaultSyncEngine.isRegenerated("工作/附件/ink-memo-會議 記錄.png"), "備忘圖片是重新產生的，衝突時不另存")
        XCTAssertEqual(InkFiles.blockName(fromEmbed: "ink-memo-會議 記錄.png"), "ink-memo-會議 記錄", "插入筆記後點圖片可以用手寫區塊編輯")
    }

    func testEmbeddedMemoKeepsItsNameAfterTheNoteIsRenamed() {
        let text = "內容\n\n![[附件/ink-memo-舊名稱.png]]\n"
        XCTAssertEqual(InkMemo.embeddedName(in: text), "ink-memo-舊名稱")
        XCTAssertEqual(InkMemo.name(forNote: "新名稱.md", text: text), "ink-memo-舊名稱")
        XCTAssertNil(InkMemo.embeddedName(in: "![[ink-1234.png]] 和 [[ink-memo-x.png]]"), "一般手寫區塊與沒有 ! 的連結不算")
    }

    func testMemoFollowsARenamedOrMovedNote() throws {
        try vault.writeText("# 筆記", to: "專案/規格.md")
        try vault.writeText("{}", to: "專案/附件/ink-memo-規格.ink")
        try vault.writeText("PNG", to: "專案/附件/ink-memo-規格.png")

        try vault.move("專案/規格.md", to: "專案/規格 v2.md")
        InkMemo.follow(from: "專案/規格.md", to: "專案/規格 v2.md", vault: vault)
        XCTAssertEqual(vault.readText("專案/附件/ink-memo-規格 v2.ink"), "{}", "改名：備忘跟著改名")
        XCTAssertFalse(vault.exists("專案/附件/ink-memo-規格.ink"))

        try vault.move("專案/規格 v2.md", to: "封存/規格 v2.md")
        InkMemo.follow(from: "專案/規格 v2.md", to: "封存/規格 v2.md", vault: vault)
        XCTAssertEqual(vault.readText("封存/附件/ink-memo-規格 v2.png"), "PNG", "搬到別的資料夾：備忘搬到新位置的附件資料夾")
    }

    func testMemoBlocksRememberTheirNarrowCanvas() throws {
        let memo = InkBlock(height: 240, paper: .blank, drawing: PKDrawing().dataRepresentation(), width: InkMemo.width)
        let decoded = try JSONDecoder().decode(InkBlock.self, from: JSONEncoder().encode(memo))
        XCTAssertEqual(decoded.canvasWidth, InkMemo.width)
        XCTAssertEqual(InkFiles.image(for: memo).size.width, InkMemo.width)

        let old = try JSONDecoder().decode(InkBlock.self, from: Data(#"{"version":2,"height":240,"paper":"blank","drawing":""}"#.utf8))
        XCTAssertEqual(old.canvasWidth, CanvasLayout.width, "舊的手寫區塊沒有寬度：維持手寫筆記的寬度")
    }
}
