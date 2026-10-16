import PencilKit
import SwiftUI

/// 日誌筆記本：一頁一頁的手寫筆記本，每頁屬於一天（每天第一次打開自動加一頁今天的）。
/// 停筆幾秒後在裝置上辨識改過的頁面：寫了「#機種代號」的地方貼上機種標記（點了開啟機種的整理筆記）；
/// 離開時依日期整理成 Markdown（Apple Intelligence 摘要、重點、待跟進、提到的機種、當天的日誌連結、每頁圖片與手寫內容）。
struct JournalNotebookView: View {
    let initialPath: String
    let notebookID: String
    var onPathChange: (String) -> Void = { _ in }

    @Environment(Workspace.self) private var workspace
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(JournalViewMode.storageKey) private var viewModeRaw = JournalViewMode.scroll.rawValue
    @State private var path = ""
    @State private var title = ""
    @State private var notebook: JournalNotebook?
    @State private var loadFailed = false
    @State private var handle = JournalCanvasHandle()
    @State private var revision = 0
    @State private var visiblePage = 0
    @State private var saveTask: Task<Void, Never>?
    @State private var organizeTask: Task<Void, Never>?
    /// 畫布回報、還沒寫進檔案的最新筆跡（與當時的排列方式）。
    @State private var pendingDrawing: (drawing: PKDrawing, mode: JournalViewMode)?
    @State private var hasUnpublishedChanges = false
    @State private var isOrganizing = false
    @State private var pendingDelete: Int?
    @State private var picking: TagReference?
    @State private var toast: String?
    @FocusState private var titleFocused: Bool
    private let store = NotesStore.shared
    private let sync = VaultSyncCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(DS.hairline).frame(height: 1)
            if let notebook {
                JournalCanvas(
                    drawing: { mode in JournalLayout.combine(notebook.pages.map(\.pkDrawing), mode: mode) },
                    pages: pageInfos(notebook),
                    paper: notebook.paper,
                    mode: viewMode,
                    handle: handle,
                    revision: revision,
                    onDrawingChange: scheduleSave,
                    onBadgeTap: { page, tag in tapBadge(page: page, tag: tag) },
                    onAddPage: { addPage() },
                    onVisiblePageChange: { visiblePage = $0 }
                )
                .ignoresSafeArea(.container, edges: .bottom)
            } else if loadFailed {
                ContentUnavailableView("無法開啟日誌筆記本", systemImage: "exclamationmark.triangle", description: Text("找不到筆記本資料（\(notebookID)），可能還沒同步到這台裝置。"))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DS.pane)
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog(
            JournalDeletePrompt.title(pendingDelete),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除", role: .destructive) {
                if let index = pendingDelete { deletePage(index) }
                pendingDelete = nil
            }
        } message: {
            Text(JournalDeletePrompt.message(pageCount: notebook?.pages.count ?? 0))
        }
        // 右側欄的「日誌」面板跟著這本筆記本
        .onAppear { attachSession() }
        .onChange(of: notebook) { _, _ in pushSession() }
        .onChange(of: isOrganizing) { _, _ in pushSession() }
        .onChange(of: visiblePage) { _, _ in pushSession() }
        .onChange(of: path) { old, _ in
            JournalSession.shared.detach(path: old)
            attachSession()
        }
        .sheet(item: $picking) { reference in
            ModelPickerSheet(tag: tag(reference), models: JournalFiles.models()) { choice in choose(choice, for: reference) }
        }
        .toast($toast)
        .onChange(of: titleFocused) { _, focused in
            if !focused { rename(to: title) }
        }
        .task { await load() }
        .onDisappear {
            JournalSession.shared.detach(path: path)
            captureDrawing()
            organizeTask?.cancel()
            guard hasUnpublishedChanges else { return }
            BackgroundWork.run("journal-publish") { await finish() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultWillSync)) { _ in captureDrawing() }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            captureDrawing()
            if hasUnpublishedChanges { BackgroundWork.run("journal-publish") { await finish() } }
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
            if let notebook, notebook.pages.indices.contains(visiblePage) {
                Text("\(JournalLayout.heading(for: notebook.pages[visiblePage].date)) · \(pageLabel(notebook))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Button {
                addPage()
            } label: {
                HeaderIcon(systemImage: "doc.badge.plus")
            }
            .buttonStyle(.plain)
            .disabled(notebook == nil)
            .accessibilityLabel("新增一頁")
            Menu {
                Picker("顯示方式", selection: $viewModeRaw) {
                    ForEach(JournalViewMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode.rawValue)
                    }
                }
            } label: {
                HeaderIcon(systemImage: viewMode.systemImage)
            }
            .disabled(notebook == nil)
            .accessibilityLabel("顯示方式")
            Menu {
                Picker("紙張", selection: Binding(get: { notebook?.paper ?? .lined }, set: { changePaper($0) })) {
                    ForEach(PaperStyle.allCases) { style in
                        Label(style.title, systemImage: style.systemImage).tag(style)
                    }
                }
            } label: {
                HeaderIcon(systemImage: notebook?.paper.systemImage ?? "doc")
            }
            .disabled(notebook == nil)
            .accessibilityLabel("紙張")
            Button {
                Task { await organize(summarize: true) }
            } label: {
                if isOrganizing {
                    ProgressView().frame(width: 32, height: 32)
                } else {
                    HeaderIcon(systemImage: "wand.and.stars")
                }
            }
            .buttonStyle(.plain)
            .disabled(notebook == nil || isOrganizing)
            .accessibilityLabel("辨識並整理")
            Button("日誌") { toggleJournalPanel() }
                .buttonStyle(PillButtonStyle(kind: isJournalPanelShown ? .primary : .secondary, compact: true))
                .disabled(notebook == nil)
                .accessibilityLabel("在右側欄依日期列出頁面與整理")
            Menu {
                Button(role: .destructive) {
                    pendingDelete = visiblePage
                } label: {
                    Label(deleteMenuTitle, systemImage: "trash")
                }
                .disabled(notebook == nil)
                if let url = NotesSettings.obsidianURL(for: path) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app")
                    }
                }
            } label: {
                HeaderIcon(systemImage: "ellipsis")
            }
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var deleteMenuTitle: String {
        let number = visiblePage + 1
        return viewMode == .spread ? "刪除左邊這一頁（第 \(number) 頁）" : "刪除這一頁（第 \(number) 頁）"
    }

    private var viewMode: JournalViewMode {
        JournalViewMode(rawValue: viewModeRaw) ?? .scroll
    }

    /// 「第 3/10 頁」；兩頁並排時「第 3–4/10 頁」。
    private func pageLabel(_ notebook: JournalNotebook) -> String {
        let count = notebook.pages.count
        if viewMode == .spread, visiblePage + 1 < count {
            return "第 \(visiblePage + 1)–\(visiblePage + 2)/\(count) 頁"
        }
        return "第 \(visiblePage + 1)/\(count) 頁"
    }

    /// 右側欄正在顯示這本的「日誌」（iPhone 的右側欄是拉出來的抽屜，按鈕不維持選取）。
    private var isJournalPanelShown: Bool {
        sizeClass != .compact && workspace.isRightOpen && workspace.rightMode == .journal
    }

    private func toggleJournalPanel() {
        if isJournalPanelShown {
            workspace.setRightOpen(false)
        } else {
            workspace.revealRight(.journal)
        }
    }

    private func attachSession() {
        guard notebook != nil else { return }
        JournalSession.shared.attach(path: path, actions: JournalSession.Actions(
            showPage: { handle.scrollToPage($0) },
            addPage: { addPage() },
            deletePage: { deletePage($0) },
            organize: { Task { await organize(summarize: true) } },
            openModel: { openModel($0) }
        ))
        pushSession()
    }

    private func pushSession() {
        JournalSession.shared.update(path: path, notebook: notebook, isOrganizing: isOrganizing, visiblePage: visiblePage)
    }

    private func pageInfos(_ notebook: JournalNotebook) -> [JournalPageInfo] {
        notebook.pages.enumerated().map { index, page in
            let badges = page.tags.enumerated().compactMap { tagIndex, tag -> JournalBadge? in
                // 使用者說「不是機種」的不顯示
                if tag.confirmed, tag.modelPath == nil { return nil }
                let state: JournalBadge.State = tag.isLinked ? .linked : (tag.candidates.isEmpty ? .unknown : .ambiguous)
                return JournalBadge(label: tag.modelCode ?? tag.text, anchor: tag.rect, state: state, tagIndex: tagIndex)
            }
            return JournalPageInfo(day: page.date, number: index + 1, badges: badges)
        }
    }

    // MARK: - 載入與儲存

    private func load() async {
        guard notebook == nil, !loadFailed else { return }
        path = initialPath
        title = ((initialPath as NSString).lastPathComponent as NSString).deletingPathExtension
        guard var loaded = await JournalFiles.load(notePath: initialPath, id: notebookID) else {
            loadFailed = true
            return
        }
        // 日誌：今天第一次打開，加一頁今天的
        if loaded.ensurePage(for: JournalLayout.day()) {
            try? JournalFiles.save(loaded, notePath: initialPath)
        }
        notebook = loaded
        revision += 1
        attachSession()
        sync.touch(initialPath)
        let last = loaded.pages.count - 1
        try? await Task.sleep(for: .milliseconds(350))
        handle.scrollToPage(last, animated: false)
    }

    private func scheduleSave(_ drawing: PKDrawing, mode: JournalViewMode) {
        hasUnpublishedChanges = true
        pendingDrawing = (drawing, mode)
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveTask = nil
            storeDrawing(drawing, mode: mode)
            scheduleOrganize()
        }
    }

    /// 把畫布筆跡分回每一頁並存檔（依畫布當時的排列方式）。
    private func storeDrawing(_ drawing: PKDrawing, mode: JournalViewMode) {
        guard var current = notebook else { return }
        pendingDrawing = nil
        let pages = JournalLayout.split(drawing, pageCount: current.pages.count, mode: mode)
        var changed = false
        for (index, page) in pages.enumerated() where current.pages[index].drawing != page.dataRepresentation() {
            current.pages[index].pkDrawing = page
            changed = true
        }
        guard changed else { return }
        current.updatedAt = Date()
        notebook = current
        do {
            try JournalFiles.save(current, notePath: path)
        } catch {
            toast = "筆跡存檔失敗：\(error.localizedDescription)"
        }
    }

    /// 取得畫布目前的筆跡（畫布已經不在時用最後回報的筆跡），有還沒存檔的就立即存檔。
    private func captureDrawing() {
        saveTask?.cancel()
        saveTask = nil
        if let drawing = handle.currentDrawing, let mode = handle.currentMode {
            storeDrawing(drawing, mode: mode)
        } else if let pending = pendingDrawing {
            storeDrawing(pending.drawing, mode: pending.mode)
        }
    }

    /// 停筆幾秒後辨識改過的頁面（貼上機種標記）；不在背景整理、不更新 Markdown（離開時才更新）。
    private func scheduleOrganize() {
        organizeTask?.cancel()
        organizeTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await organize(summarize: false)
        }
    }

    /// 辨識改過的頁面；`summarize` 時也整理每天的內容並更新 Markdown。
    private func organize(summarize: Bool) async {
        captureDrawing()
        guard let snapshot = notebook, !isOrganizing else { return }
        isOrganizing = true
        defer { isOrganizing = false }
        let (recognized, count) = await JournalIntelligence.recognizeChangedPages(snapshot, models: JournalFiles.models())
        merge(recognized)
        if summarize {
            if let current = notebook {
                merge(await JournalIntelligence.summarizeChangedDays(current), days: true)
            }
            await publish()
            toast = count > 0 ? "已辨識 \(count) 頁並整理" : "已整理"
        } else if count > 0, let current = notebook {
            try? JournalFiles.save(current, notePath: path)
        }
    }

    /// 辨識（整理）期間又寫了字：只更新筆跡沒變的頁面的辨識結果。
    private func merge(_ result: JournalNotebook, days: Bool = false) {
        guard var current = notebook else { return }
        for page in result.pages {
            guard let index = current.pages.firstIndex(where: { $0.id == page.id }), current.pages[index].drawing == page.drawing else { continue }
            current.pages[index].recognizedText = page.recognizedText
            current.pages[index].recognizedFingerprint = page.recognizedFingerprint
            current.pages[index].tags = page.tags
        }
        if days { current.days = result.days }
        if current != notebook {
            notebook = current
            hasUnpublishedChanges = true
        }
    }

    /// 離開、切到背景時：辨識、整理、更新圖片與 Markdown，並等上傳完成（在背景時間內）。
    private func finish() async {
        await organize(summarize: true)
        await VaultSyncCenter.shared.flushPushes(timeout: 20)
    }

    private func publish() async {
        guard let current = notebook else { return }
        do {
            let published = try await JournalFiles.publish(current, notePath: path, store: store)
            if var latest = notebook {
                for page in published.pages {
                    if let index = latest.pages.firstIndex(where: { $0.id == page.id }), latest.pages[index].drawing == page.drawing {
                        latest.pages[index].publishedFingerprint = page.publishedFingerprint
                    }
                }
                notebook = latest
            }
            hasUnpublishedChanges = false
        } catch {
            toast = "儲存失敗：\(error.localizedDescription)"
        }
    }

    // MARK: - 頁面

    private func addPage() {
        captureDrawing()
        guard var current = notebook else { return }
        current.pages.append(JournalPage(date: JournalLayout.day()))
        current.updatedAt = Date()
        notebook = current
        hasUnpublishedChanges = true
        try? JournalFiles.save(current, notePath: path)
        let last = current.pages.count - 1
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            handle.scrollToPage(last)
        }
    }

    /// 刪除一頁：後面的頁碼往前（頁面圖片要重新產生），刪掉的頁面圖片也從 vault 移除；只剩一頁時清成今天的空白頁。
    private func deletePage(_ index: Int) {
        captureDrawing()
        guard var current = notebook, current.pages.indices.contains(index) else { return }
        let removed = current.pages[index]
        if current.pages.count == 1 {
            current.pages[0] = JournalPage(date: JournalLayout.day())
        } else {
            current.pages.remove(at: index)
            for later in index..<current.pages.count { current.pages[later].publishedFingerprint = nil }
        }
        // 那一天沒有頁面了：整理結果也拿掉
        let dates = Set(current.pages.map(\.date))
        current.days = current.days.filter { dates.contains($0.key) }
        current.updatedAt = Date()
        notebook = current
        hasUnpublishedChanges = true
        do {
            try JournalFiles.save(current, notePath: path)
        } catch {
            toast = "刪除失敗：\(error.localizedDescription)"
            return
        }
        // 頁面位置變了：畫布依剩下的頁面重新排列
        revision += 1
        let notePath = path
        let id = current.id
        Task { await JournalFiles.removePageImage(notePath: notePath, id: id, page: removed, store: store) }
        let target = min(index, current.pages.count - 1)
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            handle.scrollToPage(target, animated: false)
        }
        toast = "已刪除第 \(index + 1) 頁"
    }

    private func changePaper(_ paper: PaperStyle) {
        captureDrawing()
        guard var current = notebook else { return }
        current.paper = paper
        for index in current.pages.indices { current.pages[index].publishedFingerprint = nil }
        notebook = current
        hasUnpublishedChanges = true
        try? JournalFiles.save(current, notePath: path)
    }

    private func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard notebook != nil, !trimmed.isEmpty else { return }
        if let newPath = try? store.rename(path, to: trimmed), newPath != path {
            path = newPath
            onPathChange(newPath)
        }
    }

    // MARK: - 機種標記

    private func tapBadge(page: Int, tag: Int) {
        guard let notebook, notebook.pages.indices.contains(page), notebook.pages[page].tags.indices.contains(tag) else { return }
        let item = notebook.pages[page].tags[tag]
        if let modelPath = item.modelPath {
            openModel(modelPath)
        } else {
            picking = TagReference(pageID: notebook.pages[page].id, index: tag)
        }
    }

    private func openModel(_ modelPath: String) {
        captureDrawing()
        workspace.openNote(modelPath)
    }

    private func tag(_ reference: TagReference) -> JournalTag? {
        guard let page = notebook?.pages.first(where: { $0.id == reference.pageID }), page.tags.indices.contains(reference.index) else { return nil }
        return page.tags[reference.index]
    }

    /// 選了機種（nil：不是機種，不再顯示標記）。
    private func choose(_ entry: ModelEntry?, for reference: TagReference) {
        guard var current = notebook, let pageIndex = current.pages.firstIndex(where: { $0.id == reference.pageID }),
              current.pages[pageIndex].tags.indices.contains(reference.index) else { return }
        current.pages[pageIndex].tags[reference.index].modelPath = entry?.path
        current.pages[pageIndex].tags[reference.index].modelCode = entry?.code
        current.pages[pageIndex].tags[reference.index].candidates = []
        current.pages[pageIndex].tags[reference.index].confirmed = true
        notebook = current
        hasUnpublishedChanges = true
        try? JournalFiles.save(current, notePath: path)
    }
}

/// 要選機種的標記（頁面代碼＋第幾個標記）。
struct TagReference: Identifiable, Equatable {
    let pageID: String
    let index: Int
    var id: String { "\(pageID)#\(index)" }
}

/// 上方一列的圖示按鈕。
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

/// 標記對不到（或不確定）時選機種：先列出可能的，也可以搜尋代號、開案單號、客戶。
struct ModelPickerSheet: View {
    let tag: JournalTag?
    let models: [ModelEntry]
    var onChoose: (ModelEntry?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty, let tag, !tag.candidates.isEmpty {
                    Section("可能是") {
                        ForEach(models.filter { tag.candidates.contains($0.path) }) { row($0) }
                    }
                }
                Section(query.isEmpty ? "所有機種（\(models.count)）" : "搜尋結果") {
                    ForEach(results) { row($0) }
                }
                Section {
                    Button("這不是機種", role: .destructive) {
                        onChoose(nil)
                        dismiss()
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "代號、開案單號、客戶")
            .navigationTitle(tag.map { "#\($0.text)" } ?? "選擇機種")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var results: [ModelEntry] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return models }
        let fuzzy = ModelCatalog.match(text, in: models, limit: 20).map(\.entry)
        let plain = models.filter { model in
            ([model.code, model.customer, model.detail, model.title] + model.aliases).contains { $0.localizedCaseInsensitiveContains(text) }
        }
        var seen = Set<String>()
        return (fuzzy + plain).filter { seen.insert($0.path).inserted }
    }

    private func row(_ model: ModelEntry) -> some View {
        Button {
            onChoose(model)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.code).font(.body.weight(.semibold)).foregroundStyle(DS.text)
                Text([model.customer, model.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
            }
        }
    }
}
