import AVFoundation
import SwiftUI
import VisionKit

/// 相機分頁：按快門一頁一頁拍，全部拍完再一起分析（與「掃描」分頁共用同一份文件）。
struct LiveScanView: View {
    @Environment(ScanDraft.self) private var draft
    @AppStorage(OCRSettings.Key.languages) private var languagesRaw = OCRSettings.encode(OCRSettings.defaultLanguages)
    @State private var isVisible = false
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var bridge = LiveScannerBridge()
    @State private var toast: String?
    @State private var shutterTrigger = 0
    @State private var captureModel = ScanViewModel()
    @State private var isCapturing = false
    @State private var showsFlash = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("連續拍照")
                .navigationBarTitleDisplayMode(.inline)
                // 推入結果頁或切換分頁時移除相機，釋放資源
                .onAppear {
                    isVisible = true
                    cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                }
                .onDisappear { isVisible = false }
                .navigationDestination(item: $captureModel.session) { session in
                    ResultView(session: session)
                }
        }
        .toast($toast)
        .sensoryFeedback(.impact, trigger: shutterTrigger)
    }

    @ViewBuilder
    private var content: some View {
        if !DataScannerViewController.isSupported {
            ContentUnavailableView(
                "此裝置無法使用連續拍照",
                systemImage: "camera",
                description: Text("需要實體 iPhone，模擬器無法使用。你仍可在「掃描」分頁從相簿加入頁面。")
            )
        } else {
            switch cameraStatus {
            case .authorized:
                if DataScannerViewController.isAvailable {
                    camera
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

    private var camera: some View {
        ZStack(alignment: .bottom) {
            if isVisible {
                DataScannerRepresentable(languages: scannerLanguages, bridge: bridge)
                    .ignoresSafeArea(edges: .horizontal)
            }
            if showsFlash {
                Color.white
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            controls
        }
        .overlay {
            if captureModel.isProcessing {
                VStack(spacing: 12) {
                    ProgressView()
                    if case let .processing(current, total) = captureModel.phase, total > 1 {
                        Text("正在辨識第 \(current)／\(total) 頁…")
                            .font(.subheadline)
                    } else {
                        Text("正在辨識…")
                            .font(.subheadline)
                    }
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if !draft.pages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(draft.pages.enumerated()), id: \.element.id) { index, page in
                                DraftPageThumbnail(draft: draft, page: page, number: index + 1, width: 48)
                                    .id(page.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: draft.pages.last?.id) { _, id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .trailing) }
                    }
                }
            }

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button(role: .destructive) {
                    draft.clear()
                } label: {
                    Label("清除", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(draft.pages.isEmpty)
                .frame(maxWidth: .infinity, alignment: .leading)

                shutterButton

                Button(action: analyzeDraft) {
                    Label("分析（\(draft.pages.count)）", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.pages.isEmpty || draft.pendingCount > 0)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .disabled(captureModel.isProcessing)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }

    private var shutterButton: some View {
        Button {
            Task { await capturePage() }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.8), lineWidth: 4)
                    .frame(width: 74, height: 74)
                Circle()
                    .fill(.white)
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.15), radius: 2)
                if isCapturing {
                    ProgressView()
                        .tint(.black)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isCapturing)
        .accessibilityLabel(draft.pages.isEmpty ? "拍下這一頁" : "再拍一頁")
    }

    private var deniedView: some View {
        ContentUnavailableView {
            Label("需要相機權限", systemImage: "camera")
        } description: {
            Text("請到「設定」允許本 App 使用相機。照片與辨識全程在裝置上處理。")
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

    private var hint: String {
        if draft.pendingCount > 0 { return "處理中…" }
        if draft.pages.isEmpty { return "對準文件按下快門；多頁文件（例如發票＋報單）全部拍完再按「分析」。" }
        return "已拍 \(draft.pages.count) 頁，可以繼續拍下一頁。長按縮圖可調整順序。"
    }

    private var scannerLanguages: [String] {
        let supported = Set(DataScannerViewController.supportedTextRecognitionLanguages)
        return OCRSettings.decode(languagesRaw).filter { supported.contains($0) }
    }

    /// 拍一張高解析度照片，加入正在收集的文件。
    @MainActor
    private func capturePage() async {
        isCapturing = true
        defer { isCapturing = false }
        do {
            let image = try await bridge.capturePhoto()
            shutterTrigger += 1
            showsFlash = true
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(.easeOut(duration: 0.25)) { showsFlash = false }
            }
            await draft.add([image], source: .liveScanner)
        } catch {
            toast = "無法拍照：\(error.localizedDescription)"
        }
    }

    /// 完整流程：逐頁 OCR → 判斷情境 → Apple Intelligence 產生 JSON。
    private func analyzeDraft() {
        let pages = draft.pages.map(\.imageData)
        let source = draft.primarySource
        Task {
            await captureModel.process(imageData: pages, source: source)
            if captureModel.session != nil {
                draft.clear()
            } else if case .failed(let message) = captureModel.phase {
                toast = message
            }
        }
    }

    @MainActor
    private func requestCameraAccess() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    }
}
