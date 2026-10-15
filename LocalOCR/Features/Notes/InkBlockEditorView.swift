import PencilKit
import SwiftUI

/// 要編輯的手寫區塊（新增或既有）。
struct InkEditRequest: Identifiable {
    let name: String
    let isNew: Bool

    var id: String { name }
}

/// 筆記中的手寫區塊：與手寫筆記相同的連續畫布，打開就能直接書寫，寫到底部自動加長。
/// 完成時存成「附件/ink-xxxx.png」（Obsidian 顯示，高度剛好包住筆跡）與「附件/ink-xxxx.ink」（可再編輯）。
struct InkBlockEditorView: View {
    let notePath: String
    let request: InkEditRequest
    var onSaved: (InkEditRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var block = InkBlock(height: InkBlock.minimumHeight, paper: NotesSettings.lastPaper, drawing: PKDrawing().dataRepresentation())
    @State private var handle = CanvasNotebookHandle()
    @State private var revision = 0
    @State private var didLoad = false
    @State private var loadFailed = false
    @State private var isSaving = false
    /// 打開後寫過或改過紙張（取消時要確認）。
    @State private var hasChanges = false
    /// 新的區塊已經插入筆記（切到背景時先存過一次）。
    @State private var embedded = false
    @State private var confirmsDiscard = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Group {
                if loadFailed {
                    ContentUnavailableView("無法開啟手寫區塊", systemImage: "icloud.slash", description: Text("筆跡資料還沒下載到這台裝置，請連上網路後再試。"))
                } else if didLoad {
                    CanvasNotebook(
                        drawing: { handle.currentDrawing ?? block.pkDrawing },
                        minimumSegments: 1,
                        paper: block.paper,
                        handle: handle,
                        revision: revision,
                        onDrawingChange: { _ in hasChanges = true },
                        width: block.canvasWidth
                    )
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("手寫區塊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if hasChanges { confirmsDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("紙張", selection: Binding(get: { block.paper }, set: { changePaper($0) })) {
                            ForEach(PaperStyle.allCases) { style in
                                Label(style.title, systemImage: style.systemImage).tag(style)
                            }
                        }
                    } label: {
                        Label("紙張", systemImage: block.paper.systemImage)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("完成").bold() }
                    }
                    .disabled(isSaving || loadFailed)
                }
            }
            .task { await load() }
            .confirmationDialog("要捨棄這次的手寫嗎？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("儲存") { Task { await save() } }
                Button("捨棄", role: .destructive) { dismiss() }
            }
            .alert("儲存失敗", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("好") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .onChange(of: scenePhase) { _, phase in
                // 切到其他 App 或被系統關閉前先存一次（不關閉畫面）
                guard phase == .background, hasChanges, didLoad, !loadFailed else { return }
                BackgroundWork.run("ink-block") { _ = await persist() }
            }
        }
        .interactiveDismissDisabled()
    }

    private func load() async {
        guard !didLoad, !loadFailed else { return }
        if !request.isNew {
            // 按需模式下筆跡資料可能還在遠端：先下載；拿不到時不能編輯（否則會蓋掉原本的筆跡）
            let sync = VaultSyncCenter.shared
            let dataPath = InkFiles.dataPath(notePath: notePath, name: request.name)
            if let url = try? await sync.download(dataPath),
               let data = try? Data(contentsOf: url),
               var saved = try? JSONDecoder().decode(InkBlock.self, from: data) {
                saved.migrateToCanvas()
                block = saved
            } else {
                loadFailed = true
                return
            }
        }
        didLoad = true
    }

    private func captureDrawing() {
        if let drawing = handle.currentDrawing {
            block.pkDrawing = drawing
        }
    }

    private func changePaper(_ paper: PaperStyle) {
        captureDrawing()
        block.paper = paper
        NotesSettings.lastPaper = paper
        hasChanges = true
        revision += 1
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await persist() { dismiss() }
    }

    /// 寫入筆跡與圖片（新的區塊第一次存時插入筆記）；成功時回傳 true。
    private func persist() async -> Bool {
        captureDrawing()
        block.height = InkBlock.fittedHeight(for: block.pkDrawing)
        let sync = VaultSyncCenter.shared
        let vault = sync.vault
        let block = block
        let image = await Task.detached(priority: .userInitiated) { InkFiles.image(for: block).pngData() }.value
        // 筆記搬到別的資料夾後，筆跡與圖片存回原本的位置（依檔名找到）
        let dataPath = InkFiles.dataPath(notePath: notePath, name: request.name)
        let imagePath = ((dataPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("\(request.name).png")
        await sync.prepareOverwrite([dataPath, imagePath])
        do {
            guard let image else { throw InkSaveError.render }
            try vault.write(try JSONEncoder().encode(block), to: dataPath)
            try vault.write(image, to: imagePath)
            sync.fileDidChange(dataPath)
            sync.fileDidChange(imagePath)
            sync.localDidChange()
            if !request.isNew || !embedded {
                onSaved(request)
                embedded = true
            }
            hasChanges = false
            return true
        } catch {
            // 寫入本機失敗（空間不足等）：保留畫面讓使用者再試
            saveError = error.localizedDescription
            return false
        }
    }
}

private enum InkSaveError: LocalizedError {
    case render

    var errorDescription: String? { "無法產生手寫區塊的圖片，請再試一次。" }
}
