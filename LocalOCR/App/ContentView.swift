import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(TemplateLibrary.self) private var library
    @State private var selectedTab: AppTab = UIDevice.current.userInterfaceIdiom == .pad ? .notes : .scan

    var body: some View {
        // iPad 顯示為側邊欄（可收合成上方分頁列），iPhone 顯示為底部分頁列
        TabView(selection: $selectedTab) {
            Tab("筆記", systemImage: "pencil.and.scribble", value: AppTab.notes) {
                NotesLibraryView()
            }
            Tab("Obsidian", systemImage: "books.vertical", value: AppTab.vault) {
                VaultBrowserView()
            }
            TabSection("掃描") {
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
        .modelContainer(for: [ScanRecord.self, Notebook.self], inMemory: true)
}
