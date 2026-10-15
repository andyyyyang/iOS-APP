import PencilKit
import SwiftUI

/// 筆記的手寫備忘：每則筆記一份，與手寫區塊相同的格式（「附件/ink-memo-筆記名稱.ink」可再編輯、「.png」給 Obsidian 看）。
/// 插入筆記後，在筆記中點圖片也能用手寫區塊編輯。
enum InkMemo {
    static let prefix = "ink-memo-"
    /// 側欄畫布的邏輯寬度：縮放到側欄寬度時筆畫粗細接近實際書寫。
    static let width: CGFloat = 420

    /// 這則筆記的備忘名稱：筆記中已經插入備忘圖片時用那個名稱（在 Obsidian 改過筆記名稱也找得到），否則依筆記名稱。
    static func name(forNote path: String, text: String?) -> String {
        if let text, let embedded = embeddedName(in: text) { return embedded }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return prefix + stem
    }

    /// 筆記中插入的手寫備忘（![[ink-memo-….png]]）的名稱。
    static func embeddedName(in text: String) -> String? {
        guard let range = text.range(of: #"!\[\[[^\]|#\n]*?ink-memo-[^\]|#\n]*?\.png"#, options: .regularExpression) else { return nil }
        let file = (String(text[range].dropFirst(3)) as NSString).lastPathComponent
        return String(file.dropLast(4))
    }

    static func embed(name: String) -> String { "![[\(name).png]]" }

    /// 筆記改名或搬移後，這台裝置上的手寫備忘跟著搬（沒有插入筆記時名稱也跟著筆記改）。
    static func follow(from oldPath: String, to newPath: String, vault: LocalVault) {
        let embedded = vault.readText(newPath).flatMap(embeddedName(in:))
        let oldName = embedded ?? name(forNote: oldPath, text: nil)
        let newName = embedded ?? name(forNote: newPath, text: nil)
        let pairs = [
            (InkFiles.expectedDataPath(notePath: oldPath, name: oldName), InkFiles.expectedDataPath(notePath: newPath, name: newName)),
            (InkFiles.expectedImagePath(notePath: oldPath, name: oldName), InkFiles.expectedImagePath(notePath: newPath, name: newName)),
        ]
        for (from, to) in pairs where from != to && vault.exists(from) && !vault.exists(to) {
            try? vault.move(from, to: to)
        }
    }
}

/// 右側欄的手寫備忘：打開筆記就能在旁邊直接手寫（Apple Pencil 書寫、手指捲動），停筆約一秒自動存檔並同步。
struct InkMemoPanel: View {
    let path: String

    @Environment(Workspace.self) private var workspace
    @Environment(\.scenePhase) private var scenePhase
    @State private var block: InkBlock?
    @State private var name = ""
    @State private var loadFailed = false
    @State private var handle = CanvasNotebookHandle()
    @State private var revision = 0
    @State private var hasChanges = false
    @State private var saveTask: Task<Void, Never>?
    /// 上次存檔（或載入）的內容；相同時不重寫檔案。
    @State private var savedData: Data?
    @State private var toast: String?
    private let sync = VaultSyncCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Group {
                if let block {
                    CanvasNotebook(
                        drawing: { handle.currentDrawing ?? block.pkDrawing },
                        minimumSegments: 1,
                        paper: block.paper,
                        handle: handle,
                        revision: revision,
                        onDrawingChange: { _ in changed() },
                        width: block.canvasWidth,
                        activatesOnAppear: false
                    )
                } else if loadFailed {
                    Text("手寫備忘還沒下載到這台裝置，連上網路後再打開這則筆記。")
                        .font(.footnote)
                        .foregroundStyle(DS.textTertiary)
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1))
        }
        .padding(.bottom, 12)
        .task(id: path) { await load() }
        .onDisappear { persistNow() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { persistNow() }
        }
        // 同步前先存檔：剛寫的筆跡也會被這次同步帶上
        .onReceive(NotificationCenter.default.publisher(for: .vaultWillSync)) { _ in persistNow() }
        .onChange(of: sync.revision) { _, _ in reloadIfChangedElsewhere() }
        .toast($toast)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("手寫備忘")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.textSecondary)
            if hasChanges {
                Text("編輯中")
                    .font(.caption2)
                    .foregroundStyle(DS.textTertiary)
            }
            Spacer(minLength: 4)
            Menu {
                Button {
                    insertIntoNote()
                } label: {
                    Label(isEmbedded ? "已插入筆記" : "插入到筆記", systemImage: "text.badge.plus")
                }
                .disabled(isEmbedded || block == nil)
                Picker("紙張", selection: Binding(get: { block?.paper ?? .blank }, set: { changePaper($0) })) {
                    ForEach(PaperStyle.allCases) { style in
                        Label(style.title, systemImage: style.systemImage).tag(style)
                    }
                }
                Divider()
                Button(role: .destructive) {
                    handle.replace(PKDrawing())
                    changed()
                } label: {
                    Label("清除筆跡", systemImage: "trash")
                }
                .disabled(block == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.textSecondary)
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("手寫備忘選項")
        }
    }

    private var noteText: String {
        workspace.liveText[path] ?? sync.vault.readText(path) ?? ""
    }

    private var isEmbedded: Bool {
        !name.isEmpty && InkMemo.embeddedName(in: noteText) == name
    }

    /// 備忘的檔案位置（載入時決定：筆記搬走後依檔名找到原本的位置，之後也存回那裡）。
    @State private var dataPath = ""
    private var imagePath: String { ((dataPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("\(name).png") }

    // MARK: 載入

    private func load() async {
        name = InkMemo.name(forNote: path, text: noteText)
        dataPath = InkFiles.dataPath(notePath: path, name: name)
        let isRemote = sync.pendingFiles.contains { $0.path == LocalVault.normalize(dataPath) }
        if !sync.vault.exists(dataPath), isRemote {
            // 按需模式下備忘可能還在遠端：先下載；拿不到時不能編輯（否則會蓋掉原本的筆跡）
            _ = try? await sync.download(dataPath)
        }
        if sync.vault.exists(dataPath) {
            guard let data = try? sync.vault.read(dataPath), var saved = try? JSONDecoder().decode(InkBlock.self, from: data) else {
                loadFailed = true
                return
            }
            saved.migrateToCanvas()
            savedData = data
            block = saved
        } else if isRemote {
            loadFailed = true
            return
        } else {
            block = InkBlock(height: InkBlock.minimumHeight, paper: .blank, drawing: PKDrawing().dataRepresentation(), width: InkMemo.width)
        }
        revision += 1
    }

    /// 其他裝置改過（或在筆記中用手寫區塊編輯過）、這裡沒有未存的筆跡時載入新的內容。
    private func reloadIfChangedElsewhere() {
        guard !hasChanges, let current = block, !dataPath.isEmpty,
              let data = try? sync.vault.read(dataPath), data != savedData,
              var saved = try? JSONDecoder().decode(InkBlock.self, from: data) else { return }
        saved.migrateToCanvas()
        savedData = data
        handle.replace(saved.pkDrawing)
        block = saved
        if saved.paper != current.paper || saved.canvasWidth != current.canvasWidth { revision += 1 }
    }

    // MARK: 存檔

    private func changed() {
        hasChanges = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    private func changePaper(_ paper: PaperStyle) {
        guard var current = block else { return }
        if let drawing = handle.currentDrawing { current.pkDrawing = drawing }
        current.paper = paper
        block = current
        revision += 1
        changed()
    }

    /// 寫入筆跡與圖片並上傳；還沒寫過字的備忘不建立檔案。
    @discardableResult
    private func persistNow() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard var current = block, !dataPath.isEmpty else { return false }
        if let drawing = handle.currentDrawing { current.pkDrawing = drawing }
        current.height = InkBlock.fittedHeight(for: current.pkDrawing)
        guard let data = try? JSONEncoder().encode(current) else { return false }
        hasChanges = false
        guard data != savedData else { return true }
        let dataPath = self.dataPath, imagePath = self.imagePath
        if savedData == nil, current.pkDrawing.strokes.isEmpty, !sync.vault.exists(dataPath) { return true }
        guard let image = InkFiles.image(for: current).pngData() else {
            hasChanges = true
            return false
        }
        do {
            try sync.vault.write(data, to: dataPath)
            try sync.vault.write(image, to: imagePath)
        } catch {
            toast = "手寫備忘儲存失敗：\(error.localizedDescription)"
            hasChanges = true
            return false
        }
        savedData = data
        block = current
        let sync = self.sync
        Task {
            // 圖片與筆跡是這裡整個重新產生的：上傳時直接取代遠端版本
            await sync.prepareOverwrite([dataPath, imagePath])
            sync.fileDidChange(dataPath)
            sync.fileDidChange(imagePath)
        }
        return true
    }

    /// 把備忘圖片插入筆記最後面（之後備忘更新時，筆記中的圖片也跟著更新）。
    private func insertIntoNote() {
        guard let drawing = handle.currentDrawing ?? block?.pkDrawing, !drawing.strokes.isEmpty else {
            toast = "先寫一點東西再插入"
            return
        }
        changed()
        guard persistNow() else { return }
        let embed = InkMemo.embed(name: name)
        workspace.editRequest = EditRequest(path: path) { text in
            guard !text.contains(embed) else { return text }
            let trimmed = text.hasSuffix("\n") ? text : text + "\n"
            return trimmed + "\n" + embed + "\n"
        }
    }
}
