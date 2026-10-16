import Foundation
import Observation

/// 日誌的自動整理：不用按按鈕。分成幾種小工作排隊，一次做一件、每做完一天就讓出，使用者正在寫字時先停：
/// - 開著的筆記本自己處理：停筆幾秒辨識，閒置一分鐘或離開時整理內容有變的日子、更新圖片與 Markdown
/// - 其他日誌（打開 App、離開筆記本時）：辨識還沒辨識的頁面、整理內容有變的日子、更新 Markdown
/// - 統整（日誌有變時）：所有日誌的每週重點、每月摘要、待跟進與提到的機種，寫成「日誌統整」筆記
/// 也可以強制：整理全部日誌，或全部重新整理（每一頁重新辨識、每一天重新整理）。
@MainActor
@Observable
final class JournalOrganizer {
    static let shared = JournalOrganizer()

    enum Job: Hashable {
        case notebook(path: String, id: String, force: Bool)
        case overview(force: Bool)
    }

    private(set) var pending: [Job] = []
    /// 目前在做什麼（側欄顯示）。
    private(set) var current: String?
    private(set) var lastFinished: Date?
    private(set) var lastEngine: JournalAI.Engine?
    /// 開著的筆記本：由它自己整理，背景工作略過。
    var openPath: String?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var lastSweep: Date?
    @ObservationIgnored private var lastActivity = Date.distantPast

    var isWorking: Bool { runner != nil }

    /// 開著的筆記本自己整理完（狀態列顯示）。
    func noteOrganized(engine: JournalAI.Engine?) {
        lastFinished = Date()
        if let engine { lastEngine = engine }
    }

    /// 開著的筆記本有筆跡：背景整理先等一下（不跟書寫搶資源）。
    func noteActivity() {
        lastActivity = Date()
    }

    /// 打開 App、離開日誌時：排入有變更的日誌與統整。平常最多 20 分鐘一次；`force` 時立即、全部檢查。
    func sweep(force: Bool = false, rebuild: Bool = false) {
        if !force, let lastSweep, Date().timeIntervalSince(lastSweep) < 1200 { return }
        lastSweep = Date()
        for note in NotesStore.shared.notes where note.isJournal && note.isLocal && note.path != openPath {
            guard let id = note.notebookID else { continue }
            enqueue(.notebook(path: note.path, id: id, force: rebuild))
        }
        enqueue(.overview(force: force || rebuild))
    }

    func enqueue(_ job: Job) {
        guard !pending.contains(job) else { return }
        pending.append(job)
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let self, !self.pending.isEmpty {
                let next = self.pending.removeFirst()
                await self.run(next)
                await Task.yield()
            }
            self?.current = nil
            self?.runner = nil
        }
    }

    /// 使用者停筆 20 秒以上才繼續。
    private func waitForIdle() async -> Bool {
        while Date().timeIntervalSince(lastActivity) < 20 {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return false }
        }
        return true
    }

    private func run(_ job: Job) async {
        switch job {
        case .notebook(let path, let id, let force):
            guard path != openPath, await waitForIdle() else { return }
            current = "整理「\(Self.title(of: path))」"
            guard var notebook = await JournalFiles.load(notePath: path, id: id) else { return }
            let original = notebook
            if force {
                for index in notebook.pages.indices { notebook.pages[index].recognizedFingerprint = nil }
            }
            notebook = await JournalIntelligence.recognizeChangedPages(notebook, models: JournalFiles.models()).0
            notebook = await JournalIntelligence.summarizeChangedDays(
                notebook,
                force: force,
                onEngine: { self.lastEngine = $0 },
                shouldContinue: { await self.waitForIdle() && path != self.openPath }
            )
            // 整理期間使用者打開了這本：交給筆記本自己（不覆寫它正在編輯的內容）
            guard path != openPath, force || notebook != original else { return }
            _ = try? await JournalFiles.publish(notebook, notePath: path, store: NotesStore.shared)
        case .overview(let force):
            guard await waitForIdle() else { return }
            current = "統整所有日誌"
            await updateOverview(force: force)
        }
        lastFinished = Date()
    }

    // MARK: 統整

    private static let fingerprintKey = "journal.overview.fingerprint"
    private static let monthsKey = "journal.overview.months"

    /// 讀所有日誌，內容有變（或強制）時重寫「日誌統整」：每週重點與每月摘要交給 AI，其他依資料整理。
    private func updateOverview(force: Bool) async {
        let store = NotesStore.shared
        let journals = store.notes.filter { $0.isJournal && $0.isLocal }
        guard !journals.isEmpty else { return }
        var loaded: [(title: String, notebook: JournalNotebook)] = []
        for note in journals {
            guard let id = note.notebookID, let notebook = await JournalFiles.load(notePath: note.path, id: id) else { continue }
            loaded.append((note.title, notebook))
        }
        let days = JournalOverview.collect(loaded)
        guard !days.isEmpty else { return }
        let folder = JournalFiles.defaultFolder(store: store, fallback: (journals[0].path as NSString).deletingLastPathComponent)
        let path = (folder.isEmpty ? "" : folder + "/") + JournalOverview.fileName + ".md"
        let fingerprint = JournalOverview.fingerprint(days)
        let defaults = UserDefaults.standard
        if !force, defaults.string(forKey: Self.fingerprintKey) == fingerprint, store.vault.exists(path) { return }

        var engines: Set<JournalAI.Engine> = []
        // 最近一週的重點
        let weekPrompt = JournalOverview.weekPrompt(days)
        var weekly: String?
        if !weekPrompt.isEmpty, await waitForIdle(),
           let (text, engine) = await JournalAI.write(prompt: weekPrompt, instructions: JournalOverview.weekInstructions) {
            weekly = text
            engines.insert(engine)
        }
        // 每月摘要：內容沒變的月份沿用上次的結果
        var cache = defaults.dictionary(forKey: Self.monthsKey) as? [String: [String: String]] ?? [:]
        var monthly: [(month: String, text: String)] = []
        for (month, prompt) in JournalOverview.monthPrompts(days, limit: 6) {
            let monthFingerprint = JournalMarkdown.fingerprint(prompt)
            if !force, let cached = cache[month], cached["fingerprint"] == monthFingerprint, let text = cached["text"] {
                monthly.append((month, text))
                continue
            }
            guard await waitForIdle(),
                  let (text, engine) = await JournalAI.write(prompt: prompt, instructions: JournalOverview.monthInstructions) else { continue }
            engines.insert(engine)
            cache[month] = ["fingerprint": monthFingerprint, "text": text]
            monthly.append((month, text))
        }
        defaults.set(cache, forKey: Self.monthsKey)
        if engines.contains(.privateCloud) {
            lastEngine = .privateCloud
        } else if let engine = engines.first {
            lastEngine = engine
        }

        let section = JournalOverview.markdown(days: days, weekly: weekly, monthly: monthly, engine: lastEngine?.title, updated: Date())
        let existing = store.vault.readText(path) ?? JournalOverview.newNote
        do {
            try store.save(JournalOverview.replacingSection(in: existing, with: section), to: path)
            VaultSyncCenter.shared.localDidChange()
            defaults.set(fingerprint, forKey: Self.fingerprintKey)
        } catch {
            current = "統整寫入失敗：\(error.localizedDescription)"
        }
    }

    static func title(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// 「日誌統整」筆記的路徑（側欄的捷徑用）。
    static func overviewPath() -> String? {
        let store = NotesStore.shared
        return store.notes.first { $0.title == JournalOverview.fileName }?.path
    }
}

/// 「日誌統整」筆記的內容：最近一週、待跟進、機種、每月、每天（都連回當天的日誌）。
enum JournalOverview {
    static let fileName = "日誌統整"
    static let sectionStart = "<!-- localocr:journal-overview:start -->"
    static let sectionEnd = "<!-- localocr:journal-overview:end -->"

    static let newNote = """
    ---
    type: journal-overview
    tags: [journal]
    ---
    # 日誌統整

    \(sectionStart)
    \(sectionEnd)

    """

    static let weekInstructions = "你是工作日誌的整理助理。根據最近一週每天的摘要與重點，整理出 3 到 6 點最重要的事（每點一句，用「- 」開頭），保留原文的語言（繁體中文），只能根據內容，不可編造。只輸出條列。"
    static let monthInstructions = "你是工作日誌的整理助理。根據這個月每天的摘要與重點，寫一段 3 到 5 句的月摘要：做了哪些事、進展與還沒完成的。保留原文的語言（繁體中文），只能根據內容，不可編造。只輸出摘要文字。"

    struct Day: Equatable, Sendable {
        let date: String
        /// 這天所在的日誌筆記（連結用）。
        let noteTitle: String
        let insights: JournalDay?
        let models: [JournalLinkedModel]
    }

    /// 所有日誌中有內容的日子（新的在前；同一天在不同日誌時各列一筆）。
    static func collect(_ notebooks: [(title: String, notebook: JournalNotebook)]) -> [Day] {
        var days: [Day] = []
        for (title, notebook) in notebooks {
            for group in notebook.pagesByDay {
                let pages = group.pages.filter { notebook.pages.indices.contains($0) }.map { notebook.pages[$0] }
                guard pages.contains(where: { !$0.isBlank }) else { continue }
                days.append(Day(date: group.date, noteTitle: title, insights: notebook.days[group.date], models: JournalMarkdown.linkedModels(in: pages)))
            }
        }
        return days.sorted { (a: Day, b: Day) -> Bool in
            if a.date != b.date { return a.date > b.date }
            return a.noteTitle < b.noteTitle
        }
    }

    static func fingerprint(_ days: [Day]) -> String {
        var lines: [String] = []
        for day in days {
            let parts: [String] = [day.date, day.noteTitle, day.insights?.textFingerprint ?? "", day.insights?.summary ?? "", day.models.map(\.path).joined(separator: ",")]
            lines.append(parts.joined(separator: "|"))
        }
        return JournalMarkdown.fingerprint(lines.joined(separator: "\n"))
    }

    /// 連回當天的日誌：[[手寫日誌#2026-10-15 週四|10/15]]
    static func link(_ day: Day, label: String? = nil) -> String {
        let heading = JournalLayout.heading(for: day.date)
        let shown = label ?? String(day.date.dropFirst(5)).replacingOccurrences(of: "-", with: "/")
        return "[[\(day.noteTitle)#\(heading)|\(shown)]]"
    }

    private static func describe(_ day: Day) -> String? {
        guard let insights = day.insights, !insights.summary.isEmpty else { return nil }
        var text = JournalLayout.heading(for: day.date) + "：" + insights.summary
        if !insights.keyPoints.isEmpty { text += "\n重點：" + insights.keyPoints.joined(separator: "；") }
        if !insights.actionItems.isEmpty { text += "\n待跟進：" + insights.actionItems.joined(separator: "；") }
        return text
    }

    /// 最近 7 天（以最新一天往前算）的內容。
    static func weekPrompt(_ days: [Day]) -> String {
        guard let latest = days.first?.date, let end = JournalLayout.dayFormatter.date(from: latest),
              let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -6, to: end) else { return "" }
        let from = JournalLayout.day(start)
        return days.filter { $0.date >= from }.compactMap(describe).joined(separator: "\n\n")
    }

    /// 最近幾個月，每月一段內容（新的在前）。
    static func monthPrompts(_ days: [Day], limit: Int) -> [(month: String, prompt: String)] {
        var order: [String] = []
        var byMonth: [String: [Day]] = [:]
        for day in days {
            let month = String(day.date.prefix(7))
            if byMonth[month] == nil { order.append(month) }
            byMonth[month, default: []].append(day)
        }
        return order.prefix(limit).compactMap { month in
            let text = (byMonth[month] ?? []).reversed().compactMap(describe).joined(separator: "\n\n")
            return text.isEmpty ? nil : (month, text)
        }
    }

    static func markdown(days: [Day], weekly: String?, monthly: [(month: String, text: String)], engine: String?, updated: Date) -> String {
        var lines = [sectionStart]
        let stamp = NotebookMarkdown.dateFormatter.string(from: updated)
        let engineNote: String = engine.map { "（" + $0 + "）" } ?? ""
        lines.append("> [!info] 由「記得」依所有手寫日誌自動整理，最後更新 " + stamp + engineNote + "。日誌有變更時會自動更新。")
        lines.append("")

        lines.append("## 最近一週")
        if let weekly, !weekly.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(weekly.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            var recent: [String] = []
            for day in days.prefix(7) {
                guard let summary = day.insights?.summary, !summary.isEmpty else { continue }
                recent.append("- " + link(day) + "：" + summary)
            }
            if recent.isEmpty { recent = ["（還沒有整理好的日誌）"] }
            lines.append(contentsOf: recent)
        }
        lines.append("")

        var actions: [String] = []
        for day in days.prefix(30) {
            for item in day.insights?.actionItems ?? [] {
                actions.append("- [ ] " + item + "（" + link(day) + "）")
            }
        }
        if !actions.isEmpty {
            lines.append("## 待跟進")
            lines.append(contentsOf: actions)
            lines.append("")
        }

        var modelOrder: [String] = []
        var modelDays: [String: (model: JournalLinkedModel, days: [Day])] = [:]
        for day in days {
            for model in day.models {
                if modelDays[model.path] == nil {
                    modelOrder.append(model.path)
                    modelDays[model.path] = (model, [])
                }
                modelDays[model.path]?.days.append(day)
            }
        }
        if !modelOrder.isEmpty {
            lines.append("## 機種")
            for path in modelOrder {
                guard let entry = modelDays[path] else { continue }
                let links = entry.days.map { link($0) }.joined(separator: "、")
                lines.append("- [[" + entry.model.title + "|" + entry.model.code + "]]：" + links)
            }
            lines.append("")
        }

        if !monthly.isEmpty {
            lines.append("## 每月")
            for (month, text) in monthly {
                lines.append("### \(month)")
                lines.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                lines.append("")
            }
        }

        lines.append("## 每天")
        for day in days {
            let summary: String = day.insights?.summary ?? "（尚未整理）"
            lines.append("- " + link(day, label: JournalLayout.heading(for: day.date)) + "：" + summary)
        }
        lines.append(sectionEnd)
        return lines.joined(separator: "\n")
    }

    static func replacingSection(in text: String, with section: String) -> String {
        if let start = text.range(of: sectionStart), let end = text.range(of: sectionEnd, range: start.upperBound..<text.endIndex) {
            return text.replacingCharacters(in: start.lowerBound..<end.upperBound, with: section)
        }
        let trimmed = text.trimmingCharacters(in: .newlines)
        return (trimmed.isEmpty ? "" : trimmed + "\n\n") + section + "\n"
    }
}
