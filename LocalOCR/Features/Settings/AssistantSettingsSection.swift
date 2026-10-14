import SwiftUI

/// 設定 → 筆記與 Obsidian 的「知識庫 AI」：AI 修改筆記時遵守的 vault 編輯規則檔。
struct AssistantSettingsSection: View {
    @State private var assistant = KnowledgeAssistant.shared
    @State private var customPath = KnowledgeAssistant.shared.rulesOverride ?? ""
    @State private var usesRules = KnowledgeAssistant.shared.rulesOverride != ""

    var body: some View {
        Section {
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
            Text("首頁的 AI 透過 LocalOCR 伺服器在線上搜尋與修改 vault，不會把筆記下載到這台裝置。每次新對話都會讀取編輯規則；沒有指定時，自動使用 vault 最上層名為 AGENTS.md、CLAUDE.md、編輯規則.md、rules.md 等的筆記。")
        }
        .task { await assistant.loadRules() }
    }

    private func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.lowercased().hasSuffix(".md") ? trimmed : trimmed + ".md"
    }
}
