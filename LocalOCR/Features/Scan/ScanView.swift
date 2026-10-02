import SwiftData
import SwiftUI

struct ScanView: View {
    @Binding var selectedTab: AppTab

    @Environment(TemplateLibrary.self) private var library
    @Environment(ScanDraft.self) private var draft
    @Query(sort: \ScanRecord.createdAt, order: .reverse) private var records: [ScanRecord]
    @State private var model = ScanViewModel()
    @State private var sourceRequest: PageSource?
    @State private var aiStatus = OnDeviceAIStatus.current
    @State private var showsTools = false
    @State private var pendingTool: ToolMenuView.Tool?
    @State private var showsTemplates = false
    @State private var showsServer = false
    @State private var toast: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    BannerRow(systemImage: "sparkles", title: bannerTitle, subtitle: bannerSubtitle)
                    ShelfHeader(title: "智慧掃描", detail: "\(records.count) 份紀錄")
                    sourceGrid
                    if !draft.isEmpty {
                        DraftTray(draft: draft, isProcessing: model.isProcessing, onAnalyze: analyzeDraft)
                    }
                    status
                    scenarioSection
                }
                .padding()
            }
            .screenBackground()
            .overlay(alignment: .bottomTrailing) { toolsButton }
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(isPresented: $showsTools, onDismiss: runPendingTool) {
                ToolMenuView { tool in
                    pendingTool = tool
                    showsTools = false
                }
            }
            .sheet(isPresented: $showsTemplates) {
                NavigationStack { TemplateListView() }
            }
            .sheet(isPresented: $showsServer) {
                NavigationStack { ServerSettingsView() }
            }
            .navigationDestination(item: $model.session) { session in
                ResultView(session: session)
            }
            .navigationDestination(for: ScanTemplate.self) { template in
                TemplateRecordsView(template: template)
            }
        }
        .onAppear { aiStatus = OnDeviceAIStatus.current }
        .pageSources(
            request: $sourceRequest,
            onPick: { images, source in
                Task {
                    await draft.add(images, source: source)
                    toast = "已加入 \(images.count) 頁，共 \(draft.pages.count) 頁"
                }
            },
            onError: { toast = $0 }
        )
        .toast($toast)
    }

    // MARK: - Sections

    private var bannerTitle: String {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        let count = records.filter { $0.createdAt >= weekAgo }.count
        return count > 0 ? "本週已辨識 \(count) 份文件" : "把文件的每一頁加進來，自動整理成 JSON"
    }

    private var bannerSubtitle: String {
        switch aiStatus {
        case .available: return "Apple Intelligence 在裝置上判斷情境與擷取資料"
        case .unavailable(let reason): return "文字辨識在裝置上完成 · \(reason)"
        }
    }

    private var sourceGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.isEmpty ? "加入頁面：可混用各種來源，全部加入後再開始分析" : "繼續加入頁面")
                .font(.footnote)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(PageSource.allCases) { source in
                    Button {
                        sourceRequest = source
                    } label: {
                        SourceCard(
                            title: source.title,
                            subtitle: source.isAvailable ? subtitle(for: source) : "此裝置無法使用",
                            systemImage: source.systemImage
                        )
                    }
                    .disabled(!source.isAvailable)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.isProcessing)
        }
    }

    private func subtitle(for source: PageSource) -> String {
        switch source {
        case .documentScanner: return "自動裁切，連續掃多頁"
        case .camera: return "拍一頁加一頁"
        case .photoLibrary: return "可多選，一次最多 50 頁"
        case .pasteboard: return "從剪貼簿"
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case let .processing(current, total):
            HStack(spacing: 12) {
                ProgressView()
                if total > 1 {
                    Text("正在辨識第 \(current)／\(total) 頁…")
                } else {
                    Text("正在辨識…")
                }
            }
            .frame(maxWidth: .infinity)
            .card()
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .card()
        }
    }

    private var scenarioSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardHeader(title: "情境", systemImage: "square.stack.3d.up", trailing: "\(library.all.count) 種")
                .padding(.bottom, 4)
            ForEach(library.all) { template in
                NavigationLink(value: template) {
                    ShelfRow(title: template.name, detail: "\(count(for: template)) 份")
                }
                .buttonStyle(.plain)
                if template.id != library.all.last?.id {
                    Divider()
                }
            }
        }
        .card()
    }

    private func count(for template: ScanTemplate) -> Int {
        records.filter { $0.templateID == template.id }.count
    }

    private var toolsButton: some View {
        Button {
            showsTools = true
        } label: {
            Image(systemName: "circle.grid.cross")
                .font(.title2.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 60, height: 60)
                .background(Theme.cardBackground, in: Circle())
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
        .padding(20)
        .accessibilityLabel("工具選單")
        .disabled(model.isProcessing)
    }

    private func runPendingTool() {
        guard let tool = pendingTool else { return }
        pendingTool = nil
        switch tool {
        case .photos: sourceRequest = .photoLibrary
        case .camera: sourceRequest = .camera
        case .document: sourceRequest = .documentScanner
        case .paste: sourceRequest = .pasteboard
        case .live: selectedTab = .live
        case .history: selectedTab = .history
        case .templates: showsTemplates = true
        case .server: showsServer = true
        case .settings: selectedTab = .settings
        }
    }

    // MARK: - Actions

    private func analyzeDraft() {
        let pages = draft.pages.map(\.imageData)
        let source = draft.primarySource
        Task {
            await model.process(imageData: pages, source: source)
            if model.session != nil {
                draft.clear()
            }
        }
    }
}

private struct SourceCard: View {
    let title: String
    let subtitle: String
    let systemImage: String

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .card()
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// 某個情境的所有紀錄。
struct TemplateRecordsView: View {
    let template: ScanTemplate

    @Query(sort: \ScanRecord.createdAt, order: .reverse) private var records: [ScanRecord]

    private var filtered: [ScanRecord] {
        records.filter { $0.templateID == template.id }
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView(
                    "還沒有「\(template.name)」",
                    systemImage: "tray",
                    description: Text("掃描後被判斷為這個情境的文件會出現在這裡。")
                )
            } else {
                List(filtered) { record in
                    NavigationLink {
                        HistoryDetailView(record: record)
                    } label: {
                        HistoryRow(record: record)
                    }
                }
            }
        }
        .navigationTitle(template.name)
    }
}

#Preview {
    ScanView(selectedTab: .constant(.scan))
        .environment(TemplateLibrary.shared)
        .environment(ScanDraft())
        .modelContainer(for: ScanRecord.self, inMemory: true)
}
