import PencilKit
import SwiftUI

/// 手寫筆記本：分頁紙張＋原生 Apple Pencil 工具列；右側檢閱器（iPad）或底部面板（iPhone）是 AI 整理。
/// 筆記本本身是一個 Markdown 檔（Obsidian 中顯示 AI 摘要、手寫內容與每頁圖片），筆跡存在附件資料夾。
struct NotebookEditorView: View {
    let initialPath: String
    let notebookID: String
    var onPathChange: (String) -> Void = { _ in }

    @State private var path = ""
    @State private var title = ""
    @State private var archive: NotebookArchive?
    @State private var loadFailed = false
    @State private var handle = NotebookCanvasHandle()
    @State private var revision = 0
    @State private var visiblePage = 0
    @State private var showsInspector = false
    @State private var showsPages = false
    @State private var saveTask: Task<Void, Never>?
    @State private var isPublishing = false
    @State private var toast: String?
    private let store = NotesStore.shared

    var body: some View {
        Group {
            if let archive {
                NotebookCanvas(
                    drawing: { archive.pkDrawing },
                    pageCount: archive.pageCount,
                    paper: archive.paper,
                    handle: handle,
                    revision: revision,
                    onDrawingChange: scheduleSave,
                    onVisiblePageChange: { visiblePage = $0 }
                )
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) { pageIndicator(pageCount: archive.pageCount) }
            } else if loadFailed {
                ContentUnavailableView("無法開啟筆記本", systemImage: "exclamationmark.triangle", description: Text("找不到筆跡資料（\(notebookID)），可能還沒同步到這台裝置。"))
            } else {
                ProgressView()
            }
        }
        .navigationTitle($title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar { toolbarContent }
        .inspector(isPresented: $showsInspector) {
            NotebookInspector(archive: $archive, currentDrawing: { currentDrawing }, onChange: { saveArchiveNow() }, onPublish: { await publish() })
                .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
        }
        .sheet(isPresented: $showsPages) {
            if let archive {
                NotebookPagesSheet(pageCount: archive.pageCount, paper: archive.paper, drawing: currentDrawing, current: visiblePage) { action in
                    handlePageAction(action)
                }
            }
        }
        .toast($toast)
        .onChange(of: title) { _, newTitle in rename(to: newTitle) }
        .task { await load() }
        .onDisappear { Task { await publish() } }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showsPages = true
            } label: {
                Label("頁面", systemImage: "square.grid.2x2")
            }
            .disabled(archive == nil)

            Menu {
                Button {
                    handlePageAction(.insert(after: visiblePage))
                } label: {
                    Label("在這頁後面插入", systemImage: "doc.badge.plus")
                }
                Button {
                    handlePageAction(.append)
                } label: {
                    Label("加到最後", systemImage: "plus.rectangle.on.rectangle")
                }
                Picker(selection: Binding(get: { archive?.paper ?? .lined }, set: { changePaper($0) })) {
                    ForEach(PaperStyle.allCases) { style in
                        Label(style.title, systemImage: style.systemImage).tag(style)
                    }
                } label: {
                    Label("紙張", systemImage: "doc.richtext")
                }
                Divider()
                Button(role: .destructive) {
                    handlePageAction(.delete(visiblePage))
                } label: {
                    Label("刪除這一頁", systemImage: "trash")
                }
                .disabled((archive?.pageCount ?? 1) <= 1)
            } label: {
                Label("新增頁面", systemImage: "plus")
            }
            .disabled(archive == nil)

            Button {
                Task {
                    await publish()
                    await VaultSyncCenter.shared.syncNow()
                    toast = VaultSyncCenter.shared.lastError ?? "已同步"
                }
            } label: {
                if isPublishing || VaultSyncCenter.shared.isSyncing {
                    ProgressView()
                } else {
                    Label("同步", systemImage: "arrow.triangle.2.circlepath.icloud")
                }
            }
            .disabled(archive == nil || isPublishing)

            Button {
                showsInspector.toggle()
            } label: {
                Label("Apple Intelligence", systemImage: "sparkles")
            }
        }
    }

    private func pageIndicator(pageCount: Int) -> some View {
        Text("\(visiblePage + 1) / \(pageCount)")
            .font(.footnote.monospacedDigit().weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 12)
            .allowsHitTesting(false)
    }

    private var currentDrawing: PKDrawing {
        handle.currentDrawing ?? archive?.pkDrawing ?? PKDrawing()
    }

    // MARK: - 載入與儲存

    private func load() async {
        guard archive == nil, !loadFailed else { return }
        path = initialPath
        title = ((initialPath as NSString).lastPathComponent as NSString).deletingPathExtension
        if let loaded = await NotebookFiles.load(notePath: initialPath, id: notebookID) {
            archive = loaded
        } else {
            loadFailed = true
        }
    }

    private func scheduleSave(_ drawing: PKDrawing) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            archive?.pkDrawing = drawing
            saveArchiveNow()
        }
    }

    private func captureDrawing() {
        saveTask?.cancel()
        saveTask = nil
        if let drawing = handle.currentDrawing, var current = archive, drawing != current.pkDrawing {
            current.pkDrawing = drawing
            archive = current
        }
    }

    private func saveArchiveNow() {
        guard var current = archive else { return }
        current.updatedAt = Date()
        archive = current
        try? NotebookFiles.saveArchive(current, notePath: path)
    }

    /// 更新每頁圖片與 Markdown（離開、同步、AI 整理後）。
    private func publish() async {
        captureDrawing()
        guard let current = archive, !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }
        do {
            try await NotebookFiles.publish(current, notePath: path, store: store)
        } catch {
            toast = "儲存失敗：\(error.localizedDescription)"
        }
    }

    private func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard archive != nil, !trimmed.isEmpty else { return }
        if let newPath = try? store.rename(path, to: trimmed), newPath != path {
            path = newPath
            onPathChange(newPath)
        }
    }

    // MARK: - Pages

    private func handlePageAction(_ action: NotebookPageAction) {
        captureDrawing()
        guard var current = archive else { return }
        let count = current.pageCount
        switch action {
        case .append:
            current.pageCount = count + 1
            archive = current
            reload(scrollTo: count)
        case .insert(let after):
            current.pkDrawing = current.pkDrawing.insertingPage(at: after + 1, pageCount: count)
            current.pageCount = count + 1
            archive = current
            reload(scrollTo: after + 1)
        case .delete(let index):
            guard count > 1 else { return }
            current.pkDrawing = current.pkDrawing.removingPage(index, pageCount: count)
            current.pageCount = count - 1
            archive = current
            reload(scrollTo: min(index, count - 2))
        case .go(let index):
            handle.scrollToPage(index)
            return
        }
        saveArchiveNow()
    }

    private func changePaper(_ style: PaperStyle) {
        captureDrawing()
        archive?.paper = style
        saveArchiveNow()
        reload(scrollTo: nil)
    }

    private func reload(scrollTo page: Int?) {
        revision += 1
        if let page {
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                handle.scrollToPage(page)
            }
        }
    }
}

enum NotebookPageAction {
    case append
    case insert(after: Int)
    case delete(Int)
    case go(Int)
}

// MARK: - 頁面總覽

private struct NotebookPagesSheet: View {
    let pageCount: Int
    let paper: PaperStyle
    let drawing: PKDrawing
    let current: Int
    var onAction: (NotebookPageAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var thumbnails: [Int: UIImage] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 20)], spacing: 24) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Button {
                            onAction(.go(index))
                            dismiss()
                        } label: {
                            VStack(spacing: 8) {
                                thumbnail(index)
                                Text("\(index + 1)")
                                    .font(.footnote.weight(index == current ? .bold : .regular))
                                    .foregroundStyle(index == current ? Color.accentColor : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                onAction(.insert(after: index))
                                dismiss()
                            } label: {
                                Label("在後面插入一頁", systemImage: "doc.badge.plus")
                            }
                            Button(role: .destructive) {
                                onAction(.delete(index))
                                dismiss()
                            } label: {
                                Label("刪除這一頁", systemImage: "trash")
                            }
                            .disabled(pageCount <= 1)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("頁面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onAction(.append)
                        dismiss()
                    } label: {
                        Label("新增頁面", systemImage: "plus")
                    }
                }
            }
            .task { await renderThumbnails() }
        }
    }

    private func thumbnail(_ index: Int) -> some View {
        ZStack {
            Color.white
            if let image = thumbnails[index] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .aspectRatio(NotebookLayout.pageSize.width / NotebookLayout.pageSize.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(index == current ? Color.accentColor : Color.black.opacity(0.08), lineWidth: index == current ? 2.5 : 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }

    private func renderThumbnails() async {
        let drawing = drawing
        let paper = paper
        for index in 0..<pageCount {
            let image = await Task.detached(priority: .userInitiated) {
                PaperRenderer.pageImage(drawing: drawing, page: index, paper: paper, scale: 0.35)
            }.value
            thumbnails[index] = image
        }
    }
}

// MARK: - 檢閱器：Apple Intelligence

private struct NotebookInspector: View {
    @Binding var archive: NotebookArchive?
    var currentDrawing: () -> PKDrawing
    var onChange: () -> Void
    var onPublish: () async -> Void

    @State private var phase: Phase = .idle

    enum Phase: Equatable {
        case idle
        case recognizing(Int, Int)
        case thinking
        case failed(String)
    }

    private var isWorking: Bool {
        switch phase {
        case .recognizing, .thinking: return true
        default: return false
        }
    }

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await analyze() }
                } label: {
                    HStack {
                        Label(archive?.insights == nil ? "整理這份筆記" : "重新整理", systemImage: "sparkles")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }
                .disabled(isWorking || archive == nil)
                switch phase {
                case .recognizing(let page, let total):
                    Text("正在辨識手寫（第 \(page)／\(total) 頁）…").foregroundStyle(.secondary)
                case .thinking:
                    Text("Apple Intelligence 正在整理…").foregroundStyle(.secondary)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                case .idle:
                    EmptyView()
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text("手寫辨識與整理都在裝置上完成。結果會寫進這份筆記的 Markdown（Obsidian 中可以看到與搜尋），你在 Obsidian 寫的其他文字不會被改動。")
            }

            if let insights = archive?.insights {
                insightsSections(insights)
            }

            if let text = archive?.recognizedText, !text.isEmpty {
                Section("手寫內容") {
                    Text(text)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func insightsSections(_ insights: NoteInsights) -> some View {
        Section("摘要") {
            Text(insights.summary)
                .font(.callout)
                .textSelection(.enabled)
        }
        if !insights.keyPoints.isEmpty {
            Section("重點") {
                ForEach(insights.keyPoints, id: \.self) { point in
                    Label(point, systemImage: "circle.fill")
                        .labelStyle(BulletLabelStyle())
                }
            }
        }
        if !insights.actionItems.isEmpty {
            Section("待辦") {
                ForEach(insights.actionItems, id: \.self) { item in
                    Label(item, systemImage: "circle")
                }
            }
        }
        if !insights.tags.isEmpty {
            Section("標籤") {
                Text(insights.tags.map { "#\($0)" }.joined(separator: "  "))
                    .foregroundStyle(.tint)
            }
        }
    }

    private func analyze() async {
        guard let current = archive else { return }
        let drawing = currentDrawing()
        do {
            phase = .recognizing(0, current.pageCount)
            let text = try await NoteIntelligence.recognizeHandwriting(drawing: drawing, pageCount: current.pageCount) { page, total in
                phase = .recognizing(page, total)
            }
            archive?.pkDrawing = drawing
            archive?.recognizedText = text
            phase = .thinking
            archive?.insights = try await NoteIntelligence.insights(for: text)
            onChange()
            await onPublish()
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
            onChange()
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon
                .font(.system(size: 6))
                .foregroundStyle(.tint)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            configuration.title
        }
    }
}
