import SwiftUI
import UIKit

/// 首頁（新分頁）：標題與日期、最近編輯的筆記卡片；底部是新增用的黑色浮動工具列。
struct StartPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var store = NotesStore.shared
    @State private var sync = VaultSyncCenter.shared

    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if !sync.isConfigured {
                        pairingCard
                    }
                    recent
                }
                .padding(.horizontal, isCompact ? 16 : 24)
                .padding(.top, isCompact ? 18 : 22)
                .padding(.bottom, 100)
                .frame(maxWidth: 1200, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)

            CreatePalette()
                .padding(.bottom, isCompact ? 14 : 20)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("我的筆記")
                .font(.system(size: isCompact ? 26 : 28, weight: .semibold))
                .foregroundStyle(DS.text)
            Text(Date().formatted(.dateTime.month().day().weekday(.wide)))
                .font(.subheadline)
                .foregroundStyle(DS.textSecondary)
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近編輯")
                    .font(.system(size: 17, weight: .semibold))
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
                Text(sync.isConfigured ? "vault 裡還沒有筆記，按下方的 T 新增一則。" : "配對後，整個 vault 的筆記都會出現在這裡。")
                    .font(.subheadline)
                    .foregroundStyle(DS.textTertiary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 280 : 210), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(Array(store.notes.prefix(isCompact ? 8 : 15))) { note in
                        Button {
                            workspace.openNote(note.path)
                        } label: {
                            NoteCard(note: note, featured: note.path == featuredPath)
                        }
                        .buttonStyle(CardPressStyle())
                        .contextMenu {
                            if let url = NotesSettings.obsidianURL(for: note.path) {
                                Link(destination: url) { Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app") }
                            }
                            Button(role: .destructive) { workspace.pendingDelete = note } label: { Label("刪除", systemImage: "trash") }
                        }
                    }
                }
            }
        }
    }

    /// 最近的手寫筆記本以粉紫色大卡片顯示（「繼續書寫」）。
    private var featuredPath: String? {
        store.notes.prefix(15).first(where: \.isNotebook)?.path
    }

    private var pairingCard: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("與 Obsidian 配對")
                    .font(.headline)
                    .foregroundStyle(DS.text)
                Text("在電腦（Windows 或 Mac）的 Obsidian 執行「LocalOCR：配對 iPhone／iPad」並掃描 QR Code，整個 vault 就會雙向同步。")
                    .font(.subheadline)
                    .foregroundStyle(DS.onPastelSecondary)
            }
            Spacer(minLength: 0)
            Button("開始配對") { workspace.showsPairing = true }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        }
        .pastelCard(.sky, padding: 16)
    }
}

/// 新增用的黑色浮動工具列：文字筆記、手寫筆記本、待辦清單、資料夾、掃描，最右邊是更多。
struct CreatePalette: View {
    @Environment(Workspace.self) private var workspace
    @State private var folderName = ""
    @State private var showsFolderPrompt = false

    var body: some View {
        FloatingPalette {
            PaletteButton(title: "新增筆記", glyph: "T", pastel: .lavender) { workspace.newTextNote() }
            PaletteButton(title: "新增手寫筆記本", systemImage: "pencil", pastel: .sky) { workspace.requestNewNotebook() }
            PaletteButton(title: "新增待辦清單", systemImage: "checkmark.square", pastel: .butter) { workspace.newTaskNote() }
            PaletteButton(title: "新增資料夾", systemImage: "folder", pastel: .blush) {
                folderName = ""
                showsFolderPrompt = true
            }
            PaletteButton(title: "掃描文件", systemImage: "viewfinder", pastel: .mint) { workspace.open(.scan) }
            Menu {
                Button { workspace.showsCamera = true } label: { Label("相機連續拍照", systemImage: "camera") }
                Button { workspace.open(.tasks) } label: { Label("所有待辦", systemImage: "checkmark.square") }
                Button { workspace.open(.graph) } label: { Label("關聯圖", systemImage: WorkspaceTab.graph.systemImage) }
                Button { Task { await VaultSyncCenter.shared.syncNow() } } label: { Label("立即同步", systemImage: "arrow.triangle.2.circlepath") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(DS.inkRaised, in: Circle())
            }
            .accessibilityLabel("更多")
        }
        .alert("新增資料夾", isPresented: $showsFolderPrompt) {
            TextField("名稱", text: $folderName)
            Button("取消", role: .cancel) {}
            Button("建立") { workspace.createFolder(named: folderName, in: workspace.currentFolder) }
        } message: {
            Text(workspace.currentFolder.isEmpty ? "建立在最上層" : "建立在「\(workspace.currentFolder)」中")
        }
    }
}

/// 卡片按下時稍微變淡。
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// 筆記卡片：資料夾、右上角的圓形圖示、標題、摘要，下方是標籤或待辦進度與時間。
/// `featured`：手寫筆記本的粉紫色大卡片。
struct NoteCard: View {
    let note: NoteSummary
    var featured = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(featured ? "手寫筆記本" : (note.folder.isEmpty ? "最上層" : note.folder))
                    .font(.caption.weight(featured ? .medium : .regular))
                    .foregroundStyle(featured ? DS.onPastelSecondary : DS.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let embed = note.firstEmbed, !note.isNotebook {
                    EmbedThumbnail(embed: embed)
                        .frame(width: 30, height: 30)
                } else {
                    CircleIcon(
                        systemImage: note.isNotebook ? "pencil" : "doc.text",
                        fill: featured ? DS.card : DS.Pastel.stable(for: note.path).color
                    )
                }
            }
            Text(note.title)
                .font(.system(size: featured ? 19 : 17, weight: .semibold))
                .foregroundStyle(DS.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(note.snippet.isEmpty ? (note.isNotebook ? "手寫內容" : "沒有其他文字") : note.snippet)
                .font(.system(size: 13))
                .foregroundStyle(featured ? DS.onPastelSecondary : DS.textSecondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            HStack(alignment: .center) {
                if featured {
                    Text("繼續書寫")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DS.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(DS.card, in: Capsule())
                } else if !note.tasks.isEmpty {
                    Chip(text: "待辦 \(note.tasks.filter(\.done).count)/\(note.tasks.count)", pastel: .mint)
                } else if let tag = note.tags.first {
                    Chip(text: "#" + tag, pastel: DS.Pastel.stable(for: tag))
                }
                Spacer(minLength: 4)
                Text(note.mtime.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(featured ? DS.onPastelSecondary : DS.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .card(padding: 16, fill: featured ? DS.Pastel.lavender.color : DS.card, bordered: !featured)
        .contentShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
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
                TaskCheckbox(done: task.done)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: task.done)
            .accessibilityLabel(task.done ? "標示為未完成" : "標示為完成")
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.text)
                        .font(.subheadline)
                        .foregroundStyle(task.done ? DS.textTertiary : DS.text)
                        .strikethrough(task.done)
                        .multilineTextAlignment(.leading)
                    Text(task.noteTitle)
                        .font(.caption2)
                        .foregroundStyle(DS.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// 圓形核取方塊：完成時是黑底白勾。
struct TaskCheckbox: View {
    let done: Bool
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            if done {
                Circle().fill(DS.primary)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(DS.onPrimary)
            } else {
                Circle().strokeBorder(DS.textTertiary, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
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
                DS.control
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
