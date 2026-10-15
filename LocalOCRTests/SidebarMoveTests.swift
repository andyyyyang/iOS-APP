import XCTest
@testable import LocalOCR

final class SidebarMoveTests: XCTestCase {
    func testDragPayloadRoundTrips() {
        XCTAssertEqual(TreeDrag.path(from: TreeDrag.payload("工作/會議.md")), "工作/會議.md")
        XCTAssertEqual(TreeDrag.path(from: TreeDrag.payload("附件/圖 1.png")), "附件/圖 1.png")
    }

    func testTextDraggedFromOtherAppsIsNotAFile() {
        XCTAssertNil(TreeDrag.path(from: "工作/會議.md"), "沒有前綴的文字（例如從其他 App 拖進來）不當成檔案")
        XCTAssertNil(TreeDrag.path(from: TreeDrag.prefix))
    }
}
