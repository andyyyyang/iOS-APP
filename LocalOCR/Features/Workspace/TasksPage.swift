import SwiftUI

/// 待辦分頁：所有筆記中未完成的待辦，依筆記分組，可直接打勾。
struct TasksPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var store = NotesStore.shared

    var body: some View {
        let groups = store.notes.compactMap { note -> (note: NoteSummary, tasks: [NoteTask])? in
            let open = note.tasks.filter { !$0.done }
            return open.isEmpty ? nil : (note, open)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("待辦")
                        .font(.system(size: sizeClass == .compact ? 38 : 52, weight: .heavy, design: .rounded))
                        .tracking(-1)
                        .gradientForeground()
                    Text("\(store.openTasks.count) 件未完成 · 來自 \(groups.count) 則筆記")
                        .font(.system(.subheadline, design: .rounded).monospacedDigit())
                        .foregroundStyle(Midnight.textSecondary)
                }
                if groups.isEmpty {
                    MidnightEmptyState(title: "全部完成了", systemImage: "checkmark.seal", message: "在筆記中寫「- [ ] 事項」就會出現在這裡。")
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(groups, id: \.note.path) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                Button {
                                    workspace.openNote(group.note.path)
                                } label: {
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(Midnight.hue(for: group.note.path))
                                            .frame(width: 8, height: 8)
                                            .glow(Midnight.hue(for: group.note.path), radius: 6)
                                        Text(group.note.title)
                                            .font(.system(.headline, design: .rounded))
                                            .foregroundStyle(Midnight.text)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(group.tasks.count)")
                                            .font(.system(.caption, design: .rounded).monospacedDigit())
                                            .foregroundStyle(Midnight.textTertiary)
                                        Image(systemName: "arrow.up.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Midnight.textTertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                ForEach(group.tasks) { task in
                                    TaskLine(task: task, onToggle: { store.toggle(task) }, onOpen: { workspace.openNote(task.notePath) })
                                }
                            }
                            .glassCard(padding: 18)
                        }
                    }
                }
            }
            .padding(.horizontal, sizeClass == .compact ? 20 : 40)
            .padding(.vertical, sizeClass == .compact ? 22 : 34)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }
}
