import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(TemplateLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.light.rawValue
    @State private var workspace = Workspace()
    @State private var pairingLink: PairingLinkItem?

    var body: some View {
        // 像 Obsidian 的工作區：筆記是主角，掃描、相機、紀錄是附加的工具
        WorkspaceView()
            .environment(workspace)
            .tint(DS.primary)
            .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .light).colorScheme)
            .task { await refreshServerTemplates() }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active: VaultSyncCenter.shared.startPeriodicSync()
                case .background: VaultSyncCenter.shared.stopPeriodicSync()
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
