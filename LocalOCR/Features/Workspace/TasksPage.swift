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
            VStack(alignment: .leading, spacing: 18) {
                PageHeader("待辦", subtitle: "\(store.openTasks.count) 件未完成 · \(groups.count) 則筆記")
                if groups.isEmpty {
                    EmptyStateView(title: "沒有待辦事項", message: "在筆記中寫「- [ ] 事項」就會出現在這裡。")
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(groups, id: \.note.path) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Button {
                                    workspace.openNote(group.note.path)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(group.note.title)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(DS.text)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(group.tasks.count)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(DS.onPastelSecondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(group.tasks) { task in
                                        TaskLine(task: task, onToggle: { store.toggle(task) }, onOpen: { workspace.openNote(task.notePath) })
                                    }
                                }
                                .padding(10)
                                .background(DS.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .pastelCard(DS.Pastel.stable(for: group.note.path), padding: 12)
                        }
                    }
                }
            }
            .padding(.horizontal, sizeClass == .compact ? 16 : 24)
            .padding(.vertical, sizeClass == .compact ? 18 : 22)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}
