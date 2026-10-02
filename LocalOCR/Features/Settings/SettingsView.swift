import SwiftUI

struct SettingsView: View {
    @AppStorage(OCRSettings.Key.recognitionLevel) private var levelRaw = RecognitionLevel.accurate.rawValue
    @AppStorage(OCRSettings.Key.languages) private var languagesRaw = OCRSettings.encode(OCRSettings.defaultLanguages)
    @AppStorage(OCRSettings.Key.usesLanguageCorrection) private var usesLanguageCorrection = true
    @AppStorage(OCRSettings.Key.automaticallyDetectsLanguage) private var automaticallyDetectsLanguage = false
    @AppStorage(OCRSettings.Key.autoSaveHistory) private var autoSaveHistory = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("辨識模式", selection: $levelRaw) {
                        ForEach(RecognitionLevel.allCases) { level in
                            Text(level.displayName).tag(level.rawValue)
                        }
                    }
                    Toggle("語言校正", isOn: $usesLanguageCorrection)
                } header: {
                    Text("辨識")
                } footer: {
                    Text("精確模式支援中文、日文、韓文等語言；快速模式速度較快，但只支援拉丁字母語言。語言校正會依字典修正辨識結果，辨識代碼或序號時可以關閉。")
                }

                Section {
                    NavigationLink {
                        LanguageSelectionView(languagesRaw: $languagesRaw, level: level)
                    } label: {
                        LabeledContent("辨識語言", value: languageSummary)
                    }
                    Toggle("自動偵測語言", isOn: $automaticallyDetectsLanguage)
                } header: {
                    Text("語言")
                } footer: {
                    Text("清單順序代表優先順序。開啟自動偵測時，由 Vision 自行判斷圖片中的語言。")
                }

                Section("紀錄") {
                    Toggle("自動儲存辨識結果", isOn: $autoSaveHistory)
                }

                Section("關於") {
                    Label("所有文字辨識都透過 Apple Vision 框架在裝置上完成，不需要網路，圖片不會離開這台裝置。", systemImage: "lock.shield")
                        .font(.footnote)
                    LabeledContent("版本", value: appVersion)
                }
            }
            .navigationTitle("設定")
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
}
