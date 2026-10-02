import XCTest
@testable import LocalOCR

final class JSONValueTests: XCTestCase {
    func testParsePreservesKeyOrder() throws {
        let value = try JSONValue.parse(#"{"z":1,"a":{"y":true,"b":null},"m":[1,"x"]}"#)
        guard case .object(let members) = value else { return XCTFail("應為物件") }
        XCTAssertEqual(members.map(\.key), ["z", "a", "m"])
        XCTAssertEqual(value.compactString, #"{"z":1,"a":{"y":true,"b":null},"m":[1,"x"]}"#)
    }

    func testParseStringsAndEscapes() throws {
        let value = try JSONValue.parse(#"{"text":"第一行\n「引號」\"\\ é 😀"}"#)
        XCTAssertEqual(value["text"]?.stringValue, "第一行\n「引號」\"\\ é 😀")
    }

    func testParseNumbers() throws {
        let value = try JSONValue.parse("[0, -12, 3.5, 1e3, -2.5E-2]")
        XCTAssertEqual(value, .array([.number(0), .number(-12), .number(3.5), .number(1000), .number(-0.025)]))
    }

    func testParseRejectsInvalidJSON() {
        XCTAssertThrowsError(try JSONValue.parse(#"{"a":1,}"#))
        XCTAssertThrowsError(try JSONValue.parse(#"{"a" 1}"#))
        XCTAssertThrowsError(try JSONValue.parse("[1, 2"))
        XCTAssertThrowsError(try JSONValue.parse("{} extra"))
    }

    func testPrettyPrinted() throws {
        let value = try JSONValue.parse(#"{"name":"王小明","phones":["02-1234"],"empty":[],"nested":{}}"#)
        XCTAssertEqual(value.prettyPrinted(), """
        {
          "name": "王小明",
          "phones": [
            "02-1234"
          ],
          "empty": [],
          "nested": {}
        }
        """)
    }

    func testIntegersPrintWithoutDecimalPoint() {
        XCTAssertEqual(JSONValue.number(45).compactString, "45")
        XCTAssertEqual(JSONValue.number(-3).compactString, "-3")
        XCTAssertEqual(JSONValue.number(12.5).compactString, "12.5")
    }

    func testQuoteEscapesControlCharacters() {
        XCTAssertEqual(JSONValue.string("a\"b\\c\nd\u{01}").compactString, #""a\"b\\c\nd\u0001""#)
    }

    func testRoundTrip() throws {
        let text = #"{"store":"全聯","items":[{"name":"鮮乳","quantity":1,"price":45.5}],"paid":true,"note":null}"#
        XCTAssertEqual(try JSONValue.parse(text).compactString, text)
        XCTAssertEqual(try JSONValue.parse(JSONValue.parse(text).prettyPrinted()).compactString, text)
    }

    // MARK: - conformed(to:)

    func testConformedReordersFillsAndDropsKeys() throws {
        let sample = try JSONValue.parse(#"{"store":"","date":"","total":0}"#)
        let generated = try JSONValue.parse(#"{"total":45,"extra":"x","store":"全聯"}"#)
        XCTAssertEqual(generated.conformed(to: sample).compactString, #"{"store":"全聯","date":null,"total":45}"#)
    }

    func testConformedConvertsTypes() throws {
        let sample = try JSONValue.parse(#"{"price":0,"paid":false,"code":"","tags":["a"]}"#)
        let generated = try JSONValue.parse(#"{"price":"1,234","paid":"是","code":42,"tags":"單一"}"#)
        XCTAssertEqual(generated.conformed(to: sample).compactString, #"{"price":1234,"paid":true,"code":"42","tags":["單一"]}"#)
    }

    func testConformedHandlesNestedArraysOfObjects() throws {
        let sample = try JSONValue.parse(#"{"items":[{"name":"","price":0}]}"#)
        let generated = try JSONValue.parse(#"{"items":[{"price":"10","name":"A","x":1},{"name":"B"}]}"#)
        XCTAssertEqual(
            generated.conformed(to: sample).compactString,
            #"{"items":[{"name":"A","price":10},{"name":"B","price":null}]}"#
        )
    }

    func testConformedInvalidNumberBecomesNull() throws {
        let sample = try JSONValue.parse(#"{"total":0}"#)
        XCTAssertEqual(try JSONValue.parse(#"{"total":"約一百"}"#).conformed(to: sample).compactString, #"{"total":null}"#)
    }
}
