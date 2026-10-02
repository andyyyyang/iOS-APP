import SwiftData
import SwiftUI

struct ResultView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case image = "圖片"
        case text = "文字"
        case lines = "逐行"

        var id: Self { self }
    }

    let session: ScanSession

    @Environment(\.modelContext) private var modelContext
    @AppStorage(OCRSettings.Key.autoSaveHistory) private var autoSave = true
    @State private var mode: Mode = .image
    @State private var editedText = ""
    @State private var showsBoxes = true
    @State private var savedRecord: ScanRecord?
    @State private var toast: String?
    @State private var feedbackTrigger = 0
    @State private var didLoad = false

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
            case .image: imagePages
            case .text: textEditor
            case .lines: lineList
            }
        }
        .navigationTitle("辨識結果")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .toast($toast)
        .sensoryFeedback(.success, trigger: feedbackTrigger)
        .onAppear(perform: loadIfNeeded)
    }

    // MARK: - Modes

    private var imagePages: some View {
        TabView {
            ForEach(session.pages) { page in
                AnnotatedImageView(page: page, showsBoxes: showsBoxes) { line in
                    copy(line.text, message: "已複製：\(line.text)")
                }
                .padding([.horizontal, .bottom])
            }
        }
        .tabViewStyle(.page(indexDisplayMode: session.pages.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .overlay(alignment: .top) {
            if session.allLines.isEmpty {
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
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding([.horizontal, .bottom])
    }

    private var lineList: some View {
        List {
            ForEach(Array(session.pages.enumerated()), id: \.element.id) { index, page in
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
                    if session.pages.count > 1 {
                        Text("第 \(index + 1) 頁")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var summary: some View {
        let confidence = Int((session.averageConfidence * 100).rounded())
        let seconds = String(format: "%.2f", session.duration)
        return Text("\(session.pages.count) 頁 · \(session.allLines.count) 個區塊 · 平均信心度 \(confidence)% · 耗時 \(seconds) 秒")
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
        editedText = session.fullText
        if autoSave, !session.allLines.isEmpty {
            save()
        }
    }

    private func copy(_ text: String, message: String) {
        UIPasteboard.general.string = text
        toast = message
        feedbackTrigger += 1
    }

    private func save() {
        if let savedRecord {
            savedRecord.text = editedText
        } else {
            let record = ScanRecord.make(from: session, text: editedText)
            modelContext.insert(record)
            savedRecord = record
        }
        try? modelContext.save()
    }
}
