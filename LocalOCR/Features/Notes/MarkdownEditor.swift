import SwiftUI
import UIKit

/// 點一下會有動作的東西：待辦方框、連結、[[連結]]、內嵌圖片。
enum MarkdownTapTarget: Equatable {
    case checkbox(NSRange)
    case link(String)
    case wikiLink(String)
    case image(String)
}

/// 讓 SwiftUI 對編輯器下指令（插入內容、加上格式、AI 修改後取代文字）。
@MainActor
final class MarkdownEditorController {
    fileprivate weak var textView: NoteTextView?
    fileprivate var onTextChange: ((String) -> Void)?
    fileprivate var restyle: (() -> Void)?

    /// 版面設定改了（例如全寬／易讀寬度）：重新計算邊距並重排。
    func relayout() {
        textView?.setNeedsLayout()
    }

    var cursorLocation: Int { textView?.selectedRange.location ?? 0 }
    var selectedRange: NSRange { textView?.selectedRange ?? NSRange(location: 0, length: 0) }

    /// 在游標所在處插入一個獨立的一行（例如內嵌的手寫區塊或照片）。
    func insertBlock(_ snippet: String) {
        guard let textView else { return }
        let result = NoteMarkdownEditing.inserting(snippet, into: textView.text, at: textView.selectedRange.location)
        replaceAll(with: result.text, cursor: result.cursor)
    }

    /// 用前後標記包住選取的文字（粗體、斜體、[[連結]]…）。
    func wrapSelection(_ marker: String, closing: String? = nil) {
        guard let textView else { return }
        let range = textView.selectedRange
        let selected = (textView.text as NSString).substring(with: range)
        replace(range: range, with: marker + selected + (closing ?? marker))
        textView.selectedRange = NSRange(location: range.location + (marker as NSString).length, length: range.length)
    }

    /// 切換目前這一行的開頭（標題、清單、待辦）。
    func toggleLinePrefix(_ prefix: String) {
        guard let textView else { return }
        let text = textView.text as NSString
        let lineRange = text.lineRange(for: NSRange(location: textView.selectedRange.location, length: 0))
        let line = text.substring(with: lineRange)
        let knownPrefixes = ["- [ ] ", "- [x] ", "### ", "## ", "# ", "- ", "1. "]
        var stripped = line
        var removed = ""
        for known in knownPrefixes where line.hasPrefix(known) {
            stripped = String(line.dropFirst(known.count))
            removed = known
            break
        }
        let newLine = removed == prefix ? stripped : prefix + stripped
        let cursor = textView.selectedRange.location
        replace(range: lineRange, with: newLine)
        let delta = (newLine as NSString).length - (line as NSString).length
        textView.selectedRange = NSRange(location: max(lineRange.location, cursor + delta), length: 0)
    }

    /// 取代一段文字（可以復原），例如 AI 修改的結果、點待辦方框。
    func replace(range: NSRange, with replacement: String) {
        guard let textView,
              let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end) else { return }
        textView.replace(textRange, withText: replacement)
        changed()
    }

    func focus() {
        _ = textView?.becomeFirstResponder()
    }

    /// 捲動到第 `line` 行並把游標放在那裡（右側大綱、[[筆記#標題]] 跳轉）。
    func reveal(line: Int) {
        guard let textView else { return }
        let text = textView.text as NSString
        var location = 0
        var current = 0
        while current < line, location < text.length {
            location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        let target = NSRange(location: min(location, text.length), length: 0)
        textView.selectedRange = target
        textView.scrollRangeToVisible(target)
    }

    func dismissKeyboard() {
        textView?.resignFirstResponder()
    }

    /// 捲回最上面（點收合後的標題）。
    func scrollToTop() {
        guard let textView else { return }
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: -textView.contentInset.top), animated: true)
    }

    private func replaceAll(with text: String, cursor: Int) {
        guard let textView else { return }
        textView.text = text
        textView.selectedRange = NSRange(location: min(cursor, (text as NSString).length), length: 0)
        changed()
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    fileprivate func changed() {
        guard let textView else { return }
        restyle?()
        onTextChange?(textView.text)
    }
}

/// 筆記編輯器的文字區（TextKit 1，方框、圓點、圖片等由 LiveMarkdownLayoutManager 畫出）。
/// 內容跟著畫面全寬自適應（設定中可限制在易讀的 760）；左右留白手機 18、平板 32。
/// 工作區不隨鍵盤縮放（版面才不會跑來跑去），所以由這裡依鍵盤蓋住的高度加大捲動範圍。
final class NoteTextView: UITextView {
    static let readableColumnWidth: CGFloat = 760
    /// 內容欄的最大寬度（全寬時不限制）。
    static var columnWidth: CGFloat { NotesSettings.limitsLineWidth ? readableColumnWidth : .infinity }

    static func horizontalPadding(compact: Bool) -> CGFloat { compact ? 18 : 32 }
    /// 與標題之間的距離（標題下緣的漸層淡出也在這段距離內）。
    static let topInset: CGFloat = 18
    static let bottomInset: CGFloat = 160

    var onTap: ((MarkdownTapTarget) -> Void)?
    var onWidthChange: (() -> Void)?
    /// 浮在上方的標題列：展開時與收合後的高度。內容從展開的標題下方開始，往下捲時標題縮小、內容捲到標題後面；
    /// 捲動範圍只扣掉收合後的高度，游標與跳轉才不會停在標題後面。
    var headerHeights: (expanded: CGFloat, collapsed: CGFloat) = (0, 0) {
        didSet {
            if headerHeights != oldValue { setNeedsLayout() }
        }
    }
    /// 標題已經收合了多少（0 = 在最上面，捲動的距離）。
    var headerScroll: CGFloat { contentOffset.y + contentInset.top }
    /// 這則筆記的路徑（DataviewJS 的 dv.current()）。
    var notePath = ""
    /// DataviewJS 的內容高度改變：(區塊, 新的內容高度)，要重新排版保留空間。
    var onDataviewHeight: ((String, CGFloat) -> Void)?
    private var dataviewBlocks: [(range: NSRange, info: DataviewBlockInfo)] = []
    private var dataviewViews: [String: DataviewView] = [:]

    private var keyboardOverlap: CGFloat = 0
    private var lastWidth: CGFloat = 0
    private var prioritized: Set<ObjectIdentifier> = []
    private let tapDelegate = TapDelegate()
    private lazy var interactionTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleInteractionTap(_:)))
        tap.delegate = tapDelegate
        return tap
    }()

    var markdownLayout: LiveMarkdownLayoutManager? { layoutManager as? LiveMarkdownLayoutManager }

    /// 使用 TextKit 1 與自訂的版面管理（才能畫出方框、表格與圖片）。
    static func make() -> NoteTextView {
        let storage = NSTextStorage()
        let layout = LiveMarkdownLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        return NoteTextView(frame: .zero, textContainer: container)
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        contentInsetAdjustmentBehavior = .never
        self.textContainer.lineFragmentPadding = 0
        tapDelegate.target = self
        addGestureRecognizer(interactionTap)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let compact = traitCollection.horizontalSizeClass == .compact || bounds.width < 500
        let side = max((bounds.width - Self.columnWidth) / 2, 0) + Self.horizontalPadding(compact: compact)
        let insets = UIEdgeInsets(top: Self.topInset + max(headerHeights.expanded - headerHeights.collapsed, 0), left: side, bottom: Self.bottomInset, right: side)
        if textContainerInset != insets {
            textContainerInset = insets
        }
        if abs(contentInset.top - headerHeights.collapsed) > 0.5 {
            let atTop = contentOffset.y <= -contentInset.top + 1
            contentInset.top = headerHeights.collapsed
            verticalScrollIndicatorInsets.top = headerHeights.collapsed
            if atTop { contentOffset.y = -headerHeights.collapsed }
        }
        // 內容寬度變了（旋轉、側欄開關、全寬設定）：表格等依寬度排版的內容重新排
        let contentWidth = bounds.width - insets.left - insets.right
        if abs(contentWidth - lastWidth) > 0.5 {
            lastWidth = contentWidth
            onWidthChange?()
        }
        prioritizeInteractionTap()
        positionDataviewViews()
    }

    // MARK: DataviewJS

    /// 重新排版後：為每個 ```dataviewjs 區塊建立（或沿用）執行畫面，移除不再顯示的。
    func refreshDataviewBlocks() {
        var blocks: [(range: NSRange, info: DataviewBlockInfo)] = []
        textStorage.enumerateAttribute(.mdDataview, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            if let info = value as? DataviewBlockInfo { blocks.append((range, info)) }
        }
        dataviewBlocks = blocks
        let keys = Set(blocks.map(\.info.key))
        for (key, view) in dataviewViews where !keys.contains(key) {
            view.removeFromSuperview()
            dataviewViews[key] = nil
        }
        for block in blocks where dataviewViews[block.info.key] == nil {
            let view = makeDataviewView(for: block.info)
            dataviewViews[block.info.key] = view
            addSubview(view)
        }
        positionDataviewViews()
    }

    /// 執行畫面疊在區塊第一行保留的空間上（跟著文字捲動）。
    private func positionDataviewViews() {
        guard !dataviewBlocks.isEmpty else { return }
        let width = textContainer.size.width
        for block in dataviewBlocks {
            guard let view = dataviewViews[block.info.key], block.range.location < textStorage.length else { continue }
            let glyph = layoutManager.glyphIndexForCharacter(at: block.range.location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let spacing = (textStorage.attribute(.paragraphStyle, at: block.range.location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
            let frame = CGRect(x: textContainerInset.left + line.minX, y: textContainerInset.top + line.minY + spacing, width: width, height: block.info.height)
            if view.frame != frame { view.frame = frame }
        }
    }

    private func makeDataviewView(for info: DataviewBlockInfo) -> DataviewView {
        let view = DataviewView()
        let key = info.key
        view.onHeight = { [weak self, weak view] content in
            guard let self, let view else { return }
            // 很高的內容（整頁的儀表板）只顯示到畫面的八成，裡面自己捲動
            let limit = max(320, (self.window?.bounds.height ?? 800) * 0.8)
            view.setScrollsContent(content > limit)
            let height = min(max(content, 40), limit)
            if abs(height - (DataviewBlockInfo.heights[key] ?? -1)) > 2 {
                self.onDataviewHeight?(key, height)
            }
        }
        view.onOpenLink = { [weak self] link in self?.onTap?(.wikiLink(link)) }
        view.onEdit = { [weak self] in self?.editDataview(key) }
        view.onFullScreen = { [weak self] in self?.presentDataview(key) }
        view.load(code: info.code, sourcePath: notePath, language: info.language)
        return view
    }

    /// 計算行內查詢用的網頁（不顯示），這則筆記第一次有行內查詢時建立。
    private var inlineEvaluator: DataviewView?

    func evaluateInlineQueries(_ queries: [LiveMarkdown.InlineQuery]) async -> [String] {
        let evaluator: DataviewView
        if let existing = inlineEvaluator, existing.sourcePath == notePath {
            evaluator = existing
        } else {
            inlineEvaluator?.removeFromSuperview()
            evaluator = DataviewView(showsHeader: false)
            evaluator.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            evaluator.alpha = 0
            evaluator.isUserInteractionEnabled = false
            addSubview(evaluator)
            evaluator.load(code: "", sourcePath: notePath, mode: "evaluator")
            inlineEvaluator = evaluator
        }
        do {
            return try await evaluator.evaluateInline(queries)
        } catch {
            return queries.map { _ in "⚠︎ " + error.localizedDescription }
        }
    }

    /// 編輯程式碼：游標移到區塊的第一行程式碼（區塊改回顯示原始文字）。
    private func editDataview(_ key: String) {
        guard let block = dataviewBlocks.first(where: { $0.info.key == key }) else { return }
        let text = textStorage.string as NSString
        let fenceLine = text.lineRange(for: NSRange(location: block.range.location, length: 0))
        _ = becomeFirstResponder()
        selectedRange = NSRange(location: min(NSMaxRange(fenceLine), text.length), length: 0)
        delegate?.textViewDidChangeSelection?(self)
    }

    private func presentDataview(_ key: String) {
        guard let block = dataviewBlocks.first(where: { $0.info.key == key }), let presenter = nearestViewController() else { return }
        let controller = DataviewFullScreenController(code: block.info.code, sourcePath: notePath, language: block.info.language)
        controller.onOpenLink = { [weak self] link in self?.onTap?(.wikiLink(link)) }
        presenter.present(controller, animated: true)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if var controller = current as? UIViewController {
                while let presented = controller.presentedViewController { controller = presented }
                return controller
            }
            responder = current.next
        }
        return nil
    }

    /// 點在執行畫面上：交給網頁（不移動游標、不選取文字）；上下拖曳仍然捲動筆記。
    func isOverDataview(_ point: CGPoint) -> Bool {
        dataviewViews.values.contains { !$0.isHidden && $0.frame.contains(point) }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer !== panGestureRecognizer, isOverDataview(gestureRecognizer.location(in: self)) { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        prioritizeInteractionTap()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        prioritizeInteractionTap()
        return became
    }

    /// 點方框、連結時不要移動游標或叫出鍵盤：系統的點擊手勢要等這個手勢確定不處理才動作。
    private func prioritizeInteractionTap() {
        for recognizer in gestureRecognizers ?? [] where recognizer !== interactionTap && recognizer is UITapGestureRecognizer {
            guard prioritized.insert(ObjectIdentifier(recognizer)).inserted else { continue }
            recognizer.require(toFail: interactionTap)
        }
    }

    // MARK: 點擊

    /// 某個位置上會有動作的東西。正在編輯的那一行裡的連結不算（點了是要移動游標）。
    func tapTarget(at point: CGPoint) -> MarkdownTapTarget? {
        let storage = textStorage
        guard storage.length > 0, !isOverDataview(point) else { return nil }
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: inContainer, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < storage.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard line.contains(inContainer) else { return nil }

        func hitRect(_ range: NSRange, slop: CGFloat) -> Bool {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).insetBy(dx: -slop, dy: -slop).contains(inContainer)
        }

        var range = NSRange(location: 0, length: 0)
        if storage.attribute(.mdCheckbox, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil, hitRect(range, slop: 10) {
            return .checkbox(range)
        }
        // 方框在行首：點在方框左右也算
        let lineStart = (storage.string as NSString).lineRange(for: NSRange(location: index, length: 0)).location
        for offset in 0..<min(8, storage.length - lineStart) {
            let candidate = lineStart + offset
            if storage.attribute(.mdCheckbox, at: candidate, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil, hitRect(range, slop: 10) {
                return .checkbox(range)
            }
        }
        if let info = storage.attribute(.mdImage, at: index, effectiveRange: nil) as? MarkdownImageInfo {
            return .image(info.name)
        }
        // 畫成格線表的表格：點到儲存格裡的連結就開啟，其他地方照常移動游標（顯示原始文字）。
        // 表格資訊記在表格第一行的文字上；點在表格右側或下方時對到的是那一行結尾的換行，所以用整行來找
        let tableLine = (storage.string as NSString).lineRange(for: NSRange(location: index, length: 0))
        if let table = (storage.attribute(.mdTable, at: index, effectiveRange: nil)
            ?? storage.attribute(.mdTable, at: tableLine.location, effectiveRange: nil)) as? MarkdownTableInfo {
            let style = storage.attribute(.paragraphStyle, at: tableLine.location, effectiveRange: nil) as? NSParagraphStyle
            return table.link(at: CGPoint(x: inContainer.x - line.minX, y: inContainer.y - line.minY - (style?.paragraphSpacingBefore ?? 0)))
        }
        guard !isEditingLine(containing: index) else { return nil }
        if let target = storage.attribute(.mdWikiLink, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) as? String, hitRect(range, slop: 4) {
            return .wikiLink(target)
        }
        if let url = storage.attribute(.mdLink, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) as? String, hitRect(range, slop: 4) {
            return .link(url)
        }
        return nil
    }

    /// 游標或選取範圍是否在這一行（正在編輯、顯示原始語法的行）。
    private func isEditingLine(containing index: Int) -> Bool {
        guard isFirstResponder else { return false }
        let text = textStorage.string as NSString
        let line = text.lineRange(for: NSRange(location: index, length: 0))
        let endsWithNewline = line.length > 0 && text.character(at: NSMaxRange(line) - 1) == 0x0A
        let contentEnd = NSMaxRange(line) - (endsWithNewline ? 1 : 0)
        let selection = selectedRange
        return selection.location <= contentEnd && NSMaxRange(selection) >= line.location
    }

    @objc private func handleInteractionTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let target = tapTarget(at: recognizer.location(in: self)) else { return }
        onTap?(target)
    }

    private final class TapDelegate: NSObject, UIGestureRecognizerDelegate {
        weak var target: NoteTextView?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let target else { return false }
            return target.tapTarget(at: gestureRecognizer.location(in: target)) != nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(other is UITapGestureRecognizer)
        }
    }

    // MARK: 鍵盤

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let window, let end = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        // 鍵盤位置是螢幕座標；分割畫面或台前調度時視窗不在螢幕原點
        let keyboard = window.windowScene.map { window.convert(end, from: $0.screen.coordinateSpace) } ?? end
        let visible = convert(bounds, to: window)
        // 只算停靠在底部的鍵盤（iPad 浮動鍵盤不會遮住固定位置）
        let docked = keyboard.height > 0 && keyboard.maxY >= window.bounds.maxY - 1
        let overlap = docked ? max(0, visible.maxY - max(keyboard.minY, visible.minY)) : 0
        setKeyboardOverlap(overlap, notification: notification)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        setKeyboardOverlap(0, notification: notification)
    }

    private func setKeyboardOverlap(_ overlap: CGFloat, notification: Notification) {
        guard abs(overlap - keyboardOverlap) > 0.5 else { return }
        keyboardOverlap = overlap
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState]) {
            self.contentInset.bottom = overlap
            self.verticalScrollIndicatorInsets.bottom = overlap
        }
        if overlap > 0, isFirstResponder {
            scrollRangeToVisible(selectedRange)
        }
    }
}

/// 輸入「[[」時鍵盤上方的筆記建議（取代格式工具列）。
private final class LinkSuggestionBar: UIInputView {
    private let stack = UIStackView()
    var onSelect: ((String) -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 46),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ suggestions: [MarkdownEditor.LinkSuggestion]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for suggestion in suggestions {
            var configuration = UIButton.Configuration.gray()
            configuration.title = suggestion.title
            configuration.subtitle = suggestion.detail.isEmpty ? nil : suggestion.detail
            configuration.cornerStyle = .medium
            configuration.baseForegroundColor = .label
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onSelect?(suggestion.linkText) })
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(button)
        }
    }
}

/// Markdown 筆記編輯器：只有一種模式，打字的同時直接顯示排版後的樣子（游標所在的行顯示原始語法）。
/// 點待辦方框打勾、點 [[連結]] 開啟筆記、點手寫區塊繼續編輯；輸入「[[」時列出筆記；
/// 鍵盤上方有格式工具列（AI、手寫、照片）；系統書寫工具與 Apple Pencil 隨手寫照常可用。
struct MarkdownEditor: UIViewRepresentable {
    struct LinkSuggestion: Equatable {
        let title: String
        let detail: String
        /// 插入 [[ ]] 中的文字。
        let linkText: String
    }

    @Binding var text: String
    let controller: MarkdownEditorController
    var onInsertInk: () -> Void
    var onInsertPhoto: () -> Void
    var onAIEdit: () -> Void
    var onOpenLink: (MarkdownTapTarget) -> Void
    var loadImage: (String) async -> UIImage?
    var resolvesLink: (String) -> Bool
    var linkSuggestions: (String) -> [LinkSuggestion]
    /// 浮在上方的標題列高度（見 NoteTextView.headerHeights）。
    var headerHeights: (expanded: CGFloat, collapsed: CGFloat) = (0, 0)
    /// 這則筆記的路徑（DataviewJS 用）。
    var notePath = ""
    /// 捲動距離（0 = 最上面），讓標題跟著縮小。
    var onScroll: (CGFloat) -> Void = { _ in }

    func makeUIView(context: Context) -> NoteTextView {
        let textView = NoteTextView.make()
        textView.delegate = context.coordinator
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.tintColor = LiveMarkdown.Theme.ink
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        // Markdown 不需要智慧引號與破折號
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.writingToolsBehavior = .complete
        textView.text = text
        textView.typingAttributes = LiveMarkdown.Theme.bodyAttributes
        textView.headerHeights = headerHeights
        textView.notePath = notePath
        let coordinator = context.coordinator
        textView.onDataviewHeight = { [weak coordinator, weak textView] key, height in
            DataviewBlockInfo.heights[key] = height
            guard let textView else { return }
            coordinator?.restyle(textView)
        }
        coordinator.toolbar = coordinator.makeToolbar()
        textView.inputAccessoryView = coordinator.toolbar
        textView.onTap = { [weak coordinator] target in coordinator?.handleTap(target) }
        textView.onWidthChange = { [weak coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.restyle(textView)
        }
        controller.textView = textView
        controller.onTextChange = { [weak coordinator] in coordinator?.parent.text = $0 }
        controller.restyle = { [weak coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.restyle(textView)
        }
        coordinator.restyle(textView)
        return textView
    }

    func updateUIView(_ textView: NoteTextView, context: Context) {
        context.coordinator.parent = self
        textView.headerHeights = headerHeights
        textView.notePath = notePath
        if textView.text != text {
            let selection = textView.selectedRange
            textView.text = text
            textView.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
            context.coordinator.restyle(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditor
        var toolbar: UIToolbar?
        private var images: [String: UIImage] = [:]
        private var loading: Set<String> = []
        private var styledSelectionKey: String?
        private var suggestionBar: LinkSuggestionBar?
        private var linkQuery: (range: NSRange, text: String)?

        init(parent: MarkdownEditor) {
            self.parent = parent
        }

        // MARK: 樣式

        func restyle(_ textView: NoteTextView) {
            // 輸入中文等組字時不能改動文字屬性，組字完成後會再呼叫
            guard textView.markedTextRange == nil else { return }
            let selection = textView.isFirstResponder ? textView.selectedRange : nil
            styledSelectionKey = selectionKey(textView)
            let width = max(textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right, 100)
            textView.markdownLayout?.images = images
            let missing = LiveMarkdown.apply(to: textView.textStorage, options: LiveMarkdown.Options(
                selection: selection,
                width: width,
                images: images,
                resolvesLink: parent.resolvesLink,
                dataviewHeights: DataviewBlockInfo.heights,
                rendersDataview: true,
                collapsesProperties: true,
                inlineQueryResults: inlineQueryResults
            ))
            textView.typingAttributes = LiveMarkdown.Theme.bodyAttributes
            textView.refreshDataviewBlocks()
            evaluateMissingInlineQueries(textView)
            for name in missing where !loading.contains(name) {
                loading.insert(name)
                Task { [weak self, weak textView] in
                    guard let self else { return }
                    let image = await self.parent.loadImage(name)
                    self.loading.remove(name)
                    guard let image, let textView else { return }
                    self.images[name] = image
                    self.restyle(textView)
                }
            }
        }

        // MARK: 行內查詢

        /// `= 運算式`、`$= 程式碼` 的結果（這則筆記打開期間有效）。
        private var inlineQueryResults: [String: String] = [:]
        private var pendingInlineQueries: Set<String> = []

        /// 還沒有結果的行內查詢：交給網頁計算，算好後重新排版顯示結果。
        private func evaluateMissingInlineQueries(_ textView: NoteTextView) {
            let missing = LiveMarkdown.inlineQueries(in: textView.text).filter {
                inlineQueryResults[$0.key] == nil && !pendingInlineQueries.contains($0.key)
            }
            guard !missing.isEmpty else { return }
            missing.forEach { pendingInlineQueries.insert($0.key) }
            Task { [weak self, weak textView] in
                guard let textView else { return }
                let results = await textView.evaluateInlineQueries(missing)
                guard let self else { return }
                for (index, query) in missing.enumerated() {
                    self.inlineQueryResults[query.key] = index < results.count ? results[index] : "—"
                    self.pendingInlineQueries.remove(query.key)
                }
                self.restyle(textView)
            }
        }

        /// 游標所在的行有沒有變（換行時才需要重新排版，同一行內移動不用）。
        private func selectionKey(_ textView: UITextView) -> String {
            guard textView.isFirstResponder else { return "-" }
            let text = textView.text as NSString
            let selection = textView.selectedRange
            guard selection.location <= text.length else { return "-" }
            let start = text.lineRange(for: NSRange(location: selection.location, length: 0))
            let end = text.lineRange(for: NSRange(location: min(NSMaxRange(selection), text.length), length: 0))
            // 游標在清單符號上時顯示原始文字，所以也要記下是否在行首附近
            let nearStart = selection.location - start.location < 8
            return "\(start.location)-\(NSMaxRange(end))-\(nearStart)"
        }

        // MARK: UITextViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? NoteTextView else { return }
            parent.onScroll(textView.headerScroll)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let textView = textView as? NoteTextView else { return }
            restyle(textView)
            parent.text = textView.text
            updateLinkSuggestions(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let textView = textView as? NoteTextView else { return }
            if selectionKey(textView) != styledSelectionKey {
                restyle(textView)
            }
            updateLinkSuggestions(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard let textView = textView as? NoteTextView else { return }
            restyle(textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard let textView = textView as? NoteTextView else { return }
            restyle(textView)
            showSuggestions(nil, in: textView)
        }

        // MARK: 點擊

        func handleTap(_ target: MarkdownTapTarget) {
            guard let textView = parent.controller.textView else { return }
            switch target {
            case .checkbox(let range):
                let current = (textView.text as NSString).substring(with: range)
                parent.controller.replace(range: range, with: current.lowercased() == "[x]" ? "[ ]" : "[x]")
            case .link, .wikiLink, .image:
                parent.onOpenLink(target)
            }
        }

        // MARK: [[ 連結建議

        private func updateLinkSuggestions(_ textView: NoteTextView) {
            guard textView.isFirstResponder, textView.markedTextRange == nil, let query = MarkdownEditing.openLinkQuery(in: textView.text, cursor: textView.selectedRange) else {
                linkQuery = nil
                showSuggestions(nil, in: textView)
                return
            }
            linkQuery = query
            showSuggestions(parent.linkSuggestions(query.text), in: textView)
        }

        private func showSuggestions(_ suggestions: [LinkSuggestion]?, in textView: NoteTextView) {
            if let suggestions, !suggestions.isEmpty {
                let bar = suggestionBar ?? LinkSuggestionBar()
                bar.onSelect = { [weak self, weak textView] linkText in
                    guard let self, let textView else { return }
                    self.insertLink(linkText, in: textView)
                }
                bar.update(suggestions)
                suggestionBar = bar
                if textView.inputAccessoryView !== bar {
                    textView.inputAccessoryView = bar
                    textView.reloadInputViews()
                }
            } else if textView.inputAccessoryView !== toolbar {
                textView.inputAccessoryView = toolbar
                textView.reloadInputViews()
            }
        }

        private func insertLink(_ linkText: String, in textView: NoteTextView) {
            guard let query = linkQuery else { return }
            let text = textView.text as NSString
            let after = NSMaxRange(query.range)
            let closed = after + 2 <= text.length && text.substring(with: NSRange(location: after, length: 2)) == "]]"
            parent.controller.replace(range: query.range, with: linkText + (closed ? "" : "]]"))
            textView.selectedRange = NSRange(location: query.range.location + (linkText as NSString).length + 2, length: 0)
            linkQuery = nil
            showSuggestions(nil, in: textView)
        }

        // MARK: 工具列

        func makeToolbar() -> UIToolbar {
            let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            func item(_ symbol: String, _ label: String, _ action: @escaping @MainActor () -> Void) -> UIBarButtonItem {
                let button = UIBarButtonItem(title: nil, image: UIImage(systemName: symbol), primaryAction: UIAction { _ in action() }, menu: nil)
                button.accessibilityLabel = label
                return button
            }
            let controller = parent.controller
            let heading = UIBarButtonItem(title: nil, image: UIImage(systemName: "textformat.size"), primaryAction: nil, menu: UIMenu(children: [
                UIAction(title: "標題 1") { _ in controller.toggleLinePrefix("# ") },
                UIAction(title: "標題 2") { _ in controller.toggleLinePrefix("## ") },
                UIAction(title: "標題 3") { _ in controller.toggleLinePrefix("### ") },
            ]))
            heading.accessibilityLabel = "標題"
            let ai = UIBarButtonItem(title: "AI", primaryAction: UIAction { [weak self] _ in self?.parent.onAIEdit() })
            ai.accessibilityLabel = "請 AI 修改"
            var items: [UIBarButtonItem] = [
                heading,
                item("bold", "粗體") { controller.wrapSelection("**") },
                item("italic", "斜體") { controller.wrapSelection("*") },
                item("list.bullet", "清單") { controller.toggleLinePrefix("- ") },
                item("checklist", "待辦") { controller.toggleLinePrefix("- [ ] ") },
                item("link", "連結") { controller.wrapSelection("[[", closing: "]]") },
                .flexibleSpace(),
            ]
            // 設定 → AI 功能可以關掉筆記的 AI 按鈕
            if AISettings.isOn(AISettings.noteButtonKey) { items.append(ai) }
            items += [
                item("pencil.tip.crop.circle", "手寫區塊") { [weak self] in self?.parent.onInsertInk() },
                item("photo", "照片") { [weak self] in self?.parent.onInsertPhoto() },
                item("keyboard.chevron.compact.down", "收起鍵盤") { controller.dismissKeyboard() },
            ]
            toolbar.items = items
            toolbar.sizeToFit()
            return toolbar
        }
    }
}

/// 編輯器用的純函式（方便測試）。
enum MarkdownEditing {
    /// 游標前面有還沒關閉的「[[」時，回傳 [[ 後面到游標的範圍與文字（輸入中的連結）。
    static func openLinkQuery(in text: String, cursor: NSRange) -> (range: NSRange, text: String)? {
        guard cursor.length == 0 else { return nil }
        let ns = text as NSString
        guard cursor.location <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: cursor.location, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: cursor.location - lineStart))
        guard let open = before.range(of: "[[", options: .backwards) else { return nil }
        let query = String(before[open.upperBound...])
        guard !query.contains("]"), !query.contains("|"), (query as NSString).length <= 80 else { return nil }
        let start = lineStart + (String(before[..<open.upperBound]) as NSString).length
        return (NSRange(location: start, length: cursor.location - start), query)
    }
}
