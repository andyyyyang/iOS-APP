import PhotosUI
import SwiftUI
import UIKit

/// 一則 Markdown 筆記：閱讀（可點待辦、手寫區塊、[[連結]]）與編輯（即時樣式、手寫區塊、照片），右側 Apple Intelligence。
struct NoteView: View {
    let initialPath: String
    var onPathChange: (String) -> Void = { _ in }
    var onOpenNote: (String) -> Void = { _ in }

    @Environment(\.openURL) private var openURL
    @State private var path = ""
    @State private var text = ""
    @State private var savedText = ""
    @State private var title = ""
    @State private var isEditing = false
    @State private var didLoad = false
    @State private var controller = MarkdownEditorController()
    @State private var saveTask: Task<Void, Never>?
    @State private var inkRequest: InkEditRequest?
    @State private var showsPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showsInspector = false
    @State private var insights: NoteInsights?
    @State private var aiMessage: String?
    @State private var isThinking = false
    @State private var toast: String?
    private let sync = VaultSyncCenter.shared
    private let store = NotesStore.shared

    var body: some View {
        content
            .navigationTitle($title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar { toolbarContent }
            .inspector(isPresented: $showsInspector) {
                inspector.inspectorColumnWidth(min: 300, ideal: 340, max: 440)
            }
            .sheet(item: $inkRequest) { request in
                InkBlockEditorView(notePath: path, request: request) { saved in
                    if saved.isNew {
                        insertBlock("![[\(saved.name).png]]")
                    } else {
                        // 圖片檔名不變：重新整理畫面讓新的圖片顯示
                        sync.revision += 1
                    }
                }
            }
            .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task { await insertPhoto(item) }
            }
            .onChange(of: text) { _, _ in scheduleSave() }
            .onChange(of: title) { _, newTitle in rename(to: newTitle) }
            .onChange(of: sync.revision) { _, _ in reloadIfChangedElsewhere() }
            .toast($toast)
            .task { load() }
            .onDisappear(perform: flushSave)
    }

    @ViewBuilder
    private var content: some View {
        if !didLoad {
            ProgressView()
        } else if isEditing {
            MarkdownEditor(
                text: $text,
                controller: controller,
                onInsertInk: { inkRequest = InkEditRequest(name: InkFiles.newName(), isNew: true) },
                onInsertPhoto: { showsPhotoPicker = true }
            )
            .ignoresSafeArea(.container, edges: .bottom)
        } else {
            ScrollView {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("空白筆記", systemImage: "square.and.pencil", description: Text("點右上角的鉛筆開始書寫。"))
                        .padding(.top, 80)
                } else {
                    MarkdownView(
                        text: text,
                        loadEmbed: { name in await Self.loadImage(named: name) },
                        onOpenLink: onOpenNote,
                        onToggleTask: { index in
                            text = NoteMarkdownEditing.togglingTask(at: index, in: text)
                        },
                        onTapEmbed: { name in
                            if let block = InkFiles.blockName(fromEmbed: name) {
                                inkRequest = InkEditRequest(name: block, isNew: false)
                            }
                        }
                    )
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                withAnimation { isEditing.toggle() }
                if isEditing {
                    Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        controller.focus()
                    }
                } else {
                    flushSave()
                }
            } label: {
                Label(isEditing ? "閱讀" : "編輯", systemImage: isEditing ? "book" : "pencil")
            }
            Button {
                showsInspector.toggle()
            } label: {
                Label("Apple Intelligence", systemImage: "sparkles")
            }
            Menu {
                Button {
                    inkRequest = InkEditRequest(name: InkFiles.newName(), isNew: true)
                } label: {
                    Label("插入手寫區塊", systemImage: "pencil.tip.crop.circle")
                }
                Button {
                    showsPhotoPicker = true
                } label: {
                    Label("插入照片", systemImage: "photo")
                }
                if let url = NotesSettings.obsidianURL(for: path) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app")
                    }
                }
                ShareLink(item: text) {
                    Label("分享文字", systemImage: "square.and.arrow.up")
                }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
        }
    }

    private var inspector: some View {
        Form {
            Section {
                Button {
                    Task { await analyze() }
                } label: {
                    HStack {
                        Label(insights == nil ? "整理這則筆記" : "重新整理", systemImage: "sparkles")
                        Spacer()
                        if isThinking { ProgressView() }
                    }
                }
                .disabled(isThinking || text.isEmpty)
                if let aiMessage {
                    Label(aiMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text("在裝置上整理摘要、重點、待辦與標籤；編輯時也可以選取文字使用系統的「書寫工具」。")
            }
            if let insights {
                Section("摘要") {
                    Text(insights.summary).font(.callout).textSelection(.enabled)
                }
                if !insights.keyPoints.isEmpty {
                    Section("重點") {
                        ForEach(insights.keyPoints, id: \.self) { Text("• \($0)") }
                    }
                }
                if !insights.actionItems.isEmpty {
                    Section("待辦") {
                        ForEach(insights.actionItems, id: \.self) { Label($0, systemImage: "circle") }
                    }
                }
                if !insights.tags.isEmpty {
                    Section("標籤") {
                        Text(insights.tags.map { "#\($0)" }.joined(separator: "  ")).foregroundStyle(.tint)
                    }
                }
                Section {
                    Button {
                        text = NoteMarkdownEditing.insertingInsights(insights, into: text)
                        toast = "已加到筆記開頭"
                    } label: {
                        Label("把摘要、重點與標籤加到筆記", systemImage: "text.insert")
                    }
                    if !insights.actionItems.isEmpty {
                        Button {
                            let tasks = insights.actionItems.map { "- [ ] \($0)" }.joined(separator: "\n")
                            text = text.trimmingCharacters(in: .newlines) + "\n\n## 待辦\n" + tasks + "\n"
                            toast = "已加入待辦"
                        } label: {
                            Label("把待辦加到筆記最後", systemImage: "checklist")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 載入與儲存

    private func load() {
        guard !didLoad else { return }
        path = initialPath
        text = sync.vault.readText(path) ?? ""
        savedText = text
        title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        isEditing = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        didLoad = true
        if isEditing {
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                controller.focus()
            }
        }
    }

    private func scheduleSave() {
        guard didLoad, text != savedText else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            flushSave()
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        guard didLoad, text != savedText else { return }
        do {
            try store.save(text, to: path)
            savedText = text
        } catch {
            toast = "儲存失敗：\(error.localizedDescription)"
        }
    }

    /// 同步下載了這則筆記的新版本：沒有未儲存的修改時更新畫面。
    private func reloadIfChangedElsewhere() {
        guard didLoad, text == savedText, let latest = sync.vault.readText(path), latest != savedText else { return }
        text = latest
        savedText = latest
    }

    private func rename(to newTitle: String) {
        guard didLoad else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        flushSave()
        if let newPath = try? store.rename(path, to: trimmed), newPath != path {
            path = newPath
            onPathChange(newPath)
        }
    }

    // MARK: - 插入

    private func insertBlock(_ snippet: String) {
        if isEditing {
            controller.insertBlock(snippet)
        } else {
            text = text.trimmingCharacters(in: .newlines) + (text.isEmpty ? "" : "\n\n") + snippet + "\n"
        }
    }

    private func insertPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
            toast = "無法載入照片"
            return
        }
        let name = "photo-" + UUID().uuidString.prefix(8).lowercased() + ".jpg"
        let resized = ImagePreprocessor.normalized(image, maxPixelLength: 2400)
        guard let jpeg = resized.jpegData(compressionQuality: 0.82) else { return }
        do {
            try sync.vault.write(jpeg, to: "\(NotesSettings.attachmentsFolder(forNote: path))/\(name)")
            insertBlock("![[\(name)]]")
        } catch {
            toast = "無法儲存照片：\(error.localizedDescription)"
        }
    }

    private func analyze() async {
        isThinking = true
        defer { isThinking = false }
        do {
            insights = try await NoteIntelligence.insights(for: text)
            aiMessage = nil
        } catch {
            aiMessage = error.localizedDescription
        }
    }

    /// 內嵌圖片：本機有就直接讀，沒有就從 Railway 空間下載。
    static func loadImage(named name: String) async -> UIImage? {
        guard let url = await VaultSyncCenter.shared.localURL(forEmbed: name) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil as UIImage? }
            return image.preparingThumbnail(of: CGSize(width: 1600, height: 1600 * image.size.height / max(image.size.width, 1))) ?? image
        }.value
    }
}
