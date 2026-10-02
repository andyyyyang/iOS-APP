import SwiftUI

struct SettingsView: View {
    @Environment(TemplateLibrary.self) private var library
    @AppStorage(OCRSettings.Key.recognitionLevel) private var levelRaw = RecognitionLevel.accurate.rawValue
    @AppStorage(OCRSettings.Key.languages) private var languagesRaw = OCRSettings.encode(OCRSettings.defaultLanguages)
    @AppStorage(OCRSettings.Key.usesLanguageCorrection) private var usesLanguageCorrection = true
    @AppStorage(OCRSettings.Key.automaticallyDetectsLanguage) private var automaticallyDetectsLanguage = false
    @AppStorage(OCRSettings.Key.autoSaveHistory) private var autoSaveHistory = true
    @AppStorage(ServerSettings.Key.useJev) private var useJev = true
    @AppStorage(ServerSettings.Key.baseURL) private var baseURL = ""
    @State private var aiStatus = OnDeviceAIStatus.current

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        TemplateListView()
                    } label: {
                        LabeledContent("情境樣板", value: "\(library.all.count) 種")
                    }
                    NavigationLink {
                        AIDiagnosticsView()
                    } label: {
                        LabeledContent("Apple Intelligence") {
                            switch aiStatus {
                            case .available:
                                Label("可使用", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            case .unavailable(let reason):
                                Text(reason)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    Toggle("以 Jev 判斷情境", isOn: $useJev)
                } header: {
                    Text("智慧掃描")
                } footer: {
                    Text("判斷情境的順序：Jev（經你的伺服器，速度快、費用極低）→ 裝置端 Apple Intelligence → 關鍵字。JSON 一律由裝置端模型產生，不需網路。")
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
            .navigationTitle("設定")
            .onAppear { aiStatus = OnDeviceAIStatus.current }
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
