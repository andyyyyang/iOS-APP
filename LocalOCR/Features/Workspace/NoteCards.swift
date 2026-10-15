import SwiftUI
import UIKit

/// 新增用的黑色浮動工具列：文字筆記、手寫筆記本、待辦清單、資料夾、掃描，最右邊是更多。
struct CreatePalette: View {
    @Environment(Workspace.self) private var workspace
    @State private var folderName = ""
    @State private var showsFolderPrompt = false

    var body: some View {
        FloatingPalette {
            PaletteButton(title: "新增筆記", glyph: "T", pastel: .lavender) { workspace.newTextNote() }
            PaletteButton(title: "新增手寫筆記", systemImage: "pencil", pastel: .sky) { workspace.newNotebook() }
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
            Button { workspace.open(.drawings) } label: { Label("圖面瀏覽", systemImage: WorkspaceTab.drawings.systemImage) }
            Button { workspace.open(.logistics) } label: { Label("物流追蹤", systemImage: WorkspaceTab.logistics.systemImage) }
            Button { workspace.open(.hub) } label: { Label("業務快查（通訊錄、代碼、案件、BPM）", systemImage: WorkspaceTab.hub.systemImage) }
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
                Text(featured ? "手寫筆記" : (note.folder.isEmpty ? "最上層" : note.folder))
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
            Text(note.snippet.isEmpty ? (note.isNotebook ? "手寫內容" : note.isLocal ? "沒有其他文字" : "在雲端，打開時下載") : note.snippet)
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
