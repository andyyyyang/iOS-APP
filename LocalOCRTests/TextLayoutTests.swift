import XCTest
@testable import LocalOCR

final class TextLayoutTests: XCTestCase {
    func testConvertsVisionRectToTopLeftOrigin() {
        let rect = TextLayout.topLeftNormalizedRect(fromVision: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.2))
        assertRect(rect, equals: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2))
    }

    func testAspectFitRectCentersWideImageVertically() {
        let frame = TextLayout.aspectFitRect(imageSize: CGSize(width: 200, height: 100), in: CGSize(width: 100, height: 100))
        assertRect(frame, equals: CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    func testAspectFitRectCentersTallImageHorizontally() {
        let frame = TextLayout.aspectFitRect(imageSize: CGSize(width: 100, height: 400), in: CGSize(width: 200, height: 200))
        assertRect(frame, equals: CGRect(x: 75, y: 0, width: 50, height: 200))
    }

    func testAspectFitRectReturnsZeroForEmptySizes() {
        XCTAssertEqual(TextLayout.aspectFitRect(imageSize: .zero, in: CGSize(width: 100, height: 100)), .zero)
        XCTAssertEqual(TextLayout.aspectFitRect(imageSize: CGSize(width: 10, height: 10), in: .zero), .zero)
    }

    func testDenormalizeMapsIntoDisplayFrame() {
        let rect = TextLayout.denormalize(
            CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.1),
            into: CGRect(x: 10, y: 20, width: 200, height: 100)
        )
        assertRect(rect, equals: CGRect(x: 110, y: 70, width: 50, height: 10))
    }

    func testJoinedTextGroupsSameRowAndSortsLeftToRight() {
        let lines = [
            line("World", x: 0.5, y: 0.10),
            line("Second", x: 0.1, y: 0.30),
            line("Hello", x: 0.1, y: 0.11),
        ]
        XCTAssertEqual(TextLayout.joinedText(lines), "Hello World\nSecond")
    }

    func testJoinedTextKeepsBarelyOverlappingLinesApart() {
        let lines = [
            line("B", x: 0.1, y: 0.14),
            line("A", x: 0.1, y: 0.10),
        ]
        XCTAssertEqual(TextLayout.joinedText(lines), "A\nB")
    }

    func testReadingOrderFlattensRows() {
        let lines = [
            line("3", x: 0.1, y: 0.5),
            line("2", x: 0.6, y: 0.1),
            line("1", x: 0.1, y: 0.1),
        ]
        XCTAssertEqual(TextLayout.readingOrder(lines).map(\.text), ["1", "2", "3"])
    }

    func testJoinedTextOfEmptyInputIsEmpty() {
        XCTAssertEqual(TextLayout.joinedText([]), "")
    }

    // MARK: - Helpers

    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 0.3, height: CGFloat = 0.05) -> RecognizedLine {
        RecognizedLine(text: text, confidence: 1, boundingBox: CGRect(x: x, y: y, width: width, height: height))
    }

    private func assertRect(_ rect: CGRect, equals expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        let accuracy: CGFloat = 1e-9
        XCTAssertEqual(rect.minX, expected.minX, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: accuracy, "height", file: file, line: line)
    }
}
