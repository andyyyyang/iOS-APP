import SwiftUI

/// Apple Intelligence 診斷：顯示可用狀態、語言支援，並用範例收據實際測試情境判斷與 JSON 產生。
struct AIDiagnosticsView: View {
    @State private var status = OnDeviceAIStatus.current
    @State private var result: String?
    @State private var isTesting = false

    private static let sampleText = """
    全聯福利中心 信義店
    2026/10/02 14:30
    鮮乳 1 x 45
    吐司 1 x 39
    小計 84
    合計 84
    現金 100 找零 16
    """

    var body: some View {
        Form {
            Section("狀態") {
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                LabeledContent("Apple Intelligence") {
                    switch status {
                    case .available:
                        Label("可使用", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .unavailable(let reason):
                        Text(reason)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("系統語言", value: Locale.current.identifier)
                LabeledContent("支援系統語言", value: localeSupportText)
            }

            if !languages.isEmpty {
                Section("模型支援的語言") {
                    Text(languages.joined(separator: "、"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await runTest() }
                } label: {
                    HStack {
                        Label("用範例收據測試", systemImage: "wand.and.stars")
                        Spacer()
                        if isTesting { ProgressView() }
                    }
                }
                .disabled(isTesting)
                if let result {
                    Text(result)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("測試")
            } footer: {
                Text("在裝置上判斷情境並產生 JSON，不會上傳。若失敗，請把這裡的訊息提供給開發者。")
            }
        }
        .navigationTitle("Apple Intelligence 診斷")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { status = OnDeviceAIStatus.current }
    }

    private var localeSupportText: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), status.isAvailable {
            return OnDeviceAIDiagnostics.supportsCurrentLocale ? "是" : "否（請在「設定 → Apple Intelligence 與 Siri」選擇支援的語言）"
        }
        #endif
        return "—"
    }

    private var languages: [String] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), status.isAvailable {
            return OnDeviceAIDiagnostics.supportedLanguageNames
        }
        #endif
        return []
    }

    @MainActor
    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        let start = Date()
        let templates = ScanTemplate.builtIns
        let outcome = await SmartScanEngine.run(text: Self.sampleText, templates: templates, useJev: false)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
        var lines = [
            "情境：\(outcome.template.name)（\(outcome.classification.provider.displayName)）",
            "耗時：\(seconds) 秒",
        ]
        lines.append(contentsOf: outcome.notes.map { "分類備註：\($0)" })
        if let data = outcome.data {
            lines.insert("✅ Apple Intelligence 正常", at: 0)
            lines.append(data.prettyPrinted())
        } else {
            lines.insert("❌ 無法產生 JSON", at: 0)
            lines.append(outcome.extractionError ?? "未知錯誤")
        }
        result = lines.joined(separator: "\n")
    }
}

#Preview {
    NavigationStack { AIDiagnosticsView() }
}
