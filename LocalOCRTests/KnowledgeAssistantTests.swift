import XCTest
@testable import LocalOCR

final class KnowledgeAssistantTests: XCTestCase {
    // MARK: - MCP 回應

    func testParsesToolResultTextBlocks() throws {
        let data = Data(##"{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"path\":\"a.md\",\"etag\":\"\\\"e1\\\"\"}"},{"type":"text","text":"# A\n內容"}]}}"##.utf8)
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

    // MARK: - 對話紀錄

    func testTranscriptTurnFormat() {
        let taipei = TimeZone(identifier: "Asia/Taipei")!
        let date = Date(timeIntervalSince1970: 1_760_414_100) // 2025-10-14 11:55 +08:00
        let edits = [
            AgentEdit(path: "收件匣/想法.md", summary: "新增筆記", previous: nil, etag: "e"),
            AgentEdit(AssistantClient.Edit(id: "m1", op: "move", path: "專案/A.md", from: "收件匣/A.md", summary: "", undone: false), runID: "r1"),
        ]
        let turn = ChatTranscript.turn(question: "整理收件匣", answer: "完成了。", engine: .device, sources: ["工作/週報.md", "週報"], edits: edits, date: date, timeZone: taipei)
        XCTAssertEqual(turn, """
        ## 🙋 2025-10-14 11:55
        整理收件匣

        ## 🤖 裝置端 AI
        完成了。

        > 來源：[[週報]]
        > 修改：新增 [[想法]]；搬移 [[A]] → [[A]]

        """)
    }

    func testTranscriptAppendsAndParsesBack() {
        let taipei = TimeZone(identifier: "Asia/Taipei")!
        let date = Date(timeIntervalSince1970: 1_760_414_100)
        let first = ChatTranscript.turn(question: "問一", answer: "答一 [[A]]", engine: .device, sources: ["A.md"], edits: [], date: date, timeZone: taipei)
        let created = ChatTranscript.appending(first, to: nil, created: date, timeZone: taipei)
        XCTAssertTrue(created.hasPrefix("---\ntype: ai-chat\ncreated: 2025-10-14T11:55:00+08:00\ntags: [ai-chat]\n---\n\n## 🙋"))
        let second = ChatTranscript.turn(question: "問二", answer: "答二", engine: .cloud, sources: [], edits: [], date: date, timeZone: taipei)
        let full = ChatTranscript.appending(second, to: created + "\n\n", created: date, timeZone: taipei)
        XCTAssertTrue(full.contains("[[A]]\n\n## 🙋 2025-10-14 11:55\n問二"))

        let messages = ChatTranscript.parse(full)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(messages[0].text, "問一")
        XCTAssertEqual(messages[1].text, "答一 [[A]]")
        XCTAssertEqual(messages[1].sources, ["A"])
        XCTAssertEqual(messages[1].engine, .device)
        XCTAssertEqual(messages[3].text, "答二")
        XCTAssertEqual(messages[3].engine, .cloud(model: ""))
    }

    func testParsesEditFootnotesIntoTheAnswer() {
        let text = "## 🙋 2025-10-14 11:55\n搬一下\n\n## 🤖 雲端 AI\n好了\n\n> 來源：[[A]]、[[B|別名]]\n> 修改：搬移 [[A]] → [[A]]\n"
        let messages = ChatTranscript.parse(text)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1].sources, ["A", "B"])
        XCTAssertEqual(messages[1].text, "好了\n\n修改：搬移 [[A]] → [[A]]")
    }

    func testTranscriptFileNames() {
        let taipei = TimeZone(identifier: "Asia/Taipei")!
        let date = Date(timeIntervalSince1970: 1_760_414_100)
        XCTAssertEqual(ChatTranscript.fileName(for: "把 [[會議]] 整理成表格/報告？", date: date, timeZone: taipei), "2025-10-14 1155 把 會議 整理成表格 報告.md")
        XCTAssertEqual(ChatTranscript.fileName(for: "   ", date: date, timeZone: taipei), "2025-10-14 1155.md")
        XCTAssertEqual(ChatTranscript.fileName(for: String(repeating: "長", count: 40), date: date, timeZone: taipei), "2025-10-14 1155 " + String(repeating: "長", count: 24) + ".md")
    }

    // MARK: - 雲端 AI

    func testParsesCloudRunState() {
        let value: [String: Any] = [
            "id": "run1", "status": "completed", "model": "m",
            "events": [
                ["seq": 1, "type": "tool", "name": "search_notes", "summary": "搜尋「會議」"],
                ["seq": 2, "type": "edit", "edit": ["id": "e1", "op": "move", "path": "專案/A.md", "from": "A.md", "summary": "搬到專案", "undone": false]],
                ["seq": 3, "type": "message", "text": "完成"],
                ["seq": 4, "type": "unknown"],
            ],
            "answer": "完成", "error": NSNull(), "sources": ["A.md"],
            "edits": [["id": "e1", "op": "move", "path": "專案/A.md", "from": "A.md", "summary": "搬到專案", "undone": false]],
        ]
        let run = AssistantClient.run(from: value)
        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(run.events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(run.events[0].event, .tool("搜尋「會議」"))
        guard case .edit(let edit) = run.events[1].event else { return XCTFail("應該是修改") }
        XCTAssertEqual(edit.from, "A.md")
        XCTAssertEqual(AgentEdit(edit, runID: run.id).op, .move)
        XCTAssertEqual(run.answer, "完成")
        XCTAssertNil(run.error)
        XCTAssertEqual(run.sources, ["A.md"])
    }

    // MARK: - 預算與模型分級

    func testParsesTieredRoute() {
        let route = AssistantClient.route(from: [
            "kind": "task", "route": "cloud", "confidence": 0.8, "provider": "jev", "cloudAvailable": true,
            "difficulty": "hard", "budget": "medium", "tier": "large", "model": "claude-opus-5-5", "effort": "high",
        ])
        XCTAssertTrue(route.isCloud)
        XCTAssertEqual(route.tier, "large")
        XCTAssertEqual(route.model, "claude-opus-5-5")
        XCTAssertEqual(route.effort, "high")
        XCTAssertEqual(route.summary, "困難的多步驟工作")

        // 舊版伺服器（沒有預算欄位）
        let legacy = AssistantClient.route(from: ["kind": "question", "route": "device", "confidence": 0.6, "provider": "heuristic", "cloudAvailable": true])
        XCTAssertFalse(legacy.isCloud)
        XCTAssertNil(legacy.tier)
        XCTAssertNil(legacy.model as String?)
        XCTAssertEqual(legacy.summary, "問題")
    }

    func testBudgetSettingAndModelLabels() {
        XCTAssertEqual(AssistantEngineMode.from("auto"), .medium, "舊版的「自動」")
        XCTAssertEqual(AssistantEngineMode.from("cloud"), .high, "舊版的「一律用雲端」")
        XCTAssertEqual(AssistantEngineMode.from("device"), .device)
        XCTAssertEqual(AssistantEngineMode.from(nil), .medium)
        XCTAssertEqual(AssistantEngineMode.low.budget, "low")
        XCTAssertNil(AssistantEngineMode.device.budget)

        XCTAssertEqual(KnowledgeAssistant.modelLabel("claude-sonnet-5-5"), "Sonnet 5.5")
        XCTAssertEqual(KnowledgeAssistant.modelLabel("claude-opus-4-5-20251101"), "Opus 4.5")
        XCTAssertEqual(KnowledgeAssistant.modelLabel("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(KnowledgeAssistant.modelLabel("gpt-x"), "gpt-x")
    }

    func testParsesModelSettings() {
        let value: [String: Any] = [
            "tiers": ["small": "claude-haiku-5-5", "medium": "claude-sonnet-5-5", "large": "claude-opus-5-5"],
            "models": [
                ["id": "claude-sonnet-5-5", "name": "Claude Sonnet 5.5", "family": "claude-sonnet", "releaseDate": "2026-09-28"],
                ["id": "claude-x", "name": "claude-x", "family": NSNull(), "releaseDate": "2026-01-01"],
                ["name": "no id"],
            ],
            "codeExecution": true,
            "webSearch": false,
            "maxTurns": 40,
            "issue": NSNull(),
        ]
        let settings = AssistantClient.modelSettings(from: value)
        XCTAssertEqual(settings.tiers["medium"], "claude-sonnet-5-5")
        XCTAssertEqual(settings.models.map(\.id), ["claude-sonnet-5-5", "claude-x"])
        XCTAssertEqual(settings.models[0].family, "claude-sonnet")
        XCTAssertNil(settings.models[1].family)
        XCTAssertEqual(settings.maxTurns, 40)
        XCTAssertTrue(settings.codeExecution)
        XCTAssertFalse(settings.webSearch)
        XCTAssertNil(settings.issue)
    }

    func testAISettingsRunOptions() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ai-settings-test"))
        defaults.removePersistentDomain(forName: "ai-settings-test")
        defer { defaults.removePersistentDomain(forName: "ai-settings-test") }
        // nothing chosen: the server decides everything
        XCTAssertEqual(AISettings.runOptions(tier: "medium", defaults: defaults), AISettings.RunOptions())
        XCTAssertTrue(AISettings.isOn(AISettings.noteButtonKey, defaults: defaults))

        defaults.set("claude-sonnet-5-5", forKey: AISettings.modelKey("medium"))
        defaults.set("", forKey: AISettings.modelKey("large"))
        defaults.set("on", forKey: AISettings.webSearchKey)
        defaults.set("off", forKey: AISettings.codeExecutionKey)
        defaults.set(10, forKey: AISettings.maxTurnsKey)
        defaults.set(false, forKey: AISettings.noteButtonKey)
        XCTAssertEqual(
            AISettings.runOptions(tier: "medium", defaults: defaults),
            AISettings.RunOptions(model: "claude-sonnet-5-5", webSearch: true, codeExecution: false, maxTurns: 10)
        )
        // the large tier is still automatic; no tier = the large tier
        XCTAssertNil(AISettings.runOptions(tier: nil, defaults: defaults).model)
        XCTAssertNil(AISettings.runOptions(tier: "small", defaults: defaults).model)
        XCTAssertFalse(AISettings.isOn(AISettings.noteButtonKey, defaults: defaults))
        XCTAssertEqual(AISettings.tierFamily("small"), "claude-haiku")
    }
}
