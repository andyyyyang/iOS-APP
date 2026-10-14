import PDFKit
import PencilKit
import SwiftUI
import UIKit
import WebKit

// MARK: - 往右滑回上一頁

/// 往右滑的進度（只有提示圖示讀取，滑動時不會重畫頁面內容）。
@Observable
final class BackSwipeState {
    /// 0 = 沒有在滑，1 = 放開就回上一頁。
    var progress: CGFloat = 0
}

/// 中間內容任何地方往右滑（角度可以斜一點）回上一頁；頁面裡有下一層（例如設定的子頁）時先返回那一層。
/// 從螢幕左緣開始的滑動留給左側欄；手寫畫布、PDF、已經往左捲過的橫向捲動區與正在編輯的文字不會觸發，Apple Pencil 也不會。
struct BackSwipeArea: UIViewRepresentable {
    var isEnabled: Bool
    var canGoBack: Bool
    /// 從視窗左緣這個距離內開始的滑動不算（那是打開左側欄）。
    var edgeExclusion: CGFloat
    let state: BackSwipeState
    var onBack: () -> Void

    /// 滑過這個距離放開就回上一頁（滑得快的話短一點也算）。
    static let threshold: CGFloat = 96
    /// 可以接受的角度：水平往右上下約 35°。
    static let maxSlope: CGFloat = 0.7

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// 放在內容後面標出範圍；手勢裝在視窗上，才收得到落在文字區、捲動區裡的觸控。
    final class HostView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: BackSwipeArea
        private weak var host: UIView?
        /// 這次滑動要先返回的頁內導覽（沒有就回工作區的上一頁）。
        private weak var navigation: UINavigationController?
        private lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            return pan
        }()

        init(parent: BackSwipeArea) {
            self.parent = parent
        }

        func attach(to host: UIView) {
            self.host = host
            pan.view?.removeGestureRecognizer(pan)
            host.window?.addGestureRecognizer(pan)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard parent.isEnabled, let host, let window = host.window else { return false }
            guard host.bounds.contains(touch.location(in: host)), touch.location(in: window).x > parent.edgeExclusion else { return false }
            // 只算主畫面上的觸控（表單、選單、全螢幕畫面不算）
            guard let view = touch.view, let root = window.rootViewController?.view, view.isDescendant(of: root) else { return false }
            var current: UIView? = view
            while let candidate = current {
                if candidate is PKCanvasView || candidate is PDFView || candidate is WKWebView { return false }
                if let text = candidate as? UITextView, text.isFirstResponder { return false }
                if let scroll = candidate as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1, scroll.contentOffset.x > 0.5 {
                    return false
                }
                current = candidate.superview
            }
            navigation = Self.innerNavigation(from: view)
            return parent.canGoBack || navigation != nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            let direction = abs(velocity.x) + abs(velocity.y) > 60 ? velocity : pan.translation(in: pan.view)
            return direction.x > 0 && abs(direction.y) <= direction.x * BackSwipeArea.maxSlope
        }

        /// 捲動區要等這個手勢確定不是往右滑才開始捲（往上下滑時幾乎感覺不到差別）。
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }

        @objc private func handle(_ pan: UIPanGestureRecognizer) {
            let translation = pan.translation(in: pan.view)
            switch pan.state {
            case .began, .changed:
                parent.state.progress = max(translation.x, 0) / BackSwipeArea.threshold
            case .ended:
                let velocity = pan.velocity(in: pan.view)
                let far = translation.x > BackSwipeArea.threshold || (translation.x > 40 && velocity.x > 800)
                let level = abs(translation.y) <= max(translation.x, 1)
                withAnimation(.snappy(duration: 0.2)) { parent.state.progress = 0 }
                if far, level {
                    if let navigation {
                        navigation.popViewController(animated: true)
                    } else {
                        parent.onBack()
                    }
                }
                navigation = nil
            default:
                withAnimation(.snappy(duration: 0.2)) { parent.state.progress = 0 }
                navigation = nil
            }
        }

        /// 觸控所在的導覽堆疊（例如設定的子頁）；已經在第一層就不算。
        private static func innerNavigation(from view: UIView) -> UINavigationController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let navigation = current as? UINavigationController {
                    return navigation.viewControllers.count > 1 ? navigation : nil
                }
                responder = current.next
            }
            return nil
        }
    }
}

/// 往右滑時從左邊出現的返回箭頭：滑到放開就會返回時變成實心並輕震一下。
struct BackSwipeIndicator: View {
    let state: BackSwipeState

    var body: some View {
        let progress = min(state.progress, 1)
        let ready = state.progress >= 1
        Image(systemName: "chevron.left")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(ready ? DS.onPrimary : DS.text)
            .frame(width: 44, height: 44)
            .background(ready ? DS.primary : DS.control, in: Circle())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .scaleEffect(0.6 + 0.4 * progress)
            .offset(x: -48 + 64 * progress)
            .opacity(progress > 0.05 ? 1 : 0)
            .animation(.snappy(duration: 0.2), value: ready)
            .sensoryFeedback(.impact(weight: .light), trigger: ready) { _, isReady in isReady }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
