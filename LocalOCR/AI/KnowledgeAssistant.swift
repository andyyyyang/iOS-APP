import Foundation
import Observation

/// 只使用裝置端模型：不呼叫雲端 AI，也不呼叫伺服器的 Jev（首頁 AI 只用 Apple Intelligence，智慧掃描用裝置端判斷情境）。
enum AIPrivacy {
    static let localOnlyKey = "ai.localOnly"

    static var localOnly: Bool {
        get { UserDefaults.standard.bool(forKey: localOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: localOnlyKey) }
    }
}

/// AI 的預算：三個等級都由伺服器的 Jev 依要求的種類與難度自動選擇（裝置端或哪一級的雲端模型），都以成本為先；
/// 簡單的事每個等級都在裝置端處理，預算越高，難的工作越早用上更好的模型。
enum AssistantEngineMode: String, CaseIterable, Identifiable {
    /// 盡量用裝置端：只有裝置端做不好的（困難的問題、多步驟的工作）才用便宜的雲端模型。
    case low
    /// 依難度平衡。
    case medium
    /// 難的工作用最好的模型。
    case high
    /// 完全不用雲端。
    case device

    static let key = "assistant.engine"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "低：盡量用裝置端"
        case .medium: return "中：依難度平衡"
        case .high: return "高：難的工作用最好的模型"
        case .device: return "只用裝置端（不用雲端）"
        }
    }

    /// 「預算低／中／高」中的那個字。
    var shortTitle: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .device: return "只用裝置端"
        }
    }

    /// 傳給伺服器的預算（只用裝置端時不問伺服器）。
    var budget: String? { self == .device ? nil : rawValue }

    /// 讀取設定；舊版的「自動」當成中、「一律用雲端」當成高。
    static func from(_ raw: String?) -> AssistantEngineMode {
        switch raw {
        case "auto": return .medium
        case "cloud": return .high
        default: return AssistantEngineMode(rawValue: raw ?? "") ?? .medium
        }
    }

    static var current: AssistantEngineMode {
        AIPrivacy.localOnly ? .device : from(UserDefaults.standard.string(forKey: key))
    }

    /// 設定頁的預算選項（只用裝置端是另外的開關）。
    static let budgets: [AssistantEngineMode] = [.low, .medium, .high]
}

/// 雲端工作要用的模型等級與思考程度（POST /v1/assistant/route 的判斷）。
struct CloudPlan: Equatable {
    /// small、medium 或 large。
    var tier: String
    var effort: String?
}

/// 一段以前的對話（AI 對話資料夾中的一則筆記）。
struct ChatSessionInfo: Identifiable, Equatable {
    let path: String
    var id: String { path }
    var title: String { ChatTranscript.title(of: path) }
}

/// 首頁 AI 的狀態：對話、交給哪個 AI、對話紀錄、復原。
@MainActor
@Observable
final class KnowledgeAssistant {
    static let shared = KnowledgeAssistant()

    static let rulesKey = "assistant.rulesPath"
    static let historyEnabledKey = "assistant.historyEnabled"
    static let historyFolderKey = "assistant.historyFolder"
    static let defaultHistoryFolder = "AI 對話"
    /// 自動尋找的編輯規則檔（vault 最上層）。
    static let rulesCandidates = ["agents.md", "claude.md", "ai 規則.md", "ai規則.md", "編輯規則.md", "_編輯規則.md", "規則.md", "rules.md", "_rules.md"]
    /// 規則放進裝置端模型指示的最多字數（上下文有限；雲端 AI 會讀完整的規則）。
    static let rulesLimit = 800

    private(set) var messages: [AssistantMessage] = []
    private(set) var isWorking = false
    private(set) var rulesPath: String?
    private(set) var rulesTruncated = false
    private(set) var rootNotes: [String] = []
    private(set) var undone: Set<String> = []
    /// 伺服器設定了雲端 AI（ANTHROPIC_API_KEY）。
    private(set) var cloudAvailable = false
    /// 以前的對話（最新的在前）。
    private(set) var sessions: [ChatSessionInfo] = []
    /// 這段對話的紀錄筆記。
    private(set) var transcriptPath: String?
    private var transcriptCreated = Date()
    private var rulesText: String?
    private var rulesTask: Task<Void, Never>?
    private var agent: AnyObject?
    /// 模型對話是新開的：要帶上之前的問答重點（打開以前的對話、雲端回答之後）。
    private var carryContext = false
    private var found: [String] = []
    private var work: Task<Void, Never>?
    private var cloudChecked = false
    /// 這一題交給雲端時的等級（chooseEngine 決定，runCloud 使用）。
    private var cloudPlan: CloudPlan?

    var isServerConfigured: Bool { VaultMCPClient.configured() != nil }

    /// 使用者選的規則檔：nil 自動尋找、空字串不使用。
    var rulesOverride: String? {
        UserDefaults.standard.string(forKey: Self.rulesKey)
    }

    static var historyEnabled: Bool {
        UserDefaults.standard.object(forKey: historyEnabledKey) as? Bool ?? true
    }

    static var historyFolder: String {
        let folder = UserDefaults.standard.string(forKey: historyFolderKey)?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) ?? ""
        return folder.isEmpty ? defaultHistoryFolder : folder
    }

    func setRules(_ path: String?) {
        if let path { UserDefaults.standard.set(path, forKey: Self.rulesKey) } else { UserDefaults.standard.removeObject(forKey: Self.rulesKey) }
        agent = nil
        rulesTask = nil
        Task { await loadRules() }
    }

    func newConversation() {
        guard !isWorking else { return }
        messages = []
        agent = nil
        found = []
        transcriptPath = nil
        carryContext = false
        // 新對話重新讀取規則（可能剛在 Obsidian 改過）
        rulesTask = nil
    }

    // MARK: 準備

    /// 讀取規則、對話紀錄，確認伺服器有沒有雲端 AI。
    func prepare() async {
        async let rules: Void = loadRules(force: false)
        async let history: Void = loadSessions()
        async let cloud: Void = checkCloud()
        _ = await (rules, history, cloud)
    }

    func checkCloud(force: Bool = false) async {
        guard force || !cloudChecked, let client = AssistantClient.configured() else { return }
        cloudChecked = true
        cloudAvailable = await client.isAvailable()
    }

    func loadRules(force: Bool = true) async {
        if !force, let rulesTask {
            await rulesTask.value
            return
        }
        let task = Task { await fetchRules() }
        rulesTask = task
        await task.value
    }

    private func fetchRules() async {
        guard let mcp = VaultMCPClient.configured(), let root = try? await mcp.list(folder: "") else {
            // 沒有配對或連不上：下次再試
            rulesTask = nil
            return
        }
        rootNotes = root.files.filter { $0.lowercased().hasSuffix(".md") && !$0.contains("/") }.sorted()
        var path: String?
        switch rulesOverride {
        case .some(""):
            path = nil
        case .some(let chosen):
            path = chosen
        case .none:
            path = rootNotes.first { Self.rulesCandidates.contains($0.lowercased()) }
                ?? rootNotes.first { $0.contains("規則") || $0.contains("規範") || $0.lowercased().contains("rule") }
        }
        guard let path, let note = try? await mcp.read(path) else {
            rulesPath = nil
            rulesText = nil
            rulesTruncated = false
            return
        }
        rulesPath = note.path
        rulesText = String(note.content.prefix(Self.rulesLimit))
        rulesTruncated = note.content.count > Self.rulesLimit
    }

    // MARK: 對話紀錄

    func loadSessions() async {
        guard Self.historyEnabled, let mcp = VaultMCPClient.configured(),
              let listing = try? await mcp.list(folder: Self.historyFolder) else { return }
        sessions = listing.files
            .filter { $0.lowercased().hasSuffix(".md") }
            .sorted { ChatTranscript.title(of: $0) > ChatTranscript.title(of: $1) }
            .map(ChatSessionInfo.init)
    }

    /// 打開以前的對話：讀回問答，之後的問題接著記在同一則筆記。
    func open(_ session: ChatSessionInfo) async -> String? {
        guard !isWorking else { return nil }
        guard let mcp = VaultMCPClient.configured() else { return "尚未配對伺服器" }
        do {
            guard let note = try await mcp.read(session.path) else { return "找不到這段對話。" }
            messages = ChatTranscript.parse(note.content)
            transcriptPath = note.path
            agent = nil
            found = []
            carryContext = true
            return nil
        } catch {
            return "讀取失敗：\(error.localizedDescription)"
        }
    }

    // MARK: 對話

    func send(_ text: String, openNote: String?) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isWorking else { return }
        let context = previousExchange()
        messages.append(AssistantMessage(role: .user, text: question))
        messages.append(AssistantMessage(role: .assistant, text: ""))
        isWorking = true
        found = []
        if transcriptPath == nil, Self.historyEnabled {
            transcriptCreated = Date()
            transcriptPath = Self.historyFolder + "/" + ChatTranscript.fileName(for: question, date: transcriptCreated, timeZone: .current)
        }
        work = Task {
            await answer(question, openNote: openNote, context: context)
            isWorking = false
            work = nil
            await loadSessions()
        }
    }

    /// 停止回答（雲端的工作也會在伺服器上停止；已經做的修改保留，可以復原）。
    func stop() {
        guard isWorking else { return }
        work?.cancel()
        if let runID = messages.last?.runID, let client = AssistantClient.configured() {
            Task { try? await client.cancel(runID) }
        }
    }

    private func answer(_ question: String, openNote: String?, context: String?) async {
        guard let mcp = VaultMCPClient.configured() else {
            finish("需要先與 LocalOCR 伺服器配對（設定 → 筆記與 Obsidian），AI 才能在線上搜尋你的 vault。", isError: true)
            return
        }
        await prepare()
        let engine = await chooseEngine(for: question, context: context)
        updateLast { $0.engine = engine }
        switch engine {
        case .cloud:
            await runCloud(question, openNote: openNote)
        case .device:
            await runDevice(question, openNote: openNote, context: context, mcp: mcp)
            await saveTurn(question)
        case .search:
            await searchOnly(question, mcp: mcp)
            await saveTurn(question)
        }
    }

    /// 交給哪個 AI：把預算告訴伺服器，由 Jev 依種類與難度選裝置端或哪一級的雲端模型（以成本為先）。
    private func chooseEngine(for question: String, context: String?) async -> AssistantMessage.Engine {
        cloudPlan = nil
        var deviceAvailable = false
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { deviceAvailable = OnDeviceAIStatus.current.isAvailable }
        #endif
        let mode = AssistantEngineMode.current
        guard let budget = mode.budget, cloudAvailable else { return deviceAvailable ? .device : .search }
        guard let client = AssistantClient.configured(),
              let route = try? await client.route(question, context: context, budget: budget, deviceAvailable: deviceAvailable) else {
            // 問不到伺服器：能用裝置端就用裝置端，否則用最便宜的雲端模型
            if deviceAvailable { return .device }
            cloudPlan = CloudPlan(tier: "small", effort: "low")
            return .cloud(model: "")
        }
        let judge = route.provider == "jev" ? "Jev" : "規則"
        if route.isCloud {
            let tier = route.tier ?? "large"
            cloudPlan = CloudPlan(tier: tier, effort: route.effort)
            // 設定頁固定了這一級的模型時用它
            let id = AISettings.model(for: tier) ?? route.model
            let model = id.map(Self.modelLabel) ?? Self.tierLabel(tier)
            updateLast { $0.steps.append(.route("\(judge)：\(route.summary) → 雲端 \(model)（預算\(mode.shortTitle)）")) }
            return .cloud(model: id ?? "")
        }
        guard deviceAvailable else { return .search }
        updateLast { $0.steps.append(.route("\(judge)：\(route.summary) → 裝置端 AI（免費）")) }
        return .device
    }

    /// claude-sonnet-5-5 → Sonnet 5.5（其他名稱照原樣）。
    nonisolated static func modelLabel(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts[0] == "claude" else { return id }
        let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        let version = parts.dropFirst(2).prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }
        return version.isEmpty ? family : family + " " + version.joined(separator: ".")
    }

    nonisolated static func tierLabel(_ tier: String) -> String {
        switch tier {
        case "small": return "Haiku 級"
        case "medium": return "Sonnet 級"
        default: return "Opus 級"
        }
    }

    // MARK: 裝置端

    private func runDevice(_ question: String, openNote: String?, context: String?, mcp: VaultMCPClient) async {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return }
        var prompt = Self.prompt(question, openNote: openNote, previous: carryContext ? context : nil)
        carryContext = false
        for attempt in 0..<2 {
            do {
                let session = agentSession(mcp: mcp)
                let answer = try await session.respond(to: prompt)
                finish(answer)
                return
            } catch is CancellationError {
                finish("已停止。", isError: true)
                return
            } catch where KnowledgeAgentSession.isContextOverflow(error) {
                agent = nil
                // 這次已經改了筆記就不重試（避免重複寫入），只回報做了什麼
                let edits = messages.last?.edits ?? []
                if !edits.isEmpty {
                    finish("已完成：\n" + edits.map { "- " + ChatTranscript.describe($0) }.joined(separator: "\n") + "\n（對話太長，沒有產生完整回答；之後的問題會從新的對話開始）")
                    return
                }
                guard attempt == 0 else { break }
                // 對話太長：換新的一段，只帶上一題的重點再問一次（畫面上的紀錄保留）
                prompt = Self.prompt(question, openNote: openNote, previous: context)
                updateLast { $0.steps = [] }
                found = []
            } catch {
                if Task.isCancelled {
                    finish("已停止。", isError: true)
                } else {
                    finish("Apple Intelligence 無法完成：\(AIErrorDescriber.describe(error))", isError: true)
                }
                return
            }
        }
        finish("這個問題需要讀的內容太多，超過裝置端模型能處理的長度。可以把問題縮小一點、指定要看哪一則筆記，或在設定把 AI 改成雲端。", isError: true)
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func agentSession(mcp: VaultMCPClient) -> KnowledgeAgentSession {
        if let existing = agent as? KnowledgeAgentSession { return existing }
        let sink = AgentEventSink { [weak self] event in
            await self?.handle(event)
        }
        let session = KnowledgeAgentSession(rules: rulesText, mcp: mcp, sink: sink, historyFolder: Self.historyEnabled ? Self.historyFolder : nil)
        agent = session
        return session
    }
    #endif

    /// 不能使用 Apple Intelligence（也沒有雲端 AI）時：直接列出搜尋結果（仍是線上搜尋）。
    private func searchOnly(_ question: String, mcp: VaultMCPClient) async {
        do {
            let hits = try await mcp.search(question, limit: 10)
            updateLast { $0.steps.append(.search(query: question, count: hits.count)) }
            guard !hits.isEmpty else {
                finish("沒有找到相關的筆記。（這台裝置不能使用 Apple Intelligence，所以只列出搜尋結果）")
                return
            }
            let lines = hits.map { hit in
                "- [[\(Self.title(of: hit.path))]]：\(String(hit.snippet.prefix(100)))"
            }
            found = hits.map(\.path)
            finish("這台裝置不能使用 Apple Intelligence，以下是搜尋結果：\n" + lines.joined(separator: "\n"))
        } catch {
            finish("搜尋失敗：\(error.localizedDescription)", isError: true)
        }
    }

    // MARK: 雲端

    /// 交給伺服器上的雲端 AI：持續取得它的進度（用了哪些工具、改了哪些檔案），完成後顯示回答。
    /// 對話紀錄由伺服器寫入（同一則筆記）。
    private func runCloud(_ question: String, openNote: String?) async {
        guard let client = AssistantClient.configured() else { return }
        // 之後的裝置端回答要重新帶上前面的問答（裝置端的模型沒看過雲端的回答）
        agent = nil
        carryContext = true
        let history = messages.dropLast(2).compactMap { message -> AssistantClient.HistoryTurn? in
            guard !message.text.isEmpty, !message.isError else { return nil }
            return AssistantClient.HistoryTurn(role: message.role == .user ? "user" : "assistant", text: message.text)
        }
        let run: AssistantClient.Run
        var options = AISettings.runOptions(tier: cloudPlan?.tier)
        do {
            func start() async throws -> AssistantClient.Run {
                try await client.startRun(
                    prompt: question,
                    history: Array(history.suffix(12)),
                    rulesPath: rulesOverride,
                    openNote: openNote,
                    transcriptPath: transcriptPath,
                    timeZone: .current,
                    tier: cloudPlan?.tier,
                    effort: cloudPlan?.effort,
                    options: options
                )
            }
            do {
                run = try await start()
            } catch let error as ServerError where error.code == "unknown_model" && options.model != nil {
                // 設定頁選的模型已經不能用（下架或換了 API key）：改用這一級的自動模型
                let pinned = Self.modelLabel(options.model ?? "")
                updateLast { $0.steps.append(.route("設定的模型 \(pinned) 無法使用，改用自動選擇")) }
                options.model = nil
                run = try await start()
            }
        } catch {
            finish("雲端 AI 無法開始：\(error.localizedDescription)", isError: true)
            await saveTurn(question)
            return
        }
        updateLast { message in
            message.runID = run.id
            message.engine = .cloud(model: run.model)
        }
        var after = 0
        var failures = 0
        while true {
            if Task.isCancelled {
                finish("已停止。已經做的修改保留，可以在上方復原。", isError: true)
                return
            }
            do {
                let state = try await client.run(run.id, after: after, wait: 25)
                failures = 0
                for (seq, event) in state.events where seq > after {
                    after = seq
                    apply(event, runID: run.id)
                }
                guard !state.isRunning else { continue }
                updateLast { message in
                    for path in state.sources where !message.sources.contains(path) { message.sources.append(path) }
                    // 最後一段話就是回答，不要重複顯示
                    if let answer = state.answer, case .narration(let text)? = message.steps.last, text == answer {
                        message.steps.removeLast()
                    }
                    // 失敗原因會寫在回答裡，最後一個同樣內容的錯誤步驟不要重複顯示
                    if state.status != "completed", let error = state.error, case .failed(let text)? = message.steps.last, text == error {
                        message.steps.removeLast()
                    }
                }
                switch state.status {
                case "completed":
                    finish(state.answer ?? "完成。")
                case "cancelled":
                    finish("已停止。已經做的修改保留，可以在上方復原。", isError: true)
                default:
                    finish("雲端 AI 沒有完成：\(state.error ?? "發生錯誤")", isError: true)
                }
                notesDidChange(state.edits.map(\.path) + state.edits.compactMap(\.from))
                return
            } catch {
                if Task.isCancelled { continue }
                failures += 1
                // 網路暫時中斷：伺服器上的工作會繼續，稍後再取得進度
                guard failures < 6 else {
                    finish("和伺服器的連線中斷了。雲端 AI 會在伺服器上繼續完成，結果會記在對話紀錄中。", isError: true)
                    return
                }
                try? await Task.sleep(for: .seconds(Double(min(failures * 2, 10))))
            }
        }
    }

    private func apply(_ event: AssistantClient.Event, runID: String) {
        switch event {
        case .message(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { updateLast { $0.steps.append(.narration(trimmed)) } }
        case .tool(let summary):
            updateLast { $0.steps.append(.tool(summary)) }
        case .edit(let edit):
            let edit = AgentEdit(edit, runID: runID)
            updateLast { $0.steps.append(.edit(edit)) }
            notesDidChange([edit.path] + (edit.from.map { [$0] } ?? []))
        case .file(let path):
            updateLast { message in
                message.steps.append(.file(path))
                if !message.sources.contains(path) { message.sources.append(path) }
            }
        case .error(let message):
            updateLast { $0.steps.append(.failed(message)) }
        }
    }

    // MARK: 共用

    static func prompt(_ question: String, openNote: String?, previous: String? = nil) -> String {
        let date = Date().formatted(.dateTime.year().month().day().weekday(.wide).locale(Locale(identifier: "zh_Hant_TW")))
        var lines = ["今天是 \(date)。"]
        if let previous { lines.append("先前的對話（摘要）：\n\(previous)") }
        if let openNote { lines.append("使用者最近開啟的筆記：\(openNote)") }
        lines.append(question)
        return lines.joined(separator: "\n")
    }

    /// 上一組問答的重點（換新的模型對話時帶過去）。
    private func previousExchange() -> String? {
        guard let answer = messages.last(where: { $0.role == .assistant && !$0.isError && !$0.text.isEmpty }),
              let question = messages.last(where: { $0.role == .user }) else { return nil }
        return "問：\(question.text.prefix(150))\n答：\(answer.text.prefix(300))"
    }

    static func title(of path: String) -> String {
        ChatTranscript.title(of: path)
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .step(let step):
            updateLast { $0.steps.append(step) }
            if case .edit(let edit) = step { notesDidChange([edit.path]) }
        case .found(let path):
            if !found.contains(path) { found.append(path) }
        case .read(let path):
            updateLast { message in
                if !message.sources.contains(path) { message.sources.append(path) }
            }
        }
    }

    /// AI 改了筆記：開著的話馬上更新畫面；沒有即時推送時同步一次，讓筆記清單出現新的筆記。
    private func notesDidChange(_ paths: [String]) {
        guard !paths.isEmpty, VaultBackend.storage == .server else { return }
        let sync = VaultSyncCenter.shared
        Task {
            for path in paths where sync.openPaths.contains(path) { await sync.refreshOpenFile(path) }
            if !sync.isLive { await sync.syncNow() }
            VaultIndexStore.shared.scheduleRefresh()
        }
    }

    private func finish(_ text: String, isError: Bool = false) {
        updateLast { message in
            message.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            message.isError = isError
            // 搜尋到、而且回答中提到的筆記也列為來源
            for path in found {
                if text.contains(Self.title(of: path)), !message.sources.contains(path) { message.sources.append(path) }
            }
        }
    }

    /// 把這組問答記到對話紀錄（雲端的回答由伺服器記）。
    private func saveTurn(_ question: String) async {
        guard Self.historyEnabled, let path = transcriptPath, let mcp = VaultMCPClient.configured(),
              let message = messages.last, message.role == .assistant else { return }
        let turn = ChatTranscript.turn(
            question: question,
            answer: message.text,
            engine: message.engine?.transcript ?? .device,
            sources: message.sources,
            edits: message.edits,
            date: Date(),
            timeZone: .current
        )
        try? await ChatTranscriptWriter.append(turn, to: path, created: transcriptCreated, mcp: mcp)
    }

    private func updateLast(_ change: (inout AssistantMessage) -> Void) {
        guard let index = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        change(&messages[index])
    }

    // MARK: 復原

    /// 復原一則回答中所有還沒復原的修改（新的先復原）。
    func undoAll(in message: AssistantMessage) async -> String? {
        let pending = message.edits.filter { !undone.contains($0.id) }
        guard !pending.isEmpty else { return nil }
        if let runID = message.runID, pending.allSatisfy({ $0.runID == runID }) {
            guard let client = AssistantClient.configured() else { return "尚未配對伺服器" }
            do {
                let result = try await client.undo(runID, editIDs: pending.map(\.id))
                undone.formUnion(result.undone)
                notesDidChange(pending.flatMap { [$0.path] + ($0.from.map { [$0] } ?? []) })
                guard let reason = result.failed.values.first else { return nil }
                return "有 \(result.failed.count) 項沒有復原：\(reason)"
            } catch {
                return "復原失敗：\(error.localizedDescription)"
            }
        }
        for edit in pending.reversed() {
            if let error = await undo(edit) { return error }
        }
        return nil
    }

    func undo(_ edit: AgentEdit) async -> String? {
        guard !undone.contains(edit.id) else { return nil }
        if let runID = edit.runID {
            guard let client = AssistantClient.configured() else { return "尚未配對伺服器" }
            do {
                let result = try await client.undo(runID, editIDs: [edit.id])
                if let reason = result.failed[edit.id] { return reason }
                undone.insert(edit.id)
                notesDidChange([edit.path] + (edit.from.map { [$0] } ?? []))
                return nil
            } catch {
                return "復原失敗：\(error.localizedDescription)"
            }
        }
        do {
            if let previous = edit.previous {
                guard let mcp = VaultMCPClient.configured() else { return "尚未配對伺服器" }
                try await mcp.write(edit.path, content: previous, ifMatch: edit.etag)
            } else {
                guard let client = VaultClient.configured() else { return "尚未配對伺服器" }
                try await client.delete(edit.path, ifMatch: edit.etag)
            }
            undone.insert(edit.id)
            notesDidChange([edit.path])
            return nil
        } catch VaultError.notFound {
            // 新增的筆記已經在別處刪掉了
            undone.insert(edit.id)
            return nil
        } catch {
            return error.localizedDescription.contains("precondition_failed") || error is VaultError
                ? "這則筆記之後又被修改過，沒有復原。"
                : "復原失敗：\(error.localizedDescription)"
        }
    }
}
