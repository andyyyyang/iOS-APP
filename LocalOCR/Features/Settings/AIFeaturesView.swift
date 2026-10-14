import SwiftUI

/// 設定 → AI 功能：所有 AI 的選項。執行位置與預算、雲端模型（每一級自動或固定一個模型）、雲端 AI 能做的事
/// （網路搜尋、執行程式、步驟上限）、首頁 AI 的對話紀錄與規則、筆記與智慧掃描的 AI，以及各個 AI 的狀態。
/// 都存在這台裝置；雲端的選項在每次開始雲端工作時傳給伺服器，沒有選的用伺服器的預設。
struct AIFeaturesView: View {
    @AppStorage(AIPrivacy.localOnlyKey) private var localOnly = false
    @AppStorage(AssistantEngineMode.key) private var engine = AssistantEngineMode.medium.rawValue
    @AppStorage(AISettings.modelKey("small")) private var smallModel = ""
    @AppStorage(AISettings.modelKey("medium")) private var mediumModel = ""
    @AppStorage(AISettings.modelKey("large")) private var largeModel = ""
    @AppStorage(AISettings.webSearchKey) private var webSearch = ""
    @AppStorage(AISettings.codeExecutionKey) private var codeExecution = ""
    @AppStorage(AISettings.maxTurnsKey) private var maxTurns = 0
    @AppStorage(AISettings.noteButtonKey) private var noteButton = true
    @AppStorage(AISettings.notePanelKey) private var notePanel = true
    @AppStorage(ServerSettings.Key.useJev) private var useJev = true
    @State private var settings: AssistantClient.ModelSettings?
    @State private var status: AssistantClient.ServerStatus?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var aiStatus = OnDeviceAIStatus.current

    var body: some View {
        Form {
            placeSection
            if !localOnly {
                modelsSection
                toolsSection
            }
            AssistantSettingsSection()
            notesSection
            scanSection
            statusSection
        }
        .canvasList()
        .navigationTitle("AI 功能")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: localOnly) { _, isLocal in
            if !isLocal, settings == nil { Task { await load() } }
        }
    }

    // MARK: 執行位置

    private var placeSection: some View {
        Section {
            Toggle(isOn: $localOnly) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("只使用裝置端模型")
                    Text("不使用雲端 AI 與 Jev")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !localOnly {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI 預算")
                    Picker("AI 預算", selection: $engine) {
                        ForEach(AssistantEngineMode.budgets) { mode in
                            Text(mode.shortTitle).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(AssistantEngineMode.from(engine).title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("執行位置")
        } footer: {
            Text(localOnly
                 ? "所有 AI 都在這台裝置的 Apple Intelligence 上執行，伺服器只用來搜尋與同步 vault。"
                 : "Jev 依要求的種類與難度選裝置端或哪一級的雲端模型，以成本為先：簡單的每個預算都用裝置端（免費）。")
        }
    }

    // MARK: 雲端模型

    private var modelsSection: some View {
        Section {
            ForEach(AISettings.tiers, id: \.self) { tier in
                Picker(selection: modelBinding(tier)) {
                    Text(autoLabel(tier)).tag("")
                    let split = choices(for: tier)
                    if !split.family.isEmpty {
                        Section {
                            ForEach(split.family) { model in Text(model.name).tag(model.id) }
                        }
                    }
                    if !split.others.isEmpty {
                        Section("其他模型") {
                            ForEach(split.others) { model in Text(model.name).tag(model.id) }
                        }
                    }
                    let pinned = modelBinding(tier).wrappedValue
                    if !pinned.isEmpty, settings?.models.contains(where: { $0.id == pinned }) != true {
                        Text(KnowledgeAssistant.modelLabel(pinned)).tag(pinned)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AISettings.tierTitle(tier))
                        Text(tierCaption(tier))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if isLoading, settings == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("讀取模型清單…").foregroundStyle(.secondary)
                }
            }
            if let issue = settings?.issue ?? loadError {
                Text(issue)
                    .font(.footnote)
                    .foregroundStyle(DS.warning)
            }
        } header: {
            Text("雲端模型")
        } footer: {
            Text("Jev 依難度選等級，再用那一級的模型。「自動」會跟著 Anthropic 的新模型更新（伺服器每 6 小時檢查一次）；固定一個模型後就不會自動換新，模型無法使用時改回自動。")
        }
    }

    private func modelBinding(_ tier: String) -> Binding<String> {
        switch tier {
        case "small": return $smallModel
        case "medium": return $mediumModel
        default: return $largeModel
        }
    }

    private func autoLabel(_ tier: String) -> String {
        guard let id = settings?.tiers[tier] else { return "自動（最新）" }
        return "自動（\(KnowledgeAssistant.modelLabel(id))）"
    }

    private func tierCaption(_ tier: String) -> String {
        switch tier {
        case "small": return "簡單的雲端工作，費用最低"
        case "medium": return "大部分的問題與修改"
        default: return "困難的多步驟工作"
        }
    }

    /// 這一級系列的模型，以及其他模型（新的在前）。
    private func choices(for tier: String) -> (family: [AssistantClient.ModelSettings.Model], others: [AssistantClient.ModelSettings.Model]) {
        let models = settings?.models ?? []
        let family = AISettings.tierFamily(tier)
        return (models.filter { $0.family == family }, models.filter { $0.family != family })
    }

    // MARK: 雲端 AI 能做的事

    private var toolsSection: some View {
        Section {
            Toggle(isOn: choiceBinding($webSearch, default: settings?.webSearch ?? false)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("網路搜尋")
                    Text("查 vault 以外的最新資料（每次搜尋另外計費）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: choiceBinding($codeExecution, default: settings?.codeExecution ?? true)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("執行程式")
                    Text("在沙盒中計算、分析表格、產生檔案存回 vault")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Picker("每次最多步驟", selection: $maxTurns) {
                Text(settings.map { "伺服器上限（\($0.maxTurns)）" } ?? "伺服器上限").tag(0)
                ForEach(turnOptions, id: \.self) { count in
                    Text("\(count) 步").tag(count)
                }
            }
            if !webSearch.isEmpty || !codeExecution.isEmpty || maxTurns != 0 {
                Button("使用伺服器的預設") {
                    webSearch = ""
                    codeExecution = ""
                    maxTurns = 0
                }
            }
        } header: {
            Text("雲端 AI 能做的事")
        } footer: {
            Text("一步是一次模型呼叫（讀檔、搜尋、修改各算一步）。步驟越少，每次的費用上限越低，但大型的整理工作可能做不完。")
        }
    }

    /// "on"／"off" 存在這台裝置；沒有選時顯示伺服器的預設。
    private func choiceBinding(_ stored: Binding<String>, default value: Bool) -> Binding<Bool> {
        Binding(
            get: {
                switch stored.wrappedValue {
                case "on": return true
                case "off": return false
                default: return value
                }
            },
            set: { stored.wrappedValue = $0 ? "on" : "off" }
        )
    }

    private var turnOptions: [Int] {
        let limit = settings?.maxTurns ?? 0
        let options = [5, 10, 20, 40].filter { limit == 0 || $0 < limit }
        // 設定過、但比伺服器上限大或不在清單中的值也要能顯示
        return maxTurns > 0 && !options.contains(maxTurns) ? (options + [maxTurns]).sorted() : options
    }

    // MARK: 筆記與智慧掃描

    private var notesSection: some View {
        Section {
            Toggle(isOn: $noteButton) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("筆記上的 AI 按鈕")
                    Text("選取文字或整則筆記，請 AI 修改")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $notePanel) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("右側欄的 AI 整理")
                    Text("摘要、重點、待辦與標籤")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("筆記")
        } footer: {
            Text("筆記的 AI 都在裝置端的 Apple Intelligence 上執行，內容不會離開這台裝置。關掉後仍可選取文字使用系統的「書寫工具」。")
        }
    }

    private var scanSection: some View {
        Section {
            Toggle("以 Jev 判斷情境", isOn: $useJev)
                .disabled(localOnly)
            NavigationLink {
                TemplateListView()
            } label: {
                Text("情境樣板")
            }
        } header: {
            Text("智慧掃描")
        } footer: {
            Text(localOnly
                 ? "情境由裝置端 Apple Intelligence 與關鍵字判斷。JSON 一律由裝置端模型產生。"
                 : "判斷情境的順序：Jev（經你的伺服器，速度快、費用極低）→ 裝置端 Apple Intelligence → 關鍵字。JSON 一律由裝置端模型產生。")
        }
    }

    // MARK: 狀態

    private var statusSection: some View {
        Section {
            NavigationLink {
                AIDiagnosticsView()
            } label: {
                switch aiStatus {
                case .available:
                    SettingsStatusRow(title: "Apple Intelligence", value: "可使用", systemImage: "checkmark.circle.fill", color: DS.success)
                case .unavailable(let reason):
                    SettingsStatusRow(title: "Apple Intelligence", value: reason, color: .secondary)
                }
            }
            if let status {
                SettingsStatusRow(
                    title: "雲端 AI",
                    value: localOnly ? "已關閉" : status.assistant ? (status.issue == nil ? "可使用" : "API key 有問題") : "伺服器未設定",
                    systemImage: !localOnly && status.assistant && status.issue == nil ? "checkmark.circle.fill" : nil,
                    color: localOnly ? .secondary : status.assistant ? (status.issue == nil ? DS.success : DS.warning) : .secondary
                )
                SettingsStatusRow(
                    title: "Jev",
                    value: localOnly ? "已關閉" : status.jev ? "可使用" : "伺服器未設定",
                    systemImage: !localOnly && status.jev ? "checkmark.circle.fill" : nil,
                    color: !localOnly && status.jev ? DS.success : .secondary
                )
                if !localOnly, let issue = status.issue {
                    Text(issue)
                        .font(.footnote)
                        .foregroundStyle(DS.warning)
                }
            } else if AssistantClient.configured() == nil {
                SettingsStatusRow(title: "雲端 AI 與 Jev", value: "還沒有連接伺服器", color: .secondary)
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("檢查伺服器…").foregroundStyle(.secondary)
                }
            } else {
                SettingsStatusRow(title: "雲端 AI 與 Jev", value: "連不上伺服器", color: DS.warning)
            }
        } header: {
            Text("狀態")
        } footer: {
            Text("雲端 AI 與 Jev 的 API key 設在 Railway 的伺服器變數（ANTHROPIC_API_KEY、JEV_API_KEY），不會存在這台裝置。")
        }
    }

    private func load() async {
        aiStatus = OnDeviceAIStatus.current
        guard let client = AssistantClient.configured() else {
            loadError = "還沒有連接伺服器（設定 → 伺服器與同步）。"
            return
        }
        isLoading = true
        defer { isLoading = false }
        async let health = client.status()
        if !localOnly {
            do {
                settings = try await client.modelSettings()
                loadError = nil
            } catch {
                loadError = "無法取得模型清單：\(error.localizedDescription)"
            }
        }
        status = await health
    }
}

/// 設定的一列：左邊名稱，右邊狀態（一行，太長時截斷），箭頭不會被擠到下一行。
struct SettingsStatusRow: View {
    let title: String
    let value: String
    var systemImage: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(value).lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(color)
        }
    }
}
