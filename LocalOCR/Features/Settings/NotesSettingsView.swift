import SwiftUI

/// 筆記與 Obsidian vault 的設定：存放資料夾、vault 名稱、自動同步、連線狀態。
struct NotesSettingsView: View {
    @AppStorage(NotesSettings.Key.vaultFolder) private var vaultFolder = "iPad 筆記"
    @AppStorage(NotesSettings.Key.vaultName) private var vaultName = ""
    @AppStorage(NotesSettings.Key.autoSync) private var autoSync = true
    @Environment(\.openURL) private var openURL
    @State private var status: Status = .unknown

    private enum Status: Equatable {
        case unknown
        case checking
        case connected(fileCount: Int)
        case notConfigured
        case failed(String)
    }

    private static let guideURL = URL(string: "https://github.com/andyyyyang/iOS-APP/blob/claude/ios-local-ocr-dev-pywvch/docs/OBSIDIAN-SYNC.md")!

    var body: some View {
        Form {
            Section {
                TextField("iPad 筆記", text: $vaultFolder)
                    .textInputAutocapitalization(.never)
                Toggle("離開筆記本時自動同步", isOn: $autoSync)
            } header: {
                Text("手寫筆記")
            } footer: {
                Text("每本筆記本存成「\(NotesSettings.vaultFolder)/標題.md」，頁面圖片與可再編輯的原始筆跡放在「\(NotesSettings.attachmentsFolder)」。在 Obsidian 修改過的筆記不會被覆蓋，會另存一份。")
            }

            Section {
                TextField("例如 andy-jentech", text: $vaultName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Obsidian vault 名稱")
            } footer: {
                Text("填入後可以從筆記直接「在 Obsidian 開啟」。名稱與 Obsidian 中 vault 的名稱相同。")
            }

            Section {
                LabeledContent("狀態") {
                    switch status {
                    case .unknown:
                        Text("—").foregroundStyle(.secondary)
                    case .checking:
                        ProgressView()
                    case .connected(let count):
                        Label("已連接（\(count) 個檔案）", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .notConfigured:
                        Text("伺服器尚未設定空間").foregroundStyle(.orange)
                    case .failed(let message):
                        Text(message).foregroundStyle(.red).multilineTextAlignment(.trailing)
                    }
                }
                Button("檢查連線") { Task { await check() } }
                    .disabled(status == .checking || !ServerSettings.isConfigured)
                Button {
                    openURL(Self.guideURL)
                } label: {
                    Label("在 Obsidian 設定 Remotely Save", systemImage: "book")
                }
            } header: {
                Text("Railway 空間")
            } footer: {
                if ServerSettings.isConfigured {
                    Text("Obsidian 端安裝 Remotely Save（S3），填入 Railway Bucket 的 Endpoint、Region auto、金鑰與 Bucket 名稱即可同步；不要開啟端對端加密，否則 App 與 Claude 無法讀取筆記。")
                } else {
                    Text("請先在「設定 → 伺服器與同步」連接伺服器。")
                }
            }
        }
        .navigationTitle("筆記與 Obsidian")
        .task { if ServerSettings.isConfigured { await check() } }
    }

    private func check() async {
        guard let client = VaultClient.configured() else { return }
        status = .checking
        do {
            let state = try await client.status()
            guard state.configured else {
                status = .notConfigured
                return
            }
            let listing = try await client.list(prefix: "", recursive: true)
            status = .connected(fileCount: listing.files.count)
        } catch VaultError.notConfigured {
            status = .notConfigured
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
