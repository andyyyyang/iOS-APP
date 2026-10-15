import SwiftUI

/// 筆記與 Obsidian：配對、同步狀態、這台裝置的 Obsidian 設定、新筆記的位置。
struct NotesSettingsView: View {
    @AppStorage(NotesSettings.Key.defaultFolder) private var defaultFolder = ""
    @AppStorage(NotesSettings.Key.downloadPolicy) private var downloadPolicy = VaultDownloadPolicy.onDemand.rawValue
    @AppStorage(NotesSettings.Key.vaultName) private var vaultName = ""
    @AppStorage(NotesSettings.Key.limitsLineWidth) private var limitsLineWidth = false
    @AppStorage(NotesSettings.Key.autoInkMemo) private var autoInkMemo = true
    @AppStorage(KeyboardDiagnosticsLabel.key) private var showsKeyboardDiagnostics = false
    @AppStorage(ServerSettings.Key.baseURL) private var baseURL = ""
    @Environment(\.openURL) private var openURL
    @State private var sync = VaultSyncCenter.shared
    @State private var showsPairing = false
    @State private var obsidianMessage: String?
    @State private var isOpeningObsidian = false
    @State private var localUsage: Int?
    @State private var clearedMessage: String?

    private static let guideURL = URL(string: "https://github.com/andyyyyang/iOS-APP/blob/claude/ios-local-ocr-dev-pywvch/docs/OBSIDIAN-SYNC.md")!

    var body: some View {
        form
            .task { localUsage = await sync.localUsage() }
    }

    private var form: some View {
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

            StorageSettingsSection()

            Section {
                Toggle("限制行寬（易讀寬度）", isOn: $limitsLineWidth)
                Toggle("開啟筆記時右側欄顯示手寫備忘", isOn: $autoInkMemo)
                Toggle("鍵盤版面診斷（除錯用）", isOn: $showsKeyboardDiagnostics)
            } header: {
                Text("版面")
            } footer: {
                Text("關閉行寬限制時筆記內容跟著畫面全寬自適應（表格與 Dataview 也會用滿寬度）；開啟時每行最寬約 760 點，在大螢幕上比較好讀。手寫備忘每則筆記一份，存在附件資料夾（ink-memo-筆記名稱），可以插入筆記讓 Obsidian 也看得到。鍵盤版面診斷會在右上角顯示鍵盤出現前後視窗與畫面的位置，打開鍵盤時截圖給開發者。")
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
                LabeledContent("即時同步") {
                    Text(sync.isLive ? "已連線" : (sync.isConfigured ? "連線中…" : "未配對"))
                        .foregroundStyle(sync.isLive ? DS.success : DS.textSecondary)
                }
                if let progress = sync.progress {
                    ProgressView("下載中 \(progress.done)/\(progress.total)", value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .font(.footnote)
                }
                if let report = sync.lastReport, !report.isEmpty {
                    Text("上次：下載 \(report.downloaded)、上傳 \(report.uploaded)、刪除 \(report.deleted)\(report.moves.isEmpty ? "" : "、搬移 \(report.moves.count)")\(report.conflicts.isEmpty ? "" : "、衝突 \(report.conflicts.count)（兩份都保留）")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !sync.failedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(sync.failedFiles.count) 個檔案沒有同步（其他檔案已同步，下次會再試）")
                            .foregroundStyle(.orange)
                        ForEach(sync.failedFiles.prefix(5), id: \.self) { failure in
                            Text(failure).foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                }
                Button("立即同步") { Task { await sync.syncNow() } }
                    .disabled(!sync.isConfigured || sync.isSyncing)
                if sync.blockedDeletion != nil {
                    Button("仍要同步（會刪除檔案）", role: .destructive) {
                        Task { await sync.syncNow(allowMassDeletion: true) }
                    }
                }
            } header: {
                Text("同步")
            } footer: {
                Text("與伺服器保持即時推送的連線（WebSocket），不輪詢：正在編輯的筆記停手後約 1 秒上傳，電腦的 Obsidian（LocalOCR 插件 1.5.0 以上）收到通知後立即用 Remotely Save 同步；電腦上修改並上傳後，伺服器也會立刻通知這台裝置。打開 App 與重新連線時會同步一次；兩邊同時修改同一個檔案時會保留兩份。")
            }

            Section {
                Picker("這台裝置上的檔案", selection: $downloadPolicy) {
                    ForEach(VaultDownloadPolicy.allCases) { policy in
                        Text(policy.title).tag(policy.rawValue)
                    }
                }
                .onChange(of: downloadPolicy) { _, _ in
                    Task {
                        await sync.syncNow()
                        localUsage = await sync.localUsage()
                    }
                }
                LabeledContent("已下載", value: localUsage.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                if !sync.pendingFiles.isEmpty {
                    LabeledContent("在雲端", value: "\(sync.pendingFiles.count) 個檔案")
                }
                Button("移除已下載的檔案") {
                    Task {
                        let count = await sync.clearDownloads()
                        localUsage = await sync.localUsage()
                        clearedMessage = "已從這台裝置移除 \(count) 個檔案"
                    }
                }
                .disabled(sync.isSyncing)
                if let clearedMessage {
                    Text(clearedMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("空間")
            } footer: {
                Text("「打開時才下載」只同步檔案清單：筆記與圖片打開時才下載，最近 7 天沒打開的筆記與 1 天沒打開的圖片、PDF 會自動從這台裝置移除（Railway 空間與電腦上的不受影響）。標籤、待辦、反向連結與關聯圖使用伺服器的即時索引，涵蓋整個 vault（不必下載筆記）；內文搜尋也在伺服器上進行。移除已下載的檔案時，開著的筆記與還沒上傳的修改會保留。")
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
        .canvasList()
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
