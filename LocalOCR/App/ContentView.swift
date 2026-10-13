import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(TemplateLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .notes
    @State private var pairingLink: PairingLinkItem?

    var body: some View {
        // 筆記是主要功能；掃描、相機、紀錄是附加的工具。iPad 顯示為側邊欄，iPhone 為底部分頁列。
        TabView(selection: $selectedTab) {
            Tab("筆記", systemImage: "note.text", value: AppTab.notes) {
                NotesHomeView()
            }
            TabSection("工具") {
                Tab("掃描", systemImage: "doc.text.viewfinder", value: AppTab.scan) {
                    ScanView(selectedTab: $selectedTab)
                }
                Tab("相機", systemImage: "camera", value: AppTab.live) {
                    LiveScanView()
                }
                // iPhone 的分頁列放不下：相機可從「掃描」頁進入
                .defaultVisibility(.hidden, for: .tabBar)
                Tab("紀錄", systemImage: "clock.arrow.circlepath", value: AppTab.history) {
                    HistoryView()
                }
            }
            Tab("設定", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
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
