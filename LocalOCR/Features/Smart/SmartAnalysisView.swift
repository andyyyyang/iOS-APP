import SwiftData
import SwiftUI

/// 對一段文字執行智慧分析（判斷情境＋Apple Intelligence 產生 JSON）。
/// 用於紀錄的重新分析（包含補充頁面後），以及舊版即時掃描擷取的文字。
struct SmartAnalysisView: View {
    let text: String
    let source: ScanSource
    /// 要更新的既有紀錄；為 nil 時會建立新紀錄。
    var record: ScanRecord?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(TemplateLibrary.self) private var library
    @AppStorage(ServerSettings.Key.autoUpload) private var autoUpload = true
    @AppStorage(ServerSettings.Key.useJev) private var useJev = true
    @State private var smart = SmartScanModel()
    @State private var savedRecord: ScanRecord?
    @State private var uploadState: UploadState = .notConfigured
    @State private var toast: String?
    @State private var didStart = false

    var body: some View {
        SmartResultPanel(
            model: smart,
            templates: library.all,
            uploadState: uploadState,
            onRerun: { template in Task { await run(forcedTemplate: template) } },
            onCopy: { json in
                UIPasteboard.general.string = json
                toast = "已複製 JSON"
            },
            onUpload: { Task { await upload() } }
        )
        .padding(.top)
        .screenBackground()
        .navigationTitle("智慧分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .toast($toast)
        .task {
            guard !didStart else { return }
            didStart = true
            savedRecord = record
            uploadState = ServerSettings.isConfigured ? .idle : .notConfigured
            await run(forcedTemplate: nil)
        }
    }

    private func run(forcedTemplate: ScanTemplate?) async {
        guard let outcome = await smart.run(
            text: text,
            templates: library.all,
            forcedTemplate: forcedTemplate,
            useJev: useJev
        ) else { return }

        let target: ScanRecord
        if let savedRecord {
            target = savedRecord
        } else {
            target = ScanRecord(
                text: text,
                source: source.rawValue,
                pageCount: 1,
                lineCount: text.split(whereSeparator: \.isNewline).count,
                averageConfidence: nil,
                thumbnailData: nil
            )
            modelContext.insert(target)
            savedRecord = target
        }
        target.apply(outcome)
        try? modelContext.save()
        if autoUpload, ServerSettings.isConfigured {
            await upload()
        }
    }

    private func upload() async {
        guard let savedRecord else { return }
        uploadState = .uploading
        do {
            try await ScanUploader.upload(savedRecord)
            try? modelContext.save()
            uploadState = .uploaded(Date())
        } catch {
            uploadState = .failed(error.localizedDescription)
        }
    }
}
