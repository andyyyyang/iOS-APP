import PencilKit
import SwiftUI
import UIKit

/// 紙張圖樣與頁面圖片。
enum PaperRenderer {
    static let spacing: CGFloat = 36
    /// 橫線紙上方留白（寫標題的位置）。
    static let linedTopMargin: CGFloat = 108

    static func patternColor(for style: PaperStyle) -> UIColor {
        switch style {
        case .lined: return UIColor(red: 0.55, green: 0.67, blue: 0.85, alpha: 0.55)
        case .grid: return UIColor(white: 0.5, alpha: 0.25)
        case .dotted: return UIColor(white: 0.4, alpha: 0.45)
        case .blank: return .clear
        }
    }

    /// 紙張圖樣的路徑（頁面座標，原點在頁面左上角）；點陣紙的點要填滿，其他是線條。
    static func patternPath(for style: PaperStyle, size: CGSize) -> CGPath? {
        let path = CGMutablePath()
        switch style {
        case .blank:
            return nil
        case .lined:
            var y = linedTopMargin
            while y < size.height - spacing / 2 {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
        case .grid:
            var x = spacing
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y = spacing
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
        case .dotted:
            let radius: CGFloat = 1.4
            var y = spacing
            while y < size.height {
                var x = spacing
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += spacing
                }
                y += spacing
            }
        }
        return path
    }

    /// 在目前的 context 畫一頁紙（白底＋圖樣）。
    static func drawPaper(_ style: PaperStyle, in context: CGContext, size: CGSize) {
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        guard let path = patternPath(for: style, size: size) else { return }
        context.addPath(path)
        if style == .dotted {
            context.setFillColor(patternColor(for: style).cgColor)
            context.fillPath()
        } else {
            context.setStrokeColor(patternColor(for: style).cgColor)
            context.setLineWidth(1)
            context.strokePath()
        }
    }

    /// 一頁的圖片：紙張＋筆跡。筆跡一律以淺色模式算顏色，深色模式下黑色墨水才不會變成白色。
    static func pageImage(drawing: PKDrawing, page: Int, paper: PaperStyle, scale: CGFloat) -> UIImage {
        let rect = NotebookLayout.pageRect(page)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: rect, scale: scale)
        }
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            drawPaper(paper, in: context.cgContext, size: rect.size)
            ink.draw(in: CGRect(origin: .zero, size: rect.size))
        }
    }
}

/// 畫布後面的紙張：每頁一個白色圖層加上向量圖樣（CAShapeLayer 縮放時仍保持清晰）。
final class PaperUnderlayView: UIView {
    private var pageLayers: [CALayer] = []
    private var configuration: (pageCount: Int, paper: PaperStyle)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(pageCount: Int, paper: PaperStyle) {
        if let configuration, configuration.pageCount == pageCount, configuration.paper == paper { return }
        configuration = (pageCount, paper)
        pageLayers.forEach { $0.removeFromSuperlayer() }
        pageLayers = (0..<pageCount).map { index in
            let page = CALayer()
            page.frame = NotebookLayout.pageRect(index)
            page.backgroundColor = UIColor.white.cgColor
            page.cornerRadius = 4
            page.shadowColor = UIColor.black.cgColor
            page.shadowOpacity = 0.12
            page.shadowRadius = 6
            page.shadowOffset = CGSize(width: 0, height: 2)
            page.shadowPath = UIBezierPath(roundedRect: page.bounds, cornerRadius: 4).cgPath
            if let path = PaperRenderer.patternPath(for: paper, size: NotebookLayout.pageSize) {
                let pattern = CAShapeLayer()
                pattern.frame = page.bounds
                pattern.path = path
                pattern.contentsScale = max(traitCollection.displayScale, 2)
                if paper == .dotted {
                    pattern.fillColor = PaperRenderer.patternColor(for: paper).cgColor
                } else {
                    pattern.fillColor = nil
                    pattern.strokeColor = PaperRenderer.patternColor(for: paper).cgColor
                    pattern.lineWidth = 1
                }
                page.addSublayer(pattern)
            }
            layer.addSublayer(page)
            return page
        }
        bounds = CGRect(x: 0, y: 0, width: NotebookLayout.canvasWidth, height: NotebookLayout.canvasHeight(pageCount: pageCount))
    }
}

/// 筆記本畫布：一張 PKCanvasView 承載所有頁面（由上而下排列），背後是紙張。
/// 使用系統原生的 Apple Pencil 工具列（PKToolPicker），可雙指縮放；
/// 手指書寫或捲動依系統「只用 Apple Pencil 繪圖」設定，工具列選單中也能切換。
final class NotebookCanvasController: UIViewController, PKCanvasViewDelegate {
    let canvasView = PKCanvasView()
    private let paperView = PaperUnderlayView()
    private let toolPicker = PKToolPicker()
    private(set) var pageCount = 1
    private var lastWidth: CGFloat = 0
    private var lastVisiblePage = 0

    var onDrawingChange: ((PKDrawing) -> Void)?
    var onVisiblePageChange: ((Int) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        canvasView.delegate = self
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .default
        canvasView.alwaysBounceVertical = true
        canvasView.showsHorizontalScrollIndicator = false
        // 紙張是白色的：固定用淺色模式，墨水顏色才會跟紙上一致
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        canvasView.insertSubview(paperView, at: 0)

        // 顏色以淺色模式（白紙）呈現
        toolPicker.colorUserInterfaceStyle = .light
        toolPicker.addObserver(canvasView)
        toolPicker.setVisible(true, forFirstResponder: canvasView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canvasView.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        toolPicker.setVisible(false, forFirstResponder: canvasView)
        canvasView.resignFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = canvasView.bounds.width
        guard width > 0, width != lastWidth else { return }
        // 旋轉或改變視窗大小時維持相對縮放比例
        let relativeZoom = lastWidth > 0 ? canvasView.zoomScale / fitScale(for: lastWidth) : 1
        lastWidth = width
        let fit = fitScale(for: width)
        canvasView.minimumZoomScale = fit
        canvasView.maximumZoomScale = fit * 4
        canvasView.zoomScale = fit * max(relativeZoom, 1)
        updateLayout()
    }

    private func fitScale(for width: CGFloat) -> CGFloat {
        width / NotebookLayout.canvasWidth
    }

    func configure(drawing: PKDrawing, pageCount: Int, paper: PaperStyle) {
        self.pageCount = max(pageCount, 1)
        if canvasView.drawing != drawing {
            canvasView.drawing = drawing
        }
        paperView.configure(pageCount: self.pageCount, paper: paper)
        updateLayout()
    }

    var drawing: PKDrawing { canvasView.drawing }

    func scrollToPage(_ index: Int, animated: Bool) {
        let zoom = canvasView.zoomScale
        let y = NotebookLayout.pageRect(index).minY * zoom - NotebookLayout.margin * zoom - canvasView.adjustedContentInset.top
        let maxY = max(canvasView.contentSize.height - canvasView.bounds.height + canvasView.adjustedContentInset.bottom, -canvasView.adjustedContentInset.top)
        canvasView.setContentOffset(CGPoint(x: canvasView.contentOffset.x, y: min(max(y, -canvasView.adjustedContentInset.top), maxY)), animated: animated)
    }

    private func updateLayout() {
        let zoom = canvasView.zoomScale
        canvasView.contentSize = CGSize(
            width: NotebookLayout.canvasWidth * zoom,
            height: NotebookLayout.canvasHeight(pageCount: pageCount) * zoom
        )
        paperView.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        paperView.frame.origin = .zero
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        onDrawingChange?(canvasView.drawing)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateLayout()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let zoom = max(scrollView.zoomScale, 0.01)
        let middle = (scrollView.contentOffset.y + scrollView.bounds.height / 2) / zoom
        let page = NotebookLayout.pageIndex(atY: middle, pageCount: pageCount)
        if page != lastVisiblePage {
            lastVisiblePage = page
            onVisiblePageChange?(page)
        }
    }
}

/// 讓 SwiftUI 端取得畫布目前的筆跡、捲動到某頁。
@MainActor
final class NotebookCanvasHandle {
    fileprivate weak var controller: NotebookCanvasController?

    var currentDrawing: PKDrawing? { controller?.drawing }

    func scrollToPage(_ index: Int) {
        controller?.scrollToPage(index, animated: true)
    }
}

/// SwiftUI 包裝。`revision` 改變時（插入／刪除頁面、從 vault 更新）才把筆記本的筆跡重新載入畫布。
struct NotebookCanvas: UIViewControllerRepresentable {
    let notebook: Notebook
    let handle: NotebookCanvasHandle
    let revision: Int
    var onDrawingChange: (PKDrawing) -> Void
    var onVisiblePageChange: (Int) -> Void

    func makeUIViewController(context: Context) -> NotebookCanvasController {
        let controller = NotebookCanvasController()
        controller.loadViewIfNeeded()
        controller.configure(drawing: notebook.drawing, pageCount: notebook.pageCount, paper: notebook.paper)
        handle.controller = controller
        context.coordinator.revision = revision
        return controller
    }

    func updateUIViewController(_ controller: NotebookCanvasController, context: Context) {
        controller.onDrawingChange = onDrawingChange
        controller.onVisiblePageChange = onVisiblePageChange
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            controller.configure(drawing: notebook.drawing, pageCount: notebook.pageCount, paper: notebook.paper)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var revision = 0
    }
}
