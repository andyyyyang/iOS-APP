import SwiftUI

/// 筆記與 Obsidian：配對、同步狀態、這台裝置的 Obsidian 設定、新筆記的位置。
struct NotesSettingsView: View {
    @AppStorage(NotesSettings.Key.defaultFolder) private var defaultFolder = ""
    @AppStorage(NotesSettings.Key.downloadPolicy) private var downloadPolicy = VaultDownloadPolicy.onDemand.rawValue
    @AppStorage(NotesSettings.Key.vaultName) private var vaultName = ""
    @AppStorage(NotesSettings.Key.limitsLineWidth) private var limitsLineWidth = false
    @AppStorage(NotesSettings.Key.autoInkMemo) private var autoInkMemo = true
    @AppStorage(KeyboardDiagnosticsLabel.key) private var showsKeyboardDiagnostics = false
    @AppStorage(JournalAI.privateCloudKey) private var journalPrivateCloud = true
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
            }

            StorageSettingsSection()

            Section {
                Toggle("使用 Private Cloud Compute", isOn: $journalPrivateCloud)
                    .disabled(!JournalAI.isEntitled)
                LabeledContent("狀態", value: JournalAI.cloudStatus)
                if let issue = JournalAI.lastIssue {
                    Text(issue)
                        .font(.footnote)
                        .foregroundStyle(DS.warning)
                }
            } header: {
                Text("日誌整理")
            }

            Section {
                Toggle("限制行寬", isOn: $limitsLineWidth)
                Toggle("自動顯示手寫備忘", isOn: $autoInkMemo)
                Toggle("鍵盤版面診斷", isOn: $showsKeyboardDiagnostics)
            } header: {
                Text("版面")
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
                    Text("上次：下載 \(report.downloaded)、上傳 \(report.uploaded)、刪除 \(report.deleted)\(report.moves.isEmpty ? "" : "、搬移 \(report.moves.count)")\(report.conflicts.isEmpty ? "" : "、衝突 \(report.conflicts.count)")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !sync.failedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(sync.failedFiles.count) 個檔案同步失敗")
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
                        clearedMessage = "已移除 \(count) 個檔案"
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
            }

            Section {
                LabeledContent("新筆記位置") {
                    TextField("vault 最上層", text: $defaultFolder)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent("vault 名稱") {
                    TextField("未設定", text: $vaultName)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("筆記")
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
                obsidianMessage = accepted ? nil : "請先安裝 Obsidian"
            }
        } catch {
            obsidianMessage = error.localizedDescription
        }
    }
}
