import PhotosUI
import SwiftUI

struct ScanView: View {
    private enum Capture: String, Identifiable {
        case camera
        case documentScanner

        var id: String { rawValue }
    }

    @State private var model = ScanViewModel()
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var capture: Capture?
    @AppStorage(OCRSettings.Key.languages) private var languagesRaw = OCRSettings.encode(OCRSettings.defaultLanguages)
    @AppStorage(OCRSettings.Key.recognitionLevel) private var levelRaw = RecognitionLevel.accurate.rawValue

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    sourceGrid
                    status
                }
                .padding()
            }
            .navigationTitle("文字辨識")
            .navigationDestination(item: $model.session) { session in
                ResultView(session: session)
            }
        }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("裝置端辨識", systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(.tint)
            Text("使用 Apple Vision 框架直接在裝置上辨識文字，不需要網路，圖片也不會上傳。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("目前設定：\(levelName)模式 · \(languageSummary)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var sourceGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: 10,
                selectionBehavior: .ordered,
                matching: .images
            ) {
                SourceCard(title: "從相簿選取", subtitle: "一次最多 10 張", systemImage: ScanSource.photoLibrary.systemImage)
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
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        }
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

    // MARK: - Helpers

    private var levelName: String {
        (RecognitionLevel(rawValue: levelRaw) ?? .accurate).displayName
    }

    private var languageSummary: String {
        let languages = OCRSettings.decode(languagesRaw)
        guard !languages.isEmpty else { return "系統預設語言" }
        return languages.map(OCRSettings.displayName(for:)).joined(separator: "、")
    }

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
        VStack(alignment: .leading, spacing: 10) {
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
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .opacity(isEnabled ? 1 : 0.45)
    }
}

#Preview {
    ScanView()
        .modelContainer(for: ScanRecord.self, inMemory: true)
}
