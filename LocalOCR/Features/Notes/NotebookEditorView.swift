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
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = ""
    @State private var title = ""
    @State private var archive: NotebookArchive?
    @State private var loadFailed = false
    @State private var handle = CanvasNotebookHandle()
    @State private var revision = 0
    @State private var showsInspector = false
    @State private var saveTask: Task<Void, Never>?
    @State private var recognizeTask: Task<Void, Never>?
    /// 畫布回報、還沒寫進檔案的最新筆跡（離開時畫布可能已經不在，靠它保住最後幾筆）。
    @State private var pendingDrawing: PKDrawing?
    @State private var isPublishing = false
    /// 有沒有還沒更新到 Obsidian 圖片的修改（沒改過就不必重新產生、上傳圖片）。
    @State private var hasUnpublishedChanges = false
    /// 載入筆跡時的同步 revision：之後其他裝置的版本下載下來就換過去。
    @State private var loadedRevision = 0
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
                ContentUnavailableView("無法開啟手寫筆記", systemImage: "exclamationmark.triangle", description: Text("尚未同步到這台裝置"))
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
            BackgroundWork.run("notebook-publish") { await publishAndUpload() }
        }
        // 同步前先把畫布上的最新筆跡存進檔案
        .onReceive(NotificationCenter.default.publisher(for: .vaultWillSync)) { _ in captureDrawing() }
        .onChange(of: sync.revision) { _, _ in reloadIfChangedElsewhere() }
        .onChange(of: scenePhase) { _, phase in
            // 切到其他 App、鎖定螢幕或被系統關閉前：立即存檔，並更新 Obsidian 中的圖片與 Markdown
            guard phase != .active else { return }
            captureDrawing()
            if hasUnpublishedChanges { BackgroundWork.run("notebook-publish") { await publishAndUpload() } }
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
            HandwritingMentionsMenu(text: archive?.recognizedText ?? "")
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
        loadedRevision = sync.revision
        if let loaded = await NotebookFiles.load(notePath: initialPath, id: notebookID) {
            archive = loaded
            sync.touch(initialPath)
        } else {
            loadFailed = true
        }
    }

    /// 其他裝置（iPhone、另一台 iPad）在這本寫了字、同步下載了新版本：這裡沒有還沒存的筆跡時換成新版本。
    private func reloadIfChangedElsewhere() {
        guard let current = archive, pendingDrawing == nil, saveTask == nil else { return }
        let archivePath = LocalVault.normalize(NotebookFiles.archivePath(notePath: path, id: current.id))
        guard let downloaded = sync.downloadedAt[archivePath], downloaded > loadedRevision else { return }
        loadedRevision = sync.revision
        guard let data = try? sync.vault.read(archivePath),
              var latest = try? NotebookArchive.decoder.decode(NotebookArchive.self, from: data) else { return }
        latest.migrateToCanvas()
        guard latest != current else { return }
        archive = latest
        handle.loadRemote(latest.pkDrawing)
        if latest.paper != current.paper { revision += 1 }
    }

    private func scheduleSave(_ drawing: PKDrawing) {
        hasUnpublishedChanges = true
        pendingDrawing = drawing
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveTask = nil
            archive?.pkDrawing = drawing
            pendingDrawing = nil
            saveArchiveNow()
            scheduleRecognition()
        }
    }

    /// 停筆 4 秒辨識手寫：@人名補上號碼、@時間排提醒（不必等離開筆記）。
    private func scheduleRecognition() {
        recognizeTask?.cancel()
        recognizeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let current = archive, let recognized = await NotebookFiles.recognize(current) else { return }
            // 辨識期間又寫了字：等下次停筆
            guard !Task.isCancelled, var latest = archive, latest.drawing == recognized.drawing else { return }
            latest.recognizedText = recognized.recognizedText
            latest.recognizedFingerprint = recognized.recognizedFingerprint
            latest.mentionDates = recognized.mentionDates
            archive = latest
            saveArchiveNow()
            NoteReminderCenter.shared.update(path: path, text: NotebookFiles.markdown(for: latest, notePath: path, vault: store.vault))
        }
    }

    /// 取得畫布目前的筆跡（畫布已經不在時用最後回報的筆跡）；有還沒存檔的筆跡時立即存檔。
    private func captureDrawing() {
        saveTask?.cancel()
        saveTask = nil
        let latest = handle.currentDrawing ?? pendingDrawing
        pendingDrawing = nil
        if let latest, var current = archive, latest.dataRepresentation() != current.drawing {
            current.pkDrawing = latest
            archive = current
            saveArchiveNow()
        }
    }

    private func saveArchiveNow() {
        guard var current = archive else { return }
        current.updatedAt = Date()
        archive = current
        do {
            try NotebookFiles.saveArchive(current, notePath: path)
        } catch {
            toast = "筆跡存檔失敗：\(error.localizedDescription)"
        }
    }

    /// 離開筆記、切到其他 App 時：更新圖片與 Markdown，並等筆跡上傳完成（在背景時間內）。
    private func publishAndUpload() async {
        await publish()
        await VaultSyncCenter.shared.flushPushes(timeout: 20)
    }

    /// 更新畫布圖片與 Markdown（離開、同步、AI 整理後）。
    private func publish() async {
        captureDrawing()
        guard let current = archive, !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }
        do {
            let published = try await NotebookFiles.publish(current, notePath: path, store: store)
            // 辨識結果記在畫面上的筆跡資料（筆跡沒變時），之後存檔不會蓋掉
            if var latest = archive, latest.drawing == published.drawing {
                latest.recognizedText = published.recognizedText
                latest.recognizedFingerprint = published.recognizedFingerprint
                latest.mentionDates = published.mentionDates
                latest.pageCount = published.pageCount
                archive = latest
            }
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
                    Text("整理中…").foregroundStyle(.secondary)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                case .idle:
                    EmptyView()
                }
            } header: {
                Text("Apple Intelligence")
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
            await JentechStore.shared.loadContacts()
            let enriched = HandwritingMentions.enrich(text, contacts: JentechStore.shared.contacts, known: archive?.mentionDates ?? [:], now: Date())
            archive?.pkDrawing = drawing
            archive?.recognizedText = enriched.text
            archive?.mentionDates = enriched.dates.isEmpty ? nil : enriched.dates
            archive?.recognizedFingerprint = archive?.drawingFingerprint
            phase = .thinking
            archive?.insights = try await NoteIntelligence.insights(for: enriched.text)
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
