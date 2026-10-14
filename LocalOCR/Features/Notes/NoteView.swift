import PhotosUI
import SwiftUI
import UIKit

/// 一則 Markdown 筆記：只有一種模式，打字的同時直接顯示排版後的樣子（像 Obsidian 的即時預覽）。
/// 點待辦打勾、點 [[連結]] 開啟或建立筆記、點手寫區塊繼續編輯；上方的「AI」請 Apple Intelligence 修改選取的文字或整則筆記。
/// 大綱、反向連結與整理摘要在工作區的右側欄；這裡回報即時內容並套用右側欄的跳轉與修改。
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
    @State private var didLoad = false
    @State private var controller = MarkdownEditorController()
    @State private var saveTask: Task<Void, Never>?
    @State private var inkRequest: InkEditRequest?
    @State private var aiRequest: AIEditRequest?
    @State private var showsPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var toast: String?
    @State private var header = NoteHeaderState()
    @FocusState private var titleFocused: Bool
    private let sync = VaultSyncCenter.shared
    private let store = NotesStore.shared

    var body: some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $inkRequest) { request in
                InkBlockEditorView(notePath: path, request: request) { saved in
                    if saved.isNew {
                        controller.insertBlock("![[\(saved.name).png]]")
                    } else {
                        // 圖片檔名不變：重新整理畫面讓新的圖片顯示
                        sync.revision += 1
                    }
                }
            }
            .sheet(item: $aiRequest) { request in
                AIEditSheet(request: request) { result in apply(result, for: request) }
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
                guard let request, request.path == path else { return }
                controller.reveal(line: request.heading.line)
            }
            .onChange(of: workspace.anchorRequest) { _, _ in revealPendingAnchor() }
            .onChange(of: titleFocused) { _, focused in
                if !focused { rename(to: title) }
            }
            .onChange(of: sync.revision) { _, _ in reloadIfChangedElsewhere() }
            .toast($toast)
            .task { load() }
            // 打開時先取得最新版本；之後其他裝置的修改由伺服器即時推送
            .task { await sync.refreshOpenFile(initialPath) }
            .onDisappear(perform: flushSave)
    }

    @ViewBuilder
    private var content: some View {
        if !didLoad {
            ProgressView()
        } else {
            // 內容捲到標題後面：標題列浮在上方，下緣漸層淡出；往下捲時大標題縮小收進上方一列
            ZStack(alignment: .top) {
                MarkdownEditor(
                    text: $text,
                    controller: controller,
                    onInsertInk: { inkRequest = InkEditRequest(name: InkFiles.newName(), isNew: true) },
                    onInsertPhoto: { showsPhotoPicker = true },
                    onAIEdit: { startAIEdit() },
                    onOpenLink: { handleTap($0) },
                    loadImage: { await Self.loadImage(named: $0) },
                    resolvesLink: { NoteLinks.resolve($0, in: store.linkIndex) != nil },
                    linkSuggestions: { store.linkSuggestions(for: $0) },
                    headerHeights: (header.barHeight + header.titleHeight, header.barHeight),
                    onScroll: { [header] in header.scroll = $0 }
                )
                .overlay(alignment: .top) { placeholder }
                .ignoresSafeArea(.container, edges: .bottom)
                NoteTitleHeader(
                    state: header,
                    compactTitle: title,
                    meta: headerMeta,
                    actions: headerActions,
                    title: titleField
                        .padding(.horizontal, NoteTextView.horizontalPadding)
                        .padding(.top, 6)
                        .frame(maxWidth: NoteTextView.columnWidth, alignment: .leading)
                        .frame(maxWidth: .infinity),
                    onTapCompact: { controller.scrollToTop() }
                )
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if text.isEmpty {
            Text("開始書寫…　輸入 [[ 連到其他筆記，或按上方的 AI 請它幫忙")
                .font(.body)
                .foregroundStyle(DS.textTertiary)
                .padding(.horizontal, NoteTextView.horizontalPadding)
                .padding(.top, header.barHeight + header.titleHeight + NoteTextView.topInset)
                .frame(maxWidth: NoteTextView.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
    }

    /// 上方一列的左邊：所在資料夾與修改時間（標題收合後換成標題）。
    private var headerMeta: some View {
        let folder = (path as NSString).deletingLastPathComponent
        return HStack(spacing: 4) {
            Text(folder.isEmpty ? NotesStore.folderTitle("") : folder.replacingOccurrences(of: "/", with: " / "))
            if let mtime = store.notes.first(where: { $0.path == path })?.mtime {
                Text("· \(mtime.formatted(.relative(presentation: .named)))編輯")
            }
        }
        .font(.footnote)
        .foregroundStyle(DS.textTertiary)
        .lineLimit(1)
    }

    /// 上方一列的右邊：AI 與更多。
    private var headerActions: some View {
        HStack(spacing: 8) {
            Button("AI") { startAIEdit() }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                .accessibilityLabel("請 AI 修改")
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
                Button {
                    workspace.showRight(.ai)
                } label: {
                    Label("整理摘要與標籤", systemImage: "list.bullet.rectangle")
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
    }

    /// 大標題，點一下可以改名（改名會改檔名，同步到 Obsidian，並更新其他筆記中的連結）。
    private var titleField: some View {
        TextField("標題", text: $title)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(DS.text)
            .focused($titleFocused)
            .submitLabel(.done)
            .onSubmit { titleFocused = false }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 點擊、連結與 AI

    private func handleTap(_ target: MarkdownTapTarget) {
        switch target {
        case .wikiLink(let link):
            workspace.openLink(link, from: path)
        case .link(let url):
            openMarkdownLink(url)
        case .image(let name):
            if let block = InkFiles.blockName(fromEmbed: name) {
                inkRequest = InkEditRequest(name: block, isNew: false)
            }
        case .checkbox:
            break
        }
    }

    /// [文字](網址)：網址用瀏覽器開；obsidian:// 與相對路徑的 .md 開啟 vault 中的筆記。
    private func openMarkdownLink(_ raw: String) {
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased() {
            if scheme == "obsidian", let file = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "file" })?.value {
                workspace.openLink(file, from: path)
            } else {
                openURL(url)
            }
            return
        }
        let decoded = raw.removingPercentEncoding ?? raw
        let folder = (path as NSString).deletingLastPathComponent
        let relative = LocalVault.normalize((folder as NSString).appendingPathComponent(decoded))
        if store.notes.contains(where: { $0.path == relative }) {
            onOpenNote(relative)
        } else {
            workspace.openLink(decoded, from: path)
        }
    }

    /// 有選取文字時修改選取的部分，否則修改整則筆記的內文（不含屬性）。
    private func startAIEdit() {
        let ns = text as NSString
        let selection = controller.selectedRange
        if selection.length > 0, NSMaxRange(selection) <= ns.length {
            aiRequest = AIEditRequest(range: selection, original: ns.substring(with: selection), wholeNote: false)
        } else {
            let body = NoteMarkdownEditing.bodyRange(in: text)
            aiRequest = AIEditRequest(range: body, original: ns.substring(with: body), wholeNote: true)
        }
    }

    private func apply(_ result: String, for request: AIEditRequest) {
        let ns = text as NSString
        guard NSMaxRange(request.range) <= ns.length, ns.substring(with: request.range) == request.original else {
            toast = "筆記在 AI 修改期間有變動，請重新選取後再試"
            return
        }
        controller.replace(range: request.range, with: result)
        toast = "已套用 AI 的修改"
    }

    /// [[筆記#標題]]：開啟後跳到標題或 ^區塊。
    private func revealPendingAnchor() {
        guard didLoad, let request = workspace.anchorRequest, request.path == path else { return }
        workspace.anchorRequest = nil
        if let line = NoteLinks.line(forAnchor: request.anchor, in: text) {
            controller.reveal(line: line)
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
        didLoad = true
        sync.touch(path)
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            // 空白筆記直接開始打字；從 [[筆記#標題]] 開啟時跳到標題
            if isEmpty { controller.focus() }
            revealPendingAnchor()
        }
    }

    private func scheduleSave() {
        guard didLoad, text != savedText else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
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
        let oldPath = path
        let previousIndex = store.linkIndex
        if let newPath = try? store.rename(path, to: trimmed), newPath != path {
            path = newPath
            onPathChange(newPath)
            // 像 Obsidian：更新其他筆記中指到這則筆記的連結
            Task {
                let count = await store.updateLinks(renamedFrom: oldPath, to: newPath, previousIndex: previousIndex)
                if count > 0 { toast = "已更新 \(count) 則筆記中的連結" }
            }
        }
    }

    // MARK: - 插入

    private func insertBlock(_ snippet: String) {
        controller.insertBlock(snippet)
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
        if name.hasPrefix("http://") || name.hasPrefix("https://") {
            guard let url = URL(string: name), let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return nil }
            return image.preparingThumbnail(of: CGSize(width: 1600, height: 1600 * image.size.height / max(image.size.width, 1))) ?? image
        }
        guard let url = await VaultSyncCenter.shared.localURL(forEmbed: name) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil as UIImage? }
            return image.preparingThumbnail(of: CGSize(width: 1600, height: 1600 * image.size.height / max(image.size.width, 1))) ?? image
        }.value
    }
}

// MARK: - 標題列

/// 筆記標題列的捲動狀態：只有標題列讀取捲動距離，捲動時不會重畫整個筆記頁。
@Observable
final class NoteHeaderState {
    /// 上方一列（資料夾、AI、更多）的高度。
    var barHeight: CGFloat = 46
    /// 大標題那一列的高度。
    var titleHeight: CGFloat = 46
    /// 內容往下捲的距離（0 = 最上面）。
    var scroll: CGFloat = 0

    /// 0 = 展開的大標題，1 = 收合成上方一列的小標題。
    var progress: CGFloat {
        guard titleHeight > 0 else { return 0 }
        return min(max(scroll / titleHeight, 0), 1)
    }
}

/// 浮在筆記上方的標題列：往下捲時大標題縮小、淡出，小標題出現在上方一列（點一下捲回最上面）；
/// 下緣有一段漸層，內容捲到標題後面時慢慢淡出，不會被一刀切掉。
struct NoteTitleHeader<Meta: View, Actions: View, Title: View>: View {
    let state: NoteHeaderState
    let compactTitle: String
    let meta: Meta
    let actions: Actions
    let title: Title
    var onTapCompact: () -> Void

    static var fadeHeight: CGFloat { 22 }

    var body: some View {
        let progress = state.progress
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    meta
                        .opacity(1 - min(progress * 1.6, 1))
                    Button(action: onTapCompact) {
                        Text(compactTitle)
                            .font(.headline)
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(max(progress * 2 - 1, 0))
                    .allowsHitTesting(progress > 0.6)
                    .accessibilityHidden(progress < 0.6)
                    .accessibilityHint("捲回最上面")
                }
                Spacer(minLength: 8)
                actions
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.barHeight = $0 }
            title
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.titleHeight = $0 }
                .scaleEffect(1 - 0.18 * progress, anchor: .bottomLeading)
                .opacity(1 - min(progress * 1.4, 1))
                .frame(height: max(state.titleHeight * (1 - progress), 0), alignment: .bottom)
                .clipped()
                .allowsHitTesting(progress < 0.5)
        }
        .background(DS.pane)
        .overlay(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: DS.pane, location: 0),
                    .init(color: DS.pane.opacity(0.75), location: 0.3),
                    .init(color: DS.pane.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.fadeHeight)
            .offset(y: Self.fadeHeight)
            .allowsHitTesting(false)
        }
    }
}
