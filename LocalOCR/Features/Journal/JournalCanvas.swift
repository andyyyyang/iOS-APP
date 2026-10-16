import PencilKit
import SwiftUI
import UIKit

/// 畫面上一頁的資訊：頁首日期、頁碼與 #機種標記。
struct JournalPageInfo: Equatable {
    var day: String
    var number: Int
    var badges: [JournalBadge]
}

/// 頁面上的機種標記（像貼紙）：對到機種的是藍色，不確定的是黃色，找不到的是灰色。
struct JournalBadge: Equatable {
    enum State: Equatable { case linked, ambiguous, unknown }

    var label: String
    /// 標記旁邊的 #代號在頁面上的位置（頁面座標）。
    var anchor: CGRect
    var state: State
    var tagIndex: Int
}

/// 日誌筆記本的畫布：固定大小的頁面，可以連續往下捲、一次看一頁或兩頁並排（左右翻頁），每頁有頁首日期與頁碼；
/// Apple Pencil 書寫、手指捲動或翻頁，雙指縮放（最小為整頁放得下）。頁面上的機種標記可以點。
final class JournalCanvasController: UIViewController, PKCanvasViewDelegate, PKToolPickerObserver {
    let canvasView = PKCanvasView()
    private let paperView = JournalPaperView()
    private let badgeView = JournalBadgeLayerView()
    private let toolPicker = PKToolPicker()
    private var pages: [JournalPageInfo] = []
    private var paper: PaperStyle = .lined
    private(set) var mode: JournalViewMode = .scroll
    private var lastSize: CGSize = .zero
    private var lastVisiblePage = -1
    private var toolPickerInset: CGFloat = 0
    /// 換顯示方式時重新排列筆跡：不是使用者寫的，不回報。
    private var isRearranging = false

    /// 筆跡變了（與當時的顯示方式，分回每一頁時要用同一種排列）。
    var onDrawingChange: ((PKDrawing, JournalViewMode) -> Void)?
    /// 點了機種標記（頁、標記）。
    var onBadgeTap: ((Int, Int) -> Void)?
    var onAddPage: (() -> Void)?
    /// 畫面上是第幾頁（兩頁並排時是左邊那頁）。
    var onVisiblePageChange: ((Int) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = JournalPaperView.backdrop

        canvasView.delegate = self
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .default
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        canvasView.insertSubview(paperView, at: 0)
        canvasView.addSubview(badgeView)
        badgeView.onTap = { [weak self] page, tag in self?.onBadgeTap?(page, tag) }
        badgeView.onAddPage = { [weak self] in self?.onAddPage?() }
        applyScrollBehavior()

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
        let size = canvasView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if size != lastSize {
            let previousFit = lastSize.width > 0 ? fitScale(for: lastSize) : 0
            let relativeZoom = previousFit > 0 ? canvasView.zoomScale / previousFit : 1
            lastSize = size
            let fit = fitScale(for: size)
            canvasView.minimumZoomScale = fit
            canvasView.maximumZoomScale = fit * 4
            canvasView.zoomScale = fit * max(relativeZoom, 1)
        }
        updateLayout()
    }

    /// 最小縮放：連續捲動時頁寬符合畫面寬度；翻頁時整頁（或兩頁）放得下。
    private func fitScale(for size: CGSize) -> CGFloat {
        switch mode {
        case .scroll:
            return size.width / JournalLayout.canvasWidth
        case .single, .spread:
            let slot = JournalLayout.slotSize(mode)
            let height = max(size.height - bottomObstruction, 1)
            return min(size.width / slot.width, height / slot.height)
        }
    }

    /// 下面被蓋住的高度：工具列，或至少是 Home 指示條。
    private var bottomObstruction: CGFloat {
        max(toolPickerInset, view.safeAreaInsets.bottom)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if mode.isPaged { lastSize = .zero }
        view.setNeedsLayout()
    }

    private var isAtFit: Bool {
        abs(canvasView.zoomScale - canvasView.minimumZoomScale) < canvasView.minimumZoomScale * 0.02
    }

    /// 載入筆跡與頁面。
    func configure(drawing: PKDrawing, pages: [JournalPageInfo], paper: PaperStyle, mode: JournalViewMode) {
        if mode != self.mode {
            self.mode = mode
            applyScrollBehavior()
            lastSize = .zero
            view.setNeedsLayout()
        }
        if canvasView.drawing != drawing {
            isRearranging = true
            canvasView.drawing = drawing
            isRearranging = false
        }
        update(pages: pages, paper: paper)
    }

    /// 頁面、日期或機種標記變了（筆跡不變）。
    func update(pages: [JournalPageInfo], paper: PaperStyle) {
        self.pages = pages
        self.paper = paper
        paperView.configure(pages: pages, paper: paper, mode: mode)
        badgeView.configure(pages: pages, mode: mode)
        updateLayout()
    }

    /// 換顯示方式：筆跡依原本的排列分回每一頁，再依新的排列放回畫布，停在原本看的那一頁。
    func setMode(_ newMode: JournalViewMode) {
        guard newMode != mode else { return }
        let page = max(lastVisiblePage, 0)
        let perPage = JournalLayout.split(canvasView.drawing, pageCount: pages.count, mode: mode)
        mode = newMode
        applyScrollBehavior()
        isRearranging = true
        canvasView.drawing = JournalLayout.combine(perPage, mode: newMode)
        isRearranging = false
        paperView.configure(pages: pages, paper: paper, mode: newMode)
        badgeView.configure(pages: pages, mode: newMode)
        lastSize = .zero
        lastVisiblePage = -1
        view.setNeedsLayout()
        view.layoutIfNeeded()
        scrollToPage(page, animated: false)
    }

    private func applyScrollBehavior() {
        canvasView.alwaysBounceVertical = !mode.isPaged
        canvasView.alwaysBounceHorizontal = mode.isPaged
        canvasView.showsVerticalScrollIndicator = !mode.isPaged
        canvasView.decelerationRate = mode.isPaged ? .fast : .normal
    }

    func scrollToPage(_ index: Int, animated: Bool) {
        view.layoutIfNeeded()
        let zoom = max(canvasView.zoomScale, 0.01)
        let inset = canvasView.contentInset
        switch mode {
        case .scroll:
            let rect = JournalLayout.pageRect(index)
            let y = max(0, min(rect.minY * zoom - 12, canvasView.contentSize.height - canvasView.bounds.height + inset.bottom))
            canvasView.setContentOffset(CGPoint(x: canvasView.contentOffset.x, y: y), animated: animated)
        case .single, .spread:
            let slot = JournalLayout.slot(ofPage: index, mode: mode)
            canvasView.setContentOffset(CGPoint(x: offset(forSlot: slot), y: -inset.top), animated: animated)
        }
    }

    /// 翻頁時某一格對齊畫面的位置（超過最後面時停在能捲到的最右邊）。
    private func offset(forSlot slot: Int) -> CGFloat {
        let zoom = max(canvasView.zoomScale, 0.01)
        let inset = canvasView.contentInset
        let width = JournalLayout.slotSize(mode).width * zoom
        let maxOffset = max(-inset.left, canvasView.contentSize.width + inset.right - canvasView.bounds.width)
        return min(max(CGFloat(slot) * width - inset.left, -inset.left), maxOffset)
    }

    private func updateLayout() {
        let zoom = max(canvasView.zoomScale, 0.01)
        var size = JournalLayout.canvasSize(pageCount: pages.count, mode: mode)
        if mode.isPaged {
            size.width += JournalLayout.addPageWidth
        } else {
            size.height += JournalBadgeLayerView.addPageHeight
        }
        // 以左上角為縮放原點（anchorPoint 是 .zero）：縮放時左上角固定在畫布原點
        for layerView in [paperView, badgeView] as [UIView] {
            layerView.bounds = CGRect(origin: .zero, size: size)
            layerView.layer.position = .zero
            layerView.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        }
        let contentSize = CGSize(width: size.width * zoom, height: size.height * zoom)
        if canvasView.contentSize != contentSize {
            canvasView.contentSize = contentSize
        }
        updateInsets()
        reportVisiblePage()
    }

    /// 翻頁時頁面置中（畫面比頁面寬或高時）；工具列蓋住的高度留在下面。
    private func updateInsets() {
        let bottom = bottomObstruction
        var inset = UIEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
        if mode.isPaged {
            let zoom = max(canvasView.zoomScale, 0.01)
            let slot = JournalLayout.slotSize(mode)
            let bounds = canvasView.bounds.size
            let horizontal = max(0, (bounds.width - slot.width * zoom) / 2)
            let vertical = max(0, (bounds.height - bottom - slot.height * zoom) / 2)
            inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: bottom + vertical, right: horizontal)
        }
        if canvasView.contentInset != inset {
            canvasView.contentInset = inset
            canvasView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    private func reportVisiblePage() {
        let zoom = max(canvasView.zoomScale, 0.01)
        let center = CGPoint(
            x: (canvasView.contentOffset.x + canvasView.bounds.width / 2) / zoom,
            y: (canvasView.contentOffset.y + canvasView.bounds.height / 2) / zoom
        )
        var page = JournalLayout.pageIndex(at: center, pageCount: pages.count, mode: mode)
        if mode == .spread { page -= page % 2 }
        if page != lastVisiblePage {
            lastVisiblePage = page
            // 可能在 SwiftUI 更新畫面時被呼叫：下一輪再通知，不在更新中改狀態
            DispatchQueue.main.async { [weak self] in self?.onVisiblePageChange?(page) }
        }
    }

    private func updateToolPickerInset() {
        let obscured = toolPicker.frameObscured(in: view)
        let inset = obscured.isNull ? 0 : max(0, view.bounds.maxY - obscured.minY)
        guard inset != toolPickerInset else { return }
        toolPickerInset = inset
        if mode.isPaged { lastSize = .zero }
        view.setNeedsLayout()
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isRearranging else { return }
        onDrawingChange?(canvasView.drawing, mode)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        if !canvasView.isFirstResponder {
            canvasView.becomeFirstResponder()
        }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateLayout()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportVisiblePage()
    }

    /// 翻頁：整頁放得下時放開手指就停在最近的一格（往哪邊滑就翻到哪邊）；放大後可以自由移動。
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard mode.isPaged, isAtFit else { return }
        let width = JournalLayout.slotSize(mode).width * max(canvasView.zoomScale, 0.01)
        guard width > 0 else { return }
        let inset = canvasView.contentInset.left
        let current = (scrollView.contentOffset.x + inset) / width
        var slot: CGFloat
        if velocity.x > 0.15 {
            slot = floor(current + 0.05) + 1
        } else if velocity.x < -0.15 {
            slot = ceil(current - 0.05) - 1
        } else {
            slot = ((targetContentOffset.pointee.x + inset) / width).rounded()
        }
        let last = CGFloat(JournalLayout.slotCount(pageCount: pages.count, mode: mode))
        slot = min(max(slot, 0), last)
        targetContentOffset.pointee = CGPoint(x: offset(forSlot: Int(slot)), y: -canvasView.contentInset.top)
    }

    // MARK: - PKToolPickerObserver

    func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) {
        updateToolPickerInset()
    }

    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        updateToolPickerInset()
    }
}

/// 頁面後面的紙：灰色桌面上一張張白紙（陰影、紙張圖樣、頁首日期、頁碼）。
final class JournalPaperView: UIView {
    static let backdrop = UIColor(red: 0.925, green: 0.925, blue: 0.94, alpha: 1)

    private var pageLayers: [CALayer] = []
    private var configured: ([JournalPageInfo], PaperStyle, JournalViewMode)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = Self.backdrop
        layer.anchorPoint = .zero
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(pages: [JournalPageInfo], paper: PaperStyle, mode: JournalViewMode) {
        let titles = pages.map { JournalPageInfo(day: $0.day, number: $0.number, badges: []) }
        if let configured, configured.0 == titles, configured.1 == paper, configured.2 == mode { return }
        configured = (titles, paper, mode)
        pageLayers.forEach { $0.removeFromSuperlayer() }
        pageLayers = pages.enumerated().map { index, info in makePage(index: index, info: info, paper: paper, mode: mode) }
        pageLayers.forEach { layer.addSublayer($0) }
    }

    private func makePage(index: Int, info: JournalPageInfo, paper: PaperStyle, mode: JournalViewMode) -> CALayer {
        let rect = JournalLayout.pageRect(index, mode: mode)
        let page = CALayer()
        page.frame = rect
        page.backgroundColor = UIColor.white.cgColor
        page.cornerRadius = 4
        page.shadowColor = UIColor.black.cgColor
        page.shadowOpacity = 0.12
        page.shadowRadius = 6
        page.shadowOffset = CGSize(width: 0, height: 2)
        let scale = max(traitCollection.displayScale, 2) * 2
        let pattern = CAShapeLayer()
        pattern.frame = CGRect(origin: .zero, size: rect.size)
        pattern.path = PaperRenderer.canvasPatternPath(for: paper, rect: CGRect(origin: .zero, size: rect.size))
        pattern.contentsScale = scale
        if paper == .dotted {
            pattern.fillColor = PaperRenderer.patternColor(for: paper).cgColor
        } else {
            pattern.fillColor = nil
            pattern.strokeColor = PaperRenderer.patternColor(for: paper).cgColor
            pattern.lineWidth = 1
        }
        page.addSublayer(pattern)
        for item in JournalRenderer.header(for: info.day, number: info.number) {
            let text = CATextLayer()
            text.string = NSAttributedString(string: item.text as String, attributes: item.attributes)
            text.contentsScale = scale
            let size = item.text.size(withAttributes: item.attributes)
            text.frame = CGRect(origin: item.point, size: CGSize(width: ceil(size.width) + 2, height: ceil(size.height) + 2))
            page.addSublayer(text)
        }
        return page
    }
}

/// 機種標記（可以點）與最後一頁下面的「新增一頁」。只有點到標記或按鈕時才攔截觸控，其他地方照常書寫、捲動。
final class JournalBadgeLayerView: UIView {
    static let addPageHeight: CGFloat = 110

    var onTap: ((Int, Int) -> Void)?
    var onAddPage: (() -> Void)?
    private var configured: ([JournalPageInfo], JournalViewMode)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.anchorPoint = .zero
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        var view = super.hitTest(point, with: event)
        while let current = view, current !== self {
            if current is UIControl { return current }
            view = current.superview
        }
        return nil
    }

    func configure(pages: [JournalPageInfo], mode: JournalViewMode) {
        if let configured, configured.0 == pages, configured.1 == mode { return }
        configured = (pages, mode)
        subviews.forEach { $0.removeFromSuperview() }
        for (pageIndex, info) in pages.enumerated() {
            let rect = JournalLayout.pageRect(pageIndex, mode: mode)
            for badge in info.badges {
                let button = makeBadge(badge)
                button.sizeToFit()
                var frame = button.frame
                frame.size.width += 20
                frame.size.height = 34
                // 放在 #代號的右邊，超出頁面時改放在下面
                var origin = CGPoint(x: rect.minX + badge.anchor.maxX + 8, y: rect.minY + badge.anchor.midY - frame.height / 2)
                if origin.x + frame.width > rect.maxX - 8 {
                    origin = CGPoint(x: max(rect.minX + 8, rect.minX + badge.anchor.minX), y: rect.minY + badge.anchor.maxY + 4)
                }
                frame.origin = origin
                button.frame = frame
                button.addAction(UIAction { [weak self] _ in self?.onTap?(pageIndex, badge.tagIndex) }, for: .touchUpInside)
                addSubview(button)
            }
        }
        var configuration = UIButton.Configuration.gray()
        configuration.title = "新增一頁"
        configuration.image = UIImage(systemName: "plus")
        configuration.imagePadding = 8
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = UIColor(white: 0.3, alpha: 1)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
        let add = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onAddPage?() })
        add.sizeToFit()
        if mode.isPaged {
            // 翻頁：放在最後一格右邊
            let size = JournalLayout.canvasSize(pageCount: pages.count, mode: mode)
            add.center = CGPoint(x: size.width + JournalLayout.addPageWidth / 2, y: size.height / 2)
        } else {
            let last = JournalLayout.pageRect(max(pages.count - 1, 0))
            add.center = CGPoint(x: last.midX, y: last.maxY + JournalLayout.gap + 24)
        }
        add.accessibilityLabel = "新增一頁"
        addSubview(add)
    }

    private func makeBadge(_ badge: JournalBadge) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        let (background, foreground, symbol): (UIColor, UIColor, String) = switch badge.state {
        case .linked: (UIColor(red: 0.86, green: 0.94, blue: 0.98, alpha: 1), UIColor(red: 0.12, green: 0.32, blue: 0.55, alpha: 1), "link")
        case .ambiguous: (UIColor(red: 0.99, green: 0.94, blue: 0.78, alpha: 1), UIColor(red: 0.5, green: 0.36, blue: 0.05, alpha: 1), "questionmark.circle")
        case .unknown: (UIColor(white: 0.92, alpha: 1), UIColor(white: 0.4, alpha: 1), "magnifyingglass")
        }
        configuration.baseBackgroundColor = background
        configuration.baseForegroundColor = foreground
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        configuration.imagePadding = 5
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 12)
        var title = AttributedString(badge.label)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        configuration.attributedTitle = title
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = badge.state == .linked ? "開啟機種 \(badge.label)" : "選擇機種 \(badge.label)"
        return button
    }
}

/// 讓 SwiftUI 端取得畫布目前的筆跡、捲到某一頁。
@MainActor
final class JournalCanvasHandle {
    fileprivate weak var controller: JournalCanvasController?

    var currentDrawing: PKDrawing? { controller?.canvasView.drawing }
    /// 畫布上筆跡目前的排列方式（分回每一頁時要用）。
    var currentMode: JournalViewMode? { controller?.mode }

    func scrollToPage(_ index: Int, animated: Bool = true) {
        controller?.scrollToPage(index, animated: animated)
    }
}

/// SwiftUI 包裝：`revision` 改變時（載入、換紙張）重新設定畫布；頁面與標記變了只更新頁面，不重設筆跡。
struct JournalCanvas: UIViewControllerRepresentable {
    /// 依某種顯示方式排列的整本筆跡（重新設定畫布時用）。
    let drawing: (JournalViewMode) -> PKDrawing
    let pages: [JournalPageInfo]
    let paper: PaperStyle
    let mode: JournalViewMode
    let handle: JournalCanvasHandle
    let revision: Int
    var onDrawingChange: (PKDrawing, JournalViewMode) -> Void
    var onBadgeTap: (Int, Int) -> Void
    var onAddPage: () -> Void
    var onVisiblePageChange: (Int) -> Void

    func makeUIViewController(context: Context) -> JournalCanvasController {
        let controller = JournalCanvasController()
        controller.loadViewIfNeeded()
        controller.configure(drawing: drawing(mode), pages: pages, paper: paper, mode: mode)
        handle.controller = controller
        context.coordinator.revision = revision
        return controller
    }

    func updateUIViewController(_ controller: JournalCanvasController, context: Context) {
        controller.onDrawingChange = onDrawingChange
        controller.onBadgeTap = onBadgeTap
        controller.onAddPage = onAddPage
        controller.onVisiblePageChange = onVisiblePageChange
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            controller.configure(drawing: drawing(mode), pages: pages, paper: paper, mode: mode)
        } else {
            controller.update(pages: pages, paper: paper)
            // 換了顯示方式：畫布自己重新排列筆跡（不會漏掉還沒存檔的筆跡）
            controller.setMode(mode)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var revision = 0
    }
}
