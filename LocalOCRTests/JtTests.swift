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

    // MARK: - 甘特

    private func casesFixture() throws -> JtCases {
        JtCases(try XCTUnwrap(JtSnapshot(data: snapshot(Self.casesSnapshot))).data)
    }

    func testDayNumbersRoundTripWithoutTimeZones() {
        XCTAssertEqual(JtDayNumber.number("1970-01-01"), 0)
        XCTAssertEqual(JtDayNumber.number("1970-01-02T09:30"), 1, "有時間的字串只看日期")
        XCTAssertNil(JtDayNumber.number("2026-13-01"))
        XCTAssertNil(JtDayNumber.number("10/16"))
        let day = try? XCTUnwrap(JtDayNumber.number("2026-10-16"))
        XCTAssertEqual(day.map(JtDayNumber.string), "2026-10-16")
        XCTAssertEqual(day.map(JtDayNumber.weekday), 5, "2026-10-16 是星期五")
        XCTAssertEqual(JtDayNumber.number("2024-03-01").map { $0 - (JtDayNumber.number("2024-02-28") ?? 0) }, 2, "閏年")
        XCTAssertEqual(JtDayNumber.civil(JtDayNumber.fromCivil(year: 2027, month: 1, day: 31)).month, 1)
        XCTAssertEqual(JtDates.monthDay("2026-11-02"), "11/2")
    }

    func testFilterTabsHideClosedCasesFromAll() throws {
        let cases = try casesFixture().cases
        let open = try XCTUnwrap(cases.first { $0.id == "outlook-1" })
        let done = try XCTUnwrap(cases.first { $0.id == "outlook-2" })
        XCTAssertTrue(JtGanttFilter.all.includes(open))
        XCTAssertFalse(JtGanttFilter.all.includes(done), "完成的案件在「全部」自動隱藏")
        XCTAssertTrue(JtGanttFilter.closed.includes(done))
        XCTAssertTrue(JtGanttFilter.attention.includes(open))
        XCTAssertFalse(JtGanttFilter.ready.includes(open))
    }

    func testGanttRowsFollowJtLayoutsWithFiltersAndCollapsedGroups() throws {
        let fixture = try casesFixture()
        let byId = Dictionary(uniqueKeysWithValues: fixture.cases.map { ($0.id, $0) })
        let grouped = try XCTUnwrap(fixture.layouts["customer"])

        let all = JtGanttModel.rows(layout: grouped, cases: byId, include: JtGanttFilter.all.includes, collapsed: [], expandAll: false)
        XCTAssertEqual(all.map(\.id), ["group:grp:customer:Amkor", "case:outlook-1"])
        guard case .group(let group) = all[0], case .item(_, let indent, let sameCustomer) = all[1] else { return XCTFail("列的種類不對") }
        XCTAssertEqual(group.members.count, 1, "標題列的件數只算顯示的案件")
        XCTAssertEqual(group.attention, 1)
        XCTAssertTrue(indent)
        XCTAssertTrue(sameCustomer, "組內客戶都一樣：改顯示終端客戶")

        let closed = JtGanttModel.rows(layout: grouped, cases: byId, include: JtGanttFilter.closed.includes, collapsed: [], expandAll: true)
        XCTAssertEqual(closed.map(\.id), ["group:grp:customer:Amkor", "case:outlook-2"])

        let folded = JtGanttModel.rows(layout: grouped, cases: byId, include: JtGanttFilter.all.includes, collapsed: ["grp:customer:Amkor"], expandAll: false)
        XCTAssertEqual(folded.map(\.id), ["group:grp:customer:Amkor"])
        let searching = JtGanttModel.rows(layout: grouped, cases: byId, include: { $0.matches("cv90") }, collapsed: ["grp:customer:Amkor"], expandAll: true)
        XCTAssertEqual(searching.map(\.id), ["group:grp:customer:Amkor", "case:outlook-1"], "搜尋時全部展開")

        let flat = JtGanttModel.rows(layout: try XCTUnwrap(fixture.layouts["etd-asc"]), cases: byId, include: JtGanttFilter.all.includes, collapsed: [], expandAll: false)
        guard case .item(_, let flatIndent, _) = try XCTUnwrap(flat.first) else { return XCTFail() }
        XCTAssertEqual(flat.count, 1)
        XCTAssertFalse(flatIndent, "出貨排序不分組、不縮排")

        let none = JtGanttModel.rows(layout: grouped, cases: byId, include: { _ in false }, collapsed: [], expandAll: false)
        XCTAssertTrue(none.isEmpty, "組裡沒有要顯示的案件時標題也不畫")
        XCTAssertEqual(JtGanttModel.fallbackLayout(fixture.cases).map(\.id), ["case:outlook-2", "case:outlook-1"])
    }

    func testBarGeometryExtendsAttentionToTodayAndFollowsEtdDrag() throws {
        let item = try XCTUnwrap(try casesFixture().cases.first { $0.id == "outlook-1" })
        let timeline = JtTimeline.make(cases: [item], today: "2026-10-16", dayWidth: 10)
        XCTAssertEqual(JtDayNumber.string(timeline.firstDay), "2026-09-09", "今天 −30 天再往前 7 天")
        let bar = JtBarGeometry(item: item, timeline: timeline)
        XCTAssertEqual(bar.x0, 110)
        XCTAssertEqual(bar.x1, 500, "結束那天整天都畫")
        XCTAssertEqual(bar.progressX, 375, "進度填到 progressDate 那天的正中間（今天的藍線）")
        XCTAssertEqual(bar.flagX, 500)

        let dragged = JtBarGeometry(item: item, timeline: timeline, dragDays: 3)
        XCTAssertEqual(dragged.flagX, 530)
        XCTAssertEqual(dragged.x1, 530, "bar 的結束就是 ETD：跟著旗子動")
        XCTAssertEqual(dragged.etd, "2026-10-31")

        var late = item
        late.end = "2026-10-01"
        late.etd = "2026-10-01"
        XCTAssertEqual(JtBarGeometry(item: late, timeline: timeline).x1, 375, "需要注意的案件延伸到今天的藍線")
    }

    func testMarkersCloseTogetherMergeIntoACount() {
        let timeline = JtTimeline(firstDay: JtDayNumber.number("2026-10-01") ?? 0, days: 60, dayWidth: 4, todayDay: JtDayNumber.number("2026-10-16") ?? 0)
        let markers = [
            JtMarker(id: "a", type: "品檢", title: "", date: "2026-10-05", originalDate: "", done: true),
            JtMarker(id: "b", type: "模具", title: "T1", date: "2026-10-06", originalDate: "", done: false),
            JtMarker(id: "c", type: "包裝", title: "", date: "2026-10-25", originalDate: "", done: false),
        ]
        let dots = JtMarkerDot.clusters(markers, timeline: timeline, isClosed: false)
        XCTAssertEqual(dots.map(\.count), [2, 1])
        XCTAssertTrue(dots[0].overdue, "沒完成又過了日期＝逾期")
        XCTAssertFalse(dots[0].done)
        XCTAssertEqual(dots[0].titles, ["品檢", "T1"])
        XCTAssertFalse(dots[1].overdue)
        XCTAssertEqual(dots[1].x, CGFloat(24) * 4 + 2)
        XCTAssertFalse(JtMarkerDot.clusters(markers, timeline: timeline, isClosed: true)[0].overdue, "結案的案件不標逾期")
    }

    func testTimelineHeaderTicksMatchTheDesktopWeekScale() {
        let timeline = JtTimeline(firstDay: JtDayNumber.number("2026-09-28") ?? 0, days: 40, dayWidth: 14, todayDay: JtDayNumber.number("2026-10-16") ?? 0)
        let ticks = JtTimelineHeader.ticks(timeline: timeline, scale: .week, from: 0, to: timeline.width)
        XCTAssertEqual(ticks.filter(\.isMonth).map(\.label), ["October", "November"])
        XCTAssertEqual(ticks.filter { !$0.isMonth }.map(\.label), ["29", "01", "08", "15", "22", "29", "01"])
        XCTAssertEqual(JtTimelineHeader.stickyMonth(timeline: timeline, offset: 14 * 4), "October 2026", "捲到月中：左緣標出是哪個月")
        XCTAssertNil(JtTimelineHeader.stickyMonth(timeline: timeline, offset: 0), "下個月的標籤快到左緣時讓位")
        XCTAssertNil(JtTimelineHeader.stickyMonth(timeline: timeline, offset: 14 * 3), "月初本身就有標籤")
        XCTAssertEqual(JtTimelineHeader.ticks(timeline: timeline, scale: .day, from: 0, to: 14 * 3).filter { !$0.isMonth }.count, 5)
    }

    func testLogoInitialsAndColorsMatchTheDesktop() {
        XCTAssertEqual(JtLogo.initials("AMD-Xilinx"), "AX")
        XCTAssertEqual(JtLogo.initials("Amkor"), "AM")
        XCTAssertEqual(JtLogo.initials("Qualcomm (QCT)"), "QU", "括號內的字不算")
        XCTAssertEqual(JtLogo.hueDegrees("Amkor"), 146)
        XCTAssertEqual(JtLogo.hueDegrees("AMD-Xilinx"), 53)
        XCTAssertEqual(JtLogo.hueDegrees("Qualcomm"), 13)
        XCTAssertNil(JtLogo.url(" "))
        XCTAssertEqual(JtLogo.url("amkor.com")?.absoluteString, "https://icons.duckduckgo.com/ip3/amkor.com.ico")
    }

    func testEtdAndEndUserEditsShowBeforeJtConfirms() throws {
        let store = makeStore()
        XCTAssertTrue(store.apply(kind: "cases", data: snapshot(Self.casesSnapshot)))
        store.setCase("outlook-1", ["etd": "2026-11-02", "endUser": "Nvidia"])
        let shown = try XCTUnwrap(store.displayCase("outlook-1"))
        XCTAssertEqual(shown.etd, "2026-11-02")
        XCTAssertEqual(shown.end, "2026-11-02", "bar 的結束跟著新的 ETD")
        XCTAssertEqual(shown.stat, "11/2")
        XCTAssertNil(shown.daysToEtd)
        XCTAssertEqual(shown.endUserName, "Nvidia")
        XCTAssertEqual(shown.endUserDomain, "", "換了終端客戶：舊的 logo 網域不再適用")
    }

    // MARK: - 待辦（今天分頁與右側欄）

    private static let agendaCalendar = #"""
    { "schema": "jt.v1", "kind": "calendar", "rev": "a", "generatedAt": 1,
      "data": { "today": "2026-10-16",
        "items": [
          { "id": "todo:A@2026-10-12", "kind": "todo", "title": "回覆報價", "start": "2026-10-12", "allDay": true, "entryId": "A" },
          { "id": "todo:B", "kind": "todo", "title": "寄樣品", "start": "2026-10-16", "allDay": true, "entryId": "B", "done": true },
          { "id": "todo:C", "kind": "todo", "title": "打電話", "start": "2026-10-16", "allDay": true, "entryId": "C" },
          { "id": "meet:M", "kind": "meeting", "title": "週會", "start": "2026-10-16T09:30", "allDay": false },
          { "id": "ms:D", "kind": "milestone", "title": "首試", "start": "2026-10-20", "allDay": true },
          { "id": "etd:E", "kind": "etd", "title": "出貨", "start": "2026-10-20", "allDay": true }
        ],
        "days": { "2026-10-16": { "carried": ["todo:A@2026-10-12"],
          "groups": [{ "kind": "todo", "ids": ["todo:A@2026-10-12", "todo:B", "todo:C"] }, { "kind": "meeting", "ids": ["meet:M"] }] } } },
      "clocks": {} }
    """#

    func testAgendaFollowsJtDaysAndSinksFinishedTodos() throws {
        let store = makeStore()
        XCTAssertTrue(store.apply(kind: "calendar", data: snapshot(Self.agendaCalendar)))

        var agenda = store.agenda(on: "2026-10-16")
        XCTAssertEqual(agenda.map(\.kind), ["todo", "meeting"])
        XCTAssertEqual(agenda[0].items.map(\.id), ["todo:A@2026-10-12", "todo:C", "todo:B"], "完成的沉到該段最下面")
        XCTAssertTrue(agenda[0].carried.contains("todo:A@2026-10-12"), "沒做完的待辦延續到今天")

        store.setTodo("C", ["done": true])
        agenda = store.agenda(on: "2026-10-16")
        XCTAssertEqual(agenda[0].items.map(\.id), ["todo:A@2026-10-12", "todo:B", "todo:C"], "剛打勾的馬上沉下去")

        store.createTodo(title: "新的待辦", date: "2026-10-16")
        agenda = store.agenda(on: "2026-10-16")
        XCTAssertEqual(agenda[0].items.count, 4)
        XCTAssertTrue(agenda[0].items[1].isPending, "還沒送到 JT 的新待辦排在未完成的後面")
        XCTAssertEqual(agenda[0].items[1].title, "新的待辦")

        XCTAssertEqual(store.agenda(on: "2026-10-20").map(\.kind), ["milestone", "etd"], "JT 沒排的日子依種類分段")
        XCTAssertTrue(store.agenda(on: "2026-10-21").isEmpty)
    }

    func testCalendarMarksCountOpenItemsPerDay() throws {
        let store = makeStore()
        XCTAssertTrue(store.apply(kind: "calendar", data: snapshot(Self.agendaCalendar)))
        store.setTodo("C", ["done": true])
        let marks = JtSyncStore.agendaMarks(items: store.displayItems(), days: store.calendar?.days ?? [:])
        XCTAssertEqual(marks["2026-10-16"]?.total, 4, "JT 排好的日子含延續的待辦")
        XCTAssertEqual(marks["2026-10-16"]?.open, 2)
        XCTAssertEqual(marks["2026-10-20"]?.open, 2)
        XCTAssertNil(marks["2026-10-21"])
    }

    // MARK: - 全域搜尋

    func testGlobalSearchFindsJtCasesAgendaPartsMachinesAndShipments() throws {
        let fixture = try casesFixture()
        let calendar = JtCalendar(try XCTUnwrap(JtSnapshot(data: snapshot(Self.agendaCalendar))).data)
        let items = Dictionary(uniqueKeysWithValues: calendar.items.map { ($0.id, $0) })
        let wip = JtWip(try XCTUnwrap(JtSnapshot(data: snapshot(#"""
        { "schema": "jt.v1", "kind": "wip", "rev": "w", "generatedAt": 1,
          "data": { "tracked": [], "merged": [{ "lead": "PN-77831", "pns": ["PN-77831"], "label": "散熱片 A", "customerName": "Amkor", "state": "stuck" }],
            "board": { "configured": true, "machines": [{ "eqp": "AP25", "group": "down", "summary": "AP25 停機 2.3h" }] } } }
        """#))).data)
        let po: JtObject = ["items": [["model": "DEMO-1", "customer": "Amkor", "etd": "2026-10-20"] as JtObject]]
        let entries = JtSyncStore.searchEntries(cases: fixture.cases, items: items, wip: wip.rows, machines: wip.machines, po: po, meta: nil, today: "2026-10-16")
        let sources = GlobalSearch.Sources(jt: entries)

        let cases = GlobalSearch.search("cv90", in: sources)
        XCTAssertEqual(cases.first?.section, .jtCases)
        guard case .jt(let found) = try XCTUnwrap(cases.first?.hits.first).target else { return XCTFail("應該是 JT 的結果") }
        XCTAssertEqual(found.caseId, "outlook-1")
        XCTAssertEqual(found.copyValue, "101434675 0851563HS")
        XCTAssertEqual(GlobalSearch.search("散熱蓋", in: sources).first?.hits.first?.id, "jt:caseItem:outlook-2", "完成的案件也找得到")
        XCTAssertEqual(GlobalSearch.search("Qualcomm", in: sources).first?.section, .jtCases, "終端客戶也找得到")

        XCTAssertEqual(GlobalSearch.search("週會", in: sources).first?.section, .jtAgenda)
        XCTAssertTrue(GlobalSearch.search("10/20", in: sources).contains { $0.section == .jtAgenda }, "日期也找得到")

        let part = GlobalSearch.search("PN-77831", in: sources)
        XCTAssertEqual(part.first?.section, .jtWip)
        guard case .jt(let row) = try XCTUnwrap(part.first?.hits.first).target else { return XCTFail() }
        XCTAssertEqual(row.query, "PN-77831")
        XCTAssertEqual(GlobalSearch.search("AP25", in: sources).first?.section, .jtWip, "機台也在「在製與機台」")
        XCTAssertEqual(GlobalSearch.search("DEMO-1", in: sources).first?.section, .jtPo)
        XCTAssertTrue(GlobalSearch.search("jt", in: GlobalSearch.Sources()).isEmpty)
    }

    func testSearchResultOpensTheRightPlaceInJt() {
        let store = makeStore()
        store.open(JtSearchEntry(kind: .caseItem, id: "c1", title: "", detail: "", systemImage: "", fields: [], facets: [], caseId: "c1"))
        XCTAssertEqual(store.openRequest?.section, .gantt)
        XCTAssertEqual(store.openRequest?.caseId, "c1")
        XCTAssertEqual(store.openRequest?.query, "", "打開案件時清掉甘特的篩選")

        store.open(JtSearchEntry(kind: .agenda, id: "todo:a", title: "", detail: "", systemImage: "", fields: [], facets: [], date: "2026-10-20"))
        XCTAssertEqual(store.openRequest?.section, .today)
        XCTAssertEqual(store.openRequest?.date, "2026-10-20")

        store.open(JtSearchEntry(kind: .agenda, id: "ms:d", title: "", detail: "", systemImage: "", fields: [], facets: [], caseId: "c2", date: "2026-10-20"))
        XCTAssertEqual(store.openRequest?.caseId, "c2", "里程碑、出貨直接打開案件")

        store.open(JtSearchEntry(kind: .machine, id: "AP25", title: "", detail: "", systemImage: "", fields: [], facets: [], query: "AP25"))
        XCTAssertEqual(store.openRequest?.section, .machines)
        XCTAssertEqual(store.openRequest?.query, "AP25")
    }
}
