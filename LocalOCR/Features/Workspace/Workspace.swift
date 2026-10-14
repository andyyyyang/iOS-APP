import Observation
import SwiftUI

/// 工作區中間的一個分頁：筆記、資料夾、關聯圖、待辦，或掃描等工具。
enum WorkspaceTab: Hashable, Identifiable {
    case start
    case note(String)
    case folder(String)
    case graph
    case tasks
    case drawings
    case scan
    case history
    case settings

    var id: String {
        switch self {
        case .start: return "start"
        case .note(let path): return "note:" + path
        case .folder(let path): return "folder:" + path
        case .graph: return "graph"
        case .tasks: return "tasks"
        case .drawings: return "drawings"
        case .scan: return "scan"
        case .history: return "history"
        case .settings: return "settings"
        }
    }

    init?(id: String) {
        if id.hasPrefix("note:") {
            self = .note(String(id.dropFirst(5)))
            return
        }
        if id.hasPrefix("folder:") {
            self = .folder(String(id.dropFirst(7)))
            return
        }
        switch id {
        case "start": self = .start
        case "graph": self = .graph
        case "tasks": self = .tasks
        case "drawings": self = .drawings
        case "scan": self = .scan
        case "history": self = .history
        case "settings": self = .settings
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .start: return "知識庫"
        case .note(let path): return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        case .folder(let path):
            guard !path.isEmpty else { return NotesSettings.vaultName.isEmpty ? "Vault" : NotesSettings.vaultName }
            return (path as NSString).lastPathComponent
        case .graph: return "關聯圖"
        case .tasks: return "待辦"
        case .drawings: return "圖面"
        case .scan: return "掃描"
        case .history: return "掃描紀錄"
        case .settings: return "設定"
        }
    }

    var systemImage: String {
        switch self {
        case .start: return "sparkles"
        case .note: return "doc.text"
        case .folder: return "folder"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .tasks: return "checkmark.square"
        case .drawings: return "square.stack.3d.up"
        case .scan: return "viewfinder"
        case .history: return "clock"
        case .settings: return "slider.horizontal.3"
        }
    }

    var notePath: String? {
        if case .note(let path) = self { return path }
        return nil
    }
}

/// 左側欄的內容（功能列上方的三個按鈕）。
enum LeftPanelMode: String, CaseIterable, Identifiable {
    case files
    case search
    case tags

    var id: Self { self }

    var title: String {
        switch self {
        case .files: return "檔案"
        case .search: return "搜尋"
        case .tags: return "標籤"
        }
    }

    var systemImage: String {
        switch self {
        case .files: return "folder"
        case .search: return "magnifyingglass"
        case .tags: return "tag"
        }
    }
}

/// 右側欄的內容（目前筆記的資訊）。
enum RightPanelMode: String, CaseIterable, Identifiable {
    case outline
    case links
    case properties
    case ai

    var id: Self { self }

    var title: String {
        switch self {
        case .outline: return "大綱"
        case .links: return "連結"
        case .properties: return "屬性"
        case .ai: return "AI"
        }
    }
}

/// 大綱跳轉：捲動筆記到某個標題。
struct RevealRequest: Equatable {
    let path: String
    let heading: NoteHeading
    let id = UUID()
}

/// 開啟 [[筆記#標題]]、[[筆記#^區塊]] 後要跳到的位置，由開著這則筆記的畫面處理。
struct AnchorRequest: Equatable {
    let path: String
    let anchor: String
    let id = UUID()
}

/// 右側欄對筆記內容的修改（例如把 AI 摘要加到筆記），由開著這則筆記的畫面套用。
struct EditRequest: Equatable {
    let path: String
    let transform: (String) -> String
    let id = UUID()

    static func == (lhs: EditRequest, rhs: EditRequest) -> Bool { lhs.id == rhs.id }
}

/// 工作區的狀態（像 Obsidian）：開啟的分頁、左右側欄（可收合、可調整寬度）、指令面板。
/// 側欄與分頁會記住，下次開啟 App 時還原。
@MainActor
@Observable
final class Workspace {
    private(set) var tabs: [WorkspaceTab] = [.start]
    private(set) var active: WorkspaceTab = .start

    var leftMode: LeftPanelMode = .files
    private(set) var isLeftOpen = true
    private(set) var isRightOpen = true
    private(set) var leftWidth: CGFloat = 264
    private(set) var rightWidth: CGFloat = 300
    var rightMode: RightPanelMode = .outline
    private(set) var expandedFolders: Set<String> = []

    var showsPalette = false
    var showsCamera = false
    var showsPairing = false
    var pendingDelete: NoteSummary?

    /// 開著的筆記目前的文字（含尚未存檔的修改），右側大綱與 AI 使用。
    var liveText: [String: String] = [:]
    var revealRequest: RevealRequest?
    var anchorRequest: AnchorRequest?
    var editRequest: EditRequest?
    /// Apple Intelligence 對各筆記的整理結果（切換面板時保留）。
    var insights: [String: NoteInsights] = [:]

    /// 上一頁（像瀏覽器）：之前看過的頁面。`closesCurrent` 表示目前的分頁是從那一頁開出來的，回去時關掉它（或原地換回）。
    private struct BackEntry {
        let page: WorkspaceTab
        let closesCurrent: Bool
    }
    private var backStack: [BackEntry] = []

    /// 黑色功能列的寬度。
    static let railWidth: CGFloat = 56
    static let leftWidthRange: ClosedRange<CGFloat> = 220...440
    static let rightWidthRange: ClosedRange<CGFloat> = 260...460
    private static let maxTabs = 10
    private static let maxBack = 50

    private enum Key {
        static let tabs = "workspace.tabs"
        static let active = "workspace.active"
        static let leftOpen = "workspace.leftOpen"
        static let rightOpen = "workspace.rightOpen"
        static let leftWidth = "workspace.leftWidth"
        static let rightWidth = "workspace.rightWidth"
        static let expanded = "workspace.expandedFolders"
    }

    private let defaults: UserDefaults
    private let store: NotesStore

    init(defaults: UserDefaults = .standard, store: NotesStore? = nil) {
        self.defaults = defaults
        let store = store ?? .shared
        self.store = store
        if defaults.object(forKey: Key.leftOpen) != nil { isLeftOpen = defaults.bool(forKey: Key.leftOpen) }
        if defaults.object(forKey: Key.rightOpen) != nil { isRightOpen = defaults.bool(forKey: Key.rightOpen) }
        let left = CGFloat(defaults.double(forKey: Key.leftWidth))
        if left > 0 { leftWidth = min(max(left, Self.leftWidthRange.lowerBound), Self.leftWidthRange.upperBound) }
        let right = CGFloat(defaults.double(forKey: Key.rightWidth))
        if right > 0 { rightWidth = min(max(right, Self.rightWidthRange.lowerBound), Self.rightWidthRange.upperBound) }
        expandedFolders = Set(defaults.stringArray(forKey: Key.expanded) ?? [])
        let vault = store.vault
        let restored = (defaults.stringArray(forKey: Key.tabs) ?? []).compactMap(WorkspaceTab.init(id:)).filter { tab in
            if let path = tab.notePath { return vault.exists(path) }
            return true
        }
        if !restored.isEmpty {
            tabs = restored
            active = defaults.string(forKey: Key.active).flatMap(WorkspaceTab.init(id:)).flatMap { restored.contains($0) ? $0 : nil } ?? restored[0]
        }
    }

    var activeNotePath: String? { active.notePath }

    /// 新筆記放的位置：目前的資料夾分頁、目前筆記所在的資料夾，否則是設定中的位置。
    var currentFolder: String {
        switch active {
        case .folder(let folder): return folder
        case .note(let path): return (path as NSString).deletingLastPathComponent
        default: return NotesSettings.defaultFolder
        }
    }

    // MARK: - 分頁

    /// 開啟（已經開著就切換過去）；目前是空白的新分頁時直接取代它。
    func open(_ tab: WorkspaceTab) {
        let previous = active
        let wasOpen = tabs.contains(tab)
        if !wasOpen {
            if active == .start, let index = tabs.firstIndex(of: .start) {
                tabs[index] = tab
            } else {
                let insertAt = (tabs.firstIndex(of: active) ?? tabs.count - 1) + 1
                tabs.insert(tab, at: min(insertAt, tabs.count))
                while tabs.count > Self.maxTabs, let oldest = tabs.first(where: { $0 != tab }) {
                    tabs.removeAll { $0 == oldest }
                }
            }
        }
        active = tab
        if previous != tab { pushBack(previous, closesCurrent: !wasOpen) }
        saveTabs()
    }

    func openNote(_ path: String) {
        open(.note(path))
    }

    func select(_ tab: WorkspaceTab) {
        guard tabs.contains(tab) else { return }
        if tab != active { pushBack(active, closesCurrent: false) }
        active = tab
        saveTabs()
    }

    func close(_ tab: WorkspaceTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        if let path = tab.notePath { liveText[path] = nil }
        if tabs.isEmpty { tabs = [.start] }
        if active == tab { active = tabs[min(index, tabs.count - 1)] }
        saveTabs()
    }

    func closeActive() {
        close(active)
    }

    func newTab() {
        let wasOpen = tabs.contains(.start)
        if !wasOpen { tabs.append(.start) }
        if active != .start { pushBack(active, closesCurrent: !wasOpen) }
        active = .start
        saveTabs()
    }

    // MARK: - 上一頁

    /// 有沒有上一頁可以回去（往右滑、上一頁按鈕）。
    var canGoBack: Bool {
        backStack.contains { $0.page != active && isAvailable($0.page) }
    }

    /// 回到上一頁：目前的分頁是從那一頁開出來的就關掉（那一頁已經關了就原地換回）；只是切換過來的就切回去。
    @discardableResult
    func goBack() -> Bool {
        while let entry = backStack.popLast() {
            guard entry.page != active, isAvailable(entry.page) else { continue }
            let current = active
            if entry.closesCurrent, let index = tabs.firstIndex(of: current) {
                if tabs.contains(entry.page) {
                    tabs.remove(at: index)
                    if let path = current.notePath { liveText[path] = nil }
                } else {
                    tabs[index] = entry.page
                }
            } else if !tabs.contains(entry.page) {
                let insertAt = (tabs.firstIndex(of: current) ?? tabs.count - 1) + 1
                tabs.insert(entry.page, at: min(insertAt, tabs.count))
            }
            active = entry.page
            saveTabs()
            return true
        }
        return false
    }

    private func pushBack(_ page: WorkspaceTab, closesCurrent: Bool) {
        backStack.append(BackEntry(page: page, closesCurrent: closesCurrent))
        if backStack.count > Self.maxBack { backStack.removeFirst(backStack.count - Self.maxBack) }
    }

    /// 刪掉的筆記不能回去。
    private func isAvailable(_ tab: WorkspaceTab) -> Bool {
        guard let path = tab.notePath else { return true }
        return store.vault.exists(path) || store.notes.contains { $0.path == path }
    }

    func selectAdjacentTab(_ step: Int) {
        guard let index = tabs.firstIndex(of: active), tabs.count > 1 else { return }
        select(tabs[(index + step + tabs.count) % tabs.count])
    }

    /// 筆記改名後更新分頁。
    func renameNote(from old: String, to new: String) {
        tabs = tabs.map { $0 == .note(old) ? .note(new) : $0 }
        if active == .note(old) { active = .note(new) }
        backStack = backStack.map { $0.page == .note(old) ? BackEntry(page: .note(new), closesCurrent: $0.closesCurrent) : $0 }
        liveText[new] = liveText.removeValue(forKey: old)
        saveTabs()
    }

    private func saveTabs() {
        defaults.set(tabs.map(\.id), forKey: Key.tabs)
        defaults.set(active.id, forKey: Key.active)
    }

    // MARK: - 側欄

    func toggleLeft() {
        setLeftOpen(!isLeftOpen)
    }

    func toggleRight() {
        setRightOpen(!isRightOpen)
    }

    func setLeftOpen(_ open: Bool) {
        isLeftOpen = open
        defaults.set(open, forKey: Key.leftOpen)
    }

    func setRightOpen(_ open: Bool) {
        isRightOpen = open
        defaults.set(open, forKey: Key.rightOpen)
    }

    /// 功能列的按鈕：再按一次目前的面板就收起側欄（同 Obsidian）。
    func showLeft(_ mode: LeftPanelMode) {
        if isLeftOpen && leftMode == mode {
            setLeftOpen(false)
        } else {
            leftMode = mode
            setLeftOpen(true)
        }
    }

    func showRight(_ mode: RightPanelMode) {
        rightMode = mode
        setRightOpen(true)
    }

    func setLeftWidth(_ width: CGFloat, persist: Bool) {
        leftWidth = min(max(width, Self.leftWidthRange.lowerBound), Self.leftWidthRange.upperBound)
        if persist { defaults.set(Double(leftWidth), forKey: Key.leftWidth) }
    }

    func setRightWidth(_ width: CGFloat, persist: Bool) {
        rightWidth = min(max(width, Self.rightWidthRange.lowerBound), Self.rightWidthRange.upperBound)
        if persist { defaults.set(Double(rightWidth), forKey: Key.rightWidth) }
    }

    func isExpanded(_ folder: String) -> Bool {
        expandedFolders.contains(folder)
    }

    func toggleFolder(_ folder: String) {
        if expandedFolders.contains(folder) {
            expandedFolders.remove(folder)
        } else {
            expandedFolders.insert(folder)
        }
        defaults.set(Array(expandedFolders), forKey: Key.expanded)
    }

    /// 展開到某個檔案所在的資料夾（在檔案樹中顯示目前的筆記）。
    func reveal(path: String) {
        var folder = (path as NSString).deletingLastPathComponent
        while !folder.isEmpty {
            expandedFolders.insert(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        defaults.set(Array(expandedFolders), forKey: Key.expanded)
    }

    // MARK: - 筆記

    @discardableResult
    func newTextNote(in folder: String? = nil, body: String = "") -> String? {
        let title = "未命名 " + Date().formatted(.dateTime.month().day().hour().minute())
        guard let path = try? store.createTextNote(in: folder ?? currentFolder, title: title) else { return nil }
        if !body.isEmpty { try? store.save(body, to: path) }
        reveal(path: path)
        openNote(path)
        return path
    }

    func newTaskNote(in folder: String? = nil) {
        newTextNote(in: folder, body: "- [ ] ")
    }

    /// 新增手寫筆記：直接建立空白畫布並開啟，可以馬上書寫（標題與紙張之後在筆記上方改）。
    func newNotebook(in folder: String? = nil) {
        let title = "手寫 " + Date().formatted(.dateTime.month().day().hour().minute())
        guard let path = try? NotebookFiles.create(in: folder ?? currentFolder, title: title, paper: NotesSettings.lastPaper, store: store) else { return }
        reveal(path: path)
        openNote(path)
    }

    func createFolder(named name: String, in parent: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let path = (parent.isEmpty ? "" : parent + "/") + NotebookMarkdown.fileName(for: trimmed)
        try? store.createFolder(path)
        if !parent.isEmpty {
            expandedFolders.insert(parent)
            defaults.set(Array(expandedFolders), forKey: Key.expanded)
        }
    }

    func delete(_ note: NoteSummary) {
        try? store.delete(note.path)
        close(.note(note.path))
    }

    /// 點 [[連結]]（Obsidian 的規則）：依名稱、路徑或別名找筆記（同名時取路徑最短的），
    /// #標題、#^區塊 開啟後跳到那裡，[[#標題]] 是同一則筆記；找不到時建立這則筆記（放在新筆記位置，寫了路徑就放在那裡）。
    func openLink(_ target: String, from sourcePath: String? = nil) {
        let link = NoteLinks.parse(target)
        if link.name.isEmpty {
            if let sourcePath, let anchor = link.anchor {
                anchorRequest = AnchorRequest(path: sourcePath, anchor: anchor)
            }
            return
        }
        if let path = NoteLinks.resolve(link.name, in: store.linkIndex) {
            if let anchor = link.anchor { anchorRequest = AnchorRequest(path: path, anchor: anchor) }
            openNote(path)
            return
        }
        let name = link.name.hasSuffix(".md") ? String(link.name.dropLast(3)) : link.name
        let folder = name.contains("/") ? (name as NSString).deletingLastPathComponent : NotesSettings.defaultFolder
        guard let path = try? store.createTextNote(in: folder, title: (name as NSString).lastPathComponent) else { return }
        reveal(path: path)
        openNote(path)
    }
}
