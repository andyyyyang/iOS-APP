import SwiftUI

/// 開著的日誌筆記本：右側欄的「日誌」面板從這裡讀內容，並請筆記本翻頁、新增或刪除頁面、整理。
@MainActor
@Observable
final class JournalSession {
    static let shared = JournalSession()

    struct Actions {
        var showPage: (Int) -> Void
        var addPage: () -> Void
        var deletePage: (Int) -> Void
        var organize: () -> Void
        var openModel: (String) -> Void
    }

    private(set) var path: String?
    private(set) var notebook: JournalNotebook?
    private(set) var isOrganizing = false
    /// 畫面上的頁（兩頁並排時是左邊那頁）。
    private(set) var visiblePage = 0
    @ObservationIgnored private(set) var actions: Actions?

    func attach(path: String, actions: Actions) {
        self.path = path
        self.actions = actions
    }

    func update(path: String, notebook: JournalNotebook?, isOrganizing: Bool, visiblePage: Int) {
        guard self.path == path else { return }
        if self.notebook != notebook { self.notebook = notebook }
        if self.isOrganizing != isOrganizing { self.isOrganizing = isOrganizing }
        if self.visiblePage != visiblePage { self.visiblePage = visiblePage }
    }

    func detach(path: String) {
        guard self.path == path else { return }
        self.path = nil
        notebook = nil
        actions = nil
    }
}

/// 刪除頁面的確認文字（筆記本與右側欄共用）。
enum JournalDeletePrompt {
    static func title(_ index: Int?) -> String {
        guard let index else { return "" }
        return "刪除第 \(index + 1) 頁？"
    }

    static func message(pageCount: Int) -> String {
        pageCount > 1 ? "這一頁的筆跡會一起刪除，無法復原。" : "這是唯一的一頁：會清成今天的空白頁。"
    }
}

/// 右側欄的「日誌」：顯示方式、新增一頁、辨識並整理；依日期（新的在前）列出每天的摘要、重點、待跟進、
/// 提到的機種與頁面——點了翻到那一頁，左滑或長按可以刪除。
struct JournalSidebarPanel: View {
    let path: String

    @State private var session = JournalSession.shared
    @AppStorage(JournalViewMode.storageKey) private var viewModeRaw = JournalViewMode.scroll.rawValue
    @State private var pendingDelete: Int?

    var body: some View {
        if session.path == path, let notebook = session.notebook, let actions = session.actions {
            content(notebook, actions: actions)
        } else {
            Text("打開日誌筆記本後，這裡會列出每天的頁面與整理結果。")
                .font(.footnote)
                .foregroundStyle(DS.textTertiary)
                .padding(.top, 8)
        }
    }

    private func content(_ notebook: JournalNotebook, actions: JournalSession.Actions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("顯示方式", selection: $viewModeRaw) {
                ForEach(JournalViewMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Button {
                    actions.addPage()
                } label: {
                    Label("新增一頁", systemImage: "doc.badge.plus")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                Button {
                    actions.organize()
                } label: {
                    HStack(spacing: 6) {
                        if session.isOrganizing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text("辨識並整理")
                    }
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                .disabled(session.isOrganizing)
            }

            List {
                ForEach(notebook.pagesByDay.reversed()) { day in
                    Section {
                        insights(for: day, in: notebook, actions: actions)
                        ForEach(day.pages, id: \.self) { index in
                            pageRow(index, in: notebook)
                                .contentShape(Rectangle())
                                .onTapGesture { actions.showPage(index) }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        pendingDelete = index
                                    } label: {
                                        Label("刪除", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        actions.showPage(index)
                                    } label: {
                                        Label("翻到這一頁", systemImage: "arrow.right.doc.on.clipboard")
                                    }
                                    Button(role: .destructive) {
                                        pendingDelete = index
                                    } label: {
                                        Label("刪除這一頁", systemImage: "trash")
                                    }
                                }
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text(JournalLayout.heading(for: day.date))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DS.textSecondary)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 34)
        }
        .confirmationDialog(
            JournalDeletePrompt.title(pendingDelete),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除", role: .destructive) {
                if let index = pendingDelete { actions.deletePage(index) }
                pendingDelete = nil
            }
        } message: {
            Text(JournalDeletePrompt.message(pageCount: notebook.pages.count))
        }
    }

    /// 那一天的 AI 整理：摘要、重點、待跟進、提到的機種。
    @ViewBuilder
    private func insights(for day: JournalDayPages, in notebook: JournalNotebook, actions: JournalSession.Actions) -> some View {
        let pages = day.pages.filter { notebook.pages.indices.contains($0) }.map { notebook.pages[$0] }
        if let insights = notebook.days[day.date], !insights.summary.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(insights.summary)
                    .font(.footnote)
                    .foregroundStyle(DS.text)
                ForEach(insights.keyPoints, id: \.self) { point in
                    Text("• " + point).font(.caption).foregroundStyle(DS.textSecondary)
                }
                ForEach(insights.actionItems, id: \.self) { item in
                    Text("↳ " + item).font(.caption).foregroundStyle(DS.textSecondary)
                }
            }
            .listRowBackground(Color.clear)
        }
        let models = JournalMarkdown.linkedModels(in: pages)
        if !models.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(models, id: \.path) { model in
                        Button {
                            actions.openModel(model.path)
                        } label: {
                            Label(model.code, systemImage: "link")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DS.text)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(DS.Pastel.sky.color, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    private func pageRow(_ index: Int, in notebook: JournalNotebook) -> some View {
        let page = notebook.pages.indices.contains(index) ? notebook.pages[index] : nil
        let visible = session.visiblePage
        let isSpread: Bool = viewModeRaw == JournalViewMode.spread.rawValue
        let isVisible: Bool = index == visible || (isSpread && index == visible + 1)
        let text: String = page?.recognizedText ?? ""
        let firstLine: String = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return HStack(spacing: 8) {
            Image(systemName: isVisible ? "doc.fill" : "doc")
                .font(.system(size: 12))
                .foregroundStyle(isVisible ? DS.text : DS.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("第 \(index + 1) 頁")
                    .font(.subheadline.weight(isVisible ? .semibold : .regular))
                    .foregroundStyle(DS.text)
                if page?.isBlank == true {
                    Text("空白").font(.caption).foregroundStyle(DS.textTertiary)
                } else if !firstLine.isEmpty {
                    Text(firstLine).font(.caption).foregroundStyle(DS.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
