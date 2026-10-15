import XCTest
@testable import LocalOCR

final class LogisticsTests: XCTestCase {
    func testDecodesTheServerList() throws {
        let json = #"""
        {"items":[{"tracking_number":"909556582781","courier_code":"t-cat","courier_name":"黑貓宅急便","note":"中秋禮盒","status":"delivered","is_archived":false,
          "latest_event":"順利送達 [北高營業所]","latest_time":"2026/10/05 15:40",
          "trackinfo":[{"checkpoint_date":"2026/10/05 15:40","location":"北高營業所","tracking_detail":"順利送達 [北高營業所]"}],
          "updated_at":"2026-10-15T01:02:00.000Z","extra_desktop_field":1}],
         "couriers":[{"code":"t-cat","name":"黑貓宅急便","url":"https://www.t-cat.com.tw/Inquire/Trace.aspx?BillID={number}","live":true}],
         "statuses":[{"id":"transit","label":"運送中","color":"#2563eb"}],
         "dhl":false,"track17":true,
         "refresh":{"intervalMinutes":120,"running":false,"lastRunAt":null,"lastRefreshed":0,"lastError":null},
         "path":"06 日誌/物流追蹤/watchlist.json"}
        """#
        let list = try LogisticsClient.decoder.decode(LogisticsClient.List.self, from: Data(json.utf8))
        XCTAssertEqual(list.items.count, 1)
        let item = try XCTUnwrap(list.items.first)
        XCTAssertEqual(item.trackingNumber, "909556582781")
        XCTAssertEqual(item.courierName, "黑貓宅急便")
        XCTAssertFalse(item.isArchived)
        XCTAssertEqual(item.trackinfo.first?.trackingDetail, "順利送達 [北高營業所]")
        XCTAssertEqual(list.refresh.intervalMinutes, 120)
        XCTAssertNil(list.refresh.lastRunAt)
        XCTAssertTrue(list.track17)
        XCTAssertEqual(list.couriers.first?.live, true)

        let linked = #"{"notes":[{"path":"05 客戶案件/RFQ.md","name":"RFQ","customer":"Qualcomm","caseNo":"RFQ-2608-01","trackingNumber":"784920194820","courier":"fedex","courierName":"FedEx 聯邦快遞","tracked":false}]}"#
        struct Body: Decodable { var notes: [LogisticsClient.LinkedNote] }
        let notes = try LogisticsClient.decoder.decode(Body.self, from: Data(linked.utf8)).notes
        XCTAssertEqual(notes.first?.caseNo, "RFQ-2608-01")
        XCTAssertEqual(notes.first?.trackingNumber, "784920194820")
    }

    func testGuessesCouriersAndRecognizesTrackingNumbers() {
        XCTAssertEqual(LogisticsLogic.guessCourier("SF1234567890123"), "sf-express")
        XCTAssertEqual(LogisticsLogic.guessCourier("1Z999AA10123456784"), "ups")
        XCTAssertEqual(LogisticsLogic.guessCourier("1234567890"), "dhl")
        XCTAssertEqual(LogisticsLogic.guessCourier("9095 5658 2781"), "t-cat")
        XCTAssertEqual(LogisticsLogic.guessCourier("784920194820"), "fedex")
        XCTAssertNil(LogisticsLogic.guessCourier("abc"))

        XCTAssertEqual(LogisticsLogic.normalize(" 9095 5658\n2781 "), "909556582781")
        XCTAssertTrue(LogisticsLogic.looksLikeTrackingNumber("9095-5658-2781"))
        XCTAssertTrue(LogisticsLogic.looksLikeTrackingNumber("SF0217035697020"))
        XCTAssertFalse(LogisticsLogic.looksLikeTrackingNumber("黑貓宅急便"))
        XCTAssertFalse(LogisticsLogic.looksLikeTrackingNumber("ABCDEFGHIJ"))
        XCTAssertFalse(LogisticsLogic.looksLikeTrackingNumber("12345"))

        XCTAssertEqual(TrackingNumberScanner.Coordinator.trackingNumber(in: "託運單號：909556582781 收件人"), "909556582781")
        XCTAssertEqual(TrackingNumberScanner.Coordinator.trackingNumber(in: "單號909556582781"), "909556582781")
        XCTAssertNil(TrackingNumberScanner.Coordinator.trackingNumber(in: "收件人 王小明"))
    }

    func testTrackingLinksAndTheCopiedTable() {
        XCTAssertEqual(
            LogisticsLogic.trackingURL(template: "https://www.t-cat.com.tw/Inquire/Trace.aspx?BillID={number}", number: "909556582781")?.absoluteString,
            "https://www.t-cat.com.tw/Inquire/Trace.aspx?BillID=909556582781"
        )
        XCTAssertEqual(LogisticsLogic.trackingURL(template: nil, number: "X1")?.absoluteString, "https://t.17track.net/zh-tw#nums=X1")

        let statuses = [LogisticsClient.Status(id: "transit", label: "運送中", color: "#2563eb")]
        let active = LogisticsClient.Item(
            trackingNumber: "909556582781", courierCode: "t-cat", courierName: "黑貓宅急便", note: "A|B", status: "transit", isArchived: false,
            latestEvent: "配送中 [北高營業所]", latestTime: "2026/10/05 09:15", trackinfo: [], updatedAt: ""
        )
        var archived = active
        archived.trackingNumber = "1"
        archived.isArchived = true
        XCTAssertEqual(
            LogisticsLogic.markdownTable([active, archived], statuses: statuses),
            "| 狀態 | 物流商 | 單號 | 案件說明 | 最新動態 | 時間 |\n|---|---|---|---|---|---|\n| 運送中 | 黑貓宅急便 | `909556582781` | A\\|B | 配送中 [北高營業所] | 2026/10/05 09:15 |\n"
        )
    }

    func testRecognizesTheDesktopToolNote() {
        XCTAssertTrue(LogisticsLogic.isToolNote(path: "99 工具/物流追蹤.md", text: nil))
        XCTAssertTrue(LogisticsLogic.isToolNote(path: "tools/tracker.md", text: "```dataviewjs\nconst pyScript = path.join(vaultBase, \"scripts\", \"logistics_tracker.py\");\n```"))
        XCTAssertFalse(LogisticsLogic.isToolNote(path: "04 客戶/萬泰物流.md", text: "物流"))
        XCTAssertEqual(LogisticsPage.interval(120), "2 小時")
        XCTAssertEqual(LogisticsPage.interval(45), "45 分鐘")
        XCTAssertNotNil(LogisticsPage.parseDate("2026-10-15T01:02:00.000Z"))
    }
}
