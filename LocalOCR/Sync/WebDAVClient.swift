import Foundation

/// WebDAV 上的一個項目（PROPFIND 的回應）。
struct WebDAVResource: Equatable {
    /// 相對於 vault 資料夾的路徑（不含開頭與結尾的 /）。
    let path: String
    let isFolder: Bool
    let size: Int
    let mtime: Date
    let etag: String
}

enum WebDAVError: LocalizedError {
    case unauthorized
    case http(Int)
    case network(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "WebDAV 帳號或密碼不正確。"
        case .http(let status): return "WebDAV 伺服器回應錯誤（HTTP \(status)）。"
        case .network(let message): return "無法連線到 WebDAV：\(message)"
        case .invalidResponse: return "WebDAV 伺服器的回應格式不正確。"
        }
    }
}

/// WebDAV 的 vault（例如 Railway 上的 rclone WebDAV、NAS、Nextcloud）：同步引擎透過它讀寫檔案。
/// 很多 WebDAV 伺服器不支援 If-Match，所以寫入與刪除前先查目前的版本，版本不符時當成衝突（兩份都保留）。
struct WebDAVClient: VaultRemote {
    /// vault 資料夾的網址（以 / 結尾）。
    let baseURL: URL
    let username: String
    let password: String
    var session: URLSession = .shared

    static func configured() -> WebDAVClient? {
        guard let url = WebDAVSettings.vaultURL, !WebDAVSettings.username.isEmpty, let password = WebDAVSettings.password, !password.isEmpty else { return nil }
        return WebDAVClient(baseURL: url, username: WebDAVSettings.username, password: password)
    }

    // MARK: VaultRemote

    func list(prefix: String, recursive: Bool) async throws -> VaultListing {
        let folder = prefix.hasSuffix("/") || prefix.isEmpty ? prefix : prefix + "/"
        var resources: [WebDAVResource]
        if recursive {
            resources = try await listRecursively(folder)
        } else {
            resources = try await propfind(folder, depth: "1")
        }
        resources.removeAll { $0.path.isEmpty || $0.path + "/" == folder }
        let files = resources.filter { !$0.isFolder }.map { VaultEntry(path: $0.path, size: $0.size, mtime: $0.mtime, etag: $0.etag) }
        let folders = resources.filter(\.isFolder).map { $0.path + "/" }
        return VaultListing(files: files, folders: folders)
    }

    func read(_ path: String) async throws -> VaultFile {
        let (data, response) = try await send("GET", url(for: path))
        switch response.statusCode {
        case 200..<300:
            let mtime = response.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.parseDate)
            let etag = response.value(forHTTPHeaderField: "ETag") ?? Self.syntheticETag(mtime: mtime, size: data.count)
            return VaultFile(data: data, etag: etag, mtime: mtime)
        case 404:
            throw VaultError.notFound
        default:
            throw Self.error(for: response.statusCode)
        }
    }

    @discardableResult
    func write(_ path: String, data: Data, contentType: String, condition: VaultClient.WriteCondition, mtime: Date) async throws -> VaultEntry {
        let current = try await stat(path)
        switch condition {
        case .none:
            break
        case .ifMatch(let etag):
            guard let current, VaultSyncEngine.normalizeETag(current.etag) == VaultSyncEngine.normalizeETag(etag) else {
                throw VaultError.conflict(currentETag: current?.etag)
            }
        case .createOnly:
            if let current { throw VaultError.conflict(currentETag: current.etag) }
        }
        var headers = ["Content-Type": contentType, "X-OC-Mtime": String(Int(mtime.timeIntervalSince1970))]
        if case .createOnly = condition { headers["If-None-Match"] = "*" }
        var (_, response) = try await send("PUT", url(for: path), headers: headers, body: data)
        if response.statusCode == 409 || response.statusCode == 404 {
            // 上層資料夾不存在：建立後再寫一次
            try await createFolders(for: path)
            (_, response) = try await send("PUT", url(for: path), headers: headers, body: data)
        }
        switch response.statusCode {
        case 200..<300:
            break
        case 412:
            throw VaultError.conflict(currentETag: nil)
        default:
            throw Self.error(for: response.statusCode)
        }
        if let written = try await stat(path) {
            return VaultEntry(path: path, size: written.size, mtime: written.mtime, etag: written.etag)
        }
        let etag = response.value(forHTTPHeaderField: "ETag") ?? Self.syntheticETag(mtime: mtime, size: data.count)
        return VaultEntry(path: path, size: data.count, mtime: mtime, etag: etag)
    }

    func delete(_ path: String, ifMatch: String?) async throws {
        if let ifMatch {
            guard let current = try await stat(path) else { throw VaultError.notFound }
            guard VaultSyncEngine.normalizeETag(current.etag) == VaultSyncEngine.normalizeETag(ifMatch) else {
                throw VaultError.conflict(currentETag: current.etag)
            }
        }
        let (_, response) = try await send("DELETE", url(for: path))
        switch response.statusCode {
        case 200..<300: return
        case 404: throw VaultError.notFound
        case 412: throw VaultError.conflict(currentETag: nil)
        default: throw Self.error(for: response.statusCode)
        }
    }

    // MARK: 其他

    /// 單一檔案目前的版本；不存在時回傳 nil。
    func stat(_ path: String) async throws -> VaultEntry? {
        let resources: [WebDAVResource]
        do {
            resources = try await propfind(path, depth: "0")
        } catch VaultError.notFound {
            return nil
        }
        guard let resource = resources.first(where: { !$0.isFolder }) else { return nil }
        return VaultEntry(path: path, size: resource.size, mtime: resource.mtime, etag: resource.etag)
    }

    /// 測試連線：列出 vault 資料夾第一層的項目。
    func testConnection() async throws -> [WebDAVResource] {
        try await propfind("", depth: "1").filter { !$0.path.isEmpty }
    }

    private func listRecursively(_ folder: String) async throws -> [WebDAVResource] {
        // 先試一次列出全部（Depth: infinity）；伺服器不允許時逐層列出
        if let all = try? await propfind(folder, depth: "infinity") {
            return all
        }
        var result: [WebDAVResource] = []
        var pending = [folder]
        while !pending.isEmpty {
            let batch = Array(pending.prefix(6))
            pending.removeFirst(batch.count)
            let listings = try await withThrowingTaskGroup(of: [WebDAVResource].self) { group in
                for item in batch {
                    group.addTask { try await propfind(item, depth: "1") }
                }
                var collected: [[WebDAVResource]] = []
                for try await listing in group { collected.append(listing) }
                return collected
            }
            for listing in listings {
                for resource in listing where !resource.path.isEmpty && !batch.contains(resource.path + "/") {
                    result.append(resource)
                    // . 開頭的資料夾（.obsidian、.trash）不同步，不必往下列
                    if resource.isFolder, !resource.path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                        pending.append(resource.path + "/")
                    }
                }
            }
        }
        return result
    }

    private func propfind(_ path: String, depth: String) async throws -> [WebDAVResource] {
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getlastmodified/><d:getcontentlength/></d:prop></d:propfind>
        """.utf8)
        let (data, response) = try await send("PROPFIND", url(for: path, folder: path.isEmpty || path.hasSuffix("/")), headers: [
            "Depth": depth,
            "Content-Type": "application/xml; charset=utf-8",
        ], body: body)
        switch response.statusCode {
        case 207:
            guard let resources = WebDAVMultistatus.parse(data, basePath: baseURL.path) else { throw WebDAVError.invalidResponse }
            return resources
        case 404:
            throw VaultError.notFound
        default:
            throw Self.error(for: response.statusCode)
        }
    }

    private func createFolders(for path: String) async throws {
        let parts = path.split(separator: "/").dropLast()
        var current = ""
        for part in parts {
            current += part + "/"
            let (_, response) = try await send("MKCOL", url(for: current, folder: true))
            // 201 建立、405 已存在都可以
            guard (200..<300).contains(response.statusCode) || response.statusCode == 405 else {
                throw Self.error(for: response.statusCode)
            }
        }
    }

    /// vault 資料夾中某個路徑的網址（每一段分別編碼）。
    func url(for path: String, folder: Bool = false) -> URL {
        let encoded = path.split(separator: "/").map { segment in
            String(segment).addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? String(segment)
        }.joined(separator: "/")
        let suffix = folder && !encoded.isEmpty ? "/" : ""
        return URL(string: baseURL.absoluteString + encoded + suffix) ?? baseURL
    }

    private static let segmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;"))

    private func send(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw WebDAVError.network(error.localizedDescription)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebDAVError.unauthorized }
        return (result.0, http)
    }

    private static func error(for status: Int) -> Error {
        WebDAVError.http(status)
    }

    /// 伺服器沒有提供 ETag 時，用修改時間與大小代替（任何一個變了就當成改過）。
    static func syntheticETag(mtime: Date?, size: Int) -> String {
        "t\(Int((mtime ?? .distantPast).timeIntervalSince1970))-\(size)"
    }

    static func parseDate(_ value: String) -> Date? {
        httpDate.date(from: value)
    }

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

/// PROPFIND 的 multistatus 回應（純函式，方便測試）。
enum WebDAVMultistatus {
    /// `basePath`：vault 資料夾的網址路徑（解碼後），回傳的路徑相對於它。
    static func parse(_ data: Data, basePath: String) -> [WebDAVResource]? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        let base = "/" + basePath.split(separator: "/").joined(separator: "/")
        return delegate.responses.compactMap { item in
            guard item.ok, let href = item.href else { return nil }
            let decoded = (URL(string: href)?.path ?? href.removingPercentEncoding ?? href)
            let normalized = "/" + decoded.split(separator: "/").joined(separator: "/")
            guard normalized == base || normalized.hasPrefix(base == "/" ? "/" : base + "/") else { return nil }
            let relative = String(normalized.dropFirst(base == "/" ? 1 : base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let mtime = item.lastModified.flatMap(WebDAVClient.parseDate) ?? .distantPast
            let size = Int(item.contentLength ?? "") ?? 0
            let etag = item.etag.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } ?? WebDAVClient.syntheticETag(mtime: mtime, size: size)
            return WebDAVResource(path: LocalVault.normalize(relative), isFolder: item.isCollection, size: size, mtime: mtime, etag: etag)
        }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        struct Response {
            var href: String?
            var isCollection = false
            var etag: String?
            var lastModified: String?
            var contentLength: String?
            /// 這組屬性的 propstat 狀態是 200。
            var ok = true
        }

        var responses: [Response] = []
        private var current: Response?
        private var propstatOK = true
        private var pending = Response()
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch elementName {
            case "response":
                current = Response()
            case "propstat":
                propstatOK = true
                pending = Response()
            case "collection":
                pending.isCollection = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "href":
                if current?.href == nil { current?.href = value }
            case "status":
                // HTTP/1.1 200 OK
                if value.split(separator: " ").dropFirst().first != "200" { propstatOK = false }
            case "getetag":
                pending.etag = value
            case "getlastmodified":
                pending.lastModified = value
            case "getcontentlength":
                pending.contentLength = value
            case "propstat":
                guard var response = current else { break }
                if propstatOK {
                    response.isCollection = response.isCollection || pending.isCollection
                    if let etag = pending.etag { response.etag = etag }
                    if let modified = pending.lastModified { response.lastModified = modified }
                    if let length = pending.contentLength { response.contentLength = length }
                } else if pending.isCollection {
                    response.isCollection = true
                }
                current = response
            case "response":
                if let current { responses.append(current) }
                current = nil
            default:
                break
            }
            text = ""
        }
    }
}

/// WebDAV 的設定（網址、帳號、vault 資料夾存在 UserDefaults，密碼存在鑰匙圈）。
enum WebDAVSettings {
    enum Key {
        static let url = "webdav.url"
        static let username = "webdav.username"
        static let folder = "webdav.folder"
        static let passwordAccount = "webdav.password"
    }

    static var url: String {
        get { UserDefaults.standard.string(forKey: Key.url) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.url) }
    }

    static var username: String {
        get { UserDefaults.standard.string(forKey: Key.username) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.username) }
    }

    /// vault 在 WebDAV 中的資料夾（例如 Remotely Save 預設的 vault 名稱資料夾）；空白代表最上層。
    static var folder: String {
        get { UserDefaults.standard.string(forKey: Key.folder) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.folder) }
    }

    static var password: String? {
        get { KeychainStore.string(for: Key.passwordAccount) }
        set { KeychainStore.set(newValue, for: Key.passwordAccount) }
    }

    /// 伺服器網址加上 vault 資料夾，以 / 結尾。
    static var vaultURL: URL? {
        vaultURL(server: url, folder: folder)
    }

    static func vaultURL(server: String, folder: String) -> URL? {
        var text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        let segments = folder.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;"))) ?? String($0) }
        let path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        guard let url = URL(string: text + path + "/"), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()), url.host() != nil else { return nil }
        return url
    }
}

/// vault 存在哪裡：LocalOCR 伺服器（Railway Bucket，Remotely Save 用 S3 同步）或自己的 WebDAV。
enum VaultStorage: String, CaseIterable, Identifiable {
    case server
    case webdav

    var id: String { rawValue }

    var title: String {
        switch self {
        case .server: return "LocalOCR 伺服器"
        case .webdav: return "WebDAV"
        }
    }
}

enum VaultBackend {
    static let storageKey = "vault.storage"

    static var storage: VaultStorage {
        get { UserDefaults.standard.string(forKey: storageKey).flatMap(VaultStorage.init(rawValue:)) ?? .server }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    /// 目前同步空間的連線；還沒設定時是 nil。
    static func current() -> (any VaultRemote)? {
        switch storage {
        case .server: return VaultClient.configured()
        case .webdav: return WebDAVClient.configured()
        }
    }
}
