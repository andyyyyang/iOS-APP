import UIKit
import WebKit

/// 一個 DataviewJS 區塊的執行畫面：WKWebView 跑 DataviewShim，檔案與頁面清單由 App 提供。
/// 上方一列是「DataviewJS」標籤與按鈕（編輯程式碼、重新執行、全螢幕）；高度依內容回報。
@MainActor
final class DataviewView: UIView {
    static let headerHeight: CGFloat = DataviewBlockInfo.headerHeight

    let webView: WKWebView
    private let header = UIStackView()
    private(set) var code = ""
    private(set) var sourcePath = ""
    private var loadedKey: String?

    /// 內容高度（不含上方一列）。
    var onHeight: ((CGFloat) -> Void)?
    var onOpenLink: ((String) -> Void)?
    /// 編輯程式碼（把游標移進區塊，顯示原始文字）。
    var onEdit: (() -> Void)?
    var onFullScreen: (() -> Void)?

    init(showsHeader: Bool = true) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(VaultSchemeHandler.shared, forURLScheme: DataviewShim.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        configuration.userContentController.addScriptMessageHandler(WeakReplyHandler(self), contentWorld: .page, name: "vault")
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.uiDelegate = self
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        addSubview(webView)
        if showsHeader { buildHeader() }
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let top = header.superview == nil ? 0 : Self.headerHeight
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: top)
        webView.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(bounds.height - top, 1))
    }

    /// 內容比可用高度高時，網頁自己捲動。
    func setScrollsContent(_ scrolls: Bool) {
        webView.scrollView.isScrollEnabled = scrolls
    }

    /// 執行（同一段程式碼不重跑，除非 `force`）。
    func load(code: String, sourcePath: String, force: Bool = false) {
        let key = sourcePath + "\u{0}" + code
        guard force || key != loadedKey else { return }
        loadedKey = key
        self.code = code
        self.sourcePath = sourcePath
        let html = DataviewShim.html(code: code, sourcePath: sourcePath, vaultName: NotesSettings.vaultName)
        webView.loadHTMLString(html, baseURL: DataviewShim.baseURL)
    }

    func reload() {
        load(code: code, sourcePath: sourcePath, force: true)
    }

    // MARK: 上方一列

    private func buildHeader() {
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 2
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 4)
        header.backgroundColor = LiveMarkdown.Theme.codeBackground
        let label = UILabel()
        label.text = "DataviewJS"
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = LiveMarkdown.Theme.secondary
        header.addArrangedSubview(label)
        header.addArrangedSubview(UIView())
        header.addArrangedSubview(button("chevron.left.forwardslash.chevron.right", "編輯程式碼") { [weak self] in self?.onEdit?() })
        header.addArrangedSubview(button("arrow.clockwise", "重新執行") { [weak self] in self?.reload() })
        header.addArrangedSubview(button("arrow.up.left.and.arrow.down.right", "全螢幕") { [weak self] in self?.onFullScreen?() })
        addSubview(header)
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        configuration.baseForegroundColor = LiveMarkdown.Theme.secondary
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        return button
    }

    // MARK: 網頁的要求

    fileprivate func handle(_ body: [String: Any]) async throws -> Any? {
        let op = body["op"] as? String ?? ""
        let path = LocalVault.normalize(body["path"] as? String ?? "")
        switch op {
        case "index":
            return DataviewData.index(currentPath: sourcePath)
        case "read":
            guard !path.isEmpty else { throw DataviewError.message("沒有指定檔案") }
            let data = try await DataviewData.read(path)
            return String(decoding: data, as: UTF8.self)
        case "write":
            guard !path.isEmpty, !path.hasPrefix("."), !path.contains("/.") else { throw DataviewError.message("不能寫入這個位置：\(path)") }
            try DataviewData.write(body["text"] as? String ?? "", to: path)
            return nil
        case "exists":
            return DataviewData.exists(path)
        case "list":
            return DataviewData.list(path)
        case "open":
            if let link = body["link"] as? String, !link.isEmpty { onOpenLink?(link) }
            return nil
        case "openURL":
            if let raw = body["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()) {
                _ = await UIApplication.shared.open(url)
            }
            return nil
        case "height":
            if let value = (body["value"] as? NSNumber)?.doubleValue { onHeight?(CGFloat(value)) }
            return nil
        case "copy":
            UIPasteboard.general.string = body["text"] as? String ?? ""
            return nil
        case "paste":
            return UIPasteboard.general.string ?? ""
        default:
            throw DataviewError.message("不支援的操作：\(op)")
        }
    }
}

// MARK: - alert／confirm／prompt

extension DataviewView: WKUIDelegate {
    private var presenter: UIViewController? {
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

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        guard let presenter else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in continuation.resume() })
            presenter.present(alert, animated: true)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard let presenter else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "確定", style: .default) { _ in continuation.resume(returning: true) })
            presenter.present(alert, animated: true)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard let presenter else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in continuation.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: "確定", style: .default) { [weak alert] _ in continuation.resume(returning: alert?.textFields?.first?.text ?? "") })
            presenter.present(alert, animated: true)
        }
    }
}

enum DataviewError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// WKUserContentController 會強引用處理者：用弱引用轉一手，避免畫面無法釋放。
@MainActor
private final class WeakReplyHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: DataviewView?

    init(_ target: DataviewView) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let target, let body = message.body as? [String: Any] else { return (nil, "畫面已關閉") }
        do {
            return (try await target.handle(body), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}

// MARK: - 檔案與頁面清單

/// DataviewJS 讀到的 vault：伺服器的索引（整個 vault）＋這台裝置上的檔案；還沒下載的檔案讀取時才下載。
@MainActor
enum DataviewData {
    static func index(currentPath: String) -> [String: Any] {
        var notes: [[String: Any]] = []
        var seen = Set<String>()
        let indexStore = VaultIndexStore.shared
        for note in indexStore.notes.values {
            seen.insert(note.path)
            notes.append([
                "path": note.path, "title": note.title, "mtime": note.mtime, "size": note.size,
                "tags": note.tags, "aliases": note.aliases, "links": note.links,
                "tasks": note.tasks.map { ["text": $0.text, "done": $0.done] as [String: Any] },
                "properties": note.properties.mapValues(\.jsonObject),
            ])
        }
        // 索引沒有的（WebDAV、還沒同步的新筆記）：用 App 的筆記清單
        for summary in NotesStore.shared.notes where !seen.contains(summary.path) && summary.path.lowercased().hasSuffix(".md") {
            seen.insert(summary.path)
            notes.append([
                "path": summary.path, "title": summary.title, "mtime": summary.mtime.timeIntervalSince1970 * 1000, "size": 0,
                "tags": summary.tags, "aliases": summary.aliases, "links": summary.links,
                "tasks": summary.tasks.map { ["text": $0.text, "done": $0.done] as [String: Any] }, "properties": [String: Any](),
            ])
        }
        // 目前這則筆記不在索引裡、或索引還沒有屬性：用本機的內容
        if let text = LocalVault.shared.readText(currentPath), let index = notes.firstIndex(where: { $0["path"] as? String == currentPath }),
           (notes[index]["properties"] as? [String: Any])?.isEmpty ?? true {
            notes[index]["properties"] = properties(of: text)
        }
        var files: [[String: Any]] = indexStore.files.map { ["path": $0.path, "mtime": $0.mtime, "size": $0.size] as [String: Any] }
        let indexed = Set(files.compactMap { $0["path"] as? String })
        for file in LocalVault.shared.allFiles() where !file.path.lowercased().hasSuffix(".md") && !indexed.contains(file.path) {
            files.append(["path": file.path, "mtime": file.mtime.timeIntervalSince1970 * 1000, "size": file.size])
        }
        return ["notes": notes, "files": files]
    }

    /// 筆記的屬性（frontmatter），值是文字或文字清單。
    static func properties(of text: String) -> [String: Any] {
        guard case .properties(let items)? = MarkdownParser.blocks(from: text).first else { return [:] }
        var result: [String: Any] = [:]
        for item in items where !item.key.isEmpty {
            let value = item.value.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("["), value.hasSuffix("]") {
                result[item.key] = value.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            } else {
                result[item.key] = value.isEmpty ? NSNull() : value
            }
        }
        return result
    }

    static func read(_ path: String) async throws -> Data {
        if LocalVault.shared.exists(path) { return try LocalVault.shared.read(path) }
        let url = try await VaultSyncCenter.shared.download(path)
        return try Data(contentsOf: url)
    }

    static func write(_ text: String, to path: String) throws {
        guard LocalVault.shared.readText(path) != text else { return }
        try LocalVault.shared.writeText(text, to: path)
        VaultSyncCenter.shared.fileDidChange(path)
    }

    static func exists(_ path: String) -> Bool {
        if path.isEmpty { return true }
        if LocalVault.shared.exists(path) { return true }
        let store = VaultIndexStore.shared
        if store.notes[path] != nil || store.files.contains(where: { $0.path == path }) { return true }
        // 資料夾
        let prefix = path + "/"
        return store.notes.keys.contains { $0.hasPrefix(prefix) } || store.files.contains { $0.path.hasPrefix(prefix) }
    }

    /// 一層的檔案與資料夾（adapter.list）。
    static func list(_ folder: String) -> [String: Any] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        var all = Set(VaultIndexStore.shared.notes.keys)
        all.formUnion(VaultIndexStore.shared.files.map(\.path))
        all.formUnion(LocalVault.shared.allFiles().map(\.path))
        var files = Set<String>()
        var folders = Set<String>()
        for path in all where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                folders.insert(prefix + rest[..<slash])
            } else {
                files.insert(path)
            }
        }
        return ["files": files.sorted(), "folders": folders.sorted()]
    }
}

// MARK: - localocr-vault:// 網址（圖片、PDF、readBinary）

/// 網頁中的 `localocr-vault://app/file?path=…`：回傳 vault 中的檔案（還沒下載的先下載）。
@MainActor
final class VaultSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = VaultSchemeHandler()

    /// 已經停止的要求（停止後不能再回應，否則會當掉）。
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == "/file",
              let raw = components.queryItems?.first(where: { $0.name == "path" })?.value else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let path = LocalVault.normalize(raw)
        Task { @MainActor in
            let result: Result<Data, Error>
            do {
                result = .success(try await DataviewData.read(path))
            } catch {
                result = .failure(error)
            }
            // 網頁已經不要這個檔案了：不能再回應
            if self.stopped.remove(id) != nil { return }
            switch result {
            case .success(let data):
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": Self.mimeType(for: path),
                    "Content-Length": String(data.count),
                    "Access-Control-Allow-Origin": "*",
                ])!
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
            case .failure(let error):
                let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain; charset=utf-8"])!
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(Data(error.localizedDescription.utf8))
            }
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(urlSchemeTask))
    }

    nonisolated static func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "json": return "application/json; charset=utf-8"
        case "md", "txt", "csv": return "text/plain; charset=utf-8"
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - 全螢幕

/// 全螢幕執行一個 DataviewJS 區塊（整頁的儀表板在這裡最好用）：上方是關閉與重新執行。
@MainActor
final class DataviewFullScreenController: UIViewController {
    private let code: String
    private let sourcePath: String
    private let dataview = DataviewView(showsHeader: false)
    var onOpenLink: ((String) -> Void)?

    init(code: String, sourcePath: String) {
        self.code = code
        self.sourcePath = sourcePath
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x1C1C1E) : .white }
        let bar = UIStackView()
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 4
        bar.translatesAutoresizingMaskIntoConstraints = false
        let title = UILabel()
        title.text = "DataviewJS"
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .label
        bar.addArrangedSubview(barButton("xmark", "關閉") { [weak self] in self?.dismiss(animated: true) })
        bar.addArrangedSubview(title)
        bar.addArrangedSubview(UIView())
        bar.addArrangedSubview(barButton("arrow.clockwise", "重新執行") { [weak self] in self?.dataview.reload() })
        dataview.layer.cornerRadius = 0
        dataview.translatesAutoresizingMaskIntoConstraints = false
        dataview.setScrollsContent(true)
        dataview.onOpenLink = { [weak self] link in
            self?.dismiss(animated: true) { self?.onOpenLink?(link) }
        }
        view.addSubview(bar)
        view.addSubview(dataview)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: 48),
            dataview.topAnchor.constraint(equalTo: bar.bottomAnchor),
            dataview.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            dataview.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            dataview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        dataview.load(code: code, sourcePath: sourcePath)
    }

    private func barButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }
}
