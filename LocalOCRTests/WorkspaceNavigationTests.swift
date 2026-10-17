import XCTest
@testable import LocalOCR

/// 往右滑回上一頁的規則。
@MainActor
final class WorkspaceNavigationTests: XCTestCase {
    private func makeWorkspace() -> Workspace {
        let defaults = UserDefaults(suiteName: "workspace-navigation-\(UUID().uuidString)")!
        return Workspace(defaults: defaults)
    }

    func testBackReturnsToTheOpenerAndClosesOpenedTabs() {
        let workspace = makeWorkspace()
        XCTAssertFalse(workspace.canGoBack)
        workspace.open(.folder("客戶"))
        XCTAssertEqual(workspace.tabs, [.folder("客戶")], "首頁原地換成資料夾")
        workspace.open(.tasks)
        XCTAssertEqual(workspace.tabs, [.folder("客戶"), .tasks])
        XCTAssertTrue(workspace.canGoBack)

        XCTAssertTrue(workspace.goBack())
        XCTAssertEqual(workspace.active, .folder("客戶"))
        XCTAssertEqual(workspace.tabs, [.folder("客戶")], "從資料夾開出來的分頁，回去時關掉")

        XCTAssertTrue(workspace.goBack())
        XCTAssertEqual(workspace.active, .start)
        XCTAssertEqual(workspace.tabs, [.start], "原地換掉的頁面換回來")
        XCTAssertFalse(workspace.canGoBack)
        XCTAssertFalse(workspace.goBack())
    }

    func testCloseAllAndCloseOthersFromTheTabMenu() {
        let workspace = makeWorkspace()
        workspace.open(.graph)
        workspace.open(.tasks)
        workspace.open(.jt)
        XCTAssertEqual(workspace.tabs.count, 3)

        workspace.closeOthers(.tasks)
        XCTAssertEqual(workspace.tabs, [.tasks])
        XCTAssertEqual(workspace.active, .tasks)
        XCTAssertFalse(workspace.canGoBack, "關掉的分頁不會再被「上一頁」打開")

        workspace.newTab()
        XCTAssertEqual(workspace.tabs, [.tasks, .start])
        XCTAssertEqual(workspace.active, .start)
        workspace.closeActive()
        XCTAssertEqual(workspace.tabs, [.tasks])

        workspace.open(.graph)
        workspace.closeAll()
        XCTAssertEqual(workspace.tabs, [.start], "全部關閉後留一個空白的新分頁")
        XCTAssertEqual(workspace.active, .start)
        XCTAssertFalse(workspace.canGoBack)
    }

    func testBackAfterSwitchingTabsKeepsBothOpen() {
        let workspace = makeWorkspace()
        workspace.open(.graph)
        workspace.open(.tasks)
        workspace.select(.graph)
        XCTAssertTrue(workspace.goBack())
        XCTAssertEqual(workspace.active, .tasks)
        XCTAssertEqual(workspace.tabs, [.graph, .tasks], "只是切換分頁：回去時兩個分頁都留著")
    }

    func testBackToAClosedPageReopensIt() {
        let workspace = makeWorkspace()
        workspace.open(.graph)
        workspace.open(.tasks)
        workspace.close(.graph)
        XCTAssertEqual(workspace.tabs, [.tasks])
        XCTAssertTrue(workspace.goBack())
        XCTAssertEqual(workspace.active, .graph)
        XCTAssertEqual(workspace.tabs, [.graph], "開出這個分頁的頁面已經關了：原地換回來")
    }

    func testDeletedNotesAreSkipped() {
        let workspace = makeWorkspace()
        workspace.open(.note("不存在的資料夾/已刪除的筆記.md"))
        workspace.open(.tasks)
        // 上一頁是已經不存在的筆記：跳過它，回到更早的首頁
        XCTAssertTrue(workspace.goBack())
        XCTAssertEqual(workspace.active, .start)
    }
}
