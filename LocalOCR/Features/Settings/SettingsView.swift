import SwiftUI

struct SettingsView: View {
    @Environment(TemplateLibrary.self) private var library
    @AppStorage(OCRSettings.Key.recognitionLevel) private var levelRaw = RecognitionLevel.accurate.rawValue
    @AppStorage(OCRSettings.Key.languages) private var languagesRaw = OCRSettings.encode(OCRSettings.defaultLanguages)
    @AppStorage(OCRSettings.Key.usesLanguageCorrection) private var usesLanguageCorrection = true
    @AppStorage(OCRSettings.Key.automaticallyDetectsLanguage) private var automaticallyDetectsLanguage = false
    @AppStorage(OCRSettings.Key.autoSaveHistory) private var autoSaveHistory = true
    @AppStorage(ServerSettings.Key.useJev) private var useJev = true
    @AppStorage(AIPrivacy.localOnlyKey) private var localOnly = false
    @AppStorage(AssistantEngineMode.key) private var engine = AssistantEngineMode.medium.rawValue
    @State private var assistant = KnowledgeAssistant.shared
    @AppStorage(ServerSettings.Key.baseURL) private var baseURL = ""
    @State private var aiStatus = OnDeviceAIStatus.current
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.light.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("外觀", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("外觀")
                } footer: {
                    Text("預設為淺色；深色模式改用深灰底。")
                }

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
                        }
                        .padding(.vertical, 2)
                    }
                    NavigationLink {
                        AssistantSettingsView()
                    } label: {
                        statusRow("知識庫 AI", localOnly ? "裝置端" : (assistant.cloudAvailable ? "雲端可用" : "雲端未設定"), color: .secondary)
                    }
                    NavigationLink {
                        AIDiagnosticsView()
                    } label: {
                        switch aiStatus {
                        case .available:
                            statusRow("Apple Intelligence", "可使用", systemImage: "checkmark.circle.fill", color: DS.success)
                        case .unavailable(let reason):
                            statusRow("Apple Intelligence", reason, color: .secondary)
                        }
                    }
                } header: {
                    Text("AI")
                } footer: {
                    Text(localOnly
                         ? "所有 AI 都在這台裝置的 Apple Intelligence 上執行：首頁 AI 不交給雲端、不請 Jev 判斷，智慧掃描用裝置端判斷情境。伺服器只用來搜尋與同步 vault。"
                         : "Jev 依要求的種類與難度自動選裝置端或雲端模型，以成本為先：簡單的每個等級都用裝置端（免費）。低：盡量留在裝置端；中：依難度用 Haiku、Sonnet 或 Opus 級；高：難的工作早一點用上最好的模型。")
                }

                Section {
                    NavigationLink {
                        TemplateListView()
                    } label: {
                        statusRow("情境樣板", "\(library.all.count) 種", color: .secondary)
                    }
                    Toggle("以 Jev 判斷情境", isOn: $useJev)
                        .disabled(localOnly)
                } header: {
                    Text("智慧掃描")
                } footer: {
                    Text(localOnly
                         ? "已開啟「只使用裝置端模型」：情境由裝置端 Apple Intelligence 與關鍵字判斷。JSON 一律由裝置端模型產生，不需網路。"
                         : "判斷情境的順序：Jev（經你的伺服器，速度快、費用極低）→ 裝置端 Apple Intelligence → 關鍵字。JSON 一律由裝置端模型產生，不需網路。")
                }

                Section {
                    NavigationLink {
                        NotesSettingsView()
                    } label: {
                        LabeledContent("筆記與 Obsidian", value: VaultSyncCenter.shared.isConfigured ? "已配對" : "未配對")
                    }
                } header: {
                    Text("筆記")
                } footer: {
                    Text("整個 Obsidian vault（所有資料夾的筆記、圖片與檔案）都存在這台裝置並與 Railway 空間雙向同步；電腦（Windows／Mac）與其他裝置上的 Obsidian 以 Remotely Save 同步同一份 vault。")
                }

                Section {
                    NavigationLink {
                        ServerSettingsView()
                    } label: {
                        LabeledContent("伺服器與同步", value: ServerSettings.normalizedURL(baseURL)?.host() ?? "未設定")
                    }
                } header: {
                    Text("伺服器")
                } footer: {
                    Text("連接 Railway 上的 LocalOCR 伺服器後，掃描結果可同步到 Obsidian，並透過 MCP 提供給 Claude Code 等 harness 使用。")
                }

                Section {
                    Picker("辨識模式", selection: $levelRaw) {
                        ForEach(RecognitionLevel.allCases) { level in
                            Text(level.displayName).tag(level.rawValue)
                        }
                    }
                    Toggle("語言校正", isOn: $usesLanguageCorrection)
                    NavigationLink {
                        LanguageSelectionView(languagesRaw: $languagesRaw, level: level)
                    } label: {
                        LabeledContent("辨識語言", value: languageSummary)
                    }
                    Toggle("自動偵測語言", isOn: $automaticallyDetectsLanguage)
                } header: {
                    Text("文字辨識")
                } footer: {
                    Text("精確模式支援中文、日文、韓文等語言；快速模式速度較快，但只支援拉丁字母語言。清單順序代表語言優先順序。")
                }

                Section("紀錄") {
                    Toggle("自動儲存辨識結果", isOn: $autoSaveHistory)
                }

                Section("關於") {
                    Label("文字辨識使用 Apple Vision、JSON 擷取使用 Apple Foundation Models，都在裝置上執行。只有你啟用伺服器時，資料才會上傳到你自己的伺服器。", systemImage: "lock.shield")
                        .font(.footnote)
                    LabeledContent("版本", value: appVersion)
                }
            }
            .canvasList()
            .navigationTitle("設定")
            .onAppear {
                aiStatus = OnDeviceAIStatus.current
                // 舊版的「只用裝置端」改成開關；「自動」「一律用雲端」換成新的等級
                if engine == AssistantEngineMode.device.rawValue {
                    localOnly = true
                    engine = AssistantEngineMode.medium.rawValue
                } else if AssistantEngineMode(rawValue: engine) == nil {
                    engine = AssistantEngineMode.from(engine).rawValue
                }
            }
            .task { await assistant.checkCloud(force: true) }
        }
    }

    /// 一列：左邊名稱，右邊狀態（一行，太長時截斷），箭頭不會被擠到下一行。
    private func statusRow(_ title: String, _ value: String, systemImage: String? = nil, color: Color) -> some View {
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

    private var level: RecognitionLevel {
        RecognitionLevel(rawValue: levelRaw) ?? .accurate
    }

    private var languageSummary: String {
        let languages = OCRSettings.decode(languagesRaw)
        switch languages.count {
        case 0: return "系統預設"
        case 1: return OCRSettings.displayName(for: languages[0])
        default: return "\(OCRSettings.displayName(for: languages[0])) 等 \(languages.count) 種"
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(TemplateLibrary.shared)
}
