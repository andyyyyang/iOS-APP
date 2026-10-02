import XCTest
@testable import LocalOCR
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 以使用者實際的 FV60 紀錄驗證規則：AI 只提供文件上的值，其餘由規則算出。
final class TemplateRulesTests: XCTestCase {
    private var sea: ScanTemplate { template("fv60_sea") }
    private var air: ScanTemplate { template("fv60_air") }

    private let fixedDate = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!

    private func template(_ id: String) -> ScanTemplate {
        guard let template = ScanTemplate.bundled.first(where: { $0.id == id }) else {
            XCTFail("App 中找不到內附情境 \(id)")
            return ScanTemplate.builtIns[0]
        }
        return template
    }

    private func apply(_ template: ScanTemplate, to extracted: String) throws -> JSONValue {
        let conformed = try JSONValue.parse(extracted).conformed(to: template.sample)
        return TemplateRules.apply(template.rules, to: conformed, now: fixedDate, makeID: { "testid00001" })
            .conformed(to: template.sample)
    }

    func testBundledFV60TemplatesLoad() {
        XCTAssertEqual(sea.name, "FV60 海運請款（義佳，三家發票）")
        XCTAssertEqual(air.rules.count, 12)
        XCTAssertEqual(sea.rules.count, 14)
        XCTAssertEqual(sea.origin, .builtIn)
    }

    func testSeaRulesReproduceRecord() throws {
        // 2026-09-29 的 JT2609240：AI 讀出三張發票（名稱刻意寫錯，應依統編校正）
        let extracted = #"""
        {"osat":"ATK","caseNo":"JT2609240","billNo":"E1509008","qty":34841,"taxItems":[
          {"name":"樂爾幸","invDate":"2026-09-04","invoice":"FR83149979","taxId":"28006223","taxBase":11020,"taxAmount":551},
          {"name":"義佳有限公司","invDate":"2026-09-03","invoice":"ED17531516","taxId":"22368445","taxBase":1000,"taxAmount":50},
          {"name":"","invDate":"2026-09-03","invoice":"ED17316511","taxId":"12762783","taxBase":500,"taxAmount":25}]}
        """#
        let result = try apply(sea, to: extracted)
        let expected = #"{"id":"testid00001","date":"2026-09-29","supplier":"800000","supplierName":"義佳有限公司","osat":"ATK","caseNo":"JT2609240","billNo":"E1509008","invoice":"FR83149979 / ED17531516 / ED17316511","invDate":"2026-09-29","amount":13146,"expenseAmount":12520,"isMultiItem":true,"taxItems":[{"name":"樂爾幸泛通世","invDate":"2026-09-04","invoice":"FR83149979","taxId":"28006223","taxBase":11020,"taxAmount":551},{"name":"義佳","invDate":"2026-09-03","invoice":"ED17531516","taxId":"22368445","taxBase":1000,"taxAmount":50},{"name":"貳零零","invDate":"2026-09-03","invoice":"ED17316511","taxId":"12762783","taxBase":500,"taxAmount":25}],"qty":34841,"price":0.377,"text":"出口/ATK/JT2609240","docNo":"","done":false}"#
        XCTAssertEqual(result.compactString, expected)
    }

    func testAirRulesReproduceRecord() throws {
        // 2026-09-29 的 JT2609260（萬泰物流 SCK）
        let extracted = #"{"osat":"SCK","caseNo":"JT2609260","invoice":"FR14077356","invDate":"2026-09-22","amount":1556,"qty":1200}"#
        let result = try apply(air, to: extracted)
        let expected = #"{"id":"testid00001","date":"2026-09-29","supplier":"801988","supplierName":"萬泰物流","osat":"SCK","caseNo":"JT2609260","billNo":"","invoice":"FR14077356","invDate":"2026-09-22","amount":1556,"expenseAmount":1556,"isMultiItem":false,"taxItems":[],"qty":1200,"price":1.297,"text":"出口/SCK/JT2609260","docNo":"","done":false}"#
        XCTAssertEqual(result.compactString, expected)
    }

    func testMissingQuantityLeavesPriceNull() throws {
        let result = try apply(air, to: #"{"osat":"ATK","caseNo":"JT2609248","invoice":"FR14077199","invDate":"2026-09-21","amount":12172}"#)
        XCTAssertEqual(result["price"], .null)
        XCTAssertEqual(result["expenseAmount"], .number(12172))
    }

    func testMultiPageMergeThenRules() throws {
        // 第 1 頁：義佳請款單；第 2～4 頁：三張發票；第 5 頁：重複掃到第 2 頁
        let pages = [
            #"{"osat":"ATK","caseNo":"JT2609245","billNo":"E1509025","qty":34841,"taxItems":[]}"#,
            #"{"osat":null,"caseNo":"JT2609245","taxItems":[{"invDate":"2026-09-09","invoice":"FR83150095","taxId":"28006223","taxBase":9660,"taxAmount":483}]}"#,
            #"{"taxItems":[{"invDate":"2026-09-08","invoice":"ED17531542","taxId":"22368445","taxBase":1000,"taxAmount":50}]}"#,
            #"{"taxItems":[{"invDate":"2026-09-08","invoice":"ED17316531","taxId":"12762783","taxBase":500,"taxAmount":25}]}"#,
            #"{"taxItems":[{"invDate":"2026-09-09","invoice":"FR83150095","taxId":"28006223","taxBase":9660,"taxAmount":483}]}"#,
        ].map { try! JSONValue.parse($0).conformed(to: sea.sample) }
        let merged = JSONValue.merged(pages, sample: sea.sample)
        let result = TemplateRules.apply(sea.rules, to: merged, now: fixedDate, makeID: { "x" })
        XCTAssertEqual(result["billNo"]?.stringValue, "E1509025")
        XCTAssertEqual(result["osat"]?.stringValue, "ATK")
        XCTAssertEqual(result["invoice"]?.stringValue, "FR83150095 / ED17531542 / ED17316531")
        XCTAssertEqual(result["amount"], .number(11718))
        XCTAssertEqual(result["expenseAmount"], .number(11160))
        XCTAssertEqual(result["price"], .number(0.336))
        guard case .array(let items)? = result["taxItems"] else { return XCTFail("taxItems 應為陣列") }
        XCTAssertEqual(items.count, 3, "重複的發票應只保留一筆")
    }

    func testRuleTargetsExcludeArrayPaths() {
        let targets = TemplateRules.topLevelTargets(of: sea.rules)
        XCTAssertTrue(targets.isSuperset(of: ["id", "amount", "invoice", "price", "text"]))
        XCTAssertFalse(targets.contains("taxItems"))
        XCTAssertFalse(targets.contains("osat"))
    }

    func testOnlyIfEmptyAndValidation() throws {
        let rules = try JSONValue.parse(#"[{"set":"note","value":"預設","onlyIfEmpty":true}]"#)
        guard case .array(let list) = rules else { return XCTFail() }
        XCTAssertEqual(TemplateRules.apply(list, to: try JSONValue.parse(#"{"note":"已填"}"#))["note"]?.stringValue, "已填")
        XCTAssertEqual(TemplateRules.apply(list, to: try JSONValue.parse(#"{"note":""}"#))["note"]?.stringValue, "預設")
        XCTAssertNil(TemplateRules.validate(rules))
        XCTAssertNotNil(TemplateRules.validate(try JSONValue.parse(#"[{"value":1}]"#)))
        XCTAssertNotNil(TemplateRules.validate(try JSONValue.parse(#"{"set":"a"}"#)))
    }

    func testBase36IDMatchesExistingFormat() {
        let id = TemplateRules.base36TimeID()
        XCTAssertEqual(id.count, 11)
        XCTAssertNotNil(id.range(of: "^[0-9a-z]{11}$", options: .regularExpression))
    }

    func testPageSplittingAndClassificationText() {
        let pages = PageText.split("第一頁\n第二行\n\n第二頁\n\n\n第三頁")
        XCTAssertEqual(pages.count, 3)
        let summary = PageText.classificationText(["A" + String(repeating: "x", count: 1000), "B義佳", "C泛通世"], limit: 900)
        XCTAssertTrue(summary.contains("B義佳"))
        XCTAssertTrue(summary.contains("C泛通世"))
    }

    #if canImport(FoundationModels)
    func testSchemaExcludesRuleTargets() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("需要 iOS 26") }
        XCTAssertNoThrow(try TemplateSchemaBuilder.generationSchema(
            for: sea.sample,
            excluding: TemplateRules.topLevelTargets(of: sea.rules)
        ))
        XCTAssertNoThrow(try TemplateSchemaBuilder.generationSchema(
            for: air.sample,
            excluding: TemplateRules.topLevelTargets(of: air.rules)
        ))
    }
    #endif
}
