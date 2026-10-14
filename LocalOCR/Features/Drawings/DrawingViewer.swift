import PDFKit
import QuickLook
import SwiftUI
import UIKit

/// 圖面檢視：PDF 與圖片都用 PDFKit 顯示（縮放、平移、旋轉、多頁），版本之間可以切換。
/// 圖面打開時才從 vault 取得，暫存在快取資料夾。
@MainActor
@Observable
final class DrawingCanvasState {
    enum Content: Equatable {
        case idle
        case loading
        case document(URL)
        case failed(title: String, detail: String, hint: String)
        case cadOnly(path: String)
    }

    private(set) var content: Content = .idle
    private(set) var document: PDFDocument?
    private(set) var pageIndex = 0
    private(set) var pageCount = 0
    /// 相對於「適應」的比例（100% = 適應畫面）
    private(set) var zoomPercent: Int?
    private(set) var rotation = 0
    /// 目前這一版的檔案（分享、原生檢視用）
    private(set) var fileURL: URL?
    private(set) var isImage = false

    @ObservationIgnored weak var view: PDFView?
    @ObservationIgnored private var originalRotations: [Int] = []
    @ObservationIgnored private var loadToken = UUID()

    func load(_ drawing: DrawingRef?) async {
        let token = UUID()
        loadToken = token
        document = nil
        fileURL = nil
        pageIndex = 0
        pageCount = 0
        rotation = 0
        zoomPercent = nil
        guard let drawing else {
            content = .idle
            return
        }
        let path = drawing.pdf.isEmpty ? drawing.png : drawing.pdf
        guard !path.isEmpty else {
            content = .cadOnly(path: drawing.cad)
            return
        }
        content = .loading
        do {
            let url = try await DrawingFileCache.shared.url(for: path)
            guard token == loadToken else { return }
            let document: PDFDocument
            if drawing.pdf.isEmpty {
                guard let image = UIImage(contentsOfFile: url.path(percentEncoded: false)), let page = PDFPage(image: image) else {
                    content = .failed(title: "圖片載入失敗", detail: DrawingPaths.baseName(path), hint: "檔案可能已被移走或損毀")
                    return
                }
                document = PDFDocument()
                document.insert(page, at: 0)
                isImage = true
            } else {
                let header = (try? FileHandle(forReadingFrom: url).read(upToCount: 4)) ?? Data()
                guard header == Data("%PDF".utf8) else {
                    content = .failed(title: "PDF 讀取失敗", detail: DrawingPaths.baseName(path), hint: "這個檔不是 PDF（開頭不是 %PDF），可能是 CAD 檔改了副檔名")
                    return
                }
                guard let loaded = PDFDocument(url: url) else {
                    content = .failed(title: "PDF 讀取失敗", detail: DrawingPaths.baseName(path), hint: "檔案可能已損毀")
                    return
                }
                document = loaded
                isImage = false
            }
            self.document = document
            originalRotations = (0..<document.pageCount).map { document.page(at: $0)?.rotation ?? 0 }
            pageCount = document.pageCount
            fileURL = url
            content = .document(url)
        } catch {
            guard token == loadToken else { return }
            content = .failed(title: drawing.pdf.isEmpty ? "圖片載入失敗" : "PDF 讀取失敗", detail: DrawingPaths.baseName(path), hint: error.localizedDescription)
        }
    }

    // MARK: 操作

    func fit() {
        guard let view else { return }
        view.autoScales = true
        view.scaleFactor = view.scaleFactorForSizeToFit
        updateZoom()
    }

    /// 1:1：PDF 以 150dpi 的實際大小顯示，圖片以原始像素顯示。
    func actualSize() {
        guard let view else { return }
        view.autoScales = false
        view.scaleFactor = min(max(isImage ? 1 : 150.0 / 72.0, view.minScaleFactor), view.maxScaleFactor)
        updateZoom()
    }

    func toggleFit() {
        if let zoomPercent, abs(zoomPercent - 100) <= 2 { actualSize() } else { fit() }
    }

    func rotate() {
        guard let document else { return }
        rotation = (rotation + 90) % 360
        for index in 0..<document.pageCount {
            document.page(at: index)?.rotation = ((originalRotations[safe: index] ?? 0) + rotation) % 360
        }
        view?.layoutDocumentView()
        fit()
    }

    func go(to index: Int) {
        guard let document, let view, document.pageCount > 0 else { return }
        let target = (index + document.pageCount) % document.pageCount
        if let page = document.page(at: target) { view.go(to: page) }
        fit()
    }

    func nextPage() { go(to: pageIndex + 1) }
    func previousPage() { go(to: pageIndex - 1) }

    func updateZoom() {
        guard let view, view.document != nil else {
            zoomPercent = nil
            return
        }
        let fit = view.scaleFactorForSizeToFit
        zoomPercent = fit > 0 ? Int((view.scaleFactor / fit * 100).rounded()) : nil
    }

    func updatePage() {
        guard let view, let document = view.document, let page = view.currentPage else { return }
        pageIndex = document.index(for: page)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// PDFView：縮放限制為適應大小的 0.15～12 倍，雙擊切換「適應／1:1」。
final class DrawingPDFView: PDFView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        let fit = scaleFactorForSizeToFit
        if fit > 0 {
            minScaleFactor = fit * 0.15
            maxScaleFactor = fit * 12
        }
        onLayout?()
    }
}

struct DrawingPDFCanvas: UIViewRepresentable {
    let state: DrawingCanvasState

    func makeUIView(context: Context) -> DrawingPDFView {
        let view = DrawingPDFView()
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.autoScales = true
        view.pageShadowsEnabled = false
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        view.onLayout = { [weak state] in state?.updateZoom() }
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        context.coordinator.observe(view)
        state.view = view
        return view
    }

    func updateUIView(_ view: DrawingPDFView, context: Context) {
        if view.document !== state.document {
            view.document = state.document
            state.view = view
            DispatchQueue.main.async { state.fit() }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    @MainActor
    final class Coordinator: NSObject {
        let state: DrawingCanvasState
        private var tokens: [NSObjectProtocol] = []

        init(state: DrawingCanvasState) {
            self.state = state
        }

        func observe(_ view: PDFView) {
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.state.updateZoom() }
            })
            tokens.append(center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.state.updatePage() }
            })
        }

        @objc func doubleTapped() {
            state.toggleFit()
        }
    }
}

/// 圖面檢視器：上方是版本與頁碼，右上是縮放、旋轉、規格與原生檢視。
struct DrawingViewer: View {
    let model: DrawingModel?
    var onShowSpec: (DrawingModel) -> Void

    @State private var state = DrawingCanvasState()
    @State private var versionIndex = 0
    @State private var previewURL: URL?
    @State private var sharing: URL?
    @State private var isPreparingShare = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var drawings: [DrawingRef] { model?.drawings ?? [] }
    private var current: DrawingRef? { drawings.indices.contains(versionIndex) ? drawings[versionIndex] : nil }
    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.13, green: 0.13, blue: 0.13)
            canvas
            toolbars
        }
        .clipped()
        .task(id: loadKey) {
            await state.load(current)
        }
        .onChange(of: model?.id) {
            versionIndex = 0
        }
        .quickLookPreview($previewURL)
        .sheet(item: Binding(get: { sharing.map(ShareItem.init) }, set: { sharing = $0?.url })) { item in
            ShareSheet(items: [item.url])
        }
    }

    private var loadKey: String { "\(model?.id ?? "")#\(versionIndex)#\(current?.id ?? "")" }

    @ViewBuilder
    private var canvas: some View {
        switch state.content {
        case .idle:
            placeholder(title: model == nil ? "沒有選取機種" : model!.dwg, detail: model == nil ? "" : "找不到圖面檔案", hint: "")
        case .loading:
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .document:
            DrawingPDFCanvas(state: state)
        case .failed(let title, let detail, let hint):
            placeholder(title: title, detail: detail, hint: hint)
        case .cadOnly(let path):
            VStack(spacing: 10) {
                placeholder(title: "這一版是 CAD 原始檔", detail: DrawingPaths.baseName(path), hint: "沒有可預覽的格式")
                    .frame(maxHeight: 140)
                Button {
                    Task { await share(path) }
                } label: {
                    Label(isPreparingShare ? "準備中…" : "分享 CAD 檔", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPreparingShare)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(title: String, detail: String, hint: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            if !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            if !hint.isEmpty {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 工具列

    private var toolbars: some View {
        HStack(alignment: .top, spacing: 8) {
            if model != nil {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        versionControls
                        if state.pageCount >= 2 {
                            pageControls
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: !isCompact, vertical: true)
                .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .environment(\.colorScheme, .dark)
            }
            Spacer(minLength: 0)
            if model != nil {
                viewControls
                    .padding(6)
                    .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .environment(\.colorScheme, .dark)
            }
        }
        .padding(10)
    }

    private var versionControls: some View {
        HStack(spacing: 4) {
            toolButton("chevron.left", label: "上一版") { step(-1) }
                .disabled(drawings.count < 2)
            Menu {
                ForEach(Array(drawings.enumerated()), id: \.offset) { index, drawing in
                    Button {
                        versionIndex = index
                    } label: {
                        Text("\(index + 1)/\(drawings.count) \(drawing.isViewable ? "" : "［CAD］")\(drawing.displayLabel)")
                    }
                }
            } label: {
                Text(drawings.isEmpty ? "此機種尚無圖面檔" : "\(versionIndex + 1)/\(drawings.count) \(current.map { ($0.isViewable ? "" : "［CAD］") + $0.displayLabel } ?? "")")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: isCompact ? 150 : 260)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .disabled(drawings.isEmpty)
            toolButton("chevron.right", label: "下一版") { step(1) }
                .disabled(drawings.count < 2)
        }
    }

    private var pageControls: some View {
        HStack(spacing: 4) {
            toolButton("chevron.up", label: "上一頁") { state.previousPage() }
            Text("\(state.pageIndex + 1)/\(state.pageCount)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white)
            toolButton("chevron.down", label: "下一頁") { state.nextPage() }
        }
        .padding(.leading, 6)
    }

    private var viewControls: some View {
        HStack(spacing: 4) {
            if !isCompact {
                Text(state.zoomPercent.map { "\($0)%" } ?? "—")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(minWidth: 44)
            }
            Menu {
                Button { state.fit() } label: { Label("適應畫面", systemImage: "arrow.down.right.and.arrow.up.left") }
                Button { state.actualSize() } label: { Label("1:1（150dpi 實際大小）", systemImage: "1.magnifyingglass") }
                Button { state.rotate() } label: { Label("旋轉 90°", systemImage: "rotate.right") }
                Divider()
                Button { previewURL = state.fileURL } label: { Label("原生檢視", systemImage: "doc.viewfinder") }
                    .disabled(state.fileURL == nil)
                Button { sharing = state.fileURL } label: { Label("分享這一版", systemImage: "square.and.arrow.up") }
                    .disabled(state.fileURL == nil)
            } label: {
                toolIcon("ellipsis.circle")
            }
            if !isCompact {
                toolButton("arrow.down.right.and.arrow.up.left", label: "適應") { state.fit() }
                toolButton("rotate.right", label: "旋轉 90°") { state.rotate() }
            }
            if let model {
                Button { onShowSpec(model) } label: {
                    Text("規格筆記")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
    }

    private func toolButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolIcon(systemImage) }
            .accessibilityLabel(label)
    }

    private func toolIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }

    private func step(_ delta: Int) {
        guard !drawings.isEmpty else { return }
        versionIndex = (versionIndex + delta + drawings.count) % drawings.count
    }

    private func share(_ path: String) async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        sharing = try? await DrawingFileCache.shared.url(for: path)
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 系統分享表單。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
