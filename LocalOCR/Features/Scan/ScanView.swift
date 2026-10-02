import PhotosUI
import SwiftData
import SwiftUI

struct ScanView: View {
    private enum Capture: String, Identifiable {
        case camera
        case documentScanner

        var id: String { rawValue }
    }

    @Binding var selectedTab: AppTab

    @Environment(TemplateLibrary.self) private var library
    @Query(sort: \ScanRecord.createdAt, order: .reverse) private var records: [ScanRecord]
    @State private var model = ScanViewModel()
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var capture: Capture?
    @State private var aiStatus = OnDeviceAIStatus.current
    @State private var showsTools = false
    @State private var pendingTool: ToolMenuView.Tool?
    @State private var showsPhotoPicker = false
    @State private var showsTemplates = false
    @State private var showsServer = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    BannerRow(systemImage: "sparkles", title: bannerTitle, subtitle: bannerSubtitle)
                    ShelfHeader(title: "智慧掃描", detail: "\(records.count) 份紀錄")
                    sourceGrid
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
            .photosPicker(
                isPresented: $showsPhotoPicker,
                selection: $photoItems,
                maxSelectionCount: 10,
                selectionBehavior: .ordered,
                matching: .images
            )
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
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .fullScreenCover(item: $capture) { kind in
            captureView(for: kind)
                .ignoresSafeArea()
        }
    }

    // MARK: - Sections

    private var bannerTitle: String {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        let count = records.filter { $0.createdAt >= weekAgo }.count
        return count > 0 ? "本週已辨識 \(count) 份文件" : "拍一張照片，自動整理成 JSON"
    }

    private var bannerSubtitle: String {
        switch aiStatus {
        case .available: return "Apple Intelligence 在裝置上判斷情境與擷取資料"
        case .unavailable(let reason): return "文字辨識在裝置上完成 · \(reason)"
        }
    }

    private var sourceGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: 10,
                selectionBehavior: .ordered,
                matching: .images
            ) {
                SourceCard(title: "相簿", subtitle: "一次最多 10 張", systemImage: ScanSource.photoLibrary.systemImage)
            }

            Button {
                capture = .camera
            } label: {
                SourceCard(
                    title: "拍照",
                    subtitle: CameraPicker.isAvailable ? "使用相機拍攝" : "此裝置無法使用",
                    systemImage: ScanSource.camera.systemImage
                )
            }
            .disabled(!CameraPicker.isAvailable)

            Button {
                capture = .documentScanner
            } label: {
                SourceCard(
                    title: "掃描文件",
                    subtitle: DocumentScannerView.isSupported ? "自動裁切、可多頁" : "此裝置無法使用",
                    systemImage: ScanSource.documentScanner.systemImage
                )
            }
            .disabled(!DocumentScannerView.isSupported)

            Button(action: pasteImage) {
                SourceCard(title: "貼上圖片", subtitle: "從剪貼簿", systemImage: ScanSource.pasteboard.systemImage)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isProcessing)
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
                    Text("正在辨識第 \(current)／\(total) 張…")
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

    @ViewBuilder
    private func captureView(for kind: Capture) -> some View {
        switch kind {
        case .camera:
            CameraPicker { image in
                capture = nil
                guard let image else { return }
                Task { await model.process([image], source: .camera) }
            }
        case .documentScanner:
            DocumentScannerView { images in
                capture = nil
                guard !images.isEmpty else { return }
                Task { await model.process(images, source: .documentScanner) }
            }
        }
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
        case .photos: showsPhotoPicker = true
        case .camera: capture = .camera
        case .document: capture = .documentScanner
        case .paste: pasteImage()
        case .live: selectedTab = .live
        case .history: selectedTab = .history
        case .templates: showsTemplates = true
        case .server: showsServer = true
        case .settings: selectedTab = .settings
        }
    }

    // MARK: - Helpers

    @MainActor
    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        photoItems = []
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                images.append(image)
            }
        }
        guard !images.isEmpty else {
            model.fail("無法載入所選的照片。")
            return
        }
        await model.process(images, source: .photoLibrary)
    }

    private func pasteImage() {
        let images = UIPasteboard.general.images ?? []
        guard !images.isEmpty else {
            model.fail("剪貼簿中沒有圖片。")
            return
        }
        Task { await model.process(images, source: .pasteboard) }
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
        .modelContainer(for: ScanRecord.self, inMemory: true)
}
