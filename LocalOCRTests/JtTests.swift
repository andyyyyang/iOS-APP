import XCTest
@testable import LocalOCR

/// JT 業務追蹤（jt.v1）：快照解析、op 路徑、樂觀顯示與 acks（範例取自 JT 的 docs/JT-SYNC.md）。
@MainActor
final class JtTests: XCTestCase {
    private static let casesSnapshot = #"""
    { "schema": "jt.v1", "kind": "cases", "rev": "3f2a", "generatedAt": 1792165295669,
      "data": {
        "cases": [{
          "id": "outlook-1", "ownerId": "andy", "customer": "Amkor", "customerDomain": "amkor.com",
          "product": "101434675 0851563HS (CV90-94312)", "model": "101434675 0851563HS", "customName": null,
          "status": "進行中", "tone": "attention", "stat": "剩 12d",
          "start": "2026-09-20", "end": "2026-10-28", "etd": "2026-10-28", "etdFrom": "",
          "daysToEtd": 12, "progressDate": "2026-10-16", "schedule": "behind", "scheduleDays": -3,
          "overdueDays": 3, "overdueLabel": "車削", "progress": { "done": 4, "total": 7 },
          "markers": [{ "id": "m-1-3", "type": "樣品", "title": "T1", "date": "2026-10-19", "origDate": "2026-10-10", "done": false }],
          "milestones": [{ "id": "m-1-3", "type": "樣品", "title": "T1", "date": "2026-10-19", "endDate": "", "done": false, "note": "" }],
          "note": "", "project": "CV90 散熱片",
          "endUser": { "name": "Qualcomm", "domain": "qualcomm.com" },
          "wip": { "material": "60016062", "eqp": "AP25", "state": "DOWN", "text": "停機·模具保養", "tone": "stuck" },
          "comments": [{ "id": "c1", "authorId": "andy", "text": "客戶確認圖面", "createdAt": "2026-10-15T09:30:00" }]
        }, {
          "id": "outlook-2", "ownerId": "amy", "customer": "Amkor", "product": "Lid", "customName": "散熱蓋",
          "status": "完成", "tone": "done", "stat": "完成", "start": "2026-08-01", "end": "2026-09-01"
        }],
        "layouts": {
          "etd-asc": [{ "type": "case", "caseId": "outlook-1" }, { "type": "case", "caseId": "outlook-2" }],
          "customer": [
            { "type": "group", "id": "grp:customer:Amkor", "key": "Amkor", "label": "Amkor", "count": 2, "attention": 1,
              "start": "2026-08-01", "end": "2026-10-28", "caseIds": ["outlook-1", "outlook-2"] },
            { "type": "case", "caseId": "outlook-1" }, { "type": "case", "caseId": "outlook-2" }
          ]
        }
      },
      "clocks": { "case:outlook-1": { "status": 0, "etd": 0, "note": 0 } } }
    """#

    private func snapshot(_ text: String) -> Data { Data(text.utf8) }

    private func makeStore() -> JtSyncStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "jt-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JtSyncStore(directory: directory, sendsAutomatically: false)
    }

    // MARK: - 解析

    func testCasesSnapshotParsesDisplayFieldsAndLayouts() throws {
        let parsed = try XCTUnwrap(JtSnapshot(data: snapshot(Self.casesSnapshot)))
        XCTAssertEqual(parsed.kind, "cases")
        XCTAssertEqual(parsed.rev, "3f2a")
        XCTAssertEqual(parsed.clocks["case:outlook-1"]?["status"], 0)

        let cases = JtCases(parsed.data)
        XCTAssertEqual(cases.cases.count, 2)
        let first = cases.cases[0]
        XCTAssertEqual(first.title, "101434675 0851563HS (CV90-94312)", "customName 是 null 時用品名")
        XCTAssertEqual(first.tone, "attention")
        XCTAssertEqual(first.stat, "剩 12d")
        XCTAssertEqual(first.progressDone, 4)
        XCTAssertEqual(first.progressTotal, 7)
        XCTAssertEqual(first.markers.first?.originalDate, "2026-10-10")
        XCTAssertEqual(first.milestones.count, 1)
        XCTAssertEqual(first.endUserName, "Qualcomm")
        XCTAssertEqual(first.wip?.tone, "stuck")
        XCTAssertEqual(first.comments.first?.text, "客戶確認圖面")
        XCTAssertFalse(first.isClosed)
        XCTAssertTrue(first.matches("cv90"))
        XCTAssertTrue(first.matches("Qualcomm"))

        let second = cases.cases[1]
        XCTAssertEqual(second.title, "散熱蓋")
        XCTAssertTrue(second.isClosed)
        XCTAssertNil(second.daysToEtd, "缺少的欄位不影響其他欄位")

        let grouped = try XCTUnwrap(cases.layouts["customer"])
        XCTAssertEqual(grouped.count, 3)
        guard case .group(let group) = grouped[0] else { return XCTFail("第一列應該是分組") }
        XCTAssertEqual(group.label, "Amkor")
        XCTAssertEqual(group.attention, 1)
        XCTAssertEqual(group.caseIds, ["outlook-1", "outlook-2"])
        XCTAssertEqual(grouped[1].id, "case:outlook-1")
        XCTAssertEqual(cases.layouts["etd-asc"]?.count, 2)
    }

    func testManifestReportsOfflineAfterThreeMinutes() throws {
        let now = Date()
        let ms = now.timeIntervalSince1970 * 1000
        let fresh = try XCTUnwrap(JtManifest([
            "schema": "jt.v1", "device": "JT-PC", "heartbeatAt": ms - 60_000,
            "files": ["cases": ["rev": "a", "updatedAt": ms] as JtObject, "calendar": ["path": ".jt/calendar.json", "rev": "b"] as JtObject] as JtObject,
        ]))
        XCTAssertFalse(fresh.isStale(now: now))
        XCTAssertEqual(fresh.files["cases"]?.path, ".jt/cases.json", "沒寫路徑時用預設位置")
        XCTAssertEqual(fresh.files["calendar"]?.rev, "b")

        let stale = try XCTUnwrap(JtManifest(["schema": "jt.v1", "heartbeatAt": ms - 200_000, "files": [:] as JtObject]))
        XCTAssertTrue(stale.isStale(now: now))
    }

    func testCalendarDaysAndItems() throws {
        let raw = #"""
        { "schema": "jt.v1", "kind": "calendar", "rev": "c", "generatedAt": 1,
          "data": {
            "today": "2026-10-16",
            "items": [
              { "id": "todo:A@2026-10-12", "kind": "todo", "title": "回覆報價", "start": "2026-10-12", "allDay": true, "entryId": "A" },
              { "id": "meet:B", "kind": "meeting", "title": "週會", "start": "2026-10-16T09:30", "allDay": false, "joinUrl": "https://teams.example/x" },
              { "id": "mail:C", "kind": "todo", "title": "信件", "start": "2026-10-16", "allDay": true, "entryId": "C", "mail": { "sender": "Sherry" } }
            ],
            "notes": { "2026-10-16": "**記得** 打電話" },
            "holidays": [{ "date": "2026-10-10", "name": "國慶日" }],
            "days": { "2026-10-16": { "carried": ["todo:A@2026-10-12"], "groups": [{ "kind": "todo", "ids": ["todo:A@2026-10-12", "mail:C"] }, { "kind": "meeting", "ids": ["meet:B"] }] } },
            "outlook": { "syncedAt": 1, "error": "" }
          } }
        """#
        let parsed = try XCTUnwrap(JtSnapshot(data: snapshot(raw)))
        let calendar = JtCalendar(parsed.data)
        XCTAssertEqual(calendar.today, "2026-10-16")
        XCTAssertEqual(calendar.items.count, 3)
        XCTAssertEqual(calendar.holidays["2026-10-10"], "國慶日")
        XCTAssertEqual(calendar.notes["2026-10-16"], "**記得** 打電話")
        let day = try XCTUnwrap(calendar.days["2026-10-16"])
        XCTAssertEqual(day.groups.map(\.kind), ["todo", "meeting"])
        XCTAssertEqual(day.groups.first?.ids.count, 2)
        XCTAssertTrue(day.carried.contains("todo:A@2026-10-12"))

        let meeting = try XCTUnwrap(calendar.items.first { $0.id == "meet:B" })
        XCTAssertEqual(meeting.time, "09:30")
        XCTAssertEqual(meeting.day, "2026-10-16")
        XCTAssertFalse(meeting.isCheckable)
        let todo = try XCTUnwrap(calendar.items.first { $0.id == "todo:A@2026-10-12" })
        XCTAssertNil(todo.time)
        XCTAssertTrue(todo.isCheckable)
        XCTAssertTrue(try XCTUnwrap(calendar.items.first { $0.id == "mail:C" }).isCheckable, "信件備忘也可以打勾")
    }

    func testWipMergedRowsAndMachines() throws {
        let raw = #"""
        { "schema": "jt.v1", "kind": "wip", "rev": "w", "generatedAt": 1,
          "data": {
            "tracked": [{ "productPn": "P1", "pinned": true }, { "productPn": "P2", "hidden": true }, { "productPn": "P3", "hidden": true }],
            "merged": [
              { "lead": "P1", "pns": ["P1"], "label": "散熱片 A", "state": "stuck", "rowCount": 3 },
              { "lead": "P2", "pns": ["P2", "P3"], "label": "蓋板", "state": "run" }
            ],
            "board": { "configured": true, "fetchedAt": "10:05",
              "machines": [{ "eqp": "AP25", "group": "down", "summary": "AP25 停機 2.3h（模具保養）", "mine": [{ "pn": "P1" }] }, { "eqp": "AP26", "group": "idle" }] }
          } }
        """#
        let wip = JtWip(try XCTUnwrap(JtSnapshot(data: snapshot(raw))).data)
        XCTAssertEqual(wip.rows.count, 2)
        XCTAssertTrue(wip.rows[0].pinned)
        XCTAssertFalse(wip.rows[0].hidden)
        XCTAssertTrue(wip.rows[1].hidden, "合併的料號全部隱藏時整列隱藏")
        XCTAssertEqual(wip.machines.count, 2)
        XCTAssertTrue(wip.machines[0].isMine)
        XCTAssertFalse(wip.machines[1].isMine)
        XCTAssertEqual(JtPalette.machinePastel("down"), .blush)
        XCTAssertNil(JtPalette.machinePastel("idle"))
    }

    func testListRowsPickCommonFields() {
        let rows = JtListRow.rows([
            ["customName": "散熱蓋", "customer": "Amkor", "etd": "2026-10-20", "status": "待出貨"],
            ["title": "AP25 停機", "kind": "overdue", "date": "2026-10-16T08:00:00"],
            [:],
        ])
        XCTAssertEqual(rows[0].title, "散熱蓋")
        XCTAssertEqual(rows[0].detail, "Amkor")
        XCTAssertEqual(rows[0].date, "2026-10-20")
        XCTAssertEqual(rows[0].badge, "待出貨")
        XCTAssertTrue(rows[1].isAlert)
        XCTAssertEqual(rows[1].date, "2026-10-16T08:00")
        XCTAssertEqual(rows[2].title, "（未命名）")
        XCTAssertEqual(Set(rows.map(\.id)).count, 3, "沒有 id 的列也不會重複")
    }

    // MARK: - 編輯

    func testOpPathUsesThirteenDigitEditTime() {
        XCTAssertEqual(
            JtSyncStore.opPath(client: "ipad-3F2A9C", editedAt: 1_792_165_300_123, opId: "abc"),
            ".jt/ops/ipad-3F2A9C/1792165300123-abc.json"
        )
        XCTAssertEqual(JtSyncStore.opPath(client: "c", editedAt: 42, opId: "x"), ".jt/ops/c/0000000000042-x.json")
        XCTAssertEqual(JtSyncStore.acksPath(client: "ipad-3F2A9C"), ".jt/acks/ipad-3F2A9C.json")
    }

    func testPendingEditShowsUntilSnapshotHasNewerEdit() throws {
        let store = makeStore()
        XCTAssertTrue(store.apply(kind: "cases", data: snapshot(Self.casesSnapshot)))
        XCTAssertEqual(store.displayCase("outlook-1")?.status, "進行中")

        store.setCase("outlook-1", ["status": "完成"])
        store.addComment("outlook-1", "已出貨")
        let milestone = try XCTUnwrap(store.displayCase("outlook-1")?.milestones.first)
        store.setMilestone("outlook-1", milestone, ["done": true])
        XCTAssertEqual(store.unsentCount, 3)
        XCTAssertTrue(store.isPending(caseId: "outlook-1"))

        var shown = try XCTUnwrap(store.displayCase("outlook-1"))
        XCTAssertEqual(shown.status, "完成", "快照的欄位時間比編輯舊：顯示待送的值")
        XCTAssertEqual(shown.comments.count, 2)
        XCTAssertTrue(shown.comments.last?.isPending ?? false)
        XCTAssertTrue(shown.milestones.first?.done ?? false)

        // 別處（電腦）在這個編輯之後又改了狀態：改用快照的值
        let later = Int64(Date().timeIntervalSince1970 * 1000) + 60_000
        let newer = Self.casesSnapshot
            .replacingOccurrences(of: #""status": "進行中", "tone": "attention""#, with: #""status": "取消", "tone": "cancelled""#)
            .replacingOccurrences(of: #""status": 0, "etd": 0"#, with: #""status": \#(later), "etd": 0"#)
        XCTAssertTrue(store.apply(kind: "cases", data: snapshot(newer)))
        shown = try XCTUnwrap(store.displayCase("outlook-1"))
        XCTAssertEqual(shown.status, "取消")
        XCTAssertEqual(shown.comments.count, 2, "留言仍顯示到 JT 回報為止")
    }

    func testCalendarOverlaysTodosAndNotes() throws {
        let store = makeStore()
        let raw = #"""
        { "schema": "jt.v1", "kind": "calendar", "rev": "c", "generatedAt": 1,
          "data": { "today": "2026-10-16",
            "items": [{ "id": "todo:A", "kind": "todo", "title": "回覆報價", "start": "2026-10-16", "allDay": true, "entryId": "A" },
                      { "id": "todo:B", "kind": "todo", "title": "寄樣品", "start": "2026-10-16", "allDay": true, "entryId": "B" }],
            "notes": { "2026-10-16": "舊備忘" } },
          "clocks": {} }
        """#
        XCTAssertTrue(store.apply(kind: "calendar", data: snapshot(raw)))
        store.setTodo("A", ["done": true])
        store.submit("todo.delete", ["entryId": "B"])
        store.createTodo(title: "打給 Sherry", date: "2026-10-17")
        store.setNote("2026-10-16", "新備忘")

        let items = store.displayItems()
        XCTAssertEqual(items["todo:A"]?.done, true)
        XCTAssertNil(items["todo:B"], "待送的刪除不顯示")
        XCTAssertTrue(store.isPending(entryId: "A"))
        XCTAssertEqual(store.pendingTodos(on: "2026-10-17").map(\.title), ["打給 Sherry"])
        XCTAssertTrue(store.pendingTodos(on: "2026-10-16").isEmpty)
        XCTAssertEqual(store.note(on: "2026-10-16"), "新備忘")
    }

    func testAcksClearHandledEditsAndReportProblems() {
        func op(_ id: String, sent: Bool) -> JtPendingOp {
            JtPendingOp(opId: id, editedAt: 1, kind: "case.set", payload: Data("{}".utf8), sent: sent)
        }
        let pending = [op("a", sent: true), op("b", sent: true), op("c", sent: true), op("d", sent: true), op("e", sent: false)]
        let acks = JtAck.parse(Data(#"""
        { "schema": "jt.v1", "client": "x", "results": [
          { "opId": "a", "status": "applied" }, { "opId": "b", "status": "superseded" },
          { "opId": "c", "status": "failed", "error": "找不到這筆待辦" }, { "opId": "e", "status": "applied" } ] }
        """#.utf8))
        XCTAssertEqual(acks.count, 4)
        let resolved = JtSyncStore.resolve(pending: pending, acks: acks)
        XCTAssertEqual(resolved.remaining.map(\.opId), ["d", "e"], "還沒回報的與還沒送出的留著")
        XCTAssertEqual(resolved.notices, ["別處有更新的修改，已改用最新的內容", "找不到這筆待辦"])
    }

    func testPendingEditsSurviveRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "jt-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = JtSyncStore(directory: directory, sendsAutomatically: false)
        first.setWip(["P1"], ["pinned": true])
        let second = JtSyncStore(directory: directory, sendsAutomatically: false)
        XCTAssertEqual(second.pending.map(\.kind), ["wip.set"], "離線時的編輯重新開 App 後仍會送出，編輯時間不變")
        XCTAssertEqual(second.pending.first?.editedAt, first.pending.first?.editedAt)
        let path = JtSyncStore.opPath(client: second.client, editedAt: try XCTUnwrap(second.pending.first?.editedAt), opId: try XCTUnwrap(second.pending.first?.opId))
        XCTAssertTrue(path.hasPrefix(".jt/ops/"))
    }
}
