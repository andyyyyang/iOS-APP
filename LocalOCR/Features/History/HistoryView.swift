import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScanRecord.createdAt, order: .reverse) private var records: [ScanRecord]
    @State private var searchText = ""
    @State private var confirmsDeleteAll = false

    private var filteredRecords: [ScanRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("辨識紀錄")
                .navigationDestination(for: ScanRecord.self) { record in
                    HistoryDetailView(record: record)
                }
                .searchable(text: $searchText, prompt: "搜尋文字內容")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("全部刪除", role: .destructive) {
                            confirmsDeleteAll = true
                        }
                        .disabled(records.isEmpty)
                    }
                }
                .confirmationDialog("確定要刪除全部紀錄嗎？", isPresented: $confirmsDeleteAll, titleVisibility: .visible) {
                    Button("全部刪除", role: .destructive, action: deleteAll)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if records.isEmpty {
            ContentUnavailableView(
                "尚無紀錄",
                systemImage: "clock",
                description: Text("辨識完成的文字會自動儲存在這裡，可於設定中關閉。")
            )
        } else if filteredRecords.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                ForEach(filteredRecords) { record in
                    NavigationLink(value: record) {
                        HistoryRow(record: record)
                    }
                }
                .onDelete(perform: delete)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let items = filteredRecords
        for index in offsets {
            modelContext.delete(items[index])
        }
        try? modelContext.save()
    }

    private func deleteAll() {
        for record in records {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }
}

private struct HistoryRow: View {
    let record: ScanRecord

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(record.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Label(record.sourceDisplayName, systemImage: record.sourceSystemImage)
                    Text("·")
                    Text(record.createdAt, format: .dateTime.month().day().hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = record.thumbnail {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: record.sourceSystemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemBackground))
        }
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: ScanRecord.self, inMemory: true)
}
