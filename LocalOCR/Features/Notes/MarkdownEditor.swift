import SwiftUI
import UIKit

/// Markdown 原始碼的即時樣式：標題、粗體、斜體、程式碼、連結、待辦、標籤、引用、屬性。
/// 文字本身完全不變（仍是 Markdown），只改顯示的字型與顏色。
enum MarkdownHighlighter {
    private static let rules: [(pattern: NSRegularExpression, style: Style)] = {
        func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
            // 樣式規則是固定字串，編譯失敗代表程式錯誤
            try! NSRegularExpression(pattern: pattern, options: options)
        }
        return [
            (regex(#"^(#{1,6})\s.*$"#), .heading),
            (regex(#"^\s*[-*+]\s\[[xX]\]\s.*$"#), .doneTask),
            (regex(#"^\s*[-*+]\s\[\s\]"#), .taskMarker),
            (regex(#"^\s*([-*+]|\d+\.)\s"#), .listMarker),
            (regex(#"^>.*$"#), .quote),
            (regex(#"\*\*[^*\n]+\*\*"#), .bold),
            (regex(#"(?<![*\w])\*[^*\n]+\*(?![*\w])|(?<![_\w])_[^_\n]+_(?![_\w])"#), .italic),
            (regex(#"==[^=\n]+=="#), .highlight),
            (regex(#"`[^`\n]+`"#), .code),
            (regex(#"!?\[\[[^\]\n]+\]\]|\[[^\]\n]+\]\([^)\n]+\)"#), .link),
            (regex(#"(?<![^\s])#[^\s#\d][^\s#]*"#), .tag),
            (regex(#"^```[\s\S]*?^```"#, [.anchorsMatchLines]), .codeBlock),
            (regex(#"\A---\n[\s\S]*?\n---"#, []), .frontmatter),
        ]
    }()

    enum Style {
        case heading, doneTask, taskMarker, listMarker, quote, bold, italic, highlight, code, link, tag, codeBlock, frontmatter
    }

    static var bodyFont: UIFont { UIFont.preferredFont(forTextStyle: .body) }

    static func apply(to storage: NSTextStorage) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        let body = bodyFont
        storage.beginEditing()
        storage.setAttributes([.font: body, .foregroundColor: UIColor.label], range: full)
        for (pattern, style) in rules {
            for match in pattern.matches(in: storage.string, range: full) {
                apply(style, match: match, text: text, storage: storage, body: body)
            }
        }
        storage.endEditing()
    }

    private static func apply(_ style: Style, match: NSTextCheckingResult, text: NSString, storage: NSTextStorage, body: UIFont) {
        let range = match.range
        switch style {
        case .heading:
            let level = match.range(at: 1).length
            let sizes: [UIFont.TextStyle] = [.title1, .title2, .title3, .headline, .headline, .headline]
            let font = UIFont.preferredFont(forTextStyle: sizes[min(level, 6) - 1])
            storage.addAttribute(.font, value: font.withTraits(.traitBold), range: range)
            storage.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: match.range(at: 1))
        case .doneTask:
            storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .taskMarker:
            storage.addAttribute(.foregroundColor, value: UIColor.tintColor, range: range)
        case .listMarker:
            storage.addAttribute(.foregroundColor, value: UIColor.tintColor, range: range)
        case .quote:
            storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
        case .bold:
            storage.addAttribute(.font, value: body.withTraits(.traitBold), range: range)
        case .italic:
            storage.addAttribute(.font, value: body.withTraits(.traitItalic), range: range)
        case .highlight:
            storage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.3), range: range)
        case .code, .codeBlock:
            storage.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: body.pointSize * 0.92, weight: .regular), range: range)
            storage.addAttribute(.backgroundColor, value: UIColor.secondarySystemFill, range: range)
        case .link, .tag:
            storage.addAttribute(.foregroundColor, value: UIColor.tintColor, range: range)
        case .frontmatter:
            storage.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .footnote), range: range)
            storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
        }
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// 讓 SwiftUI 對編輯器下指令（插入內容、加上格式）。
@MainActor
final class MarkdownEditorController {
    fileprivate weak var textView: UITextView?
    fileprivate var onTextChange: ((String) -> Void)?

    var cursorLocation: Int { textView?.selectedRange.location ?? 0 }

    /// 在游標所在處插入一個獨立的一行（例如內嵌的手寫區塊或照片）。
    func insertBlock(_ snippet: String) {
        guard let textView else { return }
        let result = NoteMarkdownEditing.inserting(snippet, into: textView.text, at: textView.selectedRange.location)
        replaceAll(with: result.text, cursor: result.cursor)
    }

    /// 用前後標記包住選取的文字（粗體、斜體…）。
    func wrapSelection(_ marker: String) {
        guard let textView else { return }
        let range = textView.selectedRange
        let selected = (textView.text as NSString).substring(with: range)
        textView.textStorage.replaceCharacters(in: range, with: marker + selected + marker)
        textView.selectedRange = NSRange(location: range.location + (marker as NSString).length, length: range.length)
        changed()
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
        textView.textStorage.replaceCharacters(in: lineRange, with: newLine)
        let delta = (newLine as NSString).length - (line as NSString).length
        textView.selectedRange = NSRange(location: max(lineRange.location, textView.selectedRange.location + delta), length: 0)
        changed()
    }

    func focus() {
        textView?.becomeFirstResponder()
    }

    func dismissKeyboard() {
        textView?.resignFirstResponder()
    }

    private func replaceAll(with text: String, cursor: Int) {
        guard let textView else { return }
        textView.text = text
        MarkdownHighlighter.apply(to: textView.textStorage)
        textView.selectedRange = NSRange(location: min(cursor, (text as NSString).length), length: 0)
        textView.scrollRangeToVisible(textView.selectedRange)
        onTextChange?(text)
    }

    fileprivate func changed() {
        guard let textView else { return }
        MarkdownHighlighter.apply(to: textView.textStorage)
        textView.typingAttributes = [.font: MarkdownHighlighter.bodyFont, .foregroundColor: UIColor.label]
        onTextChange?(textView.text)
    }
}

/// Markdown 編輯器（UITextView）：即時樣式、鍵盤上方的格式工具列、系統書寫工具與 Apple Pencil 隨手寫。
struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController
    var onInsertInk: () -> Void
    var onInsertPhoto: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = MarkdownHighlighter.bodyFont
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 120, right: 16)
        // Markdown 不需要智慧引號與破折號
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.writingToolsBehavior = .complete
        textView.text = text
        MarkdownHighlighter.apply(to: textView.textStorage)
        textView.inputAccessoryView = context.coordinator.makeToolbar()
        controller.textView = textView
        controller.onTextChange = { context.coordinator.parent.text = $0 }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            let selection = textView.selectedRange
            textView.text = text
            MarkdownHighlighter.apply(to: textView.textStorage)
            textView.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditor

        init(parent: MarkdownEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            let selection = textView.selectedRange
            MarkdownHighlighter.apply(to: textView.textStorage)
            textView.selectedRange = selection
            textView.typingAttributes = [.font: MarkdownHighlighter.bodyFont, .foregroundColor: UIColor.label]
            parent.text = textView.text
        }

        @MainActor
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
            toolbar.items = [
                heading,
                item("bold", "粗體") { controller.wrapSelection("**") },
                item("italic", "斜體") { controller.wrapSelection("*") },
                item("list.bullet", "清單") { controller.toggleLinePrefix("- ") },
                item("checklist", "待辦") { controller.toggleLinePrefix("- [ ] ") },
                .flexibleSpace(),
                item("pencil.tip.crop.circle", "手寫區塊") { [weak self] in self?.parent.onInsertInk() },
                item("photo", "照片") { [weak self] in self?.parent.onInsertPhoto() },
                item("keyboard.chevron.compact.down", "收起鍵盤") { controller.dismissKeyboard() },
            ]
            toolbar.sizeToFit()
            return toolbar
        }
    }
}
