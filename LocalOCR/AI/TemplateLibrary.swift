import Foundation
import Observation

/// 管理所有情境樣板：內建 + 伺服器同步 + 使用者自訂。
/// 同一個 id 的優先順序為 自訂 > 伺服器 > 內建，因此可以在伺服器或 App 中覆寫內建情境。
@MainActor
@Observable
final class TemplateLibrary {
    static let shared = TemplateLibrary()

    private(set) var serverTemplates: [ScanTemplate] = []
    private(set) var customTemplates: [ScanTemplate] = []
    private(set) var lastServerSync: Date?

    private let fileURL: URL?

    init(fileURL: URL? = TemplateLibrary.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    /// 合併後的所有情境，內建情境在前。
    var all: [ScanTemplate] {
        var merged: [String: ScanTemplate] = [:]
        for template in ScanTemplate.builtIns + ScanTemplate.bundled + serverTemplates + customTemplates {
            merged[template.id] = template
        }
        let builtInIDs = ScanTemplate.builtIns.map(\.id) + ScanTemplate.bundled.map(\.id)
        let extras = merged.values
            .filter { !builtInIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return builtInIDs.compactMap { merged[$0] } + extras
    }

    func template(id: String?) -> ScanTemplate? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    var fallback: ScanTemplate {
        template(id: ScanTemplate.fallbackID) ?? all[0]
    }

    func saveCustom(_ template: ScanTemplate) {
        var template = template
        template.origin = .custom
        if let index = customTemplates.firstIndex(where: { $0.id == template.id }) {
            template.version = customTemplates[index].version + 1
            customTemplates[index] = template
        } else {
            customTemplates.append(template)
        }
        persist()
    }

    func deleteCustom(id: String) {
        customTemplates.removeAll { $0.id == id }
        persist()
    }

    func replaceServerTemplates(_ templates: [ScanTemplate]) {
        serverTemplates = templates.map { template in
            var template = template
            template.origin = .server
            return template
        }
        lastServerSync = Date()
        persist()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var serverTemplates: [ScanTemplate]
        var customTemplates: [ScanTemplate]
        var lastServerSync: Date?
    }

    nonisolated static var defaultFileURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("templates.json")
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        serverTemplates = snapshot.serverTemplates
        customTemplates = snapshot.customTemplates
        lastServerSync = snapshot.lastServerSync
    }

    private func persist() {
        guard let fileURL else { return }
        let snapshot = Snapshot(serverTemplates: serverTemplates, customTemplates: customTemplates, lastServerSync: lastServerSync)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
