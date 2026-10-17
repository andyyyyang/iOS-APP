import SwiftUI

/// 設定 → AI 功能 → 首頁 AI：對話紀錄，以及 AI 修改筆記時遵守的 vault 編輯規則檔。
struct AssistantSettingsSection: View {
    @State private var assistant = KnowledgeAssistant.shared
    @State private var customPath = KnowledgeAssistant.shared.rulesOverride ?? ""
    @State private var usesRules = KnowledgeAssistant.shared.rulesOverride != ""
    @AppStorage(KnowledgeAssistant.historyEnabledKey) private var historyEnabled = true
    @AppStorage(KnowledgeAssistant.historyFolderKey) private var historyFolder = KnowledgeAssistant.defaultHistoryFolder

    var body: some View {
        Section {
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
                TextField("規則檔路徑", text: $customPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { assistant.setRules(customPath.isEmpty ? nil : normalized(customPath)) }
                if !assistant.rootNotes.isEmpty {
                    Picker("規則筆記", selection: Binding(
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
                    Text("規則太長，只用前 \(KnowledgeAssistant.rulesLimit) 字")
                        .font(.footnote)
                        .foregroundStyle(DS.warning)
                }
            }
        } header: {
            Text("首頁 AI")
        }
        .task { await assistant.loadRules() }
    }

    private func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.lowercased().hasSuffix(".md") ? trimmed : trimmed + ".md"
    }
}
