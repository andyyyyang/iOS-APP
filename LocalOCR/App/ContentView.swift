import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(TemplateLibrary.self) private var library
    @State private var selectedTab: AppTab = .scan

    var body: some View {
        TabView(selection: $selectedTab) {
            ScanView(selectedTab: $selectedTab)
                .tabItem { Label("掃描", systemImage: "doc.text.viewfinder") }
                .tag(AppTab.scan)

            LiveScanView()
                .tabItem { Label("相機", systemImage: "camera") }
                .tag(AppTab.live)

            HistoryView()
                .tabItem { Label("紀錄", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.history)

            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .task { await refreshServerTemplates() }
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
