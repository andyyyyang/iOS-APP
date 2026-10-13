import SwiftUI

/// 筆記與 Obsidian：配對、同步狀態、這台裝置的 Obsidian 設定、新筆記的位置。
struct NotesSettingsView: View {
    @AppStorage(NotesSettings.Key.defaultFolder) private var defaultFolder = ""
    @AppStorage(NotesSettings.Key.downloadAllFiles) private var downloadAllFiles = true
    @AppStorage(NotesSettings.Key.vaultName) private var vaultName = ""
    @AppStorage(ServerSettings.Key.baseURL) private var baseURL = ""
    @Environment(\.openURL) private var openURL
    @State private var sync = VaultSyncCenter.shared
    @State private var showsPairing = false
    @State private var obsidianMessage: String?
    @State private var isOpeningObsidian = false

    private static let guideURL = URL(string: "https://github.com/andyyyyang/iOS-APP/blob/claude/ios-local-ocr-dev-pywvch/docs/OBSIDIAN-SYNC.md")!

    var body: some View {
        Form {
            Section {
                if sync.isConfigured {
                    LabeledContent("伺服器", value: ServerSettings.normalizedURL(baseURL)?.host() ?? "—")
                    if !vaultName.isEmpty {
                        LabeledContent("Obsidian vault", value: vaultName)
                    }
                }
                Button {
                    showsPairing = true
                } label: {
                    Label(sync.isConfigured ? "重新配對" : "與 Obsidian 配對", systemImage: "qrcode.viewfinder")
                }
            } header: {
                Text("配對")
            } footer: {
                Text("在電腦（Windows 或 Mac）的 Obsidian 執行「LocalOCR：配對 iPhone／iPad」，掃描 QR Code 或輸入配對碼即可，不需要輸入網址或金鑰。")
            }

            Section {
                LabeledContent("狀態") {
                    if sync.isSyncing {
                        ProgressView()
                    } else if let error = sync.lastError {
                        Text(error).foregroundStyle(.orange).multilineTextAlignment(.trailing)
                    } else if let date = sync.lastSyncedAt {
                        Text("已同步 \(date.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                    } else {
                        Text("尚未同步").foregroundStyle(.secondary)
                    }
                }
                if let progress = sync.progress {
                    ProgressView("下載中 \(progress.done)/\(progress.total)", value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .font(.footnote)
                }
                if let report = sync.lastReport, !report.isEmpty {
                    Text("上次：下載 \(report.downloaded)、上傳 \(report.uploaded)、刪除 \(report.deleted)\(report.conflicts.isEmpty ? "" : "、衝突 \(report.conflicts.count)（兩份都保留）")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("立即同步") { Task { await sync.syncNow() } }
                    .disabled(!sync.isConfigured || sync.isSyncing)
                if sync.lastError?.contains("為了安全已停止") ?? false {
                    Button("仍要同步（會刪除檔案）", role: .destructive) {
                        Task { await sync.syncNow(allowMassDeletion: true) }
                    }
                }
                Toggle("下載所有檔案", isOn: $downloadAllFiles)
                    .onChange(of: downloadAllFiles) { _, isOn in
                        if isOn { Task { await sync.syncNow() } }
                    }
                if !sync.pendingFiles.isEmpty {
                    LabeledContent("尚未下載", value: "\(sync.pendingFiles.count) 個檔案")
                }
            } header: {
                Text("同步")
            } footer: {
                Text("整個 vault 的所有資料夾與檔案都會同步（.obsidian 設定資料夾除外），存在這台裝置的「檔案」App →「我的 iPad」→「LocalOCR」→「Obsidian」，離線也能使用。開啟 App、修改後與每 3 分鐘會和 Railway 空間同步，電腦的 Obsidian 再透過 Remotely Save 同步；兩邊同時修改同一個檔案時會保留兩份。關閉「下載所有檔案」可節省空間：筆記照常下載，圖片、PDF 等打開時才下載；超過 100 MB 的檔案一律打開時才下載。")
            }

            Section {
                Button {
                    Task { await openObsidianSetup() }
                } label: {
                    HStack {
                        Label("設定這台裝置上的 Obsidian", systemImage: "arrow.up.forward.app")
                        Spacer()
                        if isOpeningObsidian { ProgressView() }
                    }
                }
                .disabled(!sync.isConfigured || vaultName.isEmpty || isOpeningObsidian)
                if let obsidianMessage {
                    Text(obsidianMessage).font(.footnote).foregroundStyle(.orange)
                }
                Button {
                    openURL(Self.guideURL)
                } label: {
                    Label("Obsidian 同步說明", systemImage: "book")
                }
            } header: {
                Text("Obsidian（Remotely Save）")
            } footer: {
                Text("先在這台裝置的 Obsidian 安裝並啟用 Remotely Save，再按上面的按鈕，Obsidian 會自動套用同步設定；套用後請完全關閉並重新開啟 Obsidian，自動同步才會開始。")
            }

            Section {
                LabeledContent("新筆記位置") {
                    TextField("vault 最上層", text: $defaultFolder)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent("vault 名稱") {
                    TextField("配對時自動填入", text: $vaultName)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("筆記")
            } footer: {
                Text("筆記可以放在 vault 的任何資料夾：在資料夾中新增的筆記就放在那個資料夾；從首頁新增的放在「新筆記位置」（空白代表 vault 最上層，也可以填「日記/2026」這樣的路徑）。vault 名稱用來「在 Obsidian 開啟」。")
            }
        }
        .navigationTitle("筆記與 Obsidian")
        .sheet(isPresented: $showsPairing) {
            NavigationStack { PairingView() }
        }
    }

    private func openObsidianSetup() async {
        guard let client = VaultClient.configured() else { return }
        isOpeningObsidian = true
        defer { isOpeningObsidian = false }
        do {
            let uri = try await PairingClient.remotelySaveURI(vaultName: vaultName, client: client)
            openURL(uri) { accepted in
                obsidianMessage = accepted ? nil : "無法開啟 Obsidian，請先安裝 Obsidian。"
            }
        } catch {
            obsidianMessage = error.localizedDescription
        }
    }
}
