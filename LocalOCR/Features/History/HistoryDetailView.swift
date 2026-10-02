import SwiftData
import SwiftUI

struct HistoryDetailView: View {
    @Bindable var record: ScanRecord

    @State private var toast: String?
    @State private var feedbackTrigger = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = record.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            metadata

            TextEditor(text: $record.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding()
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = record.text
                    toast = "已複製全部文字"
                    feedbackTrigger += 1
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("複製")
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: record.text)
            }
        }
        .toast($toast)
        .sensoryFeedback(.success, trigger: feedbackTrigger)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Label(record.sourceDisplayName, systemImage: record.sourceSystemImage)
            Text("·")
            Text(record.createdAt, format: .dateTime.year().month().day().hour().minute())
            if let confidence = record.averageConfidence {
                Text("·")
                Text("信心度 \(Int((confidence * 100).rounded()))%")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
