import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(TemplateLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.light.rawValue
    @State private var workspace = Workspace()
    @State private var pairingLink: PairingLinkItem?
    private let reminders = NoteReminderCenter.shared

    var body: some View {
        // 像 Obsidian 的工作區：筆記是主角，掃描、相機、紀錄是附加的工具
        WorkspaceRoot()
            .environment(workspace)
            .tint(DS.primary)
            .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .light).colorScheme)
            .task { await refreshServerTemplates() }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active: VaultSyncCenter.shared.startLiveSync()
                case .background:
                    VaultSyncCenter.shared.stopLiveSync()
                    // 進入背景前把剛存檔、還沒上傳的修改（例如手寫筆跡）傳完：向系統要一點背景時間
                    if VaultSyncCenter.shared.hasPendingPushes {
                        BackgroundWork.run("vault-upload") { await VaultSyncCenter.shared.flushPushes(timeout: 20) }
                    }
                default: break
                }
            }
            // localocr://pair?server=…&code=…（點配對連結或用相機掃描 QR Code）
            .onOpenURL { url in
                if let link = PairingClient.parse(url) {
                    pairingLink = PairingLinkItem(link: link)
                }
            }
            .sheet(item: $pairingLink) { item in
                NavigationStack { PairingView(link: item.link) }
            }
            // 點了提醒的通知：打開那則筆記
            .onChange(of: reminders.openRequest, initial: true) { _, path in
                guard let path else { return }
                reminders.openRequest = nil
                workspace.openNote(path)
            }
    }

    /// 啟動時從伺服器更新情境樣板（失敗時沿用上次的快取）。
    private func refreshServerTemplates() async {
        guard let client = ServerClient.configured(),
              let templates = try? await client.fetchTemplates() else { return }
        library.replaceServerTemplates(templates)
    }
}

#Preview {
    ContentView()
        .environment(TemplateLibrary.shared)
        .environment(ScanDraft())
        .modelContainer(for: ScanRecord.self, inMemory: true)
}

private struct PairingLinkItem: Identifiable {
    let link: PairingClient.Link
    var id: String { link.code }
}
