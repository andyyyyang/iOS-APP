import AVFoundation
import SwiftData
import SwiftUI
import VisionKit

struct LiveScanView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(OCRSettings.Key.languages) private var languagesRaw = OCRSettings.encode(OCRSettings.defaultLanguages)
    @State private var isVisible = false
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var bridge = LiveScannerBridge()
    @State private var collected: [String] = []
    @State private var toast: String?
    @State private var feedbackTrigger = 0
    @State private var captureModel = ScanViewModel()
    @State private var isCapturing = false
    @State private var showsTextAnalysis = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("即時掃描")
                .navigationBarTitleDisplayMode(.inline)
                // 推入結果頁或切換分頁時移除掃描器，釋放相機
                .onAppear {
                    isVisible = true
                    cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                }
                .onDisappear { isVisible = false }
                .navigationDestination(item: $captureModel.session) { session in
                    ResultView(session: session)
                }
        }
        .sheet(isPresented: $showsTextAnalysis) {
            NavigationStack {
                SmartAnalysisView(text: collectedText, source: .liveScanner)
            }
        }
        .toast($toast)
        .sensoryFeedback(.selection, trigger: feedbackTrigger)
    }

    @ViewBuilder
    private var content: some View {
        if !DataScannerViewController.isSupported {
            ContentUnavailableView(
                "此裝置不支援即時掃描",
                systemImage: "camera.viewfinder",
                description: Text("即時文字掃描需要 A12 仿生晶片以上的實體裝置，模擬器無法使用。你仍可在「辨識」分頁選取照片進行辨識。")
            )
        } else {
            switch cameraStatus {
            case .authorized:
                if DataScannerViewController.isAvailable {
                    scanner
                } else {
                    ContentUnavailableView(
                        "目前無法使用相機",
                        systemImage: "video.slash",
                        description: Text("相機可能被其他 App 使用中，或受到螢幕使用時間限制。")
                    )
                }
            case .notDetermined:
                ProgressView("正在請求相機權限…")
                    .task { await requestCameraAccess() }
            default:
                deniedView
            }
        }
    }

    private var scanner: some View {
        ZStack(alignment: .bottom) {
            if isVisible {
                DataScannerRepresentable(languages: scannerLanguages, bridge: bridge) { text in
                    add([text])
                }
                .ignoresSafeArea(edges: .horizontal)
            }
            collectedPanel
        }
        .overlay {
            if isCapturing || captureModel.isProcessing {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在辨識並交給 Apple Intelligence 分析…")
                        .font(.subheadline)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    private var collectedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await captureAndAnalyze() }
            } label: {
                Label("拍照並用 Apple Intelligence 分析", systemImage: "camera.aperture")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isCapturing || captureModel.isProcessing)

            if collected.isEmpty {
                Text("或點選畫面中標示的文字加入清單，再按「分析文字」。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(collectedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
            }

            HStack(spacing: 16) {
                Button {
                    add(bridge.currentTexts())
                } label: {
                    Label("擷取全部", systemImage: "text.viewfinder")
                }
                .buttonStyle(.bordered)

                Spacer()

                Group {
                    Button {
                        showsTextAnalysis = true
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .accessibilityLabel("分析文字")

                    Button {
                        UIPasteboard.general.string = collectedText
                        toast = "已複製"
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("複製")

                    ShareLink(item: collectedText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享")

                    Button(action: save) {
                        Image(systemName: "tray.and.arrow.down")
                    }
                    .accessibilityLabel("儲存到紀錄")

                    Button(role: .destructive) {
                        collected.removeAll()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("清除")
                }
                .disabled(collected.isEmpty)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }

    private var deniedView: some View {
        ContentUnavailableView {
            Label("需要相機權限", systemImage: "camera")
        } description: {
            Text("請到「設定」允許本 App 使用相機，才能即時掃描文字。辨識全程在裝置上進行。")
        } actions: {
            Button("前往設定") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Helpers

    private var collectedText: String {
        collected.joined(separator: "\n")
    }

    private var scannerLanguages: [String] {
        let supported = Set(DataScannerViewController.supportedTextRecognitionLanguages)
        return OCRSettings.decode(languagesRaw).filter { supported.contains($0) }
    }

    private func add(_ texts: [String]) {
        let newTexts = texts.filter { !collected.contains($0) }
        guard !newTexts.isEmpty else {
            toast = texts.isEmpty ? "畫面中沒有文字" : "已經加入過了"
            return
        }
        collected.append(contentsOf: newTexts)
        feedbackTrigger += 1
    }

    private func save() {
        let record = ScanRecord(
            text: collectedText,
            source: ScanSource.liveScanner.rawValue,
            pageCount: 1,
            lineCount: collected.count,
            averageConfidence: nil,
            thumbnailData: nil
        )
        modelContext.insert(record)
        try? modelContext.save()
        toast = "已儲存到紀錄"
    }

    /// 以掃描器拍一張照片，走與相簿相同的完整流程：OCR → 判斷情境 → Apple Intelligence 產生 JSON。
    @MainActor
    private func captureAndAnalyze() async {
        isCapturing = true
        defer { isCapturing = false }
        do {
            let image = try await bridge.capturePhoto()
            await captureModel.process([image], source: .liveScanner)
            if case .failed(let message) = captureModel.phase {
                toast = message
            }
        } catch {
            toast = "無法拍照：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func requestCameraAccess() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    }
}
