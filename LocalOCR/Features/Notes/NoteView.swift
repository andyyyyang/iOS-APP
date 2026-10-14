import PhotosUI
import SwiftUI
import UIKit

/// 一則 Markdown 筆記：閱讀（可點待辦、手寫區塊、[[連結]]）與編輯（即時樣式、手寫區塊、照片）。
/// 大綱、反向連結與 Apple Intelligence 在工作區的右側欄；這裡回報即時內容並套用右側欄的跳轉與修改。
struct NoteView: View {
    let initialPath: String
    var onPathChange: (String) -> Void = { _ in }
    var onOpenNote: (String) -> Void = { _ in }

    @Environment(\.openURL) private var openURL
    @Environment(Workspace.self) private var workspace
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
    @State private var toast: String?
    @FocusState private var titleFocused: Bool
    private let sync = VaultSyncCenter.shared
    private let store = NotesStore.shared

    var body: some View {
        content
            .toolbar(.hidden, for: .navigationBar)
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
            .onChange(of: text) { _, newText in
                workspace.liveText[path] = newText
                scheduleSave()
            }
            .onChange(of: workspace.editRequest) { _, request in
                guard let request, request.path == path else { return }
                text = request.transform(text)
                workspace.editRequest = nil
                toast = "已更新筆記"
            }
            .onChange(of: workspace.revealRequest) { _, request in
                guard let request, request.path == path, isEditing else { return }
                controller.reveal(line: request.heading.line)
            }
            .onChange(of: titleFocused) { _, focused in
                if !focused { rename(to: title) }
            }
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
            VStack(spacing: 0) {
                headerBar
                titleField
                    .padding(.horizontal, 28)
                    .padding(.top, 6)
                MarkdownEditor(
                    text: $text,
                    controller: controller,
                    onInsertInk: { inkRequest = InkEditRequest(name: InkFiles.newName(), isNew: true) },
                    onInsertPhoto: { showsPhotoPicker = true }
                )
                .ignoresSafeArea(.container, edges: .bottom)
            }
        } else {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    headerBar
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                titleField
                                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("空白筆記。按下方的 T 開始書寫。")
                                        .font(.subheadline)
                                        .foregroundStyle(DS.textTertiary)
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
                                }
                            }
                            .padding(.horizontal, 32)
                            .padding(.top, 10)
                            .padding(.bottom, 100)
                            .frame(maxWidth: 760, alignment: .leading)
                            .frame(maxWidth: .infinity)
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: workspace.revealRequest) { _, request in
                            guard let request, request.path == path else { return }
                            withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo(request.heading.block, anchor: .top) }
                        }
                    }
                }
                notePalette
                    .padding(.bottom, 20)
            }
        }
    }

    /// 上方一列：所在資料夾與修改時間，右邊是編輯／完成與更多。
    private var headerBar: some View {
        HStack(spacing: 8) {
            let folder = (path as NSString).deletingLastPathComponent
            HStack(spacing: 4) {
                Text(folder.isEmpty ? NotesStore.folderTitle("") : folder.replacingOccurrences(of: "/", with: " / "))
                if let mtime = store.notes.first(where: { $0.path == path })?.mtime {
                    Text("· \(mtime.formatted(.relative(presentation: .named)))編輯")
                }
            }
            .font(.footnote)
            .foregroundStyle(DS.textTertiary)
            .lineLimit(1)
            Spacer(minLength: 8)
            Button(isEditing ? "完成" : "編輯") { toggleEditing() }
                .buttonStyle(PillButtonStyle(kind: isEditing ? .primary : .secondary, compact: true))
            Menu {
                Button {
                    inkRequest = InkEditRequest(name: InkFiles.newName(), isNew: true)
                } label: {
                    Label("插入手寫區塊", systemImage: "pencil")
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
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .frame(width: 32, height: 32)
                    .background(DS.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// 大標題，點一下可以改名（改名會改檔名，同步到 Obsidian）。
    private var titleField: some View {
        TextField("標題", text: $title)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(DS.text)
            .focused($titleFocused)
            .submitLabel(.done)
            .onSubmit { titleFocused = false }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 閱讀時的黑色浮動工具列：編輯、手寫區塊、照片、待辦、AI。
    private var notePalette: some View {
        FloatingPalette {
            PaletteButton(title: "編輯", glyph: "T", pastel: .lavender) { toggleEditing() }
            PaletteButton(title: "插入手寫區塊", systemImage: "pencil", pastel: .sky) {
                inkRequest = InkEditRequest(name: InkFiles.newName(), isNew: true)
            }
            PaletteButton(title: "插入照片", systemImage: "photo", pastel: .blush) { showsPhotoPicker = true }
            PaletteButton(title: "新增待辦", systemImage: "checkmark.square", pastel: .butter) {
                text = text.trimmingCharacters(in: .newlines) + (text.isEmpty ? "" : "\n") + "- [ ] "
                toggleEditing()
            }
            PaletteButton(title: "Apple Intelligence 整理", glyph: "AI", pastel: .mint) { workspace.showRight(.ai) }
        }
    }

    private func toggleEditing() {
        withAnimation(.easeOut(duration: 0.2)) { isEditing.toggle() }
        if isEditing {
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                controller.focus()
            }
        } else {
            flushSave()
        }
    }

    // MARK: - 載入與儲存

    private func load() {
        guard !didLoad else { return }
        path = initialPath
        text = sync.vault.readText(path) ?? ""
        savedText = text
        workspace.liveText[path] = text
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

    /// 內嵌圖片：本機有就直接讀，沒有就從 Railway 空間下載。
    static func loadImage(named name: String) async -> UIImage? {
        guard let url = await VaultSyncCenter.shared.localURL(forEmbed: name) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil as UIImage? }
            return image.preparingThumbnail(of: CGSize(width: 1600, height: 1600 * image.size.height / max(image.size.width, 1))) ?? image
        }.value
    }
}
