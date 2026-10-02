import SwiftData
import SwiftUI

struct HistoryDetailView: View {
    @Bindable var record: ScanRecord

    @Environment(\.modelContext) private var modelContext
    @Environment(TemplateLibrary.self) private var library
    @State private var toast: String?
    @State private var feedbackTrigger = 0
    @State private var isUploading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let json = record.jsonText {
                    jsonCard(json)
                }
                textCard
                syncCard
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: record.jsonText ?? record.text)
            }
        }
        .toast($toast)
        .sensoryFeedback(.success, trigger: feedbackTrigger)
        .onChange(of: record.text) { _, _ in
            record.syncedAt = nil
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let image = record.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(library.template(id: record.templateID)?.name ?? "未分類")
                    .font(.title3.weight(.semibold))
                Text("\(record.sourceDisplayName) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let confidence = record.classificationConfidence {
                ConfidenceGauge(value: confidence, size: 56)
            }
        }
        .card()
    }

    private func jsonCard(_ json: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "JSON", systemImage: "curlybraces")
            JSONBlock(json: json)
            Button {
                copy(json, message: "已複製 JSON")
            } label: {
                Label("複製 JSON", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .font(.subheadline.weight(.medium))
        }
        .card()
    }

    private var textCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "辨識文字", systemImage: "text.alignleft", trailing: "\(record.lineCount) 個區塊")
            TextEditor(text: $record.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 180)
                .padding(8)
                .background(Theme.screenBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button {
                copy(record.text, message: "已複製文字")
            } label: {
                Label("複製文字", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .font(.subheadline.weight(.medium))
        }
        .card()
    }

    private var syncCard: some View {
        HStack(spacing: 12) {
            if let syncedAt = record.syncedAt {
                Label("已上傳 \(syncedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.icloud")
                    .foregroundStyle(.green)
            } else if ServerSettings.isConfigured {
                Label("尚未上傳最新內容", systemImage: "icloud")
                    .foregroundStyle(.secondary)
            } else {
                Label("在設定中連接伺服器即可同步到 Obsidian 與 harness", systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if ServerSettings.isConfigured {
                if isUploading {
                    ProgressView()
                } else {
                    Button("上傳") { Task { await upload() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .font(.subheadline)
        .card()
    }

    private func copy(_ text: String, message: String) {
        UIPasteboard.general.string = text
        toast = message
        feedbackTrigger += 1
    }

    private func upload() async {
        isUploading = true
        defer { isUploading = false }
        do {
            try await ScanUploader.upload(record)
            try? modelContext.save()
            toast = "已上傳"
        } catch {
            toast = error.localizedDescription
        }
    }
}
