import PencilKit
import SwiftUI
import UIKit

/// 紙張圖樣與畫布圖片（手寫筆記與手寫區塊共用的連續畫布，`CanvasLayout`）。
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

    /// 連續畫布上 `rect` 這一段的紙張圖樣（座標以這一段的左上角為原點）；點陣紙的點要填滿，其他是線條。
    /// 線條位置以整張畫布為準，所以一段接一段是連續的：橫線從畫布頂端 `linedTopMargin` 開始，方格與點陣每 `spacing` 一格。
    static func canvasPatternPath(for style: PaperStyle, rect: CGRect) -> CGPath? {
        let path = CGMutablePath()
        switch style {
        case .blank:
            return nil
        case .lined:
            for y in positions(first: linedTopMargin, from: rect.minY, to: rect.maxY) {
                path.move(to: CGPoint(x: 0, y: y - rect.minY))
                path.addLine(to: CGPoint(x: rect.width, y: y - rect.minY))
            }
        case .grid:
            for x in positions(first: spacing, from: rect.minX, to: rect.maxX) {
                path.move(to: CGPoint(x: x - rect.minX, y: 0))
                path.addLine(to: CGPoint(x: x - rect.minX, y: rect.height))
            }
            for y in positions(first: spacing, from: rect.minY, to: rect.maxY) {
                path.move(to: CGPoint(x: 0, y: y - rect.minY))
                path.addLine(to: CGPoint(x: rect.width, y: y - rect.minY))
            }
        case .dotted:
            let radius: CGFloat = 1.4
            let columns = positions(first: spacing, from: rect.minX, to: rect.maxX)
            for y in positions(first: spacing, from: rect.minY, to: rect.maxY) {
                for x in columns {
                    path.addEllipse(in: CGRect(x: x - rect.minX - radius, y: y - rect.minY - radius, width: radius * 2, height: radius * 2))
                }
            }
        }
        return path
    }

    /// `first`、`first + spacing`、… 之中落在 `lower..<upper` 的位置。
    static func positions(first: CGFloat, from lower: CGFloat, to upper: CGFloat) -> [CGFloat] {
        var value = first + max(0, ceil((lower - first) / spacing)) * spacing
        var result: [CGFloat] = []
        while value < upper {
            result.append(value)
            value += spacing
        }
        return result
    }

    /// 連續畫布上一段的圖片（匯出給 Obsidian、手寫辨識）：白紙、圖樣與筆跡。
    /// 筆跡一律以淺色模式算顏色，深色模式下黑色墨水才不會變成白色。
    static func canvasImage(drawing: PKDrawing, rect: CGRect, paper: PaperStyle, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: rect, scale: scale)
        }
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(origin: .zero, size: rect.size))
            if let path = canvasPatternPath(for: paper, rect: rect) {
                cg.addPath(path)
                if paper == .dotted {
                    cg.setFillColor(patternColor(for: paper).cgColor)
                    cg.fillPath()
                } else {
                    cg.setStrokeColor(patternColor(for: paper).cgColor)
                    cg.setLineWidth(1)
                    cg.strokePath()
                }
            }
            ink.draw(in: CGRect(origin: .zero, size: rect.size))
        }
    }
}

// MARK: - 連續畫布

/// 連續畫布後面的紙張：每 `segmentHeight` 一個白色圖層加上向量圖樣（縮放時仍保持清晰），畫布變長時往下增加。
final class CanvasPaperView: UIView {
    private var segmentLayers: [CALayer] = []
    private var paper: PaperStyle?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .white
        // 以左上角為縮放原點：改變高度或縮放時左上角固定在畫布原點
        layer.anchorPoint = .zero
        layer.position = .zero
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(paper: PaperStyle, height: CGFloat) {
        if paper != self.paper {
            segmentLayers.forEach { $0.removeFromSuperlayer() }
            segmentLayers = []
            self.paper = paper
        }
        let count = max(Int(ceil(height / CanvasLayout.segmentHeight)), 1)
        while segmentLayers.count > count {
            segmentLayers.removeLast().removeFromSuperlayer()
        }
        while segmentLayers.count < count {
            let rect = CGRect(x: 0, y: CGFloat(segmentLayers.count) * CanvasLayout.segmentHeight, width: CanvasLayout.width, height: CanvasLayout.segmentHeight)
            let segment = CAShapeLayer()
            segment.frame = rect
            segment.path = PaperRenderer.canvasPatternPath(for: paper, rect: rect)
            segment.contentsScale = max(traitCollection.displayScale, 2)
            if paper == .dotted {
                segment.fillColor = PaperRenderer.patternColor(for: paper).cgColor
            } else {
                segment.fillColor = nil
                segment.strokeColor = PaperRenderer.patternColor(for: paper).cgColor
                segment.lineWidth = 1
            }
            layer.addSublayer(segment)
            segmentLayers.append(segment)
        }
        bounds = CGRect(x: 0, y: 0, width: CanvasLayout.width, height: CGFloat(count) * CanvasLayout.segmentHeight)
    }
}

/// 手寫筆記的畫布：寬度固定、往下無限延伸的 PKCanvasView，後面是連續的紙張。
/// 一打開就能直接書寫：Apple Pencil 書寫、手指捲動；沒有 Apple Pencil 時手指書寫、兩指捲動
/// （依系統設定，也能在 Apple Pencil 工具列的選單切換）。寫到接近底部時自動加長；雙指縮放，最小為符合寬度。
final class CanvasNotebookController: UIViewController, PKCanvasViewDelegate, PKToolPickerObserver {
    let canvasView = PKCanvasView()
    private let paperView = CanvasPaperView()
    private let toolPicker = PKToolPicker()
    private var paper: PaperStyle = .blank
    private var minimumHeight = CanvasLayout.segmentHeight
    /// 目前的畫布高度（邏輯座標）。打開期間只會變長，畫面不會因為擦掉筆跡而跳動。
    private var canvasHeight: CGFloat = 0
    private var lastWidth: CGFloat = 0

    var onDrawingChange: ((PKDrawing) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        canvasView.delegate = self
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .default
        canvasView.alwaysBounceVertical = true
        canvasView.showsHorizontalScrollIndicator = false
        // 紙張是白色的：固定用淺色模式，墨水顏色才會跟匯出的圖片一致
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

        toolPicker.colorUserInterfaceStyle = .light
        toolPicker.addObserver(canvasView)
        toolPicker.addObserver(self)
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
        guard width > 0 else { return }
        if width != lastWidth {
            // 旋轉、調整側欄或視窗大小時維持相對縮放比例
            let relativeZoom = lastWidth > 0 ? canvasView.zoomScale / fitScale(for: lastWidth) : 1
            lastWidth = width
            let fit = fitScale(for: width)
            canvasView.minimumZoomScale = fit
            canvasView.maximumZoomScale = fit * 4
            canvasView.zoomScale = fit * max(relativeZoom, 1)
        }
        updateLayout()
    }

    private func fitScale(for width: CGFloat) -> CGFloat {
        width / CanvasLayout.width
    }

    /// 載入筆跡與紙張；`minimumSegments` 是上次的畫布長度（段數）。
    func configure(drawing: PKDrawing, minimumSegments: Int, paper: PaperStyle) {
        if canvasView.drawing != drawing {
            canvasView.drawing = drawing
        }
        self.paper = paper
        minimumHeight = CGFloat(max(minimumSegments, 1)) * CanvasLayout.segmentHeight
        canvasHeight = 0
        updateLayout()
    }

    /// 依筆跡加長畫布（至少填滿畫面），更新捲動範圍與紙張。
    private func updateLayout() {
        let zoom = max(canvasView.zoomScale, 0.01)
        let viewport = canvasView.bounds.height / zoom
        canvasHeight = max(canvasHeight, CanvasLayout.height(for: canvasView.drawing, minimum: max(minimumHeight, viewport)))
        paperView.configure(paper: paper, height: canvasHeight)
        paperView.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        let size = CGSize(width: CanvasLayout.width * zoom, height: canvasHeight * zoom)
        if canvasView.contentSize != size {
            canvasView.contentSize = size
        }
    }

    /// Apple Pencil 工具列停靠在底部（iPhone）時，讓畫布可以捲到工具列上方。
    private func updateToolPickerInset() {
        let obscured = toolPicker.frameObscured(in: view)
        let inset = obscured.isNull ? 0 : max(0, view.bounds.maxY - obscured.minY)
        canvasView.contentInset.bottom = inset
        canvasView.verticalScrollIndicatorInsets.bottom = inset
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        updateLayout()
        onDrawingChange?(canvasView.drawing)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        // 改完標題後直接書寫：讓畫布重新取得焦點，Apple Pencil 工具列再次出現
        if !canvasView.isFirstResponder {
            canvasView.becomeFirstResponder()
        }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateLayout()
    }

    // MARK: - PKToolPickerObserver

    func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) {
        updateToolPickerInset()
    }

    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        updateToolPickerInset()
    }
}

/// 讓 SwiftUI 端取得畫布目前的筆跡。
@MainActor
final class CanvasNotebookHandle {
    fileprivate weak var controller: CanvasNotebookController?

    var currentDrawing: PKDrawing? { controller?.canvasView.drawing }
}

/// SwiftUI 包裝。`revision` 改變時（換紙張、重新載入）才重新設定畫布；書寫時筆跡由畫布回報，不會反覆重設。
struct CanvasNotebook: UIViewControllerRepresentable {
    let drawing: () -> PKDrawing
    let minimumSegments: Int
    let paper: PaperStyle
    let handle: CanvasNotebookHandle
    let revision: Int
    var onDrawingChange: (PKDrawing) -> Void

    func makeUIViewController(context: Context) -> CanvasNotebookController {
        let controller = CanvasNotebookController()
        controller.loadViewIfNeeded()
        controller.configure(drawing: drawing(), minimumSegments: minimumSegments, paper: paper)
        handle.controller = controller
        context.coordinator.revision = revision
        return controller
    }

    func updateUIViewController(_ controller: CanvasNotebookController, context: Context) {
        controller.onDrawingChange = onDrawingChange
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            controller.configure(drawing: drawing(), minimumSegments: minimumSegments, paper: paper)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var revision = 0
    }
}
