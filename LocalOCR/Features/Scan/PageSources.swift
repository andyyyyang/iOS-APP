import PhotosUI
import SwiftUI

/// 加入頁面的來源。
enum PageSource: String, Identifiable, CaseIterable {
    case documentScanner
    case camera
    case photoLibrary
    case pasteboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .documentScanner: return "掃描文件"
        case .camera: return "拍照"
        case .photoLibrary: return "相簿"
        case .pasteboard: return "貼上圖片"
        }
    }

    var systemImage: String { scanSource.systemImage }

    var scanSource: ScanSource {
        switch self {
        case .documentScanner: return .documentScanner
        case .camera: return .camera
        case .photoLibrary: return .photoLibrary
        case .pasteboard: return .pasteboard
        }
    }

    var isAvailable: Bool {
        switch self {
        case .documentScanner: return DocumentScannerView.isSupported
        case .camera: return CameraController.isAvailable
        case .photoLibrary, .pasteboard: return true
        }
    }
}

/// 呈現各種頁面來源並回傳取得的圖片。把 `request` 設為某個來源即開啟它。
private struct PageSourcesModifier: ViewModifier {
    @Binding var request: PageSource?
    var onPick: ([UIImage], ScanSource) -> Void
    var onError: (String) -> Void

    @State private var showsPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var capture: PageSource?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, source in
                guard let source else { return }
                request = nil
                switch source {
                case .photoLibrary: showsPhotos = true
                case .camera, .documentScanner: capture = source
                case .pasteboard: paste()
                }
            }
            .photosPicker(
                isPresented: $showsPhotos,
                selection: $photoItems,
                maxSelectionCount: 50,
                selectionBehavior: .ordered,
                matching: .images
            )
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await loadPhotos(items) }
            }
            .fullScreenCover(item: $capture) { kind in
                captureView(for: kind)
                    .ignoresSafeArea()
            }
    }

    @ViewBuilder
    private func captureView(for kind: PageSource) -> some View {
        switch kind {
        case .documentScanner:
            DocumentScannerView { images in
                capture = nil
                if !images.isEmpty { onPick(images, .documentScanner) }
            }
        default:
            // 可以連續拍多頁，按「完成」一次加入
            MultiShotCameraView { images in
                capture = nil
                if !images.isEmpty { onPick(images, .camera) }
            }
        }
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
        if images.isEmpty {
            onError("無法載入所選的照片。")
        } else {
            onPick(images, .photoLibrary)
        }
    }

    private func paste() {
        let images = UIPasteboard.general.images ?? []
        if images.isEmpty {
            onError("剪貼簿中沒有圖片。")
        } else {
            onPick(images, .pasteboard)
        }
    }
}

extension View {
    func pageSources(
        request: Binding<PageSource?>,
        onPick: @escaping ([UIImage], ScanSource) -> Void,
        onError: @escaping (String) -> Void
    ) -> some View {
        modifier(PageSourcesModifier(request: request, onPick: onPick, onError: onError))
    }

    /// 「加入頁面」：先選來源再開啟。
    func addPagesDialog(isPresented: Binding<Bool>, request: Binding<PageSource?>) -> some View {
        confirmationDialog("加入頁面", isPresented: isPresented, titleVisibility: .visible) {
            ForEach(PageSource.allCases.filter(\.isAvailable)) { source in
                Button(source.title) { request.wrappedValue = source }
            }
        } message: {
            Text("加入的頁面會與原有頁面合併，重新判斷情境並產生 JSON。")
        }
    }
}
