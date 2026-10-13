import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UIKit

/// 資料夾頁面：子資料夾以大資料夾卡片排列（「N 個檔案」），下面是這個資料夾的筆記與其他檔案（圖片、PDF…）。
/// 空字串是整個 vault 的最上層。
struct NotesFolderPage: View {
    let folder: String
    let store: NotesStore
    var onSelectFolder: (String) -> Void
    var onDelete: (NoteSummary) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var subfolders: [String] { store.childFolders(of: folder) }
    private var notes: [NoteSummary] { store.notes(inFolder: folder, recursive: false) }
    private var files: [VaultItem] { store.files(inFolder: folder) }
    private var parent: String? {
        folder.isEmpty ? nil : (folder as NSString).deletingLastPathComponent
    }

    var body: some View {
        let subfolders = self.subfolders
        let notes = self.notes
        let files = self.files
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    if let parent {
                        Button {
                            onSelectFolder(parent)
                        } label: {
                            Label(NotesStore.folderTitle(parent), systemImage: "chevron.left")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    Text(NotesStore.folderTitle(folder))
                        .font(.system(size: 34, weight: .bold))
                }

                if !subfolders.isEmpty {
                    Text("資料夾")
                        .font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 180 : 140), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(subfolders, id: \.self) { subfolder in
                            Button {
                                onSelectFolder(subfolder)
                            } label: {
                                FolderCard(name: NotesStore.folderTitle(subfolder), count: store.fileCount(inFolder: subfolder))
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                        }
                    }
                }

                if !notes.isEmpty || (subfolders.isEmpty && files.isEmpty) {
                    Text("筆記")
                        .font(.title2.bold())
                    NotesTable(notes: notes, showsFolder: false, onDelete: onDelete)
                }

                if !files.isEmpty {
                    Text("檔案")
                        .font(.title2.bold())
                    VaultFilesList(files: files)
                }
            }
            .padding(sizeClass == .regular ? 32 : 18)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(NotesStore.folderTitle(folder))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 資料夾中筆記以外的檔案：點一下用「快速查看」開啟；還在雲端的檔案先下載。
struct VaultFilesList: View {
    let files: [VaultItem]

    @Environment(\.openURL) private var openURL
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
                        Button {
                            openURL(url)
                        } label: {
                            Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app")
                        }
                    }
                    if item.isLocal {
                        ShareLink(item: LocalVault.shared.url(for: item.path)) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                if index < files.count - 1 {
                    Divider().padding(.leading, 74)
                }
            }
        }
        .noteCard(cornerRadius: 20)
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
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                Text(details(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if downloading == item.path {
                ProgressView()
            } else if !item.isLocal {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("尚未下載")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func details(_ item: VaultItem) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
        return "\(size) · \(item.mtime.formatted(.relative(presentation: .named)))"
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Pastel.stable(for: item.pathExtension).fill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: item.systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: item.isLocal ? item.path : nil) {
            guard item.isLocal else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: LocalVault.shared.url(for: item.path),
                size: CGSize(width: 44, height: 44),
                scale: displayScale,
                representationTypes: .thumbnail
            )
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
    }
}

/// 資料夾卡片：資料夾圖示＋名稱＋檔案數。
struct FolderCard: View {
    let name: String
    let count: Int

    var body: some View {
        VStack(spacing: 10) {
            FolderIllustration(tint: Color(.systemGray), hasFiles: count > 0)
                .padding(.horizontal, 18)
                .padding(.top, 16)
            VStack(spacing: 2) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(count) 個檔案")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .noteCard(cornerRadius: 22)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// 筆記清單頁（所有筆記、手寫筆記本、標籤、搜尋結果）。
struct NotesListPage: View {
    let title: String
    let notes: [NoteSummary]
    var onDelete: (NoteSummary) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                NotesTable(notes: notes, showsFolder: true, onDelete: onDelete)
            }
            .padding(sizeClass == .regular ? 32 : 18)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 筆記表格：名稱｜資料夾｜修改時間｜標籤（iPhone 只顯示名稱與時間）。
struct NotesTable: View {
    let notes: [NoteSummary]
    var showsFolder: Bool
    var onDelete: (NoteSummary) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        VStack(spacing: 0) {
            if isWide {
                HStack(spacing: 16) {
                    Text("名稱").frame(maxWidth: .infinity, alignment: .leading)
                    if showsFolder { Text("資料夾").frame(width: 180, alignment: .leading) }
                    Text("修改時間").frame(width: 130, alignment: .leading)
                    Text("標籤").frame(width: 150, alignment: .leading)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                Divider()
            }
            if notes.isEmpty {
                Text("沒有筆記")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            }
            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                NavigationLink(value: NoteRoute.note(note.path)) {
                    row(note)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let url = NotesSettings.obsidianURL(for: note.path) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app")
                        }
                    }
                    Button(role: .destructive) {
                        onDelete(note)
                    } label: {
                        Label("刪除", systemImage: "trash")
                    }
                }
                if index < notes.count - 1 {
                    Divider().padding(.leading, 18)
                }
            }
        }
        .noteCard(cornerRadius: 20)
    }

    private func row(_ note: NoteSummary) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: note.isNotebook ? "pencil.and.scribble" : "doc.text")
                    .foregroundStyle(note.isNotebook ? Color.accentColor : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title)
                        .font(.body)
                        .lineLimit(1)
                    if !isWide || !note.snippet.isEmpty {
                        Text(isWide ? note.snippet : note.mtime.formatted(.relative(presentation: .named)) + (note.snippet.isEmpty ? "" : " · " + note.snippet))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isWide {
                if showsFolder {
                    Text(note.folder.isEmpty ? "—" : note.folder)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 180, alignment: .leading)
                }
                Text(note.mtime.formatted(.relative(presentation: .named)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                HStack(spacing: 4) {
                    ForEach(note.tags.prefix(2), id: \.self) { tag in
                        NoteChip(text: "#\(tag)", color: .lavender)
                    }
                }
                .frame(width: 150, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
