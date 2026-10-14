import PencilKit
import SwiftUI

/// 手寫筆記：打開就是可以直接書寫的連續畫布（Apple Pencil 書寫、手指捲動；寫到底部自動加長），
/// 上方一列是標題（點一下改名）、紙張、同步與 AI。
/// 筆記本身是一個 Markdown 檔（Obsidian 中顯示 AI 摘要、手寫內容與畫布圖片），筆跡存在附件資料夾。
struct NotebookEditorView: View {
    let initialPath: String
    let notebookID: String
    var onPathChange: (String) -> Void = { _ in }

    @Environment(\.openURL) private var openURL
    @State private var path = ""
    @State private var title = ""
    @State private var archive: NotebookArchive?
    @State private var loadFailed = false
    @State private var handle = CanvasNotebookHandle()
    @State private var revision = 0
    @State private var showsInspector = false
    @State private var saveTask: Task<Void, Never>?
    @State private var isPublishing = false
    /// 有沒有還沒更新到 Obsidian 圖片的修改（沒改過就不必重新產生、上傳圖片）。
    @State private var hasUnpublishedChanges = false
    @State private var toast: String?
    @FocusState private var titleFocused: Bool
    private let store = NotesStore.shared
    private let sync = VaultSyncCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(DS.hairline).frame(height: 1)
            if let archive {
                CanvasNotebook(
                    drawing: { handle.currentDrawing ?? archive.pkDrawing },
                    minimumSegments: archive.pageCount,
                    paper: archive.paper,
                    handle: handle,
                    revision: revision,
                    onDrawingChange: scheduleSave
                )
                .ignoresSafeArea(.container, edges: .bottom)
            } else if loadFailed {
                ContentUnavailableView("無法開啟手寫筆記", systemImage: "exclamationmark.triangle", description: Text("找不到筆跡資料（\(notebookID)），可能還沒同步到這台裝置。"))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DS.pane)
        .toolbar(.hidden, for: .navigationBar)
        .inspector(isPresented: $showsInspector) {
            NotebookInspector(archive: $archive, currentDrawing: { currentDrawing }, onChange: {
                hasUnpublishedChanges = true
                saveArchiveNow()
            }, onPublish: { await publish() })
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .toast($toast)
        .onChange(of: titleFocused) { _, focused in
            if !focused { rename(to: title) }
        }
        .task { await load() }
        .onDisappear {
            // 畫布還在時先取得最後一筆，再更新圖片與 Markdown
            captureDrawing()
            guard hasUnpublishedChanges else { return }
            Task { await publish() }
        }
    }

    // MARK: - 上方一列

    private var header: some View {
        HStack(spacing: 8) {
            TextField("標題", text: $title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DS.text)
                .focused($titleFocused)
                .submitLabel(.done)
                .onSubmit { titleFocused = false }
            Menu {
                Picker("紙張", selection: Binding(get: { archive?.paper ?? .blank }, set: { changePaper($0) })) {
                    ForEach(PaperStyle.allCases) { style in
                        Label(style.title, systemImage: style.systemImage).tag(style)
                    }
                }
            } label: {
                HeaderIcon(systemImage: archive?.paper.systemImage ?? "doc")
            }
            .disabled(archive == nil)
            .accessibilityLabel("紙張")
            Button {
                Task { await syncNow() }
            } label: {
                if isPublishing || sync.isSyncing {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    HeaderIcon(systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.plain)
            .disabled(archive == nil || isPublishing)
            .accessibilityLabel("同步")
            Button("AI") { showsInspector.toggle() }
                .buttonStyle(PillButtonStyle(kind: showsInspector ? .primary : .secondary, compact: true))
                .disabled(archive == nil)
                .accessibilityLabel("Apple Intelligence 整理")
            if let url = NotesSettings.obsidianURL(for: path) {
                Menu {
                    Button {
                        openURL(url)
                    } label: {
                        Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app")
                    }
                } label: {
                    HeaderIcon(systemImage: "ellipsis")
                }
                .accessibilityLabel("更多")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
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
            sync.touch(initialPath)
        } else {
            loadFailed = true
        }
    }

    private func scheduleSave(_ drawing: PKDrawing) {
        hasUnpublishedChanges = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            archive?.pkDrawing = drawing
            saveArchiveNow()
        }
    }

    /// 取得畫布目前的筆跡；有還沒存檔的筆跡時立即存檔。
    private func captureDrawing() {
        let pending = saveTask != nil
        saveTask?.cancel()
        saveTask = nil
        if let drawing = handle.currentDrawing, var current = archive, drawing != current.pkDrawing {
            current.pkDrawing = drawing
            archive = current
            saveArchiveNow()
        } else if pending {
            saveArchiveNow()
        }
    }

    private func saveArchiveNow() {
        guard var current = archive else { return }
        current.updatedAt = Date()
        archive = current
        try? NotebookFiles.saveArchive(current, notePath: path)
    }

    /// 更新畫布圖片與 Markdown（離開、同步、AI 整理後）。
    private func publish() async {
        captureDrawing()
        guard let current = archive, !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }
        do {
            try await NotebookFiles.publish(current, notePath: path, store: store)
            hasUnpublishedChanges = false
        } catch {
            toast = "儲存失敗：\(error.localizedDescription)"
        }
    }

    private func syncNow() async {
        await publish()
        await sync.syncNow()
        toast = sync.lastError ?? "已同步"
    }

    private func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard archive != nil, !trimmed.isEmpty else { return }
        if let newPath = try? store.rename(path, to: trimmed), newPath != path {
            path = newPath
            onPathChange(newPath)
        }
    }

    private func changePaper(_ style: PaperStyle) {
        captureDrawing()
        archive?.paper = style
        NotesSettings.lastPaper = style
        hasUnpublishedChanges = true
        saveArchiveNow()
        revision += 1
    }
}

/// 上方一列的圖示按鈕（與 Markdown 筆記相同的淺灰方塊）。
private struct HeaderIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DS.text)
            .frame(width: 32, height: 32)
            .background(DS.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        Text(archive?.insights == nil ? "整理這份筆記" : "重新整理")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }
                .disabled(isWorking || archive == nil)
                switch phase {
                case .recognizing(let part, let total):
                    Text(total > 1 ? "正在辨識手寫（\(part)／\(total)）…" : "正在辨識手寫…").foregroundStyle(.secondary)
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
        .canvasList()
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
        guard archive != nil else { return }
        let drawing = currentDrawing()
        do {
            phase = .recognizing(0, 0)
            let text = try await NoteIntelligence.recognizeHandwriting(drawing: drawing) { part, total in
                phase = .recognizing(part, total)
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
