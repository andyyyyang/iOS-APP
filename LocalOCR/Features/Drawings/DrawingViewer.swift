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
                    content = .failed(title: "PDF 讀取失敗", detail: DrawingPaths.baseName(path), hint: "不是 PDF 檔")
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
        view.pageShadowsEnabled = true
        view.backgroundColor = UIColor(DS.sidebar)
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

/// 圖面檢視器：圖面放在淺灰底上（像紙張），下方是黑色浮動工具列（同首頁與資料夾的工具列）：
/// 版本、頁碼、適應、旋轉、規格筆記與更多（1:1、原生檢視、分享）。
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
        ZStack(alignment: .bottom) {
            DS.sidebar
            canvas
            if model != nil {
                palette
                    .padding(.bottom, isCompact ? 12 : 18)
                    .padding(.horizontal, 12)
            }
        }
        .overlay(alignment: .topTrailing) {
            if case .document = state.content, let zoom = state.zoomPercent {
                Text("\(zoom)%")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(DS.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DS.card.opacity(0.9), in: Capsule())
                    .padding(12)
                    .allowsHitTesting(false)
            }
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
            EmptyStateView(title: model == nil ? "沒有選取機種" : "\(model!.dwg) 找不到圖面檔案")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("正在取得圖面…")
                    .font(.footnote)
                    .foregroundStyle(DS.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .document:
            DrawingPDFCanvas(state: state)
        case .failed(let title, let detail, let hint):
            EmptyStateView(title: title, message: [detail, hint].filter { !$0.isEmpty }.joined(separator: "\n"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .cadOnly(let path):
            VStack(spacing: 14) {
                EmptyStateView(title: "這一版是 CAD 原始檔", message: DrawingPaths.baseName(path))
                Button {
                    Task { await share(path) }
                } label: {
                    Label(isPreparingShare ? "準備中…" : "分享 CAD 檔", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                .disabled(isPreparingShare)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 工具列

    private var palette: some View {
        FloatingPalette {
            PaletteButton(title: "上一版", systemImage: "chevron.left", size: 36) { step(-1) }
                .disabled(drawings.count < 2)
                .opacity(drawings.count < 2 ? 0.4 : 1)
            versionMenu
            PaletteButton(title: "下一版", systemImage: "chevron.right", size: 36) { step(1) }
                .disabled(drawings.count < 2)
                .opacity(drawings.count < 2 ? 0.4 : 1)
            if state.pageCount >= 2 {
                divider
                PaletteButton(title: "上一頁", systemImage: "chevron.up", size: 36) { state.previousPage() }
                Text("\(state.pageIndex + 1)/\(state.pageCount)")
                    .font(.footnote.monospacedDigit().weight(.medium))
                    .foregroundStyle(DS.onInk)
                PaletteButton(title: "下一頁", systemImage: "chevron.down", size: 36) { state.nextPage() }
            }
            divider
            if !isCompact {
                PaletteButton(title: "適應畫面", systemImage: "arrow.down.right.and.arrow.up.left", size: 36) { state.fit() }
                PaletteButton(title: "旋轉 90°", systemImage: "rotate.right", size: 36) { state.rotate() }
            }
            if let model {
                PaletteButton(title: "規格筆記", systemImage: "info", pastel: .lavender, size: 36) { onShowSpec(model) }
            }
            moreMenu
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.onInkDim.opacity(0.4))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 2)
    }

    private var versionMenu: some View {
        Menu {
            ForEach(Array(drawings.enumerated()), id: \.offset) { index, drawing in
                Button {
                    versionIndex = index
                } label: {
                    if index == versionIndex {
                        Label("\(index + 1). \(drawing.isViewable ? "" : "［CAD］")\(drawing.displayLabel)", systemImage: "checkmark")
                    } else {
                        Text("\(index + 1). \(drawing.isViewable ? "" : "［CAD］")\(drawing.displayLabel)")
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(drawings.isEmpty ? "沒有圖面" : (current.map { ($0.isViewable ? "" : "［CAD］") + $0.displayLabel } ?? ""))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DS.onInk)
                    .lineLimit(1)
                if drawings.count > 1 {
                    Text("第 \(versionIndex + 1) / \(drawings.count) 版")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(DS.onInkDim)
                }
            }
            .frame(maxWidth: isCompact ? 120 : 220, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(DS.inkRaised, in: Capsule())
        }
        .disabled(drawings.isEmpty)
    }

    private var moreMenu: some View {
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
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.onInk)
                .frame(width: 36, height: 36)
                .background(DS.inkRaised, in: Circle())
        }
        .accessibilityLabel("更多")
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
