import SwiftUI
import UIKit
import XCTest
@testable import LocalOCR

/// 「Probe」工作流程（TEST_RUNNER_JT_SHOT=1）：用假資料畫 JT 甘特，把截圖以 base64 印在記錄裡（[shot] 開頭），
/// 不必下載產物就看得到畫面。資料全部是編的（客戶名只用來顯示 logo），不含任何真實案件。
@MainActor
final class JtScreenshotProbeTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        for key in ["jt.groupMode", "jt.scale", "jt.filter", "jt.collapsedGroups", "jt.owners"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testGanttScreenshots() async throws {
        guard ProcessInfo.processInfo.environment["JT_SHOT"] == "1" else { throw XCTSkip("只在 Probe 工作流程執行") }
        let store = try makeStore()
        let shots: [(name: String, mode: String, scale: String, style: UIUserInterfaceStyle)] = [
            ("customer-dark", "customer", "week", .dark),
            ("etd-light", "etd-asc", "week", .light),
            ("status-day-dark", "status", "day", .dark),
        ]
        for shot in shots {
            UserDefaults.standard.set(shot.mode, forKey: "jt.groupMode")
            UserDefaults.standard.set(shot.scale, forKey: "jt.scale")
            UserDefaults.standard.set("all", forKey: "jt.filter")
            UserDefaults.standard.set("", forKey: "jt.collapsedGroups")
            UserDefaults.standard.set("", forKey: "jt.owners")
            let root = JtGanttView(store: store, query: .constant(""), onOpen: { _ in })
                .background(DS.pane)
            let window = try host(root, style: shot.style)
            try await Task.sleep(for: .seconds(4))
            printShot(shot.name, window)
            window.isHidden = true
            self.window = nil
        }
    }

    // MARK: - 假資料

    private func makeStore() throws -> JtSyncStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "jt-shot-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = JtSyncStore(directory: directory, sendsAutomatically: false)
        let today = JtDayNumber.number(JtDates.string(Date())) ?? 0
        XCTAssertTrue(store.apply(kind: "meta", data: try snapshot("meta", Self.meta(today: today))))
        XCTAssertTrue(store.apply(kind: "cases", data: try snapshot("cases", Self.cases(today: today))))
        return store
    }

    private func snapshot(_ kind: String, _ data: [String: Any]) throws -> Data {
        let object: [String: Any] = ["schema": "jt.v1", "kind": kind, "rev": UUID().uuidString, "generatedAt": 0, "data": data, "clocks": [String: Any]()]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func meta(today: Int) -> [String: Any] {
        let owners: [[String: Any]] = [
            ["id": "demo-a", "name": "業務甲", "initial": "甲", "color": ["bg": "#8c80c2", "fg": "#ffffff"]],
            ["id": "demo-b", "name": "業務乙", "initial": "乙", "color": ["bg": "#c9a078", "fg": "#2a2118"]],
        ]
        return [
            "today": JtDayNumber.string(today),
            "me": "demo-a",
            "owners": owners,
            "customers": [] as [Any],
            "endUsers": [["name": "Nvidia"], ["name": "Apple"]],
            "groupModes": JtMeta.defaultModes.map { ["mode": $0.mode, "label": $0.label] },
        ]
    }

    private static func cases(today: Int) -> [String: Any] {
        let customers = [("Amkor", "amkor.com"), ("AMD-Xilinx", "xilinx.com"), ("Qualcomm", "qualcomm.com")]
        let tones = ["active", "attention", "ready", "active", "attention", "active", "active", "active", "ready", "done", "done", "active"]
        var list: [[String: Any]] = []
        for index in 0..<12 {
            let customer = customers[index % 3]
            let tone = tones[index]
            let start = today - 50 + index * 3
            let end = today - 6 + index * 7
            let days = end - today
            let stat: String
            switch tone {
            case "done": stat = "完成"
            case "ready": stat = "待出貨"
            default: stat = days < 0 ? "逾期 \(-days)d" : (days <= 30 ? "剩 \(days)d" : JtDayNumber.string(end))
            }
            var markers: [[String: Any]] = []
            let count = 2 + index % 5
            for step in 0..<count {
                let day = start + (end - start) * (step + 1) / (count + 1)
                var marker: [String: Any] = ["id": "m-\(index)-\(step)", "type": ["模具", "首試", "品檢", "包裝", "電鍍"][step % 5], "title": "", "date": JtDayNumber.string(day), "done": day < today - 3]
                if step == 1, index % 4 == 1 { marker["origDate"] = JtDayNumber.string(day - 9) }
                markers.append(marker)
            }
            if index == 4 {
                for step in 0..<3 {
                    markers.append(["id": "m-c-\(step)", "type": "品檢", "title": "", "date": JtDayNumber.string(today - 2 + step / 2), "done": false])
                }
            }
            var item: [String: Any] = [
                "id": "demo-\(index)",
                "ownerId": index % 4 == 3 ? "demo-b" : "demo-a",
                "customer": customer.0,
                "customerDomain": customer.1,
                "product": "DEMO-\(1000 + index * 37) 散熱片 \(index + 1) 型 (TEST-\(9000 + index))",
                "model": "DEMO-\(1000 + index * 37)",
                "status": tone == "done" ? "完成" : "進行中",
                "tone": tone,
                "stat": stat,
                "start": JtDayNumber.string(start),
                "end": JtDayNumber.string(end),
                "etd": JtDayNumber.string(end),
                "daysToEtd": days,
                "progressDate": JtDayNumber.string(today),
                "overdueDays": tone == "attention" ? 4 : 0,
                "overdueLabel": tone == "attention" ? "品檢" : "",
                "progress": ["done": count / 2, "total": count],
                "markers": markers,
                "milestones": [] as [Any],
                "note": "",
                "project": index < 4 ? "示範專案" : "",
                "comments": [] as [Any],
            ]
            if index % 3 == 0 { item["endUser"] = ["name": index % 2 == 0 ? "Nvidia" : "Apple", "domain": index % 2 == 0 ? "nvidia.com" : "apple.com"] }
            if index % 5 == 0 { item["wip"] = ["material": "DEMO", "eqp": "M01", "state": "RUN", "text": "生產中", "tone": index == 5 ? "stuck" : "run"] }
            list.append(item)
        }
        let byEnd = list.sorted { ($0["end"] as? String ?? "") < ($1["end"] as? String ?? "") }
        let ids = byEnd.compactMap { $0["id"] as? String }
        func grouped(_ mode: String, key: ([String: Any]) -> String, label: (String) -> String, order: [String]) -> [[String: Any]] {
            var rows: [[String: Any]] = []
            for value in order {
                let members = byEnd.filter { key($0) == value }
                guard !members.isEmpty else { continue }
                let header: [String: Any] = [
                    "type": "group", "id": "grp:\(mode):\(value)", "key": value, "label": label(value),
                    "count": members.count, "attention": members.filter { ($0["tone"] as? String) == "attention" }.count,
                    "start": members.compactMap { $0["start"] as? String }.min() ?? "", "end": members.compactMap { $0["end"] as? String }.max() ?? "",
                    "caseIds": members.compactMap { $0["id"] as? String },
                ]
                rows.append(header)
                rows += members.map { member -> [String: Any] in ["type": "case", "caseId": member["id"] as? String ?? ""] }
            }
            return rows
        }
        let statusTitles = ["attention": "注意", "ready": "待出貨", "active": "進行中", "done": "完成"]
        let flat: [[String: Any]] = ids.map { id -> [String: Any] in ["type": "case", "caseId": id] }
        var layouts: [String: Any] = [:]
        layouts["etd-asc"] = flat
        layouts["project"] = flat
        layouts["customer"] = grouped("customer", key: { $0["customer"] as? String ?? "" }, label: { $0 }, order: ["AMD-Xilinx", "Amkor", "Qualcomm"])
        layouts["status"] = grouped("status", key: { $0["tone"] as? String ?? "" }, label: { statusTitles[$0] ?? $0 }, order: ["attention", "ready", "active", "done"])
        layouts["owner"] = grouped("owner", key: { $0["ownerId"] as? String ?? "" }, label: { $0 }, order: ["demo-a", "demo-b"])
        return ["cases": list, "layouts": layouts]
    }

    // MARK: - 截圖

    private func host<Root: View>(_ root: Root, style: UIUserInterfaceStyle) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, "沒有視窗場景")
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    /// 縮成 1000 點寬的 JPEG，base64 分段印出（[shot] 名稱 序號 內容）。
    private func printShot(_ name: String, _ window: UIWindow) {
        let full = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let width: CGFloat = 1000
        let size = CGSize(width: width, height: full.size.height * width / max(full.size.width, 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            full.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = small.jpegData(compressionQuality: 0.62) else { return }
        let text = Array(data.base64EncodedString().utf8)
        let chunk = 3000
        let count = (text.count + chunk - 1) / chunk
        print("[shot] \(name) begin \(count) \(Int(window.bounds.width))x\(Int(window.bounds.height))")
        for index in 0..<count {
            let slice = text[(index * chunk)..<min((index + 1) * chunk, text.count)]
            print("[shot] \(name) \(index) \(String(decoding: slice, as: UTF8.self))")
        }
        print("[shot] \(name) end")
    }
}
