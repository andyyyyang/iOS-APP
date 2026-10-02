import SwiftData
import SwiftUI

struct ResultView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case json = "JSON"
        case image = "圖片"
        case text = "文字"
        case lines = "逐行"

        var id: Self { self }
    }

    let session: ScanSession

    @Environment(\.modelContext) private var modelContext
    @Environment(TemplateLibrary.self) private var library
    @AppStorage(OCRSettings.Key.autoSaveHistory) private var autoSave = true
    @AppStorage(ServerSettings.Key.autoUpload) private var autoUpload = true
    @AppStorage(ServerSettings.Key.useJev) private var useJev = true
    @State private var mode: Mode = .json
    @State private var editedText = ""
    @State private var showsBoxes = true
    @State private var savedRecord: ScanRecord?
    @State private var smart = SmartScanModel()
    @State private var uploadState: UploadState = .notConfigured
    @State private var toast: String?
    @State private var feedbackTrigger = 0
    @State private var didLoad = false
    /// 目前文件的所有頁面（可在結果頁繼續加入）。
    @State private var pages: [OCRPage] = []
    @State private var showsAddPages = false
    @State private var sourceRequest: PageSource?
    @State private var addingPages: (current: Int, total: Int)?

    var body: some View {
        VStack(spacing: 0) {
            Picker("顯示方式", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            switch mode {
            case .json:
                SmartResultPanel(
                    model: smart,
                    templates: library.all,
                    uploadState: uploadState,
                    onRerun: { template in Task { await runSmartScan(forcedTemplate: template) } },
                    onCopy: { copy($0, message: "已複製 JSON") },
                    onUpload: { Task { await upload() } }
                )
            case .image: imagePages
            case .text: textEditor
            case .lines: lineList
            }
        }
        .screenBackground()
        .navigationTitle("辨識結果")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .toast($toast)
        .sensoryFeedback(.success, trigger: feedbackTrigger)
        .onAppear(perform: loadIfNeeded)
        .addPagesDialog(isPresented: $showsAddPages, request: $sourceRequest)
        .pageSources(
            request: $sourceRequest,
            onPick: { images, _ in Task { await addPages(images) } },
            onError: { toast = $0 }
        )
        .overlay {
            if let progress = addingPages {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在辨識新加入的第 \(progress.current)／\(progress.total) 頁…")
                        .font(.subheadline)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    // MARK: - Modes

    private var imagePages: some View {
        TabView {
            ForEach(pages) { page in
                AnnotatedImageView(page: page, showsBoxes: showsBoxes) { line in
                    copy(line.text, message: "已複製：\(line.text)")
                }
                .padding([.horizontal, .bottom])
            }
        }
        .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .overlay(alignment: .top) {
            if pages.allSatisfy({ $0.lines.isEmpty }) {
                Label("沒有辨識到任何文字", systemImage: "text.badge.xmark")
                    .font(.subheadline)
                    .padding(10)
                    .background(.thinMaterial, in: Capsule())
            }
        }
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            TextEditor(text: $editedText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            Button {
                mode = .json
                Task { await runSmartScan(forcedTemplate: nil) }
            } label: {
                Label("以目前文字重新產生 JSON", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(smart.isRunning || editedText.isEmpty)
        }
        .padding([.horizontal, .bottom])
    }

    private var lineList: some View {
        List {
            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                Section {
                    ForEach(page.orderedLines) { line in
                        Button {
                            copy(line.text, message: "已複製")
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(line.text)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ConfidenceBadge(confidence: line.confidence)
                            }
                        }
                    }
                } header: {
                    if pages.count > 1 {
                        Text("第 \(index + 1) 頁")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var summary: some View {
        let lines = pages.flatMap(\.lines)
        let average = lines.isEmpty ? 0 : lines.reduce(0) { $0 + Double($1.confidence) } / Double(lines.count)
        let seconds = String(format: "%.2f", session.duration)
        return Text("\(pages.count) 頁 · \(lines.count) 個區塊 · 平均信心度 \(Int((average * 100).rounded()))% · 首次辨識 \(seconds) 秒")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showsBoxes.toggle()
            } label: {
                Image(systemName: showsBoxes ? "eye" : "eye.slash")
            }
            .disabled(mode != .image)
            .accessibilityLabel(showsBoxes ? "隱藏文字框" : "顯示文字框")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showsAddPages = true
                } label: {
                    Label("加入頁面…", systemImage: "doc.badge.plus")
                }
                .disabled(smart.isRunning || addingPages != nil)
                Button {
                    copy(editedText, message: "已複製全部文字")
                } label: {
                    Label("複製全部文字", systemImage: "doc.on.doc")
                }
                ShareLink(item: editedText) {
                    Label("分享文字", systemImage: "square.and.arrow.up")
                }
                Button {
                    save()
                    toast = "已儲存到紀錄"
                } label: {
                    Label(savedRecord == nil ? "儲存到紀錄" : "更新紀錄", systemImage: "tray.and.arrow.down")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Actions

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        pages = session.pages
        editedText = session.fullText
        uploadState = ServerSettings.isConfigured ? .idle : .notConfigured
        if autoSave, !session.allLines.isEmpty {
            save()
        }
        if session.allLines.isEmpty {
            mode = .image
        } else {
            Task { await runSmartScan(forcedTemplate: nil) }
        }
    }

    private func runSmartScan(forcedTemplate: ScanTemplate?) async {
        guard let outcome = await smart.run(
            text: editedText,
            templates: library.all,
            forcedTemplate: forcedTemplate,
            useJev: useJev
        ) else { return }

        guard let savedRecord else { return }
        savedRecord.apply(outcome)
        savedRecord.text = editedText
        try? modelContext.save()
        if autoUpload, ServerSettings.isConfigured {
            await upload()
        }
    }

    private func upload() async {
        if savedRecord == nil { save() }
        guard let savedRecord else { return }
        uploadState = .uploading
        do {
            try await ScanUploader.upload(savedRecord)
            try? modelContext.save()
            uploadState = .uploaded(Date())
        } catch {
            uploadState = .failed(error.localizedDescription)
        }
    }

    /// 辨識新加入的頁面，合併到這份文件後重新判斷情境並產生 JSON。
    private func addPages(_ images: [UIImage]) async {
        guard !images.isEmpty else { return }
        let service = OCRService()
        var added: [OCRPage] = []
        for (index, image) in images.enumerated() {
            addingPages = (index + 1, images.count)
            if let page = try? await service.recognize(image) {
                added.append(page)
            }
        }
        addingPages = nil
        guard !added.isEmpty else {
            toast = "無法辨識新加入的頁面"
            return
        }
        pages.append(contentsOf: added)
        let newText = added.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !newText.isEmpty {
            editedText = editedText.isEmpty ? newText : editedText + "\n\n" + newText
        }
        toast = "已加入 \(added.count) 頁，共 \(pages.count) 頁，重新分析中"
        save()
        mode = .json
        await runSmartScan(forcedTemplate: nil)
    }

    private func copy(_ text: String, message: String) {
        UIPasteboard.general.string = text
        toast = message
        feedbackTrigger += 1
    }

    private func save() {
        let record: ScanRecord
        if let savedRecord {
            record = savedRecord
            record.text = editedText
        } else {
            record = ScanRecord.make(from: session, text: editedText)
            modelContext.insert(record)
            savedRecord = record
        }
        record.pageCount = pages.count
        record.lineCount = pages.reduce(0) { $0 + $1.lines.count }
        record.syncedAt = nil
        if let outcome = smart.outcome { record.apply(outcome) }
        try? modelContext.save()
    }
}
