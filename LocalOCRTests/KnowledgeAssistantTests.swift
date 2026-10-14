import XCTest
@testable import LocalOCR

final class KnowledgeAssistantTests: XCTestCase {
    // MARK: - MCP 回應

    func testParsesToolResultTextBlocks() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"path\":\"a.md\",\"etag\":\"\\\"e1\\\"\"}"},{"type":"text","text":"# A\n內容"}]}}"#.utf8)
        let texts = try VaultMCPClient.parseToolResult(data)
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(texts[1], "# A\n內容")
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(texts[0].utf8)) as? [String: Any])
        XCTAssertEqual(meta["etag"] as? String, "\"e1\"")
    }

    func testToolErrorsThrowWithTheErrorBody() {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"{\"error\":{\"code\":\"not_found\",\"message\":\"File not found: x.md\"}}"}]}}"#.utf8)
        XCTAssertThrowsError(try VaultMCPClient.parseToolResult(data)) { error in
            XCTAssertTrue((error as? VaultMCPClient.ToolError)?.message.contains("not_found") == true)
        }
        let rpc = Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params"}}"#.utf8)
        XCTAssertThrowsError(try VaultMCPClient.parseToolResult(rpc)) { error in
            XCTAssertEqual((error as? VaultMCPClient.ToolError)?.message, "Invalid params")
        }
    }

    func testReadsJSONFromServerSentEvents() throws {
        let sse = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}\n\n".utf8)
        XCTAssertEqual(try VaultMCPClient.parseToolResult(VaultMCPClient.jsonPayload(from: sse)), ["ok"])
        let json = Data(#"{"jsonrpc":"2.0","id":1,"result":{"content":[]}}"#.utf8)
        XCTAssertEqual(VaultMCPClient.jsonPayload(from: json), json)
    }

    // MARK: - 修改筆記

    func testNormalizesPathsTheModelGives() {
        XCTAssertEqual(KnowledgeEditing.normalizedPath("[[工作/會議紀錄|會議]]"), "工作/會議紀錄.md")
        XCTAssertEqual(KnowledgeEditing.normalizedPath(" /收件匣/想法.md "), "收件匣/想法.md")
        XCTAssertEqual(KnowledgeEditing.normalizedPath("「讀書清單#2026」"), "讀書清單.md")
    }

    func testAppendsAtTheEndOfTheNote() {
        XCTAssertEqual(KnowledgeEditing.appending("新的一段", under: nil, in: "# 標題\n\n內容\n\n"), "# 標題\n\n內容\n\n新的一段\n")
        XCTAssertEqual(KnowledgeEditing.appending("- 三", under: nil, in: "- 一\n- 二\n"), "- 一\n- 二\n- 三\n", "清單接清單不留空行")
        XCTAssertEqual(KnowledgeEditing.appending("第一段", under: nil, in: ""), "第一段\n")
    }

    func testAppendsUnderAHeading() {
        let note = "---\ntags: [a]\n---\n# 專案\n\n## 待辦\n- 寫報告\n\n## 紀錄\n舊的紀錄\n"
        let result = KnowledgeEditing.appending("- 寄信", under: "## 待辦", in: note)
        XCTAssertEqual(result, "---\ntags: [a]\n---\n# 專案\n\n## 待辦\n- 寫報告\n- 寄信\n\n## 紀錄\n舊的紀錄\n")

        let tight = KnowledgeEditing.appending("補充", under: "待辦", in: "## 待辦\n- 一\n## 紀錄\n")
        XCTAssertEqual(tight, "## 待辦\n- 一\n\n補充\n\n## 紀錄\n", "段落之間與下一個標題前留空行")

        let last = KnowledgeEditing.appending("- 新", under: "紀錄", in: note)
        XCTAssertTrue(last.hasSuffix("## 紀錄\n舊的紀錄\n\n- 新\n"))
    }

    func testAddsAMissingHeadingAtTheEnd() {
        XCTAssertEqual(KnowledgeEditing.appending("內容", under: "參考資料", in: "# 筆記\n文字\n"), "# 筆記\n文字\n\n## 參考資料\n內容\n")
    }

    func testSplitsLongNotesIntoParts() {
        let text = String(repeating: "字", count: 2500)
        let first = KnowledgeEditing.part(text, number: 1)
        XCTAssertEqual(first.total, 3)
        XCTAssertEqual(first.text.count, 1000)
        let last = KnowledgeEditing.part(text, number: 9)
        XCTAssertEqual(last.number, 3)
        XCTAssertEqual(last.text.count, 500)
        XCTAssertEqual(KnowledgeEditing.part("", number: 1).total, 1)
    }

    // MARK: - 回答的連結

    func testTurnsWikiLinksIntoTappableLinks() throws {
        let source = AssistantText.markdownSource("## 結論\n依照 [[工作/會議 紀錄|會議]] 與 [[讀書清單#2026]]。")
        XCTAssertTrue(source.hasPrefix("**結論**\n"))
        XCTAssertFalse(source.contains("[["))
        let attributed = AssistantText.attributed("見 [[會議 紀錄]]")
        let link = try XCTUnwrap(attributed.runs.compactMap { $0.link }.first)
        XCTAssertEqual(AssistantText.target(of: link), "會議 紀錄")
        XCTAssertEqual(String(attributed.characters), "見 會議 紀錄")

        let aliased = AssistantText.attributed("[[工作/會議 紀錄|會議]]")
        XCTAssertEqual(String(aliased.characters), "會議")
        XCTAssertEqual(aliased.runs.compactMap { $0.link }.first.flatMap(AssistantText.target(of:)), "工作/會議 紀錄")

        let anchored = AssistantText.attributed("[[讀書清單#2026]]")
        XCTAssertEqual(String(anchored.characters), "讀書清單")
        XCTAssertEqual(anchored.runs.compactMap { $0.link }.first.flatMap(AssistantText.target(of:)), "讀書清單#2026")
    }

    func testIgnoresOtherLinks() {
        XCTAssertNil(AssistantText.target(of: URL(string: "https://example.com")!))
    }

    @MainActor
    func testTitlesAndPrompt() {
        XCTAssertEqual(KnowledgeAssistant.title(of: "工作/會議紀錄.md"), "會議紀錄")
        let prompt = KnowledgeAssistant.prompt("問題", openNote: "a.md", previous: "問：x\n答：y")
        XCTAssertTrue(prompt.hasSuffix("問題"))
        XCTAssertTrue(prompt.contains("a.md"))
        XCTAssertTrue(prompt.contains("答：y"))
    }
}
