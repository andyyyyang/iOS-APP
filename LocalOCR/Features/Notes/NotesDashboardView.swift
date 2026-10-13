import SwiftUI
import UIKit

/// 首頁：統計、最近編輯的筆記卡片，右側（iPhone 為下方）是各筆記中還沒完成的待辦。
struct NotesDashboardView: View {
    let store: NotesStore
    let isPaired: Bool
    var onOpen: (String) -> Void
    var onPair: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var recentNotes: [NoteSummary] { Array(store.notes.prefix(8)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if !isPaired {
                    PairingPromptCard(onPair: onPair)
                }
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 24) {
                            stats
                            recentSection
                        }
                        .frame(maxWidth: .infinity)
                        tasksColumn
                            .frame(width: 320)
                    }
                } else {
                    stats
                    recentSection
                    tasksColumn
                }
            }
            .padding(.horizontal, sizeClass == .regular ? 32 : 18)
            .padding(.vertical, 20)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("首頁")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month().day()))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("我的筆記 📒")
                .font(.system(size: 38, weight: .bold))
        }
    }

    private var stats: some View {
        HStack(spacing: 12) {
            StatTile(value: store.notes.count, title: "筆記", color: .sky)
            StatTile(value: store.notebookCount, title: "手寫筆記本", color: .mint)
            if sizeClass == .regular {
                StatTile(value: store.editedTodayCount, title: "今天編輯", color: .butter)
            }
            StatTile(value: store.openTasks.count, title: "待辦")
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("最近編輯")
                .font(.title2.bold())
            if recentNotes.isEmpty {
                Text("還沒有筆記。點下方的按鈕新增文字筆記或手寫筆記本。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .noteCard()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                    ForEach(Array(recentNotes.enumerated()), id: \.element.id) { index, note in
                        NavigationLink(value: NoteRoute.note(note.path)) {
                            NoteCard(note: note, highlighted: index == 0)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.lift)
                    }
                }
            }
        }
    }

    private var tasksColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("待辦 ✅")
                .font(.title2.bold())
            let groups = taskGroups
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                    Text("沒有待辦事項")
                        .foregroundStyle(.secondary)
                    Text("在筆記中寫「- [ ] 事項」就會出現在這裡。")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .background {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .foregroundStyle(.tertiary)
                }
            } else {
                ForEach(groups, id: \.path) { group in
                    TaskGroupCard(group: group, color: Pastel.stable(for: group.path), onOpen: { onOpen(group.path) }, onToggle: { store.toggle($0) })
                }
            }
        }
    }

    private var taskGroups: [TaskGroup] {
        var groups: [TaskGroup] = []
        for note in store.notes {
            let open = note.tasks.filter { !$0.done }
            guard !open.isEmpty else { continue }
            groups.append(TaskGroup(path: note.path, title: note.title, mtime: note.mtime, tasks: open))
            if groups.count == 6 { break }
        }
        return groups
    }
}

struct TaskGroup {
    let path: String
    let title: String
    let mtime: Date
    let tasks: [NoteTask]
}

/// 一則筆記的待辦（像參考圖右側的事件卡）。
struct TaskGroupCard: View {
    let group: TaskGroup
    let color: Pastel
    var onOpen: () -> Void
    var onToggle: (NoteTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                HStack {
                    Image(systemName: "checklist")
                        .foregroundStyle(color.accent)
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(group.mtime, format: .dateTime.month(.defaultDigits).day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.tasks.prefix(4)) { task in
                    Button {
                        withAnimation { onToggle(task) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "circle")
                                .foregroundStyle(color.accent)
                            Text(task.text)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("完成：\(task.text)")
                }
                if group.tasks.count > 4 {
                    Text("還有 \(group.tasks.count - 4) 項")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground).opacity(0.75), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(14)
        .background(color.fill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// 筆記卡片：標題、摘要、標籤與待辦進度；最新的一張用粉彩底色強調。
struct NoteCard: View {
    let note: NoteSummary
    var highlighted = false

    private var color: Pastel { Pastel.stable(for: note.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(note.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: note.isNotebook ? "pencil.and.scribble" : "doc.text")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(highlighted ? Color(.systemBackground).opacity(0.7) : color.fill, in: Circle())
            }
            if let embed = note.firstEmbed, note.snippet.isEmpty || note.isNotebook {
                NoteThumbnail(embed: embed, size: CGSize(width: 9999, height: 110))
                    .frame(height: 110)
            } else {
                Text(note.snippet.isEmpty ? "沒有其他文字" : note.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                NoteChip(text: note.mtime.formatted(.relative(presentation: .named)), systemImage: "clock", color: highlighted ? .butter : .mint)
                if let tag = note.tags.first {
                    NoteChip(text: "#\(tag)", color: .lavender)
                }
                let open = note.tasks.filter { !$0.done }.count
                if !note.tasks.isEmpty {
                    NoteChip(text: "\(note.tasks.count - open)/\(note.tasks.count)", systemImage: "checklist", color: open == 0 ? .mint : .butter)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(color.fill)
            } else {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(.secondarySystemGroupedBackground))
            }
        }
        .shadow(color: .black.opacity(highlighted ? 0.1 : 0.05), radius: highlighted ? 16 : 12, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// 筆記中的第一張圖片（只用本機已有的，不為了縮圖下載附件）。
struct NoteThumbnail: View {
    let embed: String
    var size = CGSize(width: 52, height: 52)
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.08)
            }
        }
        .frame(maxWidth: size.width, maxHeight: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: embed) {
            let center = VaultSyncCenter.shared
            let files = center.vault.allFiles()
            guard let path = await center.engine.resolve(name: embed, localFiles: files), center.vault.exists(path) else { return }
            let url = center.vault.url(for: path)
            image = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path(percentEncoded: false))?.preparingThumbnail(of: CGSize(width: 600, height: 600))
            }.value
        }
    }
}

struct PairingPromptCard: View {
    var onPair: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 56, height: 56)
                .background(Color(.systemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("與 Obsidian 配對")
                    .font(.headline)
                Text("在電腦（Windows 或 Mac）的 Obsidian 執行「LocalOCR：配對 iPhone／iPad」，掃描 QR Code，筆記就會雙向同步。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("開始配對", action: onPair)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        }
        .padding(18)
        .background(Pastel.sky.fill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// 所有待辦：依筆記分組，可直接打勾。
struct NotesTasksPage: View {
    let store: NotesStore
    var onOpen: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("待辦 ✅")
                    .font(.system(size: 34, weight: .bold))
                let groups = store.notes.compactMap { note -> TaskGroup? in
                    let open = note.tasks.filter { !$0.done }
                    return open.isEmpty ? nil : TaskGroup(path: note.path, title: note.title, mtime: note.mtime, tasks: open)
                }
                if groups.isEmpty {
                    ContentUnavailableView("沒有待辦事項", systemImage: "checkmark.circle", description: Text("在筆記中寫「- [ ] 事項」就會出現在這裡。"))
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(groups, id: \.path) { group in
                            TaskGroupCard(group: group, color: Pastel.stable(for: group.path), onOpen: { onOpen(group.path) }, onToggle: { store.toggle($0) })
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("待辦")
        .navigationBarTitleDisplayMode(.inline)
    }
}
