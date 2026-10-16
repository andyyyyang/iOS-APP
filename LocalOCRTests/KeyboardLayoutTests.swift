import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import LocalOCR

/// 鍵盤出現時，工作區（頂部列、側欄、分頁內容）不能移動。在模擬器上真的叫出軟體鍵盤來量：
/// 比較鍵盤出現前後，編輯器在畫面上的位置與頂部列的畫面。
@MainActor
final class KeyboardLayoutTests: XCTestCase {
    private var window: UIWindow?
    private let notePath = "鍵盤版面測試/鍵盤版面測試.md"

    override func tearDown() async throws {
        PaletteModel.shared.reset()
        window?.endEditing(true)
        window?.isHidden = true
        window = nil
        try? LocalVault.shared.delete(notePath)
        LocalVault.shared.removeEmptyParents(of: notePath)
    }

    func testTypingInANoteDoesNotMoveTheWorkspace() async throws {
        try LocalVault.shared.writeText((1...80).map { "第 \($0) 行：鍵盤出現時版面不能動。" }.joined(separator: "\n"), to: notePath)
        let workspace = Workspace(defaults: try XCTUnwrap(UserDefaults(suiteName: "keyboard-layout-\(UUID().uuidString)")))
        workspace.openNote(notePath)
        let window = try host(workspace)
        let textView = try await waitFor { Self.find(NoteTextView.self, in: window) }
        try await measure(window, focusing: textView, label: "note")
    }

    /// iPad 橫向：鍵盤佔畫面的比例大很多。
    func testTypingInANoteInLandscapeDoesNotMoveTheWorkspace() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("只在 iPad 量") }
        try LocalVault.shared.writeText((1...80).map { "第 \($0) 行：鍵盤出現時版面不能動。" }.joined(separator: "\n"), to: notePath)
        let workspace = Workspace(defaults: try XCTUnwrap(UserDefaults(suiteName: "keyboard-layout-\(UUID().uuidString)")))
        workspace.openNote(notePath)
        let window = try host(workspace)
        let scene = try XCTUnwrap(window.windowScene)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
            print("[probe] rotate failed: \(error.localizedDescription)")
        }
        try await Task.sleep(for: .seconds(2))
        defer { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
        guard scene.interfaceOrientation.isLandscape else { throw XCTSkip("模擬器沒有轉成橫向") }
        let textView = try await waitFor { Self.find(NoteTextView.self, in: window) }
        try await measure(window, focusing: textView, label: "note-landscape")
    }

    func testSearchingInAToolPageDoesNotMoveTheWorkspace() async throws {
        let workspace = Workspace(defaults: try XCTUnwrap(UserDefaults(suiteName: "keyboard-layout-\(UUID().uuidString)")))
        workspace.open(.contacts)
        let window = try host(workspace)
        // 工具頁自己的搜尋欄（不是頂部列的全域搜尋欄）
        let field = try await waitFor { Self.find(UITextField.self, in: window) { !($0 is SearchTextField) } }
        try await measure(window, focusing: field, label: "tool-search")
    }

    /// App 自己的視窗（WindowGroup 建立、ContentView 的完整畫面，與實際使用時相同），在裡面打字。
    func testTypingInTheAppWindowDoesNotMoveIt() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, "沒有視窗場景")
        let appWindow = try XCTUnwrap(scene.windows.first { $0.rootViewController != nil && !$0.isHidden && $0.windowLevel == .normal }, "找不到 App 的視窗")
        appWindow.makeKeyAndVisible()
        let input: UIView = try await waitFor {
            Self.find(UITextView.self, in: appWindow).map { $0 as UIView } ?? Self.find(UITextField.self, in: appWindow)
        }
        // 首頁的 AI 輸入框本來就會移到鍵盤上方：只比較頂部列
        try await measure(appWindow, focusing: input, label: "app-window-\(type(of: input))", checksInput: false)
    }

    /// 首頁的 AI 輸入列整個在 Home 指示條上面（工作區的內容延伸到指示條下面，輸入列要自己讓開）。
    func testAssistantInputStaysAboveTheHomeIndicator() async throws {
        let workspace = Workspace(defaults: try XCTUnwrap(UserDefaults(suiteName: "keyboard-layout-\(UUID().uuidString)")))
        workspace.open(.start)
        let window = try host(workspace)
        _ = try await waitFor { Self.lowestTextView(in: window) }
        try await Task.sleep(for: .milliseconds(800))
        let input = try XCTUnwrap(Self.lowestTextView(in: window))
        let frame = input.convert(input.bounds, to: window)
        let safeBottom = window.bounds.maxY - window.safeAreaInsets.bottom
        let name = "assistant-input-\(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")"
        print("[probe] \(name): window \(window.bounds.size) safe bottom \(safeBottom) input \(frame)")
        let attachment = XCTAttachment(image: Self.render(window))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // 輸入框下面還有一排 34 點高的按鈕
        XCTAssertLessThanOrEqual(frame.maxY + 34, safeBottom + 1, "\(name)：輸入列底部（\(Int(frame.maxY + 34))）超出安全區域（\(Int(safeBottom))），被 Home 指示條蓋住")
    }

    /// 全域搜尋：輸入關鍵字後結果列表要跟著變（使用者回報過列表不更新）。
    func testSearchResultsFollowTyping() async throws {
        let workspace = Workspace(defaults: try XCTUnwrap(UserDefaults(suiteName: "keyboard-layout-\(UUID().uuidString)")))
        workspace.showsPalette = true
        let window = try host(workspace)
        // 置中面板的搜尋欄（iPad 頂部列也有一個搜尋欄，在畫面最上面）
        let field = try await waitFor {
            Self.find(SearchTextField.self, in: window) { $0.isFirstResponder || $0.convert($0.bounds, to: nil).minY > 60 }
        }
        try await Task.sleep(for: .milliseconds(800))
        let fieldFrame = field.convert(field.bounds, to: window)
        let listArea = CGRect(x: 0, y: fieldFrame.maxY + 48, width: window.bounds.width, height: 260)
        let before = Self.render(window)
        field.insertText("zzqx")
        field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(800))
        let after = Self.render(window)
        let change = Self.difference(before, after, in: listArea, scale: window.screen.scale)
        print("[probe] palette list changed after typing: \(String(format: "%.1f", change * 100))%")
        for (image, suffix) in [(before, "before"), (after, "after")] {
            let attachment = XCTAttachment(image: image)
            attachment.name = "palette-typing-\(suffix)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertGreaterThan(change, 0.02, "輸入關鍵字後結果列表沒有更新")
        // 打空白：前面的字變成關鍵字，輸入欄清空接著打下一個
        field.insertText(" ")
        field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(field.text ?? "", "", "打空白後輸入欄要清空")
    }

    /// iPad 頂部列的搜尋欄可以直接輸入（Apple Pencil 隨手寫也是寫進這個欄位）：一開始輸入，結果列表就在下面展開、
    /// 跟著輸入更新，頂部列不被蓋住；關閉後欄位清空、結束輸入。
    func testTopBarSearchFieldOpensTheResultsList() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("頂部列只在 iPad") }
        let workspace = Workspace(defaults: try XCTUnwrap(UserDefaults(suiteName: "keyboard-layout-\(UUID().uuidString)")))
        workspace.setRightOpen(true)
        let window = try host(workspace)
        let started = Date()
        func mark(_ step: String) { print("[probe] top bar t+\(String(format: "%.1f", Date().timeIntervalSince(started)))s \(step)") }
        let field = try await waitFor { Self.find(SearchTextField.self, in: window) }
        try await Task.sleep(for: .milliseconds(800))
        mark("shown")
        XCTAssertFalse(workspace.showsPalette, "還沒輸入就打開了列表")
        let fieldFrame = field.convert(field.bounds, to: window)
        print("[probe] top bar search field \(fieldFrame)")
        XCTAssertLessThan(fieldFrame.minY, window.safeAreaInsets.top + 52, "搜尋欄不在頂部列")
        // 頂部列以下（列表與變暗的背景）、搜尋欄正下方（結果列表）
        let belowBar = CGRect(x: 0, y: fieldFrame.maxY + 20, width: window.bounds.width, height: 300)
        let listArea = CGRect(x: max(fieldFrame.maxX - 420, 0), y: fieldFrame.maxY + 16, width: min(420, fieldFrame.maxX), height: 200)
        let closed = Self.render(window)

        // 隨手寫：還沒點欄位就寫進字，也要展開列表、字不能被清掉
        field.text = "zzqx"
        field.sendActions(for: .editingChanged)
        mark("wrote zzqx")
        try await Task.sleep(for: .milliseconds(900))
        mark("after wait")
        XCTAssertTrue(workspace.showsPalette, "輸入後沒有展開結果列表")
        XCTAssertEqual(PaletteModel.shared.presentation, .attached, "列表要接在頂部列的搜尋欄下面")
        XCTAssertEqual(field.text ?? "", "zzqx", "寫進的字被清掉了")
        XCTAssertEqual(PaletteModel.shared.query, "zzqx")
        XCTAssertTrue(field.isFirstResponder || field.becomeFirstResponder(), "搜尋欄無法輸入")
        mark("focused")
        let typed = Self.render(window)
        mark("rendered typed")
        let opened = Self.difference(closed, typed, in: belowBar, scale: window.screen.scale)
        print("[probe] top bar list area changed after typing: \(String(format: "%.1f", opened * 100))%")

        // 再改字：列表跟著更新
        field.text = "通訊"
        field.sendActions(for: .editingChanged)
        mark("retyped")
        try await Task.sleep(for: .milliseconds(800))
        let retyped = Self.render(window)
        mark("rendered retyped")
        let updated = Self.difference(typed, retyped, in: listArea, scale: window.screen.scale)
        print("[probe] top bar list changed after retyping: \(String(format: "%.1f", updated * 100))%")
        for (image, suffix) in [(closed, "closed"), (typed, "typed"), (retyped, "retyped")] {
            let attachment = XCTAttachment(image: image)
            attachment.name = "top-bar-search-\(suffix)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertGreaterThan(opened, 0.1, "輸入後頂部列下面沒有出現結果列表")
        XCTAssertGreaterThan(updated, 0.02, "改字後結果列表沒有更新")
        // 頂部列的搜尋欄沒有被列表蓋住：還在原位、還是最上層可以點的
        let center = CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)
        let hit = window.hitTest(center, with: nil)
        XCTAssertTrue(hit === field || hit?.isDescendant(of: field) == true, "頂部列的搜尋欄被列表蓋住（點到的是 \(String(describing: hit.map { type(of: $0) }))）")
        mark("hit tested")

        // 空一格：前面的字變成關鍵字
        field.insertText(" ")
        mark("inserted space")
        field.sendActions(for: .editingChanged)
        mark("sent change")
        try await Task.sleep(for: .milliseconds(300))
        mark("after space wait")
        XCTAssertEqual(PaletteModel.shared.keywords, ["通訊"])
        XCTAssertEqual(field.text ?? "", "")

        // 實驗（Probe 工作流程）：先自己結束輸入，分開量收鍵盤與關列表各花多久
        if ProcessInfo.processInfo.environment["TOPBAR_SPLIT"] == "1" {
            let resigned = field.resignFirstResponder()
            mark("resigned \(resigned)")
            try await Task.sleep(for: .milliseconds(300))
            mark("after resign wait")
        }
        // 關閉：欄位清空、結束輸入
        workspace.showsPalette = false
        mark("closed")
        try await Task.sleep(for: .milliseconds(600))
        mark("after close wait")
        XCTAssertFalse(field.isFirstResponder, "關閉列表後搜尋欄還在輸入")
        XCTAssertEqual(PaletteModel.shared.keywords, [])
        XCTAssertEqual(PaletteModel.shared.presentation, .centered)
    }

    /// iPad 橫向打開鍵盤後，鍵盤上方只剩約 450 點（台前調度的小視窗更矮）。版面中只要有固定高度比這高的內容
    /// （例如一整排固定的按鈕），SwiftUI 就會把整個版面置中排版，頂部列跟著往上推。各種畫面都要放得進 320 點高。
    func testWorkspaceFitsInAShortSpace() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad 的版面") }
        try LocalVault.shared.writeText("# 鍵盤版面測試\n\n內容", to: notePath)
        let cases: [(WorkspaceTab, LeftPanelMode, RightPanelMode)] = [
            (.note(notePath), .files, .memo),
            (.note(notePath), .tools, .outline),
            (.note(notePath), .search, .ai),
            (.note(notePath), .tags, .properties),
            (.start, .files, .outline),
            (.contacts, .tools, .outline),
            (.logistics, .files, .outline),
            (.settings, .files, .outline),
        ]
        for (tab, left, right) in cases {
            let workspace = Workspace(defaults: try XCTUnwrap(UserDefaults(suiteName: "keyboard-layout-\(UUID().uuidString)")))
            workspace.open(tab)
            workspace.showLeft(left)
            workspace.setRightOpen(true)
            workspace.rightMode = right
            let host = UIHostingController(
                rootView: WorkspaceRoot()
                    .environment(workspace)
                    .environment(TemplateLibrary.shared)
                    .environment(ScanDraft())
                    .environment(\.horizontalSizeClass, .regular)
                    .modelContainer(for: ScanRecord.self, inMemory: true)
            )
            let size = host.sizeThatFits(in: CGSize(width: 1376, height: 320))
            print("[probe] fit \(tab.id) left=\(left) right=\(right): \(size)")
            XCTAssertLessThanOrEqual(size.height, 321, "\(tab.id)（左：\(left)，右：\(right)）需要 \(Int(size.height)) 點高，放不進 320 點：矮的畫面打開鍵盤時整個版面會被往上推")
        }
    }

    // MARK: - 量測

    private func measure(_ window: UIWindow, focusing input: UIView, label: String, checksInput: Bool = true) async throws {
        try await Task.sleep(for: .milliseconds(800))
        let frameBefore = input.convert(input.bounds, to: window)
        let before = Self.render(window)

        let keyboard = KeyboardWatcher()
        XCTAssertTrue(input.becomeFirstResponder(), "\(label)：無法開始輸入")
        let deadline = Date().addingTimeInterval(8)
        while keyboard.frame == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let keyboardFrame = keyboard.frame, keyboardFrame.height > 150 else {
            print("[probe] \(label): no software keyboard (frame \(String(describing: keyboard.frame)))")
            throw XCTSkip("模擬器沒有顯示軟體鍵盤（可能接著硬體鍵盤）")
        }
        try await Task.sleep(for: .milliseconds(900))
        let frameAfter = input.convert(input.bounds, to: window)
        let after = Self.render(window)

        let top = window.safeAreaInsets.top
        let topBand = CGRect(x: 0, y: top, width: window.bounds.width, height: 44)
        let topChange = Self.difference(before, after, in: topBand, scale: window.screen.scale)
        let name = "\(label)-\(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")"
        print("[probe] \(name): window \(window.bounds.size) keyboard \(keyboardFrame) input before \(frameBefore) after \(frameAfter) top-bar changed \(String(format: "%.1f", topChange * 100))%")
        for (image, suffix) in [(before, "before"), (after, "after")] {
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(name)-\(suffix)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        if checksInput {
            XCTAssertEqual(frameAfter.minY, frameBefore.minY, accuracy: 1, "\(name)：鍵盤出現後輸入框的位置移動了 \(frameAfter.minY - frameBefore.minY) 點")
        }
        XCTAssertLessThan(topChange, 0.02, "\(name)：鍵盤出現後頂部列的畫面變了 \(Int(topChange * 100))%（整個版面被推動）")
    }

    private func host(_ workspace: Workspace) throws -> UIWindow {
        try host(
            WorkspaceRoot()
                .environment(workspace)
                .environment(TemplateLibrary.shared)
                .environment(ScanDraft())
                .modelContainer(for: ScanRecord.self, inMemory: true)
        )
    }

    private func host<Root: View>(_ root: Root) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, "沒有視窗場景")
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func waitFor<T>(timeout: Double = 10, _ find: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = find() { return found }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw XCTSkip("畫面沒有在時間內出現")
    }

    static func find<T: UIView>(_ type: T.Type, in view: UIView, where matches: (T) -> Bool = { _ in true }) -> T? {
        if let match = view as? T, !match.isHidden, match.window != nil, matches(match) { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview, where: matches) { return match }
        }
        return nil
    }

    /// 畫面最下面的輸入框（首頁的 AI 輸入框）。
    static func lowestTextView(in window: UIWindow) -> UIView? {
        var found: [UIView] = []
        func collect(_ view: UIView) {
            if view is UITextView || view is UITextField, !view.isHidden, view.window != nil { found.append(view) }
            view.subviews.forEach(collect)
        }
        collect(window)
        return found.max { $0.convert($0.bounds, to: window).maxY < $1.convert($1.bounds, to: window).maxY }
    }

    static func render(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// 兩張畫面在 `rect`（點）範圍內不同的像素比例。
    static func difference(_ a: UIImage, _ b: UIImage, in rect: CGRect, scale: CGFloat) -> Double {
        guard let pa = pixels(a, rect: rect, scale: scale), let pb = pixels(b, rect: rect, scale: scale), pa.count == pb.count, !pa.isEmpty else { return 1 }
        var changed = 0
        for index in stride(from: 0, to: pa.count, by: 4) {
            let delta = abs(Int(pa[index]) - Int(pb[index])) + abs(Int(pa[index + 1]) - Int(pb[index + 1])) + abs(Int(pa[index + 2]) - Int(pb[index + 2]))
            if delta > 24 { changed += 1 }
        }
        return Double(changed) / Double(pa.count / 4)
    }

    private static func pixels(_ image: UIImage, rect: CGRect, scale: CGFloat) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        let crop = CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale, width: rect.width * image.scale, height: rect.height * image.scale).integral
        guard let part = cg.cropping(to: crop) else { return nil }
        let width = part.width, height = part.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }
}

/// 記下鍵盤出現後的位置。
private final class KeyboardWatcher: @unchecked Sendable {
    private(set) var frame: CGRect?
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { [weak self] notification in
            self?.frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
