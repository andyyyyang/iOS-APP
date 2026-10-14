import XCTest
@testable import LocalOCR

final class VaultIndexTests: XCTestCase {
    func testDecodesTheServerIndexWithMissingFields() throws {
        let json = #"""
        {"version":1,"notes":[
          {"path":"工作/週報.md","mtime":1760400000000,"size":120,"etag":"\"e\"","title":"週報","aliases":["weekly"],"tags":["work"],
           "links":["專案 A","工作/會議#決議"],"firstEmbed":"圖.png","tasks":[{"text":"寄信","done":false},{"text":"開會","done":true}],
           "snippet":"本週重點","notebook":null},
          {"path":"收件匣/想法.md","mtime":1760300000000}
        ],"files":[{"path":"圖.png","mtime":1760300000000,"size":2048}]}
        """#
        let index = try JSONDecoder().decode(VaultIndex.self, from: Data(json.utf8))
        XCTAssertEqual(index.notes.count, 2)
        XCTAssertEqual(index.files.first?.size, 2048)

        let summary = index.notes[0].summary()
        XCTAssertEqual(summary.title, "週報")
        XCTAssertEqual(summary.folder, "工作")
        XCTAssertFalse(summary.isLocal)
        XCTAssertEqual(summary.aliases, ["weekly"])
        XCTAssertEqual(summary.links, ["專案 A", "工作/會議#決議"])
        XCTAssertEqual(summary.tasks.map(\.text), ["寄信", "開會"])
        XCTAssertEqual(summary.tasks.map(\.index), [0, 1])
        XCTAssertEqual(summary.tasks.first?.notePath, "工作/週報.md")
        XCTAssertNil(summary.notebookID)
        XCTAssertEqual(summary.mtime, Date(timeIntervalSince1970: 1_760_400_000))

        let bare = index.notes[1].summary()
        XCTAssertEqual(bare.title, "想法", "沒有 title 時用檔名")
        XCTAssertTrue(bare.links.isEmpty)
    }

    func testIndexedNotesResolveLinksAndAliases() {
        let notes = [
            VaultIndex.Note(path: "工作/週報.md", mtime: 0, aliases: ["weekly"], links: ["專案 A"]).summary(),
            VaultIndex.Note(path: "專案 A.md", mtime: 0).summary(),
        ]
        let index = NoteLinks.index(notes)
        XCTAssertEqual(NoteLinks.resolve("weekly", in: index), "工作/週報.md")
        XCTAssertEqual(NoteLinks.resolve("專案 A", in: index), "專案 A.md")
    }
}
