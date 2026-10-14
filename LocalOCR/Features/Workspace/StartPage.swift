import SwiftUI
import UIKit

/// 新分頁：大字問候、快速動作、統計、最近編輯、待辦與關聯圖預覽。
struct StartPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = NotesStore.shared
    @State private var sync = VaultSyncCenter.shared
    @State private var appeared = false

    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 26 : 34) {
                hero
                    .reveal(appeared, index: 0, reduceMotion: reduceMotion)
                actions
                    .reveal(appeared, index: 1, reduceMotion: reduceMotion)
                if !sync.isConfigured {
                    pairingCard
                        .reveal(appeared, index: 2, reduceMotion: reduceMotion)
                }
                stats
                    .reveal(appeared, index: 2, reduceMotion: reduceMotion)
                recent
                    .reveal(appeared, index: 3, reduceMotion: reduceMotion)
                if isCompact {
                    tasksCard
                    graphCard
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        tasksCard
                        graphCard
                    }
                    .reveal(appeared, index: 4, reduceMotion: reduceMotion)
                }
            }
            .padding(.horizontal, isCompact ? 20 : 44)
            .padding(.vertical, isCompact ? 24 : 40)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .onAppear { appeared = true }
    }

    // MARK: - 英雄區

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: return "早安"
        case 11..<14: return "午安"
        case 14..<18: return "午後好"
        case 18..<23: return "晚安"
        default: return "夜深了"
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                GlassChip(text: NotesStore.folderTitle(""), systemImage: "books.vertical")
                if sync.isConfigured {
                    GlassChip(
                        text: sync.isSyncing ? "同步中" : (sync.lastError == nil ? "已同步" : "同步失敗"),
                        systemImage: sync.lastError == nil ? "checkmark.icloud" : "exclamationmark.icloud",
                        tint: sync.lastError == nil ? Midnight.success : Midnight.warning
                    )
                }
            }
            Text(greeting)
                .font(.system(size: isCompact ? 52 : 76, weight: .heavy, design: .rounded))
                .tracking(-1.5)
                .gradientForeground()
                .glow(Midnight.violet, radius: 30, opacity: 0.35)
            Text(subtitle)
                .font(.system(isCompact ? .body : .title3, design: .rounded))
                .foregroundStyle(Midnight.textSecondary)
        }
        .padding(.top, isCompact ? 8 : 18)
        .background(alignment: .topTrailing) {
            DotGrid(spacing: 20, opacity: 0.12)
                .frame(width: 320, height: 200)
                .mask(RadialGradient(colors: [.black, .clear], center: .topTrailing, startRadius: 0, endRadius: 260))
                .offset(x: 20, y: -20)
        }
    }

    private var subtitle: String {
        let date = Date().formatted(.dateTime.month().day().weekday(.wide))
        let today = store.editedTodayCount
        return today > 0 ? "\(date) · 今天編輯了 \(today) 則筆記" : "\(date) · 今天想寫點什麼？"
    }

    // MARK: - 快速動作

    private var actions: some View {
        FlowLayout(spacing: 10) {
            Button {
                workspace.newTextNote()
            } label: {
                Label("新增筆記", systemImage: "square.and.pencil")
            }
            .buttonStyle(MidnightButtonStyle(kind: .primary))
            Button {
                workspace.requestNewNotebook()
            } label: {
                Label("手寫筆記本", systemImage: "pencil.and.scribble")
            }
            .buttonStyle(MidnightButtonStyle(kind: .secondary))
            Button {
                workspace.open(.scan)
            } label: {
                Label("掃描文件", systemImage: "doc.viewfinder")
            }
            .buttonStyle(MidnightButtonStyle(kind: .secondary))
            Button {
                workspace.showsPalette = true
            } label: {
                HStack(spacing: 8) {
                    Label("搜尋", systemImage: "magnifyingglass")
                    if !isCompact {
                        Text("⌘P")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(Midnight.textTertiary)
                    }
                }
            }
            .buttonStyle(MidnightButtonStyle(kind: .secondary))
        }
    }

    // MARK: - 統計

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 140 : 180), spacing: 14)], spacing: 14) {
            GlowStat(value: store.notes.count, title: "筆記", systemImage: "doc.text")
            GlowStat(value: store.notebookCount, title: "手寫筆記本", systemImage: "pencil.and.scribble")
            GlowStat(value: store.editedTodayCount, title: "今天編輯", systemImage: "clock")
            GlowStat(value: store.openTasks.count, title: "待辦", systemImage: "checklist")
        }
    }

    // MARK: - 最近編輯

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("最近編輯", trailing: store.notes.isEmpty ? nil : "\(min(store.notes.count, 12))")
            if store.notes.isEmpty {
                Text(sync.isConfigured ? "vault 裡還沒有筆記，按「新增筆記」開始。" : "配對後，整個 vault 的筆記都會出現在這裡。")
                    .font(.callout)
                    .foregroundStyle(Midnight.textTertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(Array(store.notes.prefix(12))) { note in
                            Button {
                                workspace.openNote(note.path)
                            } label: {
                                RecentNoteCard(note: note)
                            }
                            .buttonStyle(CardPressStyle())
                            .hoverEffect(.lift)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
                .scrollClipDisabled()
            }
        }
    }

    // MARK: - 待辦與關聯圖

    private var tasksCard: some View {
        let tasks = Array(store.openTasks.prefix(7))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("待辦", trailing: "\(store.openTasks.count)")
                Button {
                    workspace.open(.tasks)
                } label: {
                    Image(systemName: "arrow.up.right")
                }
                .buttonStyle(GlassIconButtonStyle(size: 28))
                .accessibilityLabel("所有待辦")
            }
            if tasks.isEmpty {
                Text("沒有待辦事項。在筆記中寫「- [ ] 事項」就會出現在這裡。")
                    .font(.callout)
                    .foregroundStyle(Midnight.textTertiary)
            } else {
                ForEach(tasks) { task in
                    TaskLine(task: task, onToggle: { store.toggle(task) }, onOpen: { workspace.openNote(task.notePath) })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard(padding: 18)
    }

    private var graphCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("關聯圖")
                Button {
                    workspace.open(.graph)
                } label: {
                    Image(systemName: "arrow.up.right")
                }
                .buttonStyle(GlassIconButtonStyle(size: 28))
                .accessibilityLabel("開啟關聯圖")
            }
            GraphView(focus: nil)
                .frame(height: 260)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard(padding: 18)
    }

    private var pairingCard: some View {
        HStack(alignment: .center, spacing: 16) {
            GlowIcon(systemImage: "qrcode.viewfinder", size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text("與 Obsidian 配對")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Midnight.text)
                Text("在電腦（Windows 或 Mac）的 Obsidian 執行「LocalOCR：配對 iPhone／iPad」並掃描 QR Code，整個 vault 就會雙向同步。")
                    .font(.subheadline)
                    .foregroundStyle(Midnight.textSecondary)
            }
            Spacer(minLength: 0)
            if !isCompact {
                Button("開始配對") { workspace.showsPairing = true }
                    .buttonStyle(MidnightButtonStyle(kind: .primary, compact: true))
            }
        }
        .glassCard(padding: 18)
        .overlay(RoundedRectangle(cornerRadius: Midnight.radiusL, style: .continuous).strokeBorder(Midnight.gradient, lineWidth: 1).opacity(0.5))
        .onTapGesture { workspace.showsPairing = true }
    }
}

// MARK: - 元件

/// 進場動畫：依序淡入上移。
private extension View {
    func reveal(_ appeared: Bool, index: Int, reduceMotion: Bool) -> some View {
        opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 18)
            .animation(reduceMotion ? .none : .smooth(duration: 0.7).delay(Double(index) * 0.07), value: appeared)
    }
}

/// 卡片按下時微微縮小。
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// 最近編輯的筆記卡：標題、摘要、時間、標籤與待辦進度；有圖片時顯示縮圖。
struct RecentNoteCard: View {
    let note: NoteSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: note.isNotebook ? "pencil.and.scribble" : "doc.text")
                    .font(.caption.weight(.semibold))
                    .gradientForeground()
                Text(note.mtime.formatted(.relative(presentation: .named)))
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Midnight.textTertiary)
                Spacer(minLength: 0)
                if let embed = note.firstEmbed {
                    EmbedThumbnail(embed: embed)
                        .frame(width: 34, height: 34)
                }
            }
            Text(note.title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Midnight.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(note.snippet.isEmpty ? "沒有其他文字" : note.snippet)
                .font(.subheadline)
                .foregroundStyle(Midnight.textSecondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if let tag = note.tags.first {
                    GlassChip(text: "#" + tag, tint: Midnight.hue(for: tag))
                }
                if !note.tasks.isEmpty {
                    let done = note.tasks.filter(\.done).count
                    GlassChip(text: "\(done)/\(note.tasks.count)", systemImage: "checklist", tint: done == note.tasks.count ? Midnight.success : Midnight.accent)
                }
            }
        }
        .padding(16)
        .frame(width: 236, height: 196, alignment: .topLeading)
        .glass(cornerRadius: 22, shadow: false)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// 一個待辦：打勾、點文字開啟筆記。
struct TaskLine: View {
    let task: NoteTask
    var onToggle: () -> Void
    var onOpen: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.body.weight(.medium))
                    .foregroundStyle(task.done ? AnyShapeStyle(Midnight.gradient) : AnyShapeStyle(Midnight.textTertiary))
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: task.done)
            .accessibilityLabel(task.done ? "標示為未完成" : "標示為完成")
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.text)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(task.done ? Midnight.textTertiary : Midnight.text)
                        .strikethrough(task.done)
                        .multilineTextAlignment(.leading)
                    Text(task.noteTitle)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(Midnight.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// 筆記中的第一張圖片（只用本機已有的，不為了縮圖下載附件）。
struct EmbedThumbnail: View {
    let embed: String

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Midnight.raised
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .task(id: embed) {
            let center = VaultSyncCenter.shared
            let files = center.vault.allFiles()
            guard let path = await center.engine.resolve(name: embed, localFiles: files), center.vault.exists(path) else { return }
            let url = center.vault.url(for: path)
            image = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path(percentEncoded: false))?.preparingThumbnail(of: CGSize(width: 200, height: 200))
            }.value
        }
    }
}
