import SwiftUI

/// 指令面板（⌘K）：搜尋筆記並開啟，或執行指令。上下鍵選擇、Return 執行、Esc 關閉。
struct CommandPalette: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var store = NotesStore.shared
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let systemImage: String
        let isCommand: Bool
        let action: () -> Void
    }

    var body: some View {
        let items = results
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(DS.textSecondary)
                    TextField("搜尋筆記或輸入指令", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($focused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .onSubmit { run(items) }
                    Button("取消") { close() }
                        .font(.subheadline)
                        .foregroundStyle(DS.textSecondary)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)

                Rectangle().fill(DS.hairline).frame(height: 1)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, isSelected: index == selection)
                                    .id(index)
                                    .onTapGesture {
                                        selection = index
                                        run(items)
                                    }
                            }
                            if items.isEmpty {
                                Text("找不到「\(query)」")
                                    .font(.subheadline)
                                    .foregroundStyle(DS.textTertiary)
                                    .padding(16)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: selection) { _, value in
                        withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(value) }
                    }
                }
            }
            .frame(maxWidth: 620)
            .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .padding(.horizontal, 12)
            .padding(.top, sizeClass == .compact ? 8 : 64)
        }
        .onAppear {
            query = ""
            selection = 0
            focused = true
        }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(items.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
    }

    private func row(_ item: Item, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? DS.onPrimary : DS.textSecondary)
                .frame(width: 30, height: 30)
                .background(isSelected ? DS.primary : DS.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if item.isCommand {
                Text("指令")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(DS.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? DS.control : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: - 結果

    private var results: [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let commands = self.commands.filter { trimmed.isEmpty || Self.score($0.title, query: trimmed) != nil }
        let notes: [Item]
        if trimmed.isEmpty {
            notes = store.notes.prefix(8).map(noteItem)
        } else {
            notes = store.notes
                .compactMap { note in Self.score(note.title, query: trimmed).map { (note, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(30)
                .map { noteItem($0.0) }
        }
        return trimmed.isEmpty ? notes + commands : Array(commands.prefix(4)) + notes + Array(commands.dropFirst(4))
    }

    private func noteItem(_ note: NoteSummary) -> Item {
        Item(
            id: "note:" + note.path,
            title: note.title,
            detail: note.folder.isEmpty ? "最上層" : note.folder,
            systemImage: note.isNotebook ? "pencil" : "doc.text",
            isCommand: false,
            action: { workspace.openNote(note.path) }
        )
    }

    private var commands: [Item] {
        var items: [Item] = [
            Item(id: "new-note", title: "新增筆記", detail: "", systemImage: "square.and.pencil", isCommand: true, action: { workspace.newTextNote() }),
            Item(id: "new-notebook", title: "新增手寫筆記本", detail: "", systemImage: "pencil", isCommand: true, action: { workspace.requestNewNotebook() }),
            Item(id: "new-tasks", title: "新增待辦清單", detail: "", systemImage: "checkmark.square", isCommand: true, action: { workspace.newTaskNote() }),
            Item(id: "graph", title: "開啟關聯圖", detail: "", systemImage: WorkspaceTab.graph.systemImage, isCommand: true, action: { workspace.open(.graph) }),
            Item(id: "tasks", title: "所有待辦", detail: "", systemImage: "checkmark.square", isCommand: true, action: { workspace.open(.tasks) }),
            Item(id: "vault", title: "瀏覽整個 vault", detail: "", systemImage: "folder", isCommand: true, action: { workspace.open(.folder("")) }),
            Item(id: "scan", title: "掃描文件", detail: "", systemImage: "viewfinder", isCommand: true, action: { workspace.open(.scan) }),
            Item(id: "camera", title: "開啟相機連續拍照", detail: "", systemImage: "camera", isCommand: true, action: { workspace.showsCamera = true }),
            Item(id: "history", title: "掃描紀錄", detail: "", systemImage: "clock", isCommand: true, action: { workspace.open(.history) }),
            Item(id: "left", title: "切換左側欄", detail: "", systemImage: "sidebar.left", isCommand: true, action: { workspace.toggleLeft() }),
            Item(id: "right", title: "切換右側欄", detail: "", systemImage: "sidebar.right", isCommand: true, action: { workspace.toggleRight() }),
            Item(id: "search", title: "搜尋內文", detail: "", systemImage: "magnifyingglass", isCommand: true, action: { workspace.showLeft(.search) }),
            Item(id: "sync", title: "立即同步", detail: "", systemImage: "arrow.triangle.2.circlepath", isCommand: true, action: { Task { await VaultSyncCenter.shared.syncNow() } }),
            Item(id: "settings", title: "設定", detail: "", systemImage: "slider.horizontal.3", isCommand: true, action: { workspace.open(.settings) }),
        ]
        if !VaultSyncCenter.shared.isConfigured {
            items.insert(Item(id: "pair", title: "與 Obsidian 配對", detail: "", systemImage: "link", isCommand: true, action: { workspace.showsPairing = true }), at: 0)
        }
        if workspace.active != .start {
            items.append(Item(id: "close", title: "關閉目前分頁", detail: "", systemImage: "xmark", isCommand: true, action: { workspace.closeActive() }))
        }
        return items
    }

    /// 模糊比對：字依序出現即可；連續、開頭、越短的標題分數越高。
    nonisolated static func score(_ title: String, query: String) -> Int? {
        let haystack = Array(title.lowercased())
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        var score = 0
        var position = 0
        var previous = -2
        for character in needle {
            guard let found = haystack[position...].firstIndex(of: character) else { return nil }
            score += found == previous + 1 ? 8 : 1
            if found == 0 { score += 10 }
            previous = found
            position = found + 1
        }
        if title.lowercased().contains(query.lowercased()) { score += 20 }
        return score * 100 - haystack.count
    }

    private func run(_ items: [Item]) {
        guard items.indices.contains(selection) else { return }
        let action = items[selection].action
        close()
        action()
    }

    private func close() {
        workspace.showsPalette = false
    }
}
