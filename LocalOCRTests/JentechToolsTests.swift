import XCTest
@testable import LocalOCR

final class JentechToolsTests: XCTestCase {
    func testParsesTheCompanyDirectoryLikeThePlugin() {
        let markdown = """
        | 廠區 | 主力部門 | 外部電話 | 桌機跨廠直撥 | MVPN 前綴 | 廠區內部跳轉 | 單廠通訊錄 |
        |---|---|---|---|---|---|---|
        | **華亞廠** ⭐ | 業務 / R&D / 行政總部 | (03)211-5678 | `*0910` + 分機 | `26xxx` | [[#華亞]] | [[華亞廠通訊錄]] |

        | 姓名 / 職稱 | 所屬部門 / 課別 | 廠區 | 分機 | MVPN |
        |---|---|---|---|---|
        | [[陳雅婷 Sherry - 課長]] Sherry | 業務四課 (課長) | 華亞廠 | 6651 | 26651 |

        | 廠區 | 部門 | 姓名 / 項目 | 分機 | MVPN |
        |---|---|---|---|---|
        | 華亞廠 | 董事長 | 吳麗淑 | 6124 | 26124 |
        | 華亞廠 | 董事長 | 盧常治 | — | 26648 |
        | **平鎮廠** | 研發 | [[王小明 Ming\\|王小明]] | 7123 | — |
        """
        let contacts = JentechLogic.parseContacts(markdown)
        XCTAssertEqual(contacts.map(\.name), ["吳麗淑", "盧常治", "王小明"])
        XCTAssertEqual(contacts[0].copyValue, "6124")
        XCTAssertEqual(contacts[1].copyValue, "26648")
        XCTAssertEqual(contacts[2].plant, "平鎮廠")
        XCTAssertEqual(contacts[2].linkTarget, "王小明 Ming")
        XCTAssertNil(contacts[0].linkTarget)

        XCTAssertEqual(JentechLogic.displayName("[[陳雅婷 Sherry - 課長]] Sherry"), "陳雅婷 Sherry - 課長")
        XCTAssertEqual(JentechLogic.dialable("26651"), "26651")
        XCTAssertEqual(JentechLogic.dialable("(03)211-5678"), "032115678")
        XCTAssertNil(JentechLogic.dialable("—"))
        XCTAssertTrue(JentechLogic.matches("sherry", ["陳雅婷 Sherry"]))
        XCTAssertTrue(JentechLogic.matches("  ", ["x"]))
    }

    func testReadsCustomersCodesCasesAndCardsFromTheIndex() {
        let notes = [
            VaultIndex.Note(path: "04 客戶/Amkor.md", mtime: 0, properties: ["type": .text("customer"), "name": .text("Amkor Technology"), "alias": .text("AMK"), "credit_account": .text("100123"), "industry": .text("OSAT"), "region": .text("KR")]),
            VaultIndex.Note(path: "11 SOP/常用代碼/代碼紀錄/TCode/tc-VA01.md", mtime: 0, properties: ["type": .text("code"), "code": .text("VA01"), "name": .text("建立銷售訂單"), "detail": .text("ZOR1 量產")]),
            VaultIndex.Note(path: "11 SOP/常用代碼/代碼紀錄/TCode/tc-MM01.md", mtime: 0, properties: ["type": .text("code"), "name": .text("建立料號")]),
            VaultIndex.Note(path: "05 客戶案件/開案 Checklist/A.md", mtime: 0, properties: ["type": .text("checklist"), "case_no": .text("T1"), "created": .text("2026-05-22"), "customer": .text("AECG")]),
            VaultIndex.Note(path: "05 客戶案件/開案 Checklist/B.md", mtime: 0, properties: ["type": .text("checklist"), "case_no": .text("T2"), "created": .text("2026-06-01")]),
            VaultIndex.Note(path: "05 客戶案件/開案 Checklist/C.md", mtime: 0, properties: ["type": .text("checklist"), "case_no": .text("T9")]),
            VaultIndex.Note(path: "03 人員/業務處/陳雅婷 Sherry.md", mtime: 0, properties: ["type": .text("person"), "name": .text("陳雅婷"), "english_name": .text("Sherry")]),
            VaultIndex.Note(path: "雜記.md", mtime: 0, properties: ["type": .text("customer")]),
        ]
        let codes = JentechLogic.codes(from: notes)
        XCTAssertEqual(codes.map(\.displayCode), ["AMK / 100123", "MM01", "VA01"])
        XCTAssertEqual(codes[0].fullName, "Amkor Technology")
        XCTAssertEqual(codes[0].detail, "OSAT KR")
        XCTAssertEqual(codes[1].kind, .tcode)

        XCTAssertEqual(JentechLogic.cases(from: notes).map(\.caseNo), ["T2", "T1", "T9"])

        let cards = JentechLogic.cards(from: notes)
        XCTAssertEqual(cards.map(\.kind), [.customer, .person])
        XCTAssertEqual(cards.first { $0.kind == .person }?.english, "Sherry")
    }

    func testDecodesBpmAndShipments() throws {
        let json = #"{"fetched_at":"2026-10-15 08:30:42","total":2,"stuck_threshold":3,"items":[{"idx":1,"status":"簽核中","process_name":"開案申請","subject":"PLP0261","current_step":"工程","sign_time":"2026/10/10","days_stuck":5,"is_working":false},{"idx":"2","status":"簽核中","process_name":"用印","subject":"NDA","current_step":"法務","sign_time":"","days_stuck":4,"is_working":true}]}"#
        let bpm = try JSONDecoder().decode(JentechBpm.self, from: Data(json.utf8))
        XCTAssertEqual(bpm.items.map(\.idx), ["1", "2"])
        XCTAssertEqual(bpm.stuck.map(\.processName), ["開案申請"])
        XCTAssertEqual(bpm.working.map(\.processName), ["用印"])

        let csv = "\u{FEFF}收件人姓名,收件人電話,收件人手機,收件人地址,代收金額或到付,件數,品名(詳參數表),備註,訂單編號,希望配達時間(詳參數表),出貨日期(YYYY/MM/DD),預定配達日期(YYYY/MM/DD),溫層,尺寸,寄件人姓名,寄件人電話,寄件人手機,寄件人地址,保值金額,品名說明\n林正彬,,'0975256667,406 台中市北屯區軍福十九路298號11樓-3,,1,2,中秋禮盒,2026MOON01,4,2026/09/17,,1,2,健策 Sherry,'032115678,'0933643216,333桃園市龜山區科技一路40號,,中秋禮盒\n\"王, 小明\",'035682538,,\"806 高雄市, 前鎮區\",,1,2,,2026MOON02,4,2026/09/17\n"
        let rows = JentechLogic.parseShipments(csv)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].recipient, "林正彬")
        XCTAssertEqual(rows[0].mobile, "0975256667")
        XCTAssertEqual(rows[0].address, "406 台中市北屯區軍福十九路298號11樓-3")
        XCTAssertEqual(rows[0].orderNo, "2026MOON01")
        XCTAssertEqual(rows[0].item, "中秋禮盒")
        XCTAssertEqual(rows[1].recipient, "王, 小明")
        XCTAssertEqual(rows[1].phone, "035682538")
        XCTAssertEqual(rows[1].address, "806 高雄市, 前鎮區")
    }

    func testCardPathsAndFrontmatterEdits() {
        XCTAssertEqual(JentechLogic.cardPath(kind: .person, values: ["name": "陳雅婷", "english_name": "Sherry", "dept": "業務四課"]), "03 人員/業務四課/陳雅婷 Sherry.md")
        XCTAssertEqual(JentechLogic.cardPath(kind: .person, values: ["name": "王小明"]), "03 人員/業務處/王小明.md")
        XCTAssertEqual(JentechLogic.cardPath(kind: .customer, values: ["name": "日月光", "english_name": "ASE"]), "04 客戶/ASE.md")
        XCTAssertNil(JentechLogic.cardPath(kind: .customer, values: ["name": " "]))

        XCTAssertEqual(JentechLogic.yamlValue("people, sales", isList: true), "[people, sales]")
        XCTAssertEqual(JentechLogic.yamlValue("Note: x", isList: false), "\"Note: x\"")
        XCTAssertEqual(JentechLogic.yamlValue("6651", isList: false), "6651")

        let card = JentechLogic.newCard(fields: [(key: "type", value: "person", isList: false), (key: "name", value: "王小明", isList: false), (key: "ext", value: "", isList: false), (key: "tags", value: "people", isList: true)])
        XCTAssertEqual(card, "---\ntype: person\nname: 王小明\ntags: [people]\n---\n\n# 王小明\n\n## 基本資料\n")

        let note = "---\ntype: person\nname: 王小明\naliases:\n  - Ming\n  - 小明\nnested:\n  a: 1\next: 6100\n---\n# 王小明\n內文 ext: 不要改\n"
        let updated = JentechLogic.updateFrontmatter(note, set: [(key: "ext", value: "6200", isList: false), (key: "aliases", value: "Ming", isList: true), (key: "mvpn", value: "26200", isList: false)], remove: ["type"])
        XCTAssertEqual(updated, "---\nname: 王小明\naliases: [Ming]\nnested:\n  a: 1\next: 6200\nmvpn: 26200\n---\n# 王小明\n內文 ext: 不要改\n")

        XCTAssertEqual(JentechLogic.updateFrontmatter("# 沒有屬性\n", set: [(key: "type", value: "customer", isList: false)], remove: []), "---\ntype: customer\n---\n# 沒有屬性\n")
    }

    func testSopSearch() {
        let billing = JentechLogic.sops.first { $0.file == "SOP - SAP 立帳（VF04 VF03）" }!
        XCTAssertTrue(JentechLogic.sopMatches(billing, "#billing"))
        XCTAssertTrue(JentechLogic.sopMatches(billing, "billing"))
        XCTAssertTrue(JentechLogic.sopMatches(billing, "VF04"))
        XCTAssertFalse(JentechLogic.sopMatches(billing, "#dhl"))
        XCTAssertEqual(Set(JentechLogic.sops.map(\.stage)), Set(JentechLogic.sopStages))
    }
}
