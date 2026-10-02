import SwiftData
import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ScanView()
                .tabItem { Label("辨識", systemImage: "doc.text.viewfinder") }

            LiveScanView()
                .tabItem { Label("即時", systemImage: "camera.viewfinder") }

            HistoryView()
                .tabItem { Label("紀錄", systemImage: "clock.arrow.circlepath") }

            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: ScanRecord.self, inMemory: true)
}
