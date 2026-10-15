import XCTest
@testable import LocalOCR

final class GlobalSearchTests: XCTestCase {
    private let sources = GlobalSearch.Sources(
        contacts: [
            JentechContact(order: 0, plant: "大園一廠", dept: "業務課", rawName: "[[王小明]]", ext: "2345", mvpn: "62345"),
            JentechContact(order: 1, plant: "平鎮廠", dept: "品保課", rawName: "陳大華", ext: "5123", mvpn: ""),
            JentechContact(order: 2, plant: "大園二廠", dept: "業務課", rawName: "林美玲", ext: "2399", mvpn: "62399"),
        ],
        codes: [
            JentechCode(kind: .customer, code: "C10023", alias: "ASE", name: "日月光", fullName: "日月光半導體", detail: "封測 高雄", path: "04 客戶/日月光.md"),
            JentechCode(kind: .tcode, code: "VA01", alias: "", name: "建立銷售訂單", fullName: "", detail: "", path: "11 SOP/常用代碼/代碼紀錄/TCode/tc-VA01.md"),
        ],
        models: [
            ModelEntry(code: "0851563HS", path: "05 客戶案件/0851563HS 主卡.md", title: "0851563HS 主卡", aliases: ["T12608029", "60016062"], customer: "Amkor Korea", detail: "44.6x57.6"),
            ModelEntry(code: "CV90-A3316-X1", path: "05 客戶案件/CV90-A3316-X1 主卡.md", title: "CV90-A3316-X1 主卡", aliases: ["A3316"], customer: "Qualcomm", detail: ""),
        ],
        cases: [
            JentechCase(path: "05 客戶案件/開案 Checklist/T12608029.md", file: "T12608029", caseNo: "T12608029", sapNo: "60016062", product: "0851563HS", customer: "Amkor Korea", osat: "", bpmRdmn: "", created: "2026-08-20"),
        ],
        people: [JentechCard(kind: .person, path: "03 人員/王小明.md", name: "王小明", english: "Ming")],
        sops: JentechLogic.sops,
        parcels: []
    )

    private func sections(_ query: String) -> [GlobalSearch.Section] {
        GlobalSearch.search(query, in: sources).map(\.section)
    }

    func testExtensionFindsTheContactFirst() {
        let groups = GlobalSearch.search("2345", in: sources)
        XCTAssertEqual(groups.first?.section, .contacts)
        guard case .contact(let contact)? = groups.first?.hits.first?.target else { return XCTFail("沒有找到聯絡人") }
        XCTAssertEqual(contact.name, "王小明")
    }

    func testEveryWordMustMatch() {
        let groups = GlobalSearch.search("大園 業務", in: sources)
        let contacts = groups.first { $0.section == .contacts }
        XCTAssertEqual(contacts?.total, 2)
        XCTAssertNil(GlobalSearch.search("大園 品保", in: sources).first { $0.section == .contacts })
    }

    func testCaseAndModelShareTheOpeningNumber() {
        let found = sections("T12608029")
        XCTAssertTrue(found.contains(.cases))
        XCTAssertTrue(found.contains(.models))
    }

    func testModelCodesIgnoreDashesCaseAndMissingSuffix() {
        XCTAssertTrue(sections("cv90a3316").contains(.models))
        XCTAssertTrue(sections("0851-563").contains(.models))
        // 手寫常認錯的 O/0 也找得到
        XCTAssertTrue(sections("O851563HS").contains(.models))
    }

    func testCustomersAndTCodes() {
        XCTAssertEqual(GlobalSearch.search("ASE", in: sources).first?.section, .codes)
        XCTAssertEqual(GlobalSearch.search("va01", in: sources).first?.section, .codes)
        XCTAssertTrue(sections("日月光").contains(.codes))
    }

    func testSopTagsWorkWithOrWithoutHash() {
        XCTAssertTrue(sections("fbl5n").contains(.sops))
        XCTAssertTrue(sections("#fbl5n").contains(.sops))
    }

    func testExactMatchesRankAbovePartialOnes() {
        XCTAssertGreaterThan(GlobalSearch.rank("VA01", ["VA01"]) ?? 0, GlobalSearch.rank("VA01", ["VA01N"]) ?? 0)
        XCTAssertGreaterThan(GlobalSearch.rank("VA01", ["VA01N"]) ?? 0, GlobalSearch.rank("VA01", ["XVA01"]) ?? 0)
        XCTAssertNil(GlobalSearch.rank("2345", ["王小明", "5123"]))
        XCTAssertNil(GlobalSearch.search("   ", in: sources).first)
    }

    func testFacetsSuggestKeywordsThatNarrowTheResults() {
        // 「業務」符合兩個廠區的人：建議廠區（各 1 筆），課別每個人都一樣、不能縮小範圍就不列
        let facets = GlobalSearch.facets("業務", in: sources).map(\.text)
        XCTAssertTrue(facets.contains("大園一廠"))
        XCTAssertTrue(facets.contains("大園二廠"))
        XCTAssertFalse(facets.contains("業務課"))
        // 加了廠區之後只剩一筆，沒有可以再加的
        XCTAssertFalse(GlobalSearch.facets("業務 大園一廠", in: sources).map(\.text).contains("大園二廠"))
        XCTAssertEqual(GlobalSearch.search("業務 大園一廠", in: sources).first { $0.section == .contacts }?.total, 1)
    }

    func testScopeOnlySearchesOneSectionAndCanBrowseIt() {
        XCTAssertEqual(GlobalSearch.search("T12608029", in: sources, scope: .cases).map(\.section), [.cases])
        // 只選了區、沒有關鍵字：列出這一區
        let contacts = GlobalSearch.search("", in: sources, scope: .contacts)
        XCTAssertEqual(contacts.first?.total, 3)
        XCTAssertTrue(GlobalSearch.search("", in: sources).isEmpty)
        // 在通訊錄裡，建議依廠區與課別篩選
        XCTAssertTrue(GlobalSearch.facets("", in: sources, scope: .contacts).map(\.text).contains("業務課"))
    }

    func testSectionsAreLimited() {
        let many = (0..<30).map { JentechContact(order: $0, plant: "華亞廠", dept: "業務課", rawName: "業務\($0)", ext: "\(1000 + $0)", mvpn: "") }
        let groups = GlobalSearch.search("業務", in: GlobalSearch.Sources(contacts: many))
        XCTAssertEqual(groups.first?.hits.count, GlobalSearch.Section.contacts.limit)
        XCTAssertEqual(groups.first?.total, 30)
    }
}
