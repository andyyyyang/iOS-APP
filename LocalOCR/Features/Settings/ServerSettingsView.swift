import SwiftData
import SwiftUI

struct ServerSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(TemplateLibrary.self) private var library
    @Query(sort: \ScanRecord.createdAt) private var records: [ScanRecord]
    @AppStorage(ServerSettings.Key.baseURL) private var baseURL = ""
    @AppStorage(ServerSettings.Key.autoUpload) private var autoUpload = true
    @State private var apiKey = ServerSettings.apiKey ?? ""
    @State private var status: String?
    @State private var isWorking = false
    @State private var toast: String?

    private var pendingRecords: [ScanRecord] {
        records.filter { $0.syncedAt == nil }
    }

    var body: some View {
        Form {
            Section {
                TextField("https://xxx.up.railway.app", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API 金鑰", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveKey)
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text("測試連線")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }
                .disabled(isWorking || baseURL.isEmpty)
                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("連線")
            } footer: {
                Text("API 金鑰存在 iOS 鑰匙圈。伺服器端的 Jev 金鑰只放在伺服器，不會傳到手機。")
            }

            Section("同步") {
                Toggle("辨識完成後自動上傳", isOn: $autoUpload)
                Button("上傳未同步的紀錄（\(pendingRecords.count)）") {
                    Task { await uploadPending() }
                }
                .disabled(isWorking || pendingRecords.isEmpty || !ServerSettings.isConfigured)
                Button("從伺服器更新情境樣板") {
                    Task { await syncTemplates() }
                }
                .disabled(isWorking || !ServerSettings.isConfigured)
                if let date = library.lastServerSync {
                    LabeledContent("上次更新樣板", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if let url = ServerSettings.baseURL {
                Section {
                    endpointRow("MCP（harness）", "\(url.absoluteString)/mcp")
                    endpointRow("REST API", "\(url.absoluteString)/v1")
                    endpointRow("OpenAPI", "\(url.absoluteString)/v1/openapi.json")
                } header: {
                    Text("接入點")
                } footer: {
                    Text("Claude Code、Obsidian 插件與自建 harness 都使用同一把 API 金鑰（Authorization: Bearer）。")
                }
            }
        }
        .navigationTitle("伺服器與同步")
        .onDisappear(perform: saveKey)
        .toast($toast)
    }

    private func endpointRow(_ title: String, _ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            toast = "已複製 \(title) 網址"
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func saveKey() {
        ServerSettings.apiKey = apiKey
    }

    private func testConnection() async {
        saveKey()
        guard let client = ServerClient.configured() else {
            status = "請輸入正確的網址與 API 金鑰"
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let health = try await client.health()
            let templates = try await client.fetchTemplates()
            library.replaceServerTemplates(templates)
            status = "已連線 · 伺服器 \(health.version) · Jev \(health.jev ? "已設定" : "未設定") · 情境 \(templates.count) 種"
        } catch {
            status = error.localizedDescription
        }
    }

    private func syncTemplates() async {
        guard let client = ServerClient.configured() else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let templates = try await client.fetchTemplates()
            library.replaceServerTemplates(templates)
            toast = "已更新 \(templates.count) 種情境"
        } catch {
            toast = error.localizedDescription
        }
    }

    private func uploadPending() async {
        isWorking = true
        defer { isWorking = false }
        var uploaded = 0
        for record in pendingRecords {
            do {
                try await ScanUploader.upload(record)
                uploaded += 1
            } catch {
                toast = error.localizedDescription
                break
            }
        }
        try? modelContext.save()
        if uploaded > 0 { toast = "已上傳 \(uploaded) 筆" }
    }
}
