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
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if !subfolders.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader("資料夾", trailing: "\(subfolders.count)")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 150 : 180), spacing: 12)], spacing: 12) {
                                ForEach(subfolders, id: \.self) { subfolder in
                                    Button {
                                        workspace.open(.folder(subfolder))
                                    } label: {
                                        FolderTile(folder: subfolder, count: store.fileCount(inFolder: subfolder))
                                    }
                                    .buttonStyle(CardPressStyle())
                                }
                            }
                        }
                    }

                    if !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader("筆記", trailing: "\(notes.count)")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 280 : 210), spacing: 12)], alignment: .leading, spacing: 12) {
                                ForEach(notes) { note in
                                    Button {
                                        workspace.openNote(note.path)
                                    } label: {
                                        NoteCard(note: note)
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

                    if !files.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader("檔案", trailing: "\(files.count)")
                            VaultFilesList(files: files)
                        }
                    }

                    if subfolders.isEmpty && notes.isEmpty && files.isEmpty {
                        EmptyStateView(title: "空的資料夾", message: "用下方的工具列新增筆記或手寫筆記。")
                    }
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
        VStack(alignment: .leading, spacing: 6) {
            // 路徑：Vault / 工作 / 會議
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Text("/").foregroundStyle(DS.textTertiary)
                        }
                        Button(NotesStore.folderTitle(crumb)) {
                            workspace.open(.folder(crumb))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(crumb == folder ? DS.text : DS.textSecondary)
                    }
                }
                .font(.footnote)
            }
            PageHeader(NotesStore.folderTitle(folder), subtitle: "\(store.fileCount(inFolder: folder)) 個檔案")
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

/// 資料夾卡片：粉彩圓形圖示、名稱與檔案數。
private struct FolderTile: View {
    let folder: String
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            CircleIcon(systemImage: "folder", fill: DS.Pastel.stable(for: folder).color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(NotesStore.folderTitle(folder))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Text("\(count) 個檔案")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DS.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 12)
        .contentShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
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
                    Rectangle().fill(DS.hairline).frame(height: 1).padding(.leading, 66)
                }
            }
        }
        .card(padding: 0)
        .quickLookPreview($previewURL)
        .alert("無法下載", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ item: VaultItem) -> some View {
        HStack(spacing: 12) {
            FileThumbnail(item: item)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)) · \(item.mtime.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if downloading == item.path {
                ProgressView()
            } else if !item.isLocal {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(DS.textTertiary)
                    .accessibilityLabel("尚未下載")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DS.control)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: item.systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .task(id: item.isLocal ? item.path : nil) {
            guard item.isLocal else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: LocalVault.shared.url(for: item.path),
                size: CGSize(width: 38, height: 38),
                scale: displayScale,
                representationTypes: .thumbnail
            )
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
    }
}
