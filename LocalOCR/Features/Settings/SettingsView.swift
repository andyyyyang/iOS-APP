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
                }

                Section {
                    Toggle("只使用裝置端模型", isOn: $localOnly)
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
                        AIFeaturesView()
                    } label: {
                        statusRow("AI 功能", localOnly ? "只用裝置端" : (assistant.cloudAvailable ? "雲端可用" : "雲端未設定"), color: .secondary)
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
                }

                Section {
                    NavigationLink {
                        NotesSettingsView()
                    } label: {
                        LabeledContent("筆記與 Obsidian", value: VaultSyncCenter.shared.isConfigured ? "已配對" : "未配對")
                    }
                } header: {
                    Text("筆記")
                }

                Section {
                    NavigationLink {
                        ServerSettingsView()
                    } label: {
                        LabeledContent("伺服器與同步", value: ServerSettings.normalizedURL(baseURL)?.host() ?? "未設定")
                    }
                } header: {
                    Text("伺服器")
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
                }

                Section("紀錄") {
                    Toggle("自動儲存辨識結果", isOn: $autoSaveHistory)
                }

                Section("關於") {
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

    private func statusRow(_ title: String, _ value: String, systemImage: String? = nil, color: Color) -> some View {
        SettingsStatusRow(title: title, value: value, systemImage: systemImage, color: color)
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
