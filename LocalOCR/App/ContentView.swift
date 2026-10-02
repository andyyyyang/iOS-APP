import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(TemplateLibrary.self) private var library

    var body: some View {
        TabView {
            ScanView()
                .tabItem { Label("掃描", systemImage: "doc.text.viewfinder") }

            LiveScanView()
                .tabItem { Label("即時", systemImage: "camera.viewfinder") }

            HistoryView()
                .tabItem { Label("紀錄", systemImage: "clock.arrow.circlepath") }

            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
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
        .modelContainer(for: ScanRecord.self, inMemory: true)
}
