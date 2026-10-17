import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(TemplateLibrary.self) private var library
    @Query(sort: \ScanRecord.createdAt, order: .reverse) private var records: [ScanRecord]
    @State private var searchText = ""
    @State private var confirmsDeleteAll = false
    @State private var selection: ScanRecord?

    private var filteredRecords: [ScanRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.text.localizedCaseInsensitiveContains(query)
                || ($0.jsonText?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        // iPad 左邊列表、右邊內容；iPhone 自動變成一層層進入
        NavigationSplitView {
            content
                .canvasList()
                .navigationTitle("紀錄")
                .searchable(text: $searchText, prompt: "搜尋")
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
                .task { fillMissingDisplayNames() }
        } detail: {
            NavigationStack {
                if let selection {
                    HistoryDetailView(record: selection)
                        .id(selection.persistentModelID)
                } else {
                    EmptyStateView(title: "選擇一筆紀錄")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DS.sidebar)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if records.isEmpty {
            ContentUnavailableView("尚無紀錄", systemImage: "clock")
        } else if filteredRecords.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List(selection: $selection) {
                ForEach(filteredRecords) { record in
                    HistoryRow(record: record)
                        .tag(record)
                }
                .onDelete(perform: delete)
            }
            .listStyle(.insetGrouped)
        }
    }

    private func delete(at offsets: IndexSet) {
        let items = filteredRecords
        for index in offsets {
            if items[index] == selection { selection = nil }
            PageImageStore.remove(for: items[index].pagesID)
            modelContext.delete(items[index])
        }
        try? modelContext.save()
    }

    /// 舊紀錄（在樣板加入名稱規則之前分析的）補上名稱與副標。
    private func fillMissingDisplayNames() {
        var changed = false
        for record in records where record.displayTitle == nil && record.displaySubtitle == nil {
            guard let data = record.dataValue, let template = library.template(id: record.templateID) else { continue }
            let display = TemplateRules.display(rules: template.rules, data: data)
            guard display.title != nil || display.subtitle != nil else { continue }
            record.displayTitle = display.title
            record.displaySubtitle = display.subtitle
            changed = true
        }
        if changed { try? modelContext.save() }
    }

    private func deleteAll() {
        selection = nil
        for record in records {
            PageImageStore.remove(for: record.pagesID)
            modelContext.delete(record)
        }
        try? modelContext.save()
    }
}

struct HistoryRow: View {
    let record: ScanRecord

    @Environment(TemplateLibrary.self) private var library

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(record.displaySubtitle ?? record.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let name = library.template(id: record.templateID)?.name {
                        Text(name)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    Text(record.createdAt, format: .dateTime.month().day().hour().minute())
                    if record.syncedAt != nil {
                        Image(systemName: "checkmark.icloud")
                            .accessibilityLabel("已上傳")
                    }
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
                .background(Theme.screenBackground)
        }
    }
}

#Preview {
    HistoryView()
        .environment(TemplateLibrary.shared)
        .modelContainer(for: ScanRecord.self, inMemory: true)
}
