import SwiftUI
import UIKit

/// 首頁：知識庫 AI。問問題或下指令，AI 在線上搜尋、閱讀、修改 vault（透過伺服器的 MCP，不下載），
/// 回答附上來源；改過的筆記可以復原。沒有對話時顯示建議問題與最近編輯的筆記。
struct AssistantHome: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var assistant = KnowledgeAssistant.shared
    @State private var store = NotesStore.shared
    @State private var sync = VaultSyncCenter.shared
    @State private var keyboard = KeyboardFrame.shared
    @State private var draft = ""
    @State private var notice: String?
    @State private var folderName = ""
    @State private var showsFolderPrompt = false
    @FocusState private var inputFocused: Bool

    private var isCompact: Bool { sizeClass == .compact }
    private var gutter: CGFloat { isCompact ? 16 : 24 }

    var body: some View {
        GeometryReader { proxy in
            let overlap = keyboard.overlap(with: proxy.frame(in: .global))
            VStack(spacing: 0) {
                header
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if assistant.messages.isEmpty {
                                welcome
                            } else {
                                ForEach(assistant.messages) { message in
                                    AssistantMessageView(message: message, undone: assistant.undone, onOpen: openReference, onUndo: undo, onUndoAll: undoAll)
                                }
                            }
                        }
                        .padding(.horizontal, gutter)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                        .frame(maxWidth: 800, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: assistant.messages) {
                        withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: overlap) {
                        reader.scrollTo("bottom", anchor: .bottom)
                    }
                }
                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(DS.warning)
                        .padding(.horizontal, gutter)
                        .padding(.bottom, 6)
                        .onTapGesture { self.notice = nil }
                }
                inputBar
                    .padding(.horizontal, gutter)
                    .padding(.bottom, overlap > 0 ? overlap + 8 : (isCompact ? 12 : 18))
                    .frame(maxWidth: 800)
                    .frame(maxWidth: .infinity)
            }
            .animation(.easeOut(duration: 0.25), value: overlap)
        }
        .task {
            if sync.isConfigured { await assistant.prepare() }
        }
        .alert("新增資料夾", isPresented: $showsFolderPrompt) {
            TextField("名稱", text: $folderName)
            Button("取消", role: .cancel) {}
            Button("建立") { workspace.createFolder(named: folderName, in: workspace.currentFolder) }
        }
    }

    // MARK: 標題

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("知識庫")
                .font(.system(size: isCompact ? 24 : 26, weight: .semibold))
                .foregroundStyle(DS.text)
            Text(Date().formatted(.dateTime.month().day().weekday(.wide)))
                .font(.subheadline)
                .foregroundStyle(DS.textSecondary)
            Spacer(minLength: 8)
            if !assistant.sessions.isEmpty {
                Menu {
                    ForEach(assistant.sessions.prefix(20)) { session in
                        Button(session.title) { open(session) }
                    }
                    Divider()
                    Button { workspace.open(.folder(KnowledgeAssistant.historyFolder)) } label: {
                        Label("在資料夾中查看全部", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DS.text)
                        .frame(width: 34, height: 34)
                        .background(DS.control, in: Circle())
                }
                .disabled(assistant.isWorking)
                .accessibilityLabel("對話紀錄")
            }
            if !assistant.messages.isEmpty {
                Button {
                    assistant.newConversation()
                    draft = ""
                    notice = nil
                } label: {
                    Label("新對話", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                .disabled(assistant.isWorking)
            }
        }
        .padding(.horizontal, gutter)
        .padding(.top, isCompact ? 16 : 20)
        .padding(.bottom, 10)
    }

    // MARK: 沒有對話時

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("想找什麼，或要整理什麼？")
                    .font(.system(size: isCompact ? 22 : 26, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text("AI 會在線上搜尋你的 vault（不下載到這台裝置），回答附上來源筆記；也可以直接請它新增、補充或修改筆記，改過的都能復原。")
                    .font(.subheadline)
                    .foregroundStyle(DS.textSecondary)
            }
            if !sync.isConfigured || !assistant.isServerConfigured {
                pairingCard
            } else {
                statusLines
                suggestions
            }
            if !assistant.sessions.isEmpty {
                history
            }
            recent
        }
        .padding(.top, 12)
    }

    private var statusLines: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .unavailable(let reason) = OnDeviceAIStatus.current {
                statusLine("sparkles", "\(reason)。目前只會列出搜尋結果。", tint: DS.warning)
            }
            if let path = assistant.rulesPath {
                Button { workspace.openNote(path) } label: {
                    statusLine("list.bullet.clipboard", "照著「\(KnowledgeAssistant.title(of: path))」的編輯規則\(assistant.rulesTruncated ? "（太長，只用前 \(KnowledgeAssistant.rulesLimit) 字）" : "")", tint: DS.textSecondary)
                }
                .buttonStyle(.plain)
            } else if assistant.rulesOverride != "" {
                Button { workspace.open(.settings) } label: {
                    statusLine("list.bullet.clipboard", "vault 最上層沒有找到編輯規則檔（可以在設定指定）", tint: DS.textTertiary)
                }
                .buttonStyle(.plain)
            }
            if assistant.cloudAvailable {
                statusLine("cloud", AssistantEngineMode.current == .device ? "只用裝置端 AI（可以在設定改成自動）" : "多步驟的整理工作會交給雲端 AI（\(AssistantEngineMode.current == .cloud ? "一律用雲端" : "Jev 自動判斷")）", tint: DS.textSecondary)
            }
            if VaultBackend.storage == .webdav {
                statusLine("externaldrive.badge.icloud", "AI 搜尋的是 LocalOCR 伺服器上的 vault，不是 WebDAV。", tint: DS.textTertiary)
            }
        }
    }

    private func statusLine(_ systemImage: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(tint)
    }

    private static let prompts: [(text: String, sendsNow: Bool)] = [
        ("最近的筆記有哪些重點？", true),
        ("幫我找關於「」的筆記", false),
        ("把今天的待辦整理成一則筆記", true),
        ("在「」這則筆記補上：", false),
    ]

    private var suggestions: some View {
        FlowLayout(spacing: 8) {
            ForEach(Self.prompts, id: \.text) { prompt in
                Button {
                    if prompt.sendsNow {
                        send(prompt.text)
                    } else {
                        draft = prompt.text
                        inputFocused = true
                    }
                } label: {
                    Text(prompt.text)
                        .font(.subheadline)
                        .foregroundStyle(DS.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().strokeBorder(DS.cardBorder, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近的對話")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DS.text)
                Spacer()
                Button("全部 \(assistant.sessions.count)") { workspace.open(.folder(KnowledgeAssistant.historyFolder)) }
                    .font(.footnote)
                    .foregroundStyle(DS.textSecondary)
                    .buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                ForEach(assistant.sessions.prefix(5)) { session in
                    Button { open(session) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .font(.system(size: 13))
                                .foregroundStyle(DS.textSecondary)
                            Text(session.title)
                                .font(.subheadline)
                                .foregroundStyle(DS.text)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(DS.textTertiary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if session != assistant.sessions.prefix(5).last {
                        Divider().overlay(DS.hairline)
                    }
                }
            }
            .padding(.horizontal, 14)
            .card(padding: 0)
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近編輯")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DS.text)
                Spacer()
                if !store.notes.isEmpty {
                    Button("全部 \(store.notes.count)") { workspace.open(.folder("")) }
                        .font(.footnote)
                        .foregroundStyle(DS.textSecondary)
                        .buttonStyle(.plain)
                }
            }
            if store.notes.isEmpty {
                Text(sync.isConfigured ? "vault 裡還沒有筆記，按輸入列左邊的 + 新增一則。" : "配對後，整個 vault 的筆記都會出現在這裡。")
                    .font(.subheadline)
                    .foregroundStyle(DS.textTertiary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(Array(store.notes.prefix(10))) { note in
                            Button { workspace.openNote(note.path) } label: {
                                NoteCard(note: note)
                                    .frame(width: isCompact ? 230 : 240)
                            }
                            .buttonStyle(CardPressStyle())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var pairingCard: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("與 Obsidian 配對")
                    .font(.headline)
                    .foregroundStyle(DS.text)
                Text("在電腦的 Obsidian 執行「LocalOCR：配對 iPhone／iPad」並掃描 QR Code。配對後 AI 才能在線上搜尋與整理你的 vault。")
                    .font(.subheadline)
                    .foregroundStyle(DS.onPastelSecondary)
            }
            Spacer(minLength: 0)
            Button("開始配對") { workspace.showsPairing = true }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        }
        .pastelCard(.sky, padding: 16)
    }

    // MARK: 輸入列

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            createMenu
            TextField("問問題，或請 AI 整理、修改筆記", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .font(.body)
                .foregroundStyle(DS.text)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send(draft) }
                .padding(.vertical, 10)
            Button {
                if assistant.isWorking {
                    assistant.stop()
                } else {
                    send(draft)
                }
            } label: {
                Image(systemName: assistant.isWorking ? "stop.fill" : "arrow.up")
                    .font(.system(size: assistant.isWorking ? 13 : 16, weight: .semibold))
                    .foregroundStyle(DS.onPrimary)
                    .frame(width: 36, height: 36)
                    .background(DS.primary.opacity(canSend || assistant.isWorking ? 1 : 0.3), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !assistant.isWorking)
            .padding(.bottom, 4)
            .accessibilityLabel(assistant.isWorking ? "停止" : "送出")
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .background(DS.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1))
    }

    private var canSend: Bool {
        !assistant.isWorking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 原本首頁浮動工具列的新增動作。
    private var createMenu: some View {
        Menu {
            Button { workspace.newTextNote() } label: { Label("新增筆記", systemImage: "doc.text") }
            Button { workspace.newNotebook() } label: { Label("新增手寫筆記", systemImage: "pencil") }
            Button { workspace.newTaskNote() } label: { Label("新增待辦清單", systemImage: "checkmark.square") }
            Button {
                folderName = ""
                showsFolderPrompt = true
            } label: { Label("新增資料夾", systemImage: "folder") }
            Divider()
            Button { workspace.open(.scan) } label: { Label("掃描文件", systemImage: "viewfinder") }
            Button { workspace.showsCamera = true } label: { Label("相機連續拍照", systemImage: "camera") }
            Button { workspace.open(.tasks) } label: { Label("所有待辦", systemImage: "checkmark.square") }
            Button { workspace.open(.graph) } label: { Label("關聯圖", systemImage: WorkspaceTab.graph.systemImage) }
            Button { workspace.open(.drawings) } label: { Label("圖面瀏覽", systemImage: WorkspaceTab.drawings.systemImage) }
            Button { Task { await sync.syncNow() } } label: { Label("立即同步", systemImage: "arrow.triangle.2.circlepath") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(DS.text)
                .frame(width: 36, height: 36)
                .background(DS.control, in: Circle())
        }
        .padding(.bottom, 4)
        .accessibilityLabel("新增")
    }

    // MARK: 動作

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !assistant.isWorking else { return }
        draft = ""
        notice = nil
        let recentNote = workspace.tabs.last(where: { $0.notePath != nil })?.notePath
        assistant.send(question, openNote: recentNote)
    }

    private func open(_ session: ChatSessionInfo) {
        notice = nil
        Task {
            if let error = await assistant.open(session) { notice = error }
        }
    }

    /// 開啟回答中的 [[連結]] 或來源：先找這則回答的來源，再找 vault 的連結索引；找不到不建立新筆記（避免 AI 寫錯的名稱變成空白筆記）。
    private func openReference(_ target: String, sources: [String]) {
        let link = NoteLinks.parse(target)
        let name = link.name.lowercased()
        // 來源是路徑；以前的對話紀錄中只有筆記名稱，要再解析
        if let source = sources.first(where: { $0.lowercased() == name || KnowledgeAssistant.title(of: $0).lowercased() == name || $0.lowercased() == name + ".md" }),
           let path = source.lowercased().hasSuffix(".md") ? source : NoteLinks.resolve(source, in: store.linkIndex) {
            workspace.openNote(path)
        } else if let path = NoteLinks.resolve(link.name, in: store.linkIndex) {
            workspace.openNote(path)
        } else {
            notice = "找不到「\(link.name)」這則筆記。"
        }
    }

    private func undo(_ edit: AgentEdit) {
        Task {
            if let error = await assistant.undo(edit) { notice = error }
        }
    }

    private func undoAll(_ message: AssistantMessage) {
        Task {
            if let error = await assistant.undoAll(in: message) { notice = error }
        }
    }
}

// MARK: - 一則訊息

struct AssistantMessageView: View {
    let message: AssistantMessage
    let undone: Set<String>
    var onOpen: (String, [String]) -> Void
    var onUndo: (AgentEdit) -> Void
    var onUndoAll: (AssistantMessage) -> Void

    /// 步驟很多時（雲端的整理工作）只顯示最後幾個。
    @State private var showsAllSteps = false
    private static let collapsedSteps = 6

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(DS.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(DS.control, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if !message.steps.isEmpty {
                    let hidden = showsAllSteps ? 0 : max(0, message.steps.count - Self.collapsedSteps - 2)
                    VStack(alignment: .leading, spacing: 6) {
                        if hidden > 0 {
                            Button { showsAllSteps = true } label: {
                                stepLine("ellipsis", "顯示前面 \(hidden) 個步驟")
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(Array(message.steps.enumerated()).dropFirst(hidden), id: \.offset) { _, step in
                            stepView(step)
                        }
                    }
                }
                let pendingEdits = message.edits.filter { !undone.contains($0.id) }
                if message.edits.count > 1, !pendingEdits.isEmpty, !message.text.isEmpty {
                    Button { onUndoAll(message) } label: {
                        Label("復原這次的 \(pendingEdits.count) 項修改", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                }
                if message.text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(progressText)
                            .font(.subheadline)
                            .foregroundStyle(DS.textSecondary)
                    }
                } else {
                    Text(AssistantText.attributed(message.text))
                        .font(.body)
                        .foregroundStyle(message.isError ? DS.textSecondary : DS.text)
                        .tint(DS.link)
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            if let target = AssistantText.target(of: url) {
                                onOpen(target, message.sources)
                                return .handled
                            }
                            return .systemAction
                        })
                }
                if !message.sources.isEmpty {
                    sources
                }
                if let engine = message.engine, !message.text.isEmpty {
                    Text(engineLabel(engine))
                        .font(.caption2)
                        .foregroundStyle(DS.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var progressText: String {
        if case .cloud? = message.engine { return message.steps.isEmpty ? "雲端 AI 準備中…" : "雲端 AI 工作中…" }
        return message.steps.isEmpty ? "思考中…" : "整理中…"
    }

    private func engineLabel(_ engine: AssistantMessage.Engine) -> String {
        switch engine {
        case .cloud(let model) where !model.isEmpty: return "雲端 AI · \(model)"
        default: return engine.label
        }
    }

    @ViewBuilder
    private func stepView(_ step: AgentStep) -> some View {
        switch step {
        case .search(let query, let count):
            stepLine("magnifyingglass", "搜尋「\(query)」・\(count == 0 ? "沒有結果" : "\(count) 則")")
        case .read(let path):
            Button { onOpen(path, [path]) } label: {
                stepLine("doc.text", "讀取 \(KnowledgeAssistant.title(of: path))")
            }
            .buttonStyle(.plain)
        case .list(let folder):
            stepLine("folder", "查看 \(folder.isEmpty ? "最上層" : folder)")
        case .failed(let text):
            stepLine("exclamationmark.triangle", text)
        case .edit(let edit):
            editCard(edit)
        case .route(let text):
            stepLine("arrow.triangle.branch", text)
        case .tool(let text):
            stepLine("wrench.and.screwdriver", text)
        case .narration(let text):
            Text(AssistantText.attributed(text))
                .font(.subheadline)
                .foregroundStyle(DS.textSecondary)
                .tint(DS.link)
                .environment(\.openURL, OpenURLAction { url in
                    if let target = AssistantText.target(of: url) {
                        onOpen(target, message.sources)
                        return .handled
                    }
                    return .systemAction
                })
        case .file(let path):
            Button { onOpen(path, [path]) } label: {
                stepLine("doc.badge.arrow.up", "產生檔案 \(KnowledgeAssistant.title(of: path))")
            }
            .buttonStyle(.plain)
        }
    }

    private func stepLine(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
            Text(text)
                .font(.footnote)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(DS.textSecondary)
    }

    private func editCard(_ edit: AgentEdit) -> some View {
        let isUndone = undone.contains(edit.id)
        return HStack(spacing: 10) {
            Image(systemName: Self.icon(for: edit.op))
                .font(.system(size: 15))
                .foregroundStyle(DS.text)
            VStack(alignment: .leading, spacing: 2) {
                Text(edit.op == .move ? "\(KnowledgeAssistant.title(of: edit.from ?? "")) → \(KnowledgeAssistant.title(of: edit.path))" : KnowledgeAssistant.title(of: edit.path))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Text(isUndone ? "已復原" : (edit.summary.isEmpty ? Self.verb(for: edit.op) : edit.summary))
                    .font(.caption)
                    .foregroundStyle(DS.onPastelSecondary)
            }
            Spacer(minLength: 8)
            if !isUndone {
                if edit.op != .delete {
                    Button("開啟") { onOpen(edit.path, [edit.path]) }
                        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                }
                Button("復原") { onUndo(edit) }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            }
        }
        .pastelCard(isUndone ? .butter : .mint, padding: 12)
    }

    static func icon(for op: AgentEdit.Op) -> String {
        switch op {
        case .create: return "doc.badge.plus"
        case .update: return "pencil.line"
        case .move: return "arrow.right.doc.on.clipboard"
        case .delete: return "trash"
        }
    }

    static func verb(for op: AgentEdit.Op) -> String {
        switch op {
        case .create: return "新增筆記"
        case .update: return "修改內容"
        case .move: return "搬移"
        case .delete: return "移到垃圾桶"
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("來源")
                .font(.caption.weight(.medium))
                .foregroundStyle(DS.textTertiary)
            FlowLayout(spacing: 6) {
                ForEach(message.sources, id: \.self) { path in
                    Button { onOpen(path, [path]) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text")
                                .font(.caption2)
                            Text(KnowledgeAssistant.title(of: path))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(DS.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(DS.Pastel.stable(for: path).color, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(path)
                }
            }
        }
    }
}

// MARK: - 回答的文字

/// 把 AI 的回答轉成可以點的文字：[[筆記]] 變成連結，**粗體**、`程式碼`、網址照 Markdown 顯示，標題改成粗體。
enum AssistantText {
    static let scheme = "localocr-ref"

    static func attributed(_ text: String) -> AttributedString {
        let markdown = markdownSource(text)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(text)
    }

    /// 轉成 Markdown：`[[名稱|別名]]` → `[別名](localocr-ref://note?n=名稱)`，`# 標題` → `**標題**`。
    static func markdownSource(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).hasPrefix(" ") {
                return "**" + trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces) + "**"
            }
            return line
        }
        var result = lines.joined(separator: "\n")
        guard let regex = try? NSRegularExpression(pattern: #"!?\[\[([^\]\n]+?)\]\]"#) else { return result }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: result), let inner = Range(match.range(at: 1), in: result) else { continue }
            let content = String(result[inner])
            let parts = content.split(separator: "|", maxSplits: 1).map(String.init)
            let target = parts[0].trimmingCharacters(in: .whitespaces)
            var label = parts.count > 1 ? parts[1] : NoteLinks.parse(target).name
            if label.isEmpty { label = target }
            label = label.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            result.replaceSubrange(whole, with: "[\(label)](\(url(for: target)))")
        }
        return result
    }

    static func url(for target: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?()[] ")
        return "\(scheme)://note?n=" + (target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target)
    }

    static func target(of url: URL) -> String? {
        guard url.scheme == scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first(where: { $0.name == "n" })?.value
    }
}

// MARK: - 鍵盤

/// 工作區不讓系統因鍵盤調整版面（避免整個畫面跳動），需要時用它自己讓開鍵盤。
@MainActor
@Observable
final class KeyboardFrame {
    static let shared = KeyboardFrame()

    /// 鍵盤在視窗座標中的位置；沒有鍵盤或是浮動鍵盤時是 .null。
    private(set) var frame: CGRect = .null
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            let end = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { self?.update(end) }
        })
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame = .null }
        })
    }

    private func update(_ screenFrame: CGRect?) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        guard let screenFrame, let window, let screen = window.windowScene?.screen else {
            frame = .null
            return
        }
        let converted = window.convert(screenFrame, from: screen.coordinateSpace)
        // 浮動鍵盤（iPad）沒有貼齊視窗底部，不需要讓開
        frame = converted.maxY < window.bounds.maxY - 1 || converted.height < 1 ? .null : converted
    }

    /// 鍵盤蓋住 `rect`（全域座標）底部的高度。
    func overlap(with rect: CGRect) -> CGFloat {
        guard !frame.isNull else { return 0 }
        return max(0, rect.maxY - frame.minY)
    }
}
