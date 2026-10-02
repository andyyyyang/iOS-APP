import SwiftUI

/// 相機分頁：按快門一頁一頁拍，全部拍完再一起分析（與「掃描」分頁共用同一份文件）。
struct LiveScanView: View {
    @Environment(ScanDraft.self) private var draft
    @State private var camera = CameraController()
    @State private var toast: String?
    @State private var shutterTrigger = 0
    @State private var captureModel = ScanViewModel()
    @State private var isCapturing = false
    @State private var showsFlash = false

    var body: some View {
        NavigationStack {
            CameraAccessView { cameraScreen }
                .navigationTitle("連續拍照")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $captureModel.session) { session in
                    ResultView(session: session)
                }
        }
        .toast($toast)
        .sensoryFeedback(.impact, trigger: shutterTrigger)
    }

    private var cameraScreen: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(camera: camera)
                .ignoresSafeArea(edges: .horizontal)
            if showsFlash {
                Color.white
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            controls
        }
        // 推入結果頁或切換分頁時停止相機，回來時再啟動
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
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
        ShutterButton(isBusy: isCapturing, ringColor: .primary) {
            Task { await capturePage() }
        }
    }

    // MARK: - Helpers

    private var hint: String {
        if draft.pendingCount > 0 { return "處理中…" }
        if draft.pages.isEmpty { return "對準文件按下快門；多頁文件（例如發票＋報單）全部拍完再按「分析」。" }
        return "已拍 \(draft.pages.count) 頁，可以繼續拍下一頁。長按縮圖可調整順序。"
    }

    /// 拍一張高解析度照片，加入正在收集的文件；拍完立刻可以再拍，壓縮在背景進行。
    @MainActor
    private func capturePage() async {
        isCapturing = true
        let image: UIImage
        do {
            image = try await camera.capturePhoto()
        } catch {
            isCapturing = false
            toast = "無法拍照：\(error.localizedDescription)"
            return
        }
        isCapturing = false
        shutterTrigger += 1
        showsFlash = true
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeOut(duration: 0.25)) { showsFlash = false }
        }
        await draft.add([image], source: .liveScanner)
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
}
