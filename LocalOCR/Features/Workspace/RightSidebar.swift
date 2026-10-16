import SwiftUI

/// 右側欄：開著筆記時是它的手寫備忘、大綱、連結、屬性與 AI 整理；其他時候是所有待辦（粉彩卡片）。
struct RightSidebar: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage(AISettings.notePanelKey) private var showsAIPanel = true
    @State private var store = NotesStore.shared
    @State private var journal = JournalSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let path = workspace.activeNotePath {
                let isJournal: Bool = journal.path == path || store.notes.first(where: { $0.path == path })?.isJournal == true
                let modes = RightPanelMode.allCases.filter { mode in
                    switch mode {
                    case .journal: return isJournal
                    case .memo: return !isJournal
                    case .ai: return showsAIPanel
                    case .outline, .links, .properties: return true
                    }
                }
                let mode = Self.effectiveMode(workspace.rightMode, available: modes, isJournal: isJournal)
                ModePicker(modes: modes, active: mode)
                Group {
                    switch mode {
                    case .journal: JournalSidebarPanel(path: path)
                    case .memo: InkMemoPanel(path: path).id(path)
                    case .outline: OutlinePanel(path: path)
                    case .links: LinksPanel(path: path)
                    case .properties: PropertiesPanel(path: path)
                    case .ai: AIPanel(path: path).id(path)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                TasksColumn()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 這則筆記沒有的面板改顯示最接近的：日誌筆記本的「手寫」是日誌，其他筆記的「日誌」與關掉的 AI 是大綱。
    static func effectiveMode(_ mode: RightPanelMode, available: [RightPanelMode], isJournal: Bool) -> RightPanelMode {
        if available.contains(mode) { return mode }
        return isJournal && mode == .memo ? .journal : .outline
    }
}

/// 分段控制：日誌（日誌筆記本）｜手寫（其他筆記）｜大綱｜連結｜屬性｜AI（設定中關掉筆記 AI 時沒有 AI）。
private struct ModePicker: View {
    let modes: [RightPanelMode]
    let active: RightPanelMode
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes) { mode in
                let isActive = mode == active
                Button {
                    workspace.rightMode = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(DS.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background {
                            if isActive {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(DS.card)
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(3)
        .background(DS.controlTrack, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
    }
}

private struct PanelHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(DS.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
    }
}

/// 白底細框的小卡片（反向連結、連結）。
private struct LinkCard: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .card(padding: 11, cornerRadius: 10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 待辦（沒有開著筆記時）

private struct TasksColumn: View {
    @Environment(Workspace.self) private var workspace
    @State private var store = NotesStore.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("待辦")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DS.text)
            Spacer()
            Text("\(store.openTasks.count) 件")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(DS.textSecondary)
        }
        .padding(.horizontal, 2)
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(Array(store.openTasks.prefix(40))) { task in
                    TaskCard(task: task, onToggle: { store.toggle(task) }, onOpen: { workspace.openNote(task.notePath) })
                }
                Text("在任何筆記寫「- [ ] 事項」就會出現在這裡。")
                    .font(.footnote)
                    .foregroundStyle(DS.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(DS.textTertiary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }
}

/// 一個待辦：粉彩卡片，上方是筆記所在資料夾與日期，中間是待辦（可打勾），下方是筆記名稱（點一下開啟）。
private struct TaskCard: View {
    let task: NoteTask
    var onToggle: () -> Void
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(kind)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.text)
                Spacer()
                Text(task.mtime.formatted(.dateTime.weekday(.abbreviated).month(.defaultDigits).day()))
                    .font(.caption)
                    .foregroundStyle(DS.onPastelSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button(action: onToggle) {
                    Image(systemName: "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(DS.onPastelSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("標示為完成")
                Text(task.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(DS.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(DS.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Button(action: onOpen) {
                Text(task.noteTitle)
                    .font(.caption)
                    .foregroundStyle(DS.onPastelSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .pastelCard(DS.Pastel.stable(for: task.notePath), padding: 12)
    }

    private var kind: String {
        let folder = (task.notePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? "待辦" : (folder as NSString).lastPathComponent
    }
}

// MARK: - 大綱

private struct OutlinePanel: View {
    let path: String

    @Environment(Workspace.self) private var workspace
    @State private var store = NotesStore.shared

    var body: some View {
        let headings = NoteOutline.headings(in: workspace.liveText[path] ?? store.text(of: path) ?? "")
        let topLevel = headings.map(\.level).min() ?? 1
        let backlinks = store.backlinks(to: path)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(headings) { heading in
                    let isTop = heading.level == topLevel
                    Button {
                        workspace.revealRequest = RevealRequest(path: path, heading: heading)
                    } label: {
                        Text(heading.title)
                            .font(.system(size: isTop ? 13.5 : 13, weight: isTop ? .semibold : .regular))
                            .foregroundStyle(isTop ? DS.text : DS.onPastelSecondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .padding(.leading, CGFloat(heading.level - topLevel) * 14 + 10)
                            .padding(.trailing, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                }
                if headings.isEmpty {
                    PanelHint(text: "這則筆記沒有標題。以 # 開頭的一行會出現在大綱，點一下就能跳過去。")
                }

                Rectangle().fill(DS.hairline).frame(height: 1).padding(.vertical, 10)
                HStack {
                    Text("反向連結").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                    Spacer()
                    Text("\(backlinks.count)").font(.caption.monospacedDigit()).foregroundStyle(DS.textTertiary)
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 6)
                VStack(spacing: 8) {
                    ForEach(backlinks) { note in
                        LinkCard(title: note.title, detail: BacklinkContext.line(in: note, linkingTo: WorkspaceTab.note(path).title, store: store)) {
                            workspace.openNote(note.path)
                        }
                    }
                }
                if backlinks.isEmpty {
                    PanelHint(text: "還沒有其他筆記連到這裡。")
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }
}

private enum BacklinkContext {
    /// 反向連結所在的那一行。
    @MainActor
    static func line(in note: NoteSummary, linkingTo title: String, store: NotesStore) -> String {
        let text = store.text(of: note.path) ?? ""
        let line = text.split(separator: "\n").first { $0.localizedCaseInsensitiveContains("[[" + title) }
        return line.map { String($0).trimmingCharacters(in: .whitespaces) } ?? note.snippet
    }
}

// MARK: - 連結

private struct LinksPanel: View {
    let path: String

    @Environment(Workspace.self) private var workspace
    @State private var store = NotesStore.shared

    var body: some View {
        let title = WorkspaceTab.note(path).title
        let backlinks = store.backlinks(to: path)
        let outgoing = store.notes.first(where: { $0.path == path }).map { store.outgoingLinks(of: $0) } ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("連到這則筆記 · \(backlinks.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .padding(.horizontal, 2)
                ForEach(backlinks) { note in
                    LinkCard(title: note.title, detail: BacklinkContext.line(in: note, linkingTo: title, store: store)) { workspace.openNote(note.path) }
                }
                if backlinks.isEmpty {
                    PanelHint(text: "在別的筆記寫 [[\(title)]] 就會出現在這裡。")
                }
                Text("這則筆記連到 · \(outgoing.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .padding(.horizontal, 2)
                    .padding(.top, 10)
                ForEach(outgoing, id: \.self) { target in
                    let folder = (target as NSString).deletingLastPathComponent
                    LinkCard(title: WorkspaceTab.note(target).title, detail: folder.isEmpty ? "最上層" : folder) { workspace.openNote(target) }
                }
                if outgoing.isEmpty {
                    PanelHint(text: "沒有連到其他筆記。")
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - 屬性

private struct PropertiesPanel: View {
    let path: String

    @Environment(Workspace.self) private var workspace
    @State private var store = NotesStore.shared

    var body: some View {
        let text = workspace.liveText[path] ?? store.text(of: path) ?? ""
        let properties = Self.properties(in: text)
        let summary = store.notes.first { $0.path == path }
        let folder = (path as NSString).deletingLastPathComponent
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !properties.isEmpty {
                    table(properties.map { ($0.key, $0.value) })
                }
                if let tags = summary?.tags, !tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Chip(text: "#" + tag, pastel: DS.Pastel.stable(for: tag))
                        }
                    }
                }
                table(Self.fileRows(text: text, summary: summary, folder: folder))
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func table(_ rows: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.0)
                        .foregroundStyle(DS.textTertiary)
                        .frame(width: 60, alignment: .leading)
                    Text(row.1)
                        .foregroundStyle(DS.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                if index < rows.count - 1 {
                    Rectangle().fill(DS.hairline).frame(height: 1)
                }
            }
        }
        .card(padding: 0, cornerRadius: 10)
    }

    /// 檔案資訊：位置、修改時間、字數與待辦進度。
    static func fileRows(text: String, summary: NoteSummary?, folder: String) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("位置", folder.isEmpty ? "最上層" : folder),
            ("修改", (summary?.mtime ?? Date()).formatted(date: .abbreviated, time: .shortened)),
            ("字數", "\(wordCount(text))"),
        ]
        if let tasks = summary?.tasks, !tasks.isEmpty {
            rows.append(("待辦", "\(tasks.filter(\.done).count) / \(tasks.count) 完成"))
        }
        return rows
    }

    static func properties(in text: String) -> [(key: String, value: String)] {
        if case .properties(let items)? = MarkdownParser.blocks(from: text).first { return items }
        return []
    }

    /// 字數：中日韓文字每個字算一個，其他語言以單字計。
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isCJK = (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value)
                || (0x3040...0x30FF).contains(value) || (0xAC00...0xD7AF).contains(value) || (0xF900...0xFAFF).contains(value)
            if isCJK {
                count += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { count += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return count
    }
}

// MARK: - Apple Intelligence

private struct AIPanel: View {
    let path: String

    @Environment(Workspace.self) private var workspace
    @State private var isThinking = false
    @State private var message: String?
    @State private var applied: String?

    private var text: String { workspace.liveText[path] ?? NotesStore.shared.text(of: path) ?? "" }
    private var insights: NoteInsights? { workspace.insights[path] }

    var body: some View {
        let isNotebook = NotesStore.shared.notes.first(where: { $0.path == path })?.isNotebook == true
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if isNotebook {
                    PanelHint(text: "手寫筆記請按筆記上方的「AI」：先辨識手寫內容，再整理摘要與標籤。")
                } else {
                    Button {
                        Task { await analyze() }
                    } label: {
                        HStack(spacing: 8) {
                            if isThinking { ProgressView().tint(DS.onPrimary) }
                            Text(insights == nil ? "整理這則筆記" : "重新整理")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(isThinking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(DS.warning)
                    }
                    PanelHint(text: "在裝置上整理摘要、重點、待辦與標籤，內容不會離開這台裝置。編輯時也可以選取文字使用系統的「書寫工具」。")

                    if let insights {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("摘要").font(.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
                            Text(insights.summary)
                                .font(.system(size: 13.5))
                                .foregroundStyle(DS.text)
                                .textSelection(.enabled)
                        }
                        .card(padding: 12, cornerRadius: 10)
                        if !insights.keyPoints.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("重點").font(.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
                                ForEach(insights.keyPoints, id: \.self) { point in
                                    Text(point).font(.system(size: 13.5)).foregroundStyle(DS.text)
                                }
                            }
                            .card(padding: 12, cornerRadius: 10)
                        }
                        if !insights.actionItems.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("待辦").font(.caption.weight(.semibold)).foregroundStyle(DS.text)
                                ForEach(insights.actionItems, id: \.self) { item in
                                    Text(item).font(.system(size: 13.5)).foregroundStyle(DS.text)
                                }
                            }
                            .pastelCard(.mint, padding: 12, cornerRadius: 10)
                        }
                        if !insights.tags.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(insights.tags, id: \.self) { tag in
                                    Chip(text: "#" + tag, pastel: DS.Pastel.stable(for: tag))
                                }
                            }
                        }
                        Button {
                            workspace.editRequest = EditRequest(path: path) { NoteMarkdownEditing.insertingInsights(insights, into: $0) }
                            applied = "已把摘要、重點與標籤加到筆記開頭"
                        } label: {
                            Text("加到筆記開頭").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                        if !insights.actionItems.isEmpty {
                            Button {
                                let tasks = insights.actionItems.map { "- [ ] " + $0 }.joined(separator: "\n")
                                workspace.editRequest = EditRequest(path: path) { $0.trimmingCharacters(in: .newlines) + "\n\n## 待辦\n" + tasks + "\n" }
                                applied = "已把待辦加到筆記最後"
                            } label: {
                                Text("把待辦加到筆記最後").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                        }
                        if let applied {
                            Text(applied)
                                .font(.footnote)
                                .foregroundStyle(DS.success)
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func analyze() async {
        isThinking = true
        defer { isThinking = false }
        do {
            workspace.insights[path] = try await NoteIntelligence.insights(for: text)
            message = nil
            applied = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
