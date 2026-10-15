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
    @State private var path = ""
    @State private var title = ""
    @State private var notebook: JournalNotebook?
    @State private var loadFailed = false
    @State private var handle = JournalCanvasHandle()
    @State private var revision = 0
    @State private var visiblePage = 0
    @State private var saveTask: Task<Void, Never>?
    @State private var organizeTask: Task<Void, Never>?
    /// 畫布回報、還沒寫進檔案的最新筆跡。
    @State private var pendingDrawing: PKDrawing?
    @State private var hasUnpublishedChanges = false
    @State private var isOrganizing = false
    @State private var showsDays = false
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
                    drawing: { handle.currentDrawing ?? JournalLayout.combine(notebook.pages.map(\.pkDrawing)) },
                    pages: pageInfos(notebook),
                    paper: notebook.paper,
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
        .inspector(isPresented: $showsDays) {
            JournalDaysPanel(notebook: notebook, isOrganizing: isOrganizing, onOrganize: { Task { await organize(summarize: true) } }, onOpenModel: openModel, onShowPage: { handle.scrollToPage($0) })
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
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
                Text("\(JournalLayout.heading(for: notebook.pages[visiblePage].date)) · 第 \(visiblePage + 1)/\(notebook.pages.count) 頁")
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
            Button("日誌") { showsDays.toggle() }
                .buttonStyle(PillButtonStyle(kind: showsDays ? .primary : .secondary, compact: true))
                .disabled(notebook == nil)
                .accessibilityLabel("依日期整理")
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
        sync.touch(initialPath)
        let last = loaded.pages.count - 1
        try? await Task.sleep(for: .milliseconds(350))
        handle.scrollToPage(last, animated: false)
    }

    private func scheduleSave(_ drawing: PKDrawing) {
        hasUnpublishedChanges = true
        pendingDrawing = drawing
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveTask = nil
            storeDrawing(drawing)
            scheduleOrganize()
        }
    }

    /// 把畫布筆跡分回每一頁並存檔。
    private func storeDrawing(_ drawing: PKDrawing) {
        guard var current = notebook else { return }
        pendingDrawing = nil
        let pages = JournalLayout.split(drawing, pageCount: current.pages.count)
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
        if let latest = handle.currentDrawing ?? pendingDrawing {
            storeDrawing(latest)
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

// MARK: - 依日期整理

/// 側邊的「日誌」：每天的摘要、重點、待跟進、提到的機種與頁面（點了捲到那一頁）。
private struct JournalDaysPanel: View {
    let notebook: JournalNotebook?
    let isOrganizing: Bool
    var onOrganize: () -> Void
    var onOpenModel: (String) -> Void
    var onShowPage: (Int) -> Void

    var body: some View {
        List {
            Section {
                Button {
                    onOrganize()
                } label: {
                    HStack {
                        Text("辨識並整理")
                        Spacer()
                        if isOrganizing { ProgressView() }
                    }
                }
                .disabled(isOrganizing || notebook == nil)
            } footer: {
                Text("在裝置上辨識手寫，寫了「#機種代號」的地方會貼上機種標記；Apple Intelligence 依日期整理摘要。結果會寫進這份筆記的 Markdown，Obsidian 中也看得到。")
            }
            if let notebook {
                ForEach(notebook.pagesByDay) { day in
                    let pages = day.pages.map { notebook.pages[$0] }
                    if pages.contains(where: { !$0.isBlank }) {
                        Section(JournalLayout.heading(for: day.date)) {
                            if let insights = notebook.days[day.date] {
                                Text(insights.summary).font(.callout)
                                ForEach(insights.keyPoints, id: \.self) { point in
                                    Label(point, systemImage: "circle.fill").labelStyle(DotLabelStyle())
                                }
                                ForEach(insights.actionItems, id: \.self) { item in
                                    Label(item, systemImage: "arrow.turn.down.right").font(.callout)
                                }
                            }
                            let models = JournalMarkdown.linkedModels(in: pages)
                            if !models.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(models, id: \.path) { model in
                                            Button {
                                                onOpenModel(model.path)
                                            } label: {
                                                Label(model.code, systemImage: "link")
                                                    .font(.caption.weight(.semibold))
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 5)
                                                    .background(DS.Pastel.sky.color, in: Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            HStack(spacing: 6) {
                                ForEach(day.pages, id: \.self) { index in
                                    Button("第 \(index + 1) 頁") { onShowPage(index) }
                                        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon
                .font(.system(size: 6))
                .foregroundStyle(.tint)
            configuration.title.font(.callout)
        }
    }
}

// MARK: - 選擇機種

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
