import SwiftUI

/// 設定 → 筆記與 Obsidian 的「知識庫 AI」：AI 修改筆記時遵守的 vault 編輯規則檔。
struct AssistantSettingsSection: View {
    @State private var assistant = KnowledgeAssistant.shared
    @State private var customPath = KnowledgeAssistant.shared.rulesOverride ?? ""
    @State private var usesRules = KnowledgeAssistant.shared.rulesOverride != ""
    @AppStorage(AssistantEngineMode.key) private var engine = AssistantEngineMode.medium.rawValue
    @AppStorage(AIPrivacy.localOnlyKey) private var localOnly = false
    @AppStorage(KnowledgeAssistant.historyEnabledKey) private var historyEnabled = true
    @AppStorage(KnowledgeAssistant.historyFolderKey) private var historyFolder = KnowledgeAssistant.defaultHistoryFolder

    var body: some View {
        Section {
            Toggle("只使用裝置端模型", isOn: $localOnly)
            Picker("AI 預算", selection: $engine) {
                ForEach(AssistantEngineMode.budgets) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .disabled(localOnly)
            .onAppear {
                // 舊版的「只用裝置端」改成開關；「自動」「一律用雲端」換成新的等級
                if engine == AssistantEngineMode.device.rawValue {
                    localOnly = true
                    engine = AssistantEngineMode.medium.rawValue
                } else if AssistantEngineMode(rawValue: engine) == nil {
                    engine = AssistantEngineMode.from(engine).rawValue
                }
            }
            LabeledContent("雲端 AI") {
                Text(assistant.cloudAvailable ? "可以使用" : "伺服器尚未設定")
                    .foregroundStyle(assistant.cloudAvailable ? DS.success : DS.textSecondary)
            }
            Toggle("保存對話紀錄", isOn: $historyEnabled)
            if historyEnabled {
                TextField("對話紀錄資料夾", text: $historyFolder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Toggle("遵守 vault 編輯規則", isOn: $usesRules)
                .onChange(of: usesRules) { _, enabled in
                    assistant.setRules(enabled ? (customPath.isEmpty ? nil : customPath) : "")
                }
            if usesRules {
                LabeledContent("目前使用", value: assistant.rulesPath ?? "沒有找到")
                TextField("規則檔路徑（空白＝自動尋找）", text: $customPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { assistant.setRules(customPath.isEmpty ? nil : normalized(customPath)) }
                if !assistant.rootNotes.isEmpty {
                    Picker("從最上層的筆記選擇", selection: Binding(
                        get: { assistant.rulesPath ?? "" },
                        set: { path in
                            customPath = path
                            assistant.setRules(path.isEmpty ? nil : path)
                        }
                    )) {
                        Text("自動尋找").tag("")
                        ForEach(assistant.rootNotes, id: \.self) { path in
                            Text(path).tag(path)
                        }
                    }
                }
                if assistant.rulesTruncated {
                    Text("規則超過 \(KnowledgeAssistant.rulesLimit) 字，只會用前面的部分（裝置端模型能讀的長度有限）。")
                        .font(.footnote)
                        .foregroundStyle(DS.warning)
                }
            }
        } header: {
            Text("知識庫 AI")
        } footer: {
            Text("「只使用裝置端模型」開啟時，所有 AI 都在這台裝置上的 Apple Intelligence 執行：首頁 AI 不交給雲端、也不請 Jev 判斷，智慧掃描用裝置端判斷情境（伺服器只用來搜尋與同步 vault）。首頁的 AI 透過 LocalOCR 伺服器在線上搜尋與修改 vault，不會把筆記下載到這台裝置。三個預算都由伺服器的 Jev 依要求的種類與難度自動選擇，以成本為先：簡單的問題與修改每個等級都用裝置端的 Apple Intelligence（免費）；「低」連中等難度的也盡量留在裝置端，只有困難的才用便宜的雲端模型；「中」依難度用 Haiku、Sonnet 或 Opus 級的模型；「高」讓難的工作早一點用上最好的模型。雲端 AI 是伺服器上的 Claude，能像操作電腦一樣整理檔案、在沙盒中執行程式，模型自動跟上最新版本（要在 Railway 的伺服器設定 ANTHROPIC_API_KEY 才能使用）。每段對話都記在對話紀錄資料夾中的一則筆記。每次新對話都會讀取編輯規則；沒有指定時，自動使用 vault 最上層名為 AGENTS.md、CLAUDE.md、編輯規則.md、rules.md，或名稱含「規則」「規範」的筆記。")
        }
        .task {
            await assistant.loadRules()
            await assistant.checkCloud(force: true)
        }
    }

    private func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.lowercased().hasSuffix(".md") ? trimmed : trimmed + ".md"
    }
}
