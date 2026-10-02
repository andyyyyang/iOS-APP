import SwiftData
import SwiftUI

@main
struct LocalOCRApp: App {
    init() {
        OCRSettings.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: ScanRecord.self)
    }
}
