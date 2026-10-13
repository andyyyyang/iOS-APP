import PencilKit
import SwiftData
import SwiftUI

/// 筆記本編輯畫面：分頁紙張＋原生 Apple Pencil 工具列；右側檢閱器（iPad）或底部面板（iPhone）是 AI 整理與同步。
struct NotebookEditorView: View {
    @Bindable var notebook: Notebook

    @Environment(\.modelContext) private var modelContext
    @AppStorage(NotesSettings.Key.autoSync) private var autoSync = true
    @State private var handle = NotebookCanvasHandle()
    @State private var revision = 0
    @State private var visiblePage = 0
    @State private var showsInspector = false
    @State private var showsPages = false
    @State private var saveTask: Task<Void, Never>?
    @State private var toast: String?
    @State private var sync = NotebookSyncModel()

    var body: some View {
        NotebookCanvas(
            notebook: notebook,
            handle: handle,
            revision: revision,
            onDrawingChange: scheduleSave,
            onVisiblePageChange: { visiblePage = $0 }
        )
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .bottom) { pageIndicator }
        .navigationTitle($notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar { toolbarContent }
        .inspector(isPresented: $showsInspector) {
            NotebookInspector(notebook: notebook, sync: sync, currentDrawing: { currentDrawing })
                .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
        }
        .sheet(isPresented: $showsPages) {
            NotebookPagesSheet(notebook: notebook, drawing: currentDrawing, current: visiblePage) { action in
                handlePageAction(action)
            }
        }
        .toast($toast)
        .onChange(of: notebook.title) { _, _ in notebook.touch() }
        .onDisappear(perform: finishEditing)
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
                Picker(selection: Binding(get: { notebook.paper }, set: { changePaper($0) })) {
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
                .disabled(notebook.pageCount <= 1)
            } label: {
                Label("新增頁面", systemImage: "plus")
            }

            Button {
                Task { await syncNow() }
            } label: {
                if sync.isSyncing {
                    ProgressView()
                } else {
                    Label("同步到 Obsidian", systemImage: notebook.needsSync ? "arrow.triangle.2.circlepath.icloud" : "checkmark.icloud")
                }
            }
            .disabled(sync.isSyncing || !ServerSettings.isConfigured)

            Button {
                showsInspector.toggle()
            } label: {
                Label("Apple Intelligence", systemImage: "sparkles")
            }
        }
    }

    private var pageIndicator: some View {
        Text("\(visiblePage + 1) / \(notebook.pageCount)")
            .font(.footnote.monospacedDigit().weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 12)
            .allowsHitTesting(false)
    }

    private var currentDrawing: PKDrawing {
        handle.currentDrawing ?? notebook.drawing
    }

    // MARK: - Saving

    private func scheduleSave(_ drawing: PKDrawing) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            notebook.drawing = drawing
            notebook.touch()
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        if let drawing = handle.currentDrawing, drawing != notebook.drawing {
            notebook.drawing = drawing
            notebook.touch()
        }
    }

    private func finishEditing() {
        flushSave()
        NotebookCovers.update(notebook)
        try? modelContext.save()
        if autoSync, notebook.needsSync, let client = VaultClient.configured() {
            let notebook = notebook
            Task { try? await NotebookVaultSync.push(notebook, client: client) }
        }
    }

    private func syncNow() async {
        flushSave()
        guard let client = VaultClient.configured() else { return }
        toast = await sync.push(notebook, client: client)
        try? modelContext.save()
    }

    // MARK: - Pages

    private func handlePageAction(_ action: NotebookPageAction) {
        flushSave()
        let count = notebook.pageCount
        switch action {
        case .append:
            notebook.pageCount = count + 1
            reload(scrollTo: count)
        case .insert(let after):
            notebook.drawing = notebook.drawing.insertingPage(at: after + 1, pageCount: count)
            notebook.pageCount = count + 1
            reload(scrollTo: after + 1)
        case .delete(let index):
            guard count > 1 else { return }
            notebook.drawing = notebook.drawing.removingPage(index, pageCount: count)
            notebook.pageCount = count - 1
            reload(scrollTo: min(index, count - 2))
        case .go(let index):
            handle.scrollToPage(index)
            return
        }
        notebook.touch()
    }

    private func changePaper(_ style: PaperStyle) {
        flushSave()
        notebook.paper = style
        notebook.touch()
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

/// 同步狀態（工具列與檢閱器共用）。
@MainActor
@Observable
final class NotebookSyncModel {
    var isSyncing = false
    var lastMessage: String?

    func push(_ notebook: Notebook, client: VaultClient) async -> String {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let message = try await NotebookVaultSync.push(notebook, client: client)
            lastMessage = message
            return message
        } catch {
            let message = "同步失敗：\(error.localizedDescription)"
            lastMessage = message
            return message
        }
    }
}

// MARK: - 頁面總覽

private struct NotebookPagesSheet: View {
    let notebook: Notebook
    let drawing: PKDrawing
    let current: Int
    var onAction: (NotebookPageAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var thumbnails: [Int: UIImage] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 20)], spacing: 24) {
                    ForEach(0..<notebook.pageCount, id: \.self) { index in
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
                            .disabled(notebook.pageCount <= 1)
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
        let paper = notebook.paper
        for index in 0..<notebook.pageCount {
            let image = await Task.detached(priority: .userInitiated) {
                PaperRenderer.pageImage(drawing: drawing, page: index, paper: paper, scale: 0.35)
            }.value
            thumbnails[index] = image
        }
    }
}

// MARK: - 檢閱器：Apple Intelligence 與 Obsidian

private struct NotebookInspector: View {
    @Bindable var notebook: Notebook
    let sync: NotebookSyncModel
    var currentDrawing: () -> PKDrawing

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
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
                        Label(notebook.insights == nil ? "整理這份筆記" : "重新整理", systemImage: "sparkles")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }
                .disabled(isWorking)
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
                Text("手寫辨識與整理都在裝置上完成，筆記不會上傳到 AI 服務。")
            }

            if let insights = notebook.insights {
                insightsSections(insights)
            }

            if let text = notebook.recognizedText, !text.isEmpty {
                Section("手寫內容") {
                    Text(text)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }

            Section {
                if let path = notebook.vaultPath {
                    LabeledContent("位置", value: path)
                        .font(.footnote)
                }
                if let syncedAt = notebook.syncedAt {
                    LabeledContent("上次同步", value: syncedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let message = sync.lastMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        guard let client = VaultClient.configured() else { return }
                        notebook.drawing = currentDrawing()
                        _ = await sync.push(notebook, client: client)
                        try? modelContext.save()
                    }
                } label: {
                    Label("同步到 Obsidian", systemImage: "arrow.triangle.2.circlepath.icloud")
                }
                .disabled(sync.isSyncing || !ServerSettings.isConfigured)
                if let path = notebook.vaultPath, let url = NotesSettings.obsidianURL(for: path) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app")
                    }
                }
            } header: {
                Text("Obsidian")
            } footer: {
                if !ServerSettings.isConfigured {
                    Text("在「設定」連接伺服器後即可同步到 Obsidian。")
                }
            }
        }
    }

    @ViewBuilder
    private func insightsSections(_ insights: NoteInsights) -> some View {
        Section("摘要") {
            if !insights.title.isEmpty, insights.title != notebook.title {
                Button {
                    notebook.title = insights.title
                    notebook.touch()
                } label: {
                    Label("使用標題「\(insights.title)」", systemImage: "character.cursor.ibeam")
                }
            }
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
        let drawing = currentDrawing()
        notebook.drawing = drawing
        do {
            phase = .recognizing(0, notebook.pageCount)
            let text = try await NoteIntelligence.recognizeHandwriting(drawing: drawing, pageCount: notebook.pageCount) { page, total in
                phase = .recognizing(page, total)
            }
            notebook.recognizedText = text
            phase = .thinking
            notebook.insights = try await NoteIntelligence.insights(for: text)
            notebook.touch()
            try? modelContext.save()
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
            notebook.touch()
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
