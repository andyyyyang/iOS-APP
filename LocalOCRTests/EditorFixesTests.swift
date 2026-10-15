import UIKit
import XCTest
@testable import LocalOCR

@MainActor
final class EditorFixesTests: XCTestCase {
    func testTableLinksAreTappableAnywhereInTheirCell() throws {
        let font = UIFont.systemFont(ofSize: 15)
        let link = NSAttributedString(string: "客戶 A", attributes: [.font: font, .mdWikiLink: "客戶 A"])
        let plain = NSAttributedString(string: "說明文字", attributes: [.font: font])
        let header = NSAttributedString(string: "名稱", attributes: [.font: UIFont.boldSystemFont(ofSize: 15)])
        let table = MarkdownTableInfo(cells: [[header, header], [link, plain]], hasHeader: true, width: 600)

        let linkPiece = try XCTUnwrap(table.pieces.first { $0.text.string == "客戶 A" })
        // 正中文字
        XCTAssertEqual(table.link(at: CGPoint(x: linkPiece.frame.minX + 2, y: linkPiece.frame.midY)), .wikiLink("客戶 A"))
        // 儲存格中文字右邊的留白也算
        XCTAssertEqual(table.link(at: CGPoint(x: linkPiece.frame.maxX + 4, y: linkPiece.frame.midY)), .wikiLink("客戶 A"))
        // 沒有連結的儲存格
        let plainPiece = try XCTUnwrap(table.pieces.first { $0.text.string == "說明文字" })
        XCTAssertNil(table.link(at: CGPoint(x: plainPiece.frame.midX, y: plainPiece.frame.midY)))

        let two = NSMutableAttributedString(attributedString: link)
        two.append(NSAttributedString(string: "、", attributes: [.font: font]))
        two.append(NSAttributedString(string: "客戶 B", attributes: [.font: font, .mdWikiLink: "客戶 B"]))
        XCTAssertEqual(MarkdownTableInfo.links(in: two), [.wikiLink("客戶 A"), .wikiLink("客戶 B")])
    }

    func testNoteColumnFollowsTheLineWidthSetting() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: NotesSettings.Key.limitsLineWidth)
        defer { defaults.set(saved, forKey: NotesSettings.Key.limitsLineWidth) }
        defaults.set(false, forKey: NotesSettings.Key.limitsLineWidth)
        XCTAssertEqual(NoteTextView.columnWidth, .infinity)
        defaults.set(true, forKey: NotesSettings.Key.limitsLineWidth)
        XCTAssertEqual(NoteTextView.columnWidth, NoteTextView.readableColumnWidth)
        XCTAssertEqual(NoteTextView.horizontalPadding(compact: true), 18)
        XCTAssertEqual(NoteTextView.horizontalPadding(compact: false), 32)
    }
}
