import SwiftUI

/// 設定 → 筆記與 Obsidian 的「同步空間」：LocalOCR 伺服器（Railway Bucket）或自己的 WebDAV。
struct StorageSettingsSection: View {
    @State private var sync = VaultSyncCenter.shared
    @State private var storage = VaultBackend.storage
    @State private var url = WebDAVSettings.url
    @State private var username = WebDAVSettings.username
    @State private var password = WebDAVSettings.password ?? ""
    @State private var folder = WebDAVSettings.folder
    @State private var showsWebDAVForm = VaultBackend.storage == .webdav
    @State private var testResult: String?
    @State private var testFolders: [String] = []
    @State private var isTesting = false
    @State private var isSwitching = false
    @State private var pendingSwitch: VaultStorage?
    @State private var message: String?

    var body: some View {
        Section {
            LabeledContent("目前使用", value: storage.title)
            if showsWebDAVForm {
                TextField("網址（例如 https://webdav-xxx.up.railway.app）", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("帳號", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密碼", text: $password)
                TextField("vault 所在的資料夾（空白代表最上層）", text: $folder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !testFolders.isEmpty {
                    Picker("從資料夾中選擇", selection: $folder) {
                        Text("最上層").tag("")
                        ForEach(testFolders, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text("測試連線")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isTesting || url.isEmpty || username.isEmpty || password.isEmpty)
                if let testResult {
                    Text(testResult)
                        .font(.footnote)
                        .foregroundStyle(DS.textSecondary)
                }
                Button(storage == .webdav ? "儲存並重新同步" : "改用這個 WebDAV") {
                    pendingSwitch = .webdav
                }
                .disabled(isSwitching || WebDAVSettings.vaultURL(server: url, folder: folder) == nil || username.isEmpty || password.isEmpty)
            } else {
                Button("改用自己的 WebDAV…") { showsWebDAVForm = true }
            }
            if storage == .webdav {
                Button("改回 LocalOCR 伺服器") { pendingSwitch = .server }
                    .disabled(isSwitching)
            }
            if isSwitching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在切換…").foregroundStyle(DS.textSecondary)
                }
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(DS.warning)
            }
        } header: {
            Text("同步空間")
        } footer: {
            Text("vault 可以放在 LocalOCR 伺服器（Railway Bucket，電腦用 Remotely Save 的 S3 同步）或自己的 WebDAV（例如 Railway 上的 WebDAV，電腦用 Remotely Save 的 WebDAV 同步，資料夾預設是 vault 名稱）。WebDAV 本身沒有推送：有配對 LocalOCR 伺服器時仍會即時通知其他裝置，沒有時每分鐘同步一次。切換時會先上傳這台裝置上的修改，再從新的空間重新取得檔案，兩邊的檔案不會混在一起。")
        }
        .confirmationDialog(
            pendingSwitch == .server ? "改回 LocalOCR 伺服器？" : "改用這個 WebDAV？",
            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingSwitch == .server ? "改回伺服器" : "改用 WebDAV") {
                if let target = pendingSwitch { Task { await switchStorage(to: target) } }
                pendingSwitch = nil
            }
        } message: {
            Text("會先把這台裝置上的修改上傳到目前的空間，再清掉這台裝置上已下載的檔案，從新的空間重新取得。原本空間的檔案不受影響。")
        }
    }

    private func saveWebDAVFields() {
        WebDAVSettings.url = url
        WebDAVSettings.username = username
        WebDAVSettings.password = password
        WebDAVSettings.folder = folder
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        testResult = nil
        guard let server = WebDAVSettings.vaultURL(server: url, folder: "") else {
            testResult = "網址格式不正確。"
            return
        }
        let root = WebDAVClient(baseURL: server, username: username, password: password)
        do {
            let items = try await root.testConnection()
            testFolders = items.filter(\.isFolder).map(\.path).filter { !$0.hasPrefix(".") }.sorted()
            // Remotely Save 預設把 vault 放在以 vault 名稱命名的資料夾
            let vaultName = NotesSettings.vaultName
            if folder.isEmpty || !testFolders.contains(folder), !vaultName.isEmpty, testFolders.contains(vaultName) {
                folder = vaultName
            }
            if !folder.isEmpty, let vaultURL = WebDAVSettings.vaultURL(server: url, folder: folder) {
                let inFolder = try await WebDAVClient(baseURL: vaultURL, username: username, password: password).testConnection()
                testResult = "連線成功。「\(folder)」中有 \(inFolder.count) 個項目。"
            } else {
                testResult = "連線成功。最上層有 \(items.count) 個項目\(testFolders.isEmpty ? "" : "，可以在上方選擇 vault 所在的資料夾")。"
            }
        } catch {
            testResult = error.localizedDescription
        }
    }

    private func switchStorage(to target: VaultStorage) async {
        isSwitching = true
        defer { isSwitching = false }
        message = nil
        // 已經在用 WebDAV 但改了網址或資料夾：也要重新開始同步。新的設定要在舊空間同步完之後才存
        let error = await sync.switchStorage(to: target, force: target == .webdav) {
            if target == .webdav { saveWebDAVFields() }
        }
        if let error {
            message = error
            return
        }
        storage = VaultBackend.storage
        showsWebDAVForm = storage == .webdav
    }
}
