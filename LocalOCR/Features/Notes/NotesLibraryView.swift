import SwiftData
import SwiftUI

/// 筆記本書架：封面格狀排列，點一下開始書寫。
struct NotesLibraryView: View {
    private enum SortOrder: String, CaseIterable, Identifiable {
        case updated = "最近編輯"
        case created = "建立日期"
        case title = "名稱"

        var id: Self { self }
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Notebook.updatedAt, order: .reverse) private var notebooks: [Notebook]
    @State private var path: [Notebook] = []
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .updated
    @State private var showsNewNotebook = false
    @State private var pendingDelete: Notebook?
    @State private var isSyncing = false
    @State private var toast: String?

    private var visibleNotebooks: [Notebook] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? notebooks : notebooks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.recognizedText?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.insights?.tags.contains { $0.localizedCaseInsensitiveContains(query) } ?? false)
        }
        switch sortOrder {
        case .updated: return filtered
        case .created: return filtered.sorted { $0.createdAt > $1.createdAt }
        case .title: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 24)], alignment: .leading, spacing: 32) {
                    if searchText.isEmpty {
                        Button {
                            showsNewNotebook = true
                        } label: {
                            NewNotebookTile()
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(visibleNotebooks) { notebook in
                        NavigationLink(value: notebook) {
                            NotebookTile(notebook: notebook)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { contextMenu(for: notebook) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .screenBackground()
            .navigationTitle("筆記")
            .searchable(text: $searchText, prompt: "搜尋標題、手寫內容或標籤")
            .toolbar { toolbarContent }
            .navigationDestination(for: Notebook.self) { notebook in
                NotebookEditorView(notebook: notebook)
            }
            .sheet(isPresented: $showsNewNotebook) {
                NewNotebookSheet { title, paper, color in
                    let notebook = Notebook(title: title, paper: paper, color: color)
                    modelContext.insert(notebook)
                    NotebookCovers.update(notebook)
                    try? modelContext.save()
                    path.append(notebook)
                }
            }
            .confirmationDialog(
                "刪除「\(pendingDelete?.title ?? "")」？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("刪除筆記本", role: .destructive) {
                    if let notebook = pendingDelete {
                        modelContext.delete(notebook)
                        try? modelContext.save()
                    }
                    pendingDelete = nil
                }
            } message: {
                Text("只會從這台裝置刪除，Obsidian 中已同步的筆記會保留。")
            }
            .refreshable { await pullFromVault() }
            .task { await pullFromVault() }
            .toast($toast)
            .overlay {
                if visibleNotebooks.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("排序", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
            } label: {
                Label("排序", systemImage: "arrow.up.arrow.down")
            }
            Button {
                Task { await syncAll() }
            } label: {
                if isSyncing {
                    ProgressView()
                } else {
                    Label("與 Obsidian 同步", systemImage: "arrow.triangle.2.circlepath.icloud")
                }
            }
            .disabled(isSyncing || !ServerSettings.isConfigured)
            Button {
                showsNewNotebook = true
            } label: {
                Label("新增筆記本", systemImage: "square.and.pencil")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for notebook: Notebook) -> some View {
        Button {
            duplicate(notebook)
        } label: {
            Label("複製", systemImage: "plus.square.on.square")
        }
        Button {
            Task { await push(notebook) }
        } label: {
            Label("同步到 Obsidian", systemImage: "arrow.triangle.2.circlepath.icloud")
        }
        .disabled(!ServerSettings.isConfigured)
        Divider()
        Button(role: .destructive) {
            pendingDelete = notebook
        } label: {
            Label("刪除", systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func duplicate(_ notebook: Notebook) {
        let copy = Notebook(title: notebook.title + " 拷貝", paper: notebook.paper, color: notebook.color)
        copy.pageCount = notebook.pageCount
        copy.drawingData = notebook.drawingData
        copy.coverData = notebook.coverData
        copy.recognizedText = notebook.recognizedText
        copy.insightsJSON = notebook.insightsJSON
        modelContext.insert(copy)
        try? modelContext.save()
    }

    private func push(_ notebook: Notebook) async {
        guard let client = VaultClient.configured() else { return }
        do {
            toast = try await NotebookVaultSync.push(notebook, client: client)
            try? modelContext.save()
        } catch {
            toast = "同步失敗：\(error.localizedDescription)"
        }
    }

    /// 先匯入其他裝置的更新，再把本機修改過的筆記本寫入 vault。
    private func syncAll() async {
        guard let client = VaultClient.configured() else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let pulled = try await NotebookVaultSync.pull(into: modelContext, client: client)
            var pushed = 0
            for notebook in notebooks where notebook.needsSync {
                try await NotebookVaultSync.push(notebook, client: client)
                pushed += 1
            }
            try? modelContext.save()
            toast = pulled + pushed == 0 ? "已是最新" : "已更新 \(pulled) 本、上傳 \(pushed) 本"
        } catch {
            toast = "同步失敗：\(error.localizedDescription)"
        }
    }

    private func pullFromVault() async {
        guard let client = VaultClient.configured() else { return }
        if let pulled = try? await NotebookVaultSync.pull(into: modelContext, client: client), pulled > 0 {
            toast = "已從 Obsidian 更新 \(pulled) 本筆記本"
        }
    }
}

/// 筆記本封面：第一頁縮圖＋左側書背顏色。
struct NotebookTile: View {
    let notebook: Notebook

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .leading) {
                Color.white
                if let cover = notebook.cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                }
                notebook.color.color
                    .frame(width: 7)
            }
            .aspectRatio(NotebookLayout.pageSize.width / NotebookLayout.pageSize.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06))
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(notebook.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text(notebook.updatedAt, format: .relative(presentation: .named))
                    if notebook.syncedAt != nil {
                        Image(systemName: notebook.needsSync ? "icloud.and.arrow.up" : "checkmark.icloud")
                            .accessibilityLabel(notebook.needsSync ? "尚未同步最新修改" : "已同步")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct NewNotebookTile: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.tertiary)
                .aspectRatio(NotebookLayout.pageSize.width / NotebookLayout.pageSize.height, contentMode: .fit)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 30, weight: .light))
                        Text("新增筆記本")
                            .font(.footnote.weight(.medium))
                    }
                    .foregroundStyle(.tint)
                }
            Text(" ")
                .font(.subheadline)
        }
        .contentShape(Rectangle())
    }
}

/// 新增筆記本：名稱、紙張、顏色。
struct NewNotebookSheet: View {
    var onCreate: (String, PaperStyle, NotebookColor) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var paper: PaperStyle = .lined
    @State private var color: NotebookColor = .blue
    @FocusState private var titleFocused: Bool

    private var defaultTitle: String {
        "筆記 " + Date().formatted(.dateTime.month().day().hour().minute())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名稱") {
                    TextField(defaultTitle, text: $title)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit(create)
                }
                Section("紙張") {
                    HStack(spacing: 14) {
                        ForEach(PaperStyle.allCases) { style in
                            Button {
                                paper = style
                            } label: {
                                PaperPreview(style: style, isSelected: paper == style)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("封面顏色") {
                    HStack(spacing: 14) {
                        ForEach(NotebookColor.allCases) { option in
                            Button {
                                color = option
                            } label: {
                                Circle()
                                    .fill(option.color.gradient)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if color == option {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.rawValue)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("新增筆記本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("建立", action: create)
                }
            }
            .onAppear { titleFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(name.isEmpty ? defaultTitle : name, paper, color)
        dismiss()
    }
}

private struct PaperPreview: View {
    let style: PaperStyle
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                let scale = size.width / NotebookLayout.pageSize.width
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                guard let pattern = PaperRenderer.patternPath(for: style, size: NotebookLayout.pageSize) else { return }
                let path = Path(pattern).applying(CGAffineTransform(scaleX: scale, y: scale))
                let color = Color(PaperRenderer.patternColor(for: style))
                if style == .dotted {
                    context.fill(path, with: .color(color))
                } else {
                    context.stroke(path, with: .color(color), lineWidth: 0.6)
                }
            }
            .aspectRatio(NotebookLayout.pageSize.width / NotebookLayout.pageSize.height, contentMode: .fit)
            .frame(width: 52)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.black.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
            }
            Text(style.title)
                .font(.caption)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
    }
}
