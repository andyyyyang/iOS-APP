import SwiftUI

/// 右側欄：目前筆記的大綱、反向連結、屬性、局部關聯圖與 Apple Intelligence。
struct RightSidebar: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(RightPanelMode.allCases) { mode in
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { workspace.rightMode = mode }
                    } label: {
                        Image(systemName: mode.systemImage)
                    }
                    .buttonStyle(GlassIconButtonStyle(size: 34, isActive: workspace.rightMode == mode))
                    .help(mode.title)
                    .accessibilityLabel(mode.title)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let path = workspace.activeNotePath {
                PanelHeader(title: workspace.rightMode.title, subtitle: WorkspaceTab.note(path).title) { EmptyView() }
                Group {
                    switch workspace.rightMode {
                    case .outline: OutlinePanel(path: path)
                    case .backlinks: BacklinksPanel(path: path)
                    case .properties: PropertiesPanel(path: path)
                    case .graph: GraphView(focus: path).padding([.horizontal, .bottom], 10)
                    case .ai: AIPanel(path: path).id(path)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                PanelHeader(title: workspace.rightMode.title) { EmptyView() }
                if workspace.rightMode == .graph {
                    GraphView(focus: nil).padding([.horizontal, .bottom], 10)
                } else {
                    MidnightEmptyState(
                        title: "沒有開啟的筆記",
                        systemImage: "doc.text.magnifyingglass",
                        message: "開啟一則筆記後，這裡會顯示它的大綱、反向連結、屬性、關聯圖與 AI 整理。"
                    )
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct PanelHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Midnight.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}

// MARK: - 大綱

private struct OutlinePanel: View {
    let path: String

    @Environment(Workspace.self) private var workspace

    var body: some View {
        let headings = NoteOutline.headings(in: workspace.liveText[path] ?? NotesStore.shared.text(of: path) ?? "")
        let topLevel = headings.map(\.level).min() ?? 1
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(headings) { heading in
                    let isTop = heading.level == topLevel
                    Button {
                        workspace.revealRequest = RevealRequest(path: path, heading: heading)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Circle()
                                .fill(isTop ? AnyShapeStyle(Midnight.gradient) : AnyShapeStyle(Midnight.textTertiary))
                                .frame(width: isTop ? 6 : 4, height: isTop ? 6 : 4)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                            Text(heading.title)
                                .font(.system(isTop ? .subheadline : .footnote, design: .rounded).weight(isTop ? .semibold : .regular))
                                .foregroundStyle(isTop ? Midnight.text : Midnight.textSecondary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
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
                        .padding(.horizontal, 10)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - 反向連結

private struct BacklinksPanel: View {
    let path: String

    @Environment(Workspace.self) private var workspace
    @State private var store = NotesStore.shared

    var body: some View {
        let title = WorkspaceTab.note(path).title
        let backlinks = store.backlinks(to: path)
        let outgoing = store.notes.first(where: { $0.path == path }).map { store.outgoingLinks(of: $0) } ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("連到這則筆記", trailing: "\(backlinks.count)")
                ForEach(backlinks) { note in
                    linkCard(title: note.title, detail: context(in: note, linkingTo: title)) { workspace.openNote(note.path) }
                }
                if backlinks.isEmpty {
                    PanelHint(text: "還沒有其他筆記連到這裡。在別的筆記寫 [[\(title)]] 就會出現。")
                }
                SectionLabel("這則筆記連到", trailing: "\(outgoing.count)")
                    .padding(.top, 12)
                ForEach(outgoing, id: \.self) { target in
                    let folder = (target as NSString).deletingLastPathComponent
                    linkCard(title: WorkspaceTab.note(target).title, detail: folder.isEmpty ? "最上層" : folder) { workspace.openNote(target) }
                }
                if outgoing.isEmpty {
                    PanelHint(text: "沒有連到其他筆記。")
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
    }

    private func linkCard(title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.caption2.weight(.bold))
                        .gradientForeground()
                    Text(title)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Midnight.text)
                        .lineLimit(1)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Midnight.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(padding: 12, cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    /// 反向連結所在的那一行（前後文）。
    private func context(in note: NoteSummary, linkingTo title: String) -> String {
        let text = store.text(of: note.path) ?? ""
        let line = text.split(separator: "\n").first { $0.localizedCaseInsensitiveContains("[[" + title) }
        return line.map { String($0).trimmingCharacters(in: .whitespaces) } ?? note.snippet
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
            VStack(alignment: .leading, spacing: 10) {
                if !properties.isEmpty {
                    SectionLabel("屬性", trailing: "\(properties.count)")
                    VStack(spacing: 0) {
                        ForEach(Array(properties.enumerated()), id: \.offset) { index, item in
                            row(item.key, item.value)
                            if index < properties.count - 1 { Divider().overlay(Midnight.hairline) }
                        }
                    }
                    .glassCard(padding: 4, cornerRadius: 14)
                }
                if let tags = summary?.tags, !tags.isEmpty {
                    SectionLabel("標籤")
                        .padding(.top, 6)
                    FlowLayout(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            GlassChip(text: "#" + tag, tint: Midnight.hue(for: tag))
                        }
                    }
                }
                SectionLabel("檔案")
                    .padding(.top, 6)
                VStack(spacing: 0) {
                    row("位置", folder.isEmpty ? "最上層" : folder)
                    Divider().overlay(Midnight.hairline)
                    row("修改", (summary?.mtime ?? Date()).formatted(date: .abbreviated, time: .shortened))
                    Divider().overlay(Midnight.hairline)
                    row("字數", "\(Self.wordCount(text))")
                    Divider().overlay(Midnight.hairline)
                    row("字元", "\(text.count)")
                    if let tasks = summary?.tasks, !tasks.isEmpty {
                        Divider().overlay(Midnight.hairline)
                        row("待辦", "\(tasks.filter(\.done).count) / \(tasks.count) 完成")
                    }
                }
                .glassCard(padding: 4, cornerRadius: 14)
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(Midnight.textTertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(Midnight.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
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
            VStack(alignment: .leading, spacing: 12) {
                if isNotebook {
                    PanelHint(text: "手寫筆記本請按筆記本右上角的 ✨：先辨識手寫內容，再整理摘要與標籤。")
                } else {
                    Button {
                        Task { await analyze() }
                    } label: {
                        HStack(spacing: 8) {
                            if isThinking {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(insights == nil ? "整理這則筆記" : "重新整理")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MidnightButtonStyle(kind: .primary))
                    .disabled(isThinking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Midnight.warning)
                    }
                    PanelHint(text: "在裝置上整理摘要、重點、待辦與標籤，內容不會離開這台裝置。編輯時也可以選取文字使用系統的「書寫工具」。")

                    if let insights {
                        card("摘要") {
                            Text(insights.summary)
                                .font(.callout)
                                .foregroundStyle(Midnight.text)
                                .textSelection(.enabled)
                        }
                        if !insights.keyPoints.isEmpty {
                            card("重點") {
                                ForEach(insights.keyPoints, id: \.self) { point in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Circle().fill(Midnight.gradient).frame(width: 5, height: 5)
                                        Text(point).font(.callout).foregroundStyle(Midnight.text)
                                    }
                                }
                            }
                        }
                        if !insights.actionItems.isEmpty {
                            card("待辦") {
                                ForEach(insights.actionItems, id: \.self) { item in
                                    Label(item, systemImage: "circle")
                                        .font(.callout)
                                        .foregroundStyle(Midnight.text)
                                }
                            }
                        }
                        if !insights.tags.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(insights.tags, id: \.self) { tag in
                                    GlassChip(text: "#" + tag, tint: Midnight.hue(for: tag))
                                }
                            }
                        }
                        Button {
                            workspace.editRequest = EditRequest(path: path) { NoteMarkdownEditing.insertingInsights(insights, into: $0) }
                            applied = "已把摘要、重點與標籤加到筆記開頭"
                        } label: {
                            Label("加到筆記開頭", systemImage: "text.insert")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(MidnightButtonStyle(kind: .secondary, compact: true))
                        if !insights.actionItems.isEmpty {
                            Button {
                                let tasks = insights.actionItems.map { "- [ ] " + $0 }.joined(separator: "\n")
                                workspace.editRequest = EditRequest(path: path) { $0.trimmingCharacters(in: .newlines) + "\n\n## 待辦\n" + tasks + "\n" }
                                applied = "已把待辦加到筆記最後"
                            } label: {
                                Label("把待辦加到筆記最後", systemImage: "checklist")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(MidnightButtonStyle(kind: .secondary, compact: true))
                        }
                        if let applied {
                            Label(applied, systemImage: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(Midnight.success)
                        }
                    }
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            content()
        }
        .glassCard(padding: 14, cornerRadius: 16)
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
