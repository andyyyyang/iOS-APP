import PencilKit
import SwiftUI

/// 要編輯的手寫區塊（新增或既有）。
struct InkEditRequest: Identifiable {
    let name: String
    let isNew: Bool

    var id: String { name }
}

/// 筆記中的手寫區塊：與筆記本相同的原生 Apple Pencil 工具列，可以加長。
/// 完成時存成「附件/ink-xxxx.png」（Obsidian 顯示）與「附件/ink-xxxx.ink」（可再編輯）。
struct InkBlockEditorView: View {
    let notePath: String
    let request: InkEditRequest
    var onSaved: (InkEditRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var block = InkBlock(height: InkBlock.defaultHeight, paper: .blank, drawing: PKDrawing().dataRepresentation())
    @State private var handle = NotebookCanvasHandle()
    @State private var revision = 0
    @State private var didLoad = false
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Group {
                if didLoad {
                    NotebookCanvas(
                        drawing: { (try? PKDrawing(data: block.drawing)) ?? PKDrawing() },
                        pageCount: 1,
                        paper: block.paper,
                        layout: block.layout,
                        handle: handle,
                        revision: revision,
                        onDrawingChange: { _ in }
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
                    Button("取消") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Picker("紙張", selection: Binding(get: { block.paper }, set: { changePaper($0) })) {
                            ForEach(PaperStyle.allCases) { style in
                                Label(style.title, systemImage: style.systemImage).tag(style)
                            }
                        }
                    } label: {
                        Label("紙張", systemImage: "doc.richtext")
                    }
                    Button {
                        captureDrawing()
                        block.height += 300
                        revision += 1
                    } label: {
                        Label("加長", systemImage: "arrow.down.to.line.compact")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text("完成").bold() }
                    }
                    .disabled(isSaving)
                }
            }
            .task { load() }
        }
        .interactiveDismissDisabled()
    }

    private func load() {
        guard !didLoad else { return }
        if !request.isNew,
           let data = try? VaultSyncCenter.shared.vault.read(InkFiles.dataPath(notePath: notePath, name: request.name)),
           let saved = try? JSONDecoder().decode(InkBlock.self, from: data) {
            block = saved
        }
        didLoad = true
    }

    private func captureDrawing() {
        if let drawing = handle.currentDrawing {
            block.drawing = drawing.dataRepresentation()
        }
    }

    private func changePaper(_ paper: PaperStyle) {
        captureDrawing()
        block.paper = paper
        revision += 1
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        captureDrawing()
        let vault = VaultSyncCenter.shared.vault
        let block = block
        let image = await Task.detached(priority: .userInitiated) { InkFiles.image(for: block).pngData() }.value
        do {
            try vault.write(try JSONEncoder().encode(block), to: InkFiles.dataPath(notePath: notePath, name: request.name))
            if let image {
                try vault.write(image, to: InkFiles.imagePath(notePath: notePath, name: request.name))
            }
            VaultSyncCenter.shared.localDidChange()
            onSaved(request)
            dismiss()
        } catch {
            // 寫入本機失敗（空間不足等）：保留畫面讓使用者再試
        }
    }
}
