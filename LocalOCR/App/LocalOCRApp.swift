import SwiftData
import SwiftUI

@main
struct LocalOCRApp: App {
    @State private var library = TemplateLibrary.shared
    @State private var draft = ScanDraft()

    init() {
        OCRSettings.registerDefaults()
        ServerSettings.registerDefaults()
        // 全新安裝時 Application Support 資料夾不存在，SwiftData 會先輸出大量 CoreData 錯誤再自行修復；預先建立以避免干擾
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(draft)
        }
        .modelContainer(for: ScanRecord.self)
    }
}
