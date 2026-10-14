import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UIKit

/// 資料夾分頁：路徑、子資料夾、筆記與其他檔案（圖片、PDF…）。空字串是整個 vault 的最上層。
struct FolderPage: View {
    let folder: String

    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var store = NotesStore.shared

    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        let subfolders = store.childFolders(of: folder)
        let notes = store.notes(inFolder: folder, recursive: false)
        let files = store.files(inFolder: folder)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header(noteCount: store.noteCount(inFolder: folder))

                if !subfolders.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("資料夾", trailing: "\(subfolders.count)")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 150 : 190), spacing: 14)], spacing: 14) {
                            ForEach(subfolders, id: \.self) { subfolder in
                                Button {
                                    workspace.open(.folder(subfolder))
                                } label: {
                                    FolderTile(folder: subfolder, count: store.fileCount(inFolder: subfolder))
                                }
                                .buttonStyle(CardPressStyle())
                                .hoverEffect(.lift)
                            }
                        }
                    }
                }

                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("筆記", trailing: "\(notes.count)")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 236), spacing: 14)], alignment: .leading, spacing: 14) {
                            ForEach(notes) { note in
                                Button {
                                    workspace.openNote(note.path)
                                } label: {
                                    RecentNoteCard(note: note)
                                }
                                .buttonStyle(CardPressStyle())
                                .hoverEffect(.lift)
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

                if !files.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("檔案", trailing: "\(files.count)")
                        VaultFilesList(files: files)
                    }
                }

                if subfolders.isEmpty && notes.isEmpty && files.isEmpty {
                    MidnightEmptyState(title: "空的資料夾", systemImage: "folder", message: "用上方的按鈕新增筆記或手寫筆記本。")
                }
            }
            .padding(.horizontal, isCompact ? 20 : 40)
            .padding(.vertical, isCompact ? 22 : 34)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private func header(noteCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 路徑：Vault › 工作 › 會議
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Midnight.textTertiary)
                        }
                        Button(NotesStore.folderTitle(crumb)) {
                            workspace.open(.folder(crumb))
                        }
                        .buttonStyle(.plain)
                        .font(.system(.subheadline, design: .rounded).weight(crumb == folder ? .semibold : .regular))
                        .foregroundStyle(crumb == folder ? Midnight.text : Midnight.textSecondary)
                    }
                }
            }
            HStack(alignment: .center, spacing: 16) {
                GlowIcon(systemImage: folder.isEmpty ? "books.vertical.fill" : "folder.fill", size: isCompact ? 48 : 60, tint: folder.isEmpty ? nil : Midnight.hue(for: folder))
                VStack(alignment: .leading, spacing: 4) {
                    Text(NotesStore.folderTitle(folder))
                        .font(.system(size: isCompact ? 32 : 44, weight: .bold, design: .rounded))
                        .foregroundStyle(Midnight.text)
                        .lineLimit(2)
                    Text("\(noteCount) 則筆記 · \(store.fileCount(inFolder: folder)) 個檔案")
                        .font(.system(.subheadline, design: .rounded).monospacedDigit())
                        .foregroundStyle(Midnight.textSecondary)
                }
            }
            FlowLayout(spacing: 10) {
                Button {
                    workspace.newTextNote(in: folder)
                } label: {
                    Label("新增筆記", systemImage: "square.and.pencil")
                }
                .buttonStyle(MidnightButtonStyle(kind: .primary, compact: true))
                Button {
                    workspace.requestNewNotebook(in: folder)
                } label: {
                    Label("手寫筆記本", systemImage: "pencil.and.scribble")
                }
                .buttonStyle(MidnightButtonStyle(kind: .secondary, compact: true))
            }
        }
    }

    private var breadcrumbs: [String] {
        var result = [""]
        var current = ""
        for component in folder.split(separator: "/") {
            current = current.isEmpty ? String(component) : current + "/" + component
            result.append(current)
        }
        return result
    }
}

/// 資料夾卡片：發光的資料夾圖示、名稱與檔案數。
private struct FolderTile: View {
    let folder: String
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [Midnight.hue(for: folder), Midnight.hue(for: folder).opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .glow(Midnight.hue(for: folder), radius: 14, opacity: 0.45)
            VStack(alignment: .leading, spacing: 2) {
                Text(NotesStore.folderTitle(folder))
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Midnight.text)
                    .lineLimit(1)
                Text("\(count) 個檔案")
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundStyle(Midnight.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16, cornerRadius: 20)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// 筆記以外的檔案：點一下用「快速查看」開啟；還在雲端的檔案先下載。
struct VaultFilesList: View {
    let files: [VaultItem]

    @State private var previewURL: URL?
    @State private var downloading: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, item in
                Button {
                    open(item)
                } label: {
                    row(item)
                }
                .buttonStyle(.plain)
                .disabled(downloading != nil)
                .contextMenu {
                    if let url = NotesSettings.obsidianURL(for: item.path) {
                        Link(destination: url) { Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app") }
                    }
                    if item.isLocal {
                        ShareLink(item: LocalVault.shared.url(for: item.path)) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                if index < files.count - 1 {
                    Divider().overlay(Midnight.hairline).padding(.leading, 72)
                }
            }
        }
        .glass(cornerRadius: 20, shadow: false)
        .quickLookPreview($previewURL)
        .alert("無法下載", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ item: VaultItem) -> some View {
        HStack(spacing: 14) {
            FileThumbnail(item: item)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(Midnight.text)
                    .lineLimit(1)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)) · \(item.mtime.formatted(.relative(presentation: .named)))")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Midnight.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if downloading == item.path {
                ProgressView()
            } else if !item.isLocal {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(Midnight.textTertiary)
                    .accessibilityLabel("尚未下載")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func open(_ item: VaultItem) {
        if item.isLocal {
            previewURL = LocalVault.shared.url(for: item.path)
            return
        }
        downloading = item.path
        Task {
            defer { downloading = nil }
            do {
                previewURL = try await VaultSyncCenter.shared.download(item.path)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// 檔案縮圖（圖片、PDF 等由系統產生）；沒有縮圖或還在雲端時顯示檔案類型圖示。
struct FileThumbnail: View {
    let item: VaultItem

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Midnight.hue(for: item.pathExtension).opacity(0.16))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            } else {
                Image(systemName: item.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Midnight.hue(for: item.pathExtension))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Midnight.hairline, lineWidth: 1))
        .task(id: item.isLocal ? item.path : nil) {
            guard item.isLocal else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: LocalVault.shared.url(for: item.path),
                size: CGSize(width: 42, height: 42),
                scale: displayScale,
                representationTypes: .thumbnail
            )
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
    }
}
