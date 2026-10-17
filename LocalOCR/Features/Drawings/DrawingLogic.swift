import Foundation

// 純函式（移植自插件的 core/paths、scanner、customers、capacity、format、theory），方便測試。

// MARK: - 路徑與檔名

enum DrawingPaths {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "svg"]
    static let documentExtensions: Set<String> = ["pdf"]
    static let cadExtensions: Set<String> = ["dwg", "dxf", "step", "stp", "igs", "iges"]

    enum Kind {
        case png, pdf, cad
    }

    static func baseName(_ path: String) -> String {
        // Windows 路徑（PO LIST 的 source）也要吃
        guard let index = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return path }
        return String(path[path.index(after: index)...])
    }

    static func ext(of path: String) -> String {
        let base = baseName(path)
        guard let dot = base.lastIndex(of: ".") else { return "" }
        return base[base.index(after: dot)...].lowercased()
    }

    static func stem(of path: String) -> String {
        let base = baseName(path)
        guard let dot = base.lastIndex(of: ".") else { return base }
        return String(base[..<dot])
    }

    static func kind(of path: String) -> Kind? {
        let ext = ext(of: path)
        if imageExtensions.contains(ext) { return .png }
        if documentExtensions.contains(ext) { return .pdf }
        if cadExtensions.contains(ext) { return .cad }
        return nil
    }

    /// 檔名開頭的機種號（後面接空白／底線／連字號）拿掉。
    static func stripDwgPrefix(_ stem: String, dwg: String) -> String {
        guard !dwg.isEmpty, stem.lowercased().hasPrefix(dwg.lowercased()) else { return stem }
        let rest = stem.dropFirst(dwg.count)
        guard let first = rest.first, first == " " || first == "_" || first == "-" else { return stem }
        return String(rest.drop { $0 == " " || $0 == "_" || $0 == "-" })
    }

    /// 合併鍵：檔名主幹（去掉機種號），底線／空白／連字號一律當成單一空白。
    static func drawingKey(_ path: String, dwg: String) -> String {
        guard !path.isEmpty else { return "" }
        let stripped = stripDwgPrefix(stem(of: path).lowercased().trimmingCharacters(in: .whitespaces), dwg: dwg)
        return stripped.replacingOccurrences(of: #"[\s_-]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// xxx_rot90 / xxx_rot90_ccw -> xxx（旋轉版不另立一筆）
    static func rotationBaseKey(_ key: String) -> String {
        key.replacingOccurrences(of: #"[\s_-]*rot90([\s_-]*ccw)?$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    /// amkor -> Amkor；已經有大寫就不動
    static func prettyCustomer(_ id: String) -> String {
        guard let first = id.first else { return "" }
        if id.contains(where: \.isUppercase) { return id }
        return first.uppercased() + id.dropFirst()
    }
}

// MARK: - 掃描（把資料夾的檔案併進機種的圖面清單）

enum DrawingScanner {
    private struct Group {
        var key: String
        var stem: String
        var png = ""
        var pdf = ""
        var cad = ""
    }

    /// 把資料夾的實際檔案併進 drawings：已登錄的同名檔不重複加，只補缺的格式。
    static func mergeDiskFiles(_ drawings: inout [DrawingRef], files: [String], dwg: String) {
        var groups: [String: Group] = [:]
        var order: [String] = []
        for file in files {
            guard let kind = DrawingPaths.kind(of: file) else { continue }
            let key = DrawingPaths.drawingKey(file, dwg: dwg)
            var group = groups[key] ?? Group(key: key, stem: DrawingPaths.stem(of: file))
            if groups[key] == nil { order.append(key) }
            switch kind {
            case .png: if group.png.isEmpty { group.png = file }
            case .pdf: if group.pdf.isEmpty { group.pdf = file }
            case .cad: if group.cad.isEmpty { group.cad = file }
            }
            groups[key] = group
        }
        var existing = Set(drawings.flatMap { [$0.png, $0.pdf, $0.cad] }.map { DrawingPaths.drawingKey($0, dwg: dwg) }.filter { !$0.isEmpty })

        for key in order {
            guard let group = groups[key] else { continue }
            let rotationBase = DrawingPaths.rotationBaseKey(key)
            if rotationBase != key, groups[rotationBase] != nil || existing.contains(rotationBase) { continue }

            if existing.contains(key) {
                // 已登錄的圖，但資料夾裡多了 catalog 沒寫的格式就補上
                if let index = drawings.firstIndex(where: { DrawingPaths.drawingKey($0.png.isEmpty ? ($0.pdf.isEmpty ? $0.cad : $0.pdf) : $0.png, dwg: dwg) == key }) {
                    if drawings[index].png.isEmpty { drawings[index].png = group.png }
                    if drawings[index].pdf.isEmpty { drawings[index].pdf = group.pdf }
                    if drawings[index].cad.isEmpty { drawings[index].cad = group.cad }
                }
                continue
            }
            let label = DrawingPaths.stripDwgPrefix(group.stem, dwg: dwg)
            drawings.append(DrawingRef(label: label.isEmpty ? group.stem : label, title: group.stem, png: group.png, pdf: group.pdf, cad: group.cad, source: .disk))
            existing.insert(key)
        }
    }

    /// 客戶根目錄的平鋪檔：檔名第一個底線前＝機種號。
    static func flatFileModel(_ file: String) -> String? {
        guard DrawingPaths.kind(of: file) != nil else { return nil }
        let stem = DrawingPaths.stem(of: file)
        let dwg = (stem.firstIndex(of: "_").map { String(stem[..<$0]) } ?? stem).trimmingCharacters(in: .whitespaces)
        return dwg.isEmpty ? nil : dwg
    }

    /// 圖面清單收尾：登錄了但檔案不存在的格式拿掉，看得到的排前面。
    static func finalize(_ drawings: [DrawingRef], existing: Set<String>) -> [DrawingRef] {
        let cleaned = drawings.map { drawing -> DrawingRef in
            var drawing = drawing
            if !drawing.png.isEmpty, !existing.contains(drawing.png) { drawing.png = "" }
            if !drawing.pdf.isEmpty, !existing.contains(drawing.pdf) { drawing.pdf = "" }
            if !drawing.cad.isEmpty, !existing.contains(drawing.cad) { drawing.cad = "" }
            return drawing
        }.filter { !$0.png.isEmpty || !$0.pdf.isEmpty || !$0.cad.isEmpty }
        // 穩定排序：看得到的排前面
        return cleaned.enumerated().sorted { a, b in
            if a.element.isViewable != b.element.isViewable { return a.element.isViewable }
            return a.offset < b.offset
        }.map(\.element)
    }
}

// MARK: - 終端客戶

enum DrawingCustomers {
    /// 客戶圖號字頭 -> 終端客戶（Qualcomm 的型號都是 CV90 開頭）
    static let prefixRules: [(pattern: String, endUser: String)] = [
        (#"\bCV90[-_ ]"#, "Qualcomm"),
    ]

    /// 回傳（終端客戶, 是不是推定的）
    static func endUser(of model: DrawingModel, capacity: CapacityItem?) -> (String, Bool) {
        let declared = model.endUser.trimmingCharacters(in: .whitespaces)
        if !declared.isEmpty { return (declared, false) }
        let haystack = ([model.endUserDwg, model.spec.notes] + (capacity?.orders?.refs ?? [])).joined(separator: " ")
        for rule in prefixRules where haystack.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return (rule.endUser, true)
        }
        return ("", false)
    }

    /// 客戶圖號：catalog 沒寫就從 PO LIST 的物料號碼撈。
    static func customerDwg(of model: DrawingModel, capacity: CapacityItem?) -> (value: String, fromPoList: Bool) {
        let declared = model.endUserDwg.trimmingCharacters(in: .whitespaces)
        if !declared.isEmpty { return (declared, false) }
        for ref in capacity?.orders?.refs ?? [] {
            if let range = ref.range(of: #"CV90[-_ ][A-Z0-9-]+"#, options: [.regularExpression, .caseInsensitive]) {
                return (ref[range].uppercased(), true)
            }
        }
        return ("", false)
    }
}

// MARK: - 產能

enum DrawingCapacity {
    private static let unitAlias: [String: String] = [
        "d": "日", "day": "日", "天": "日", "日": "日",
        "w": "週", "week": "週", "週": "週", "周": "週",
        "班": "班", "h": "時", "時": "時", "月": "月",
    ]

    static func normalizeUnit(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return unitAlias[trimmed.lowercased()] ?? unitAlias[trimmed] ?? ""
    }

    struct Parts: Equatable {
        var num: String
        var mag: String
        var unit: String
        var ok: Bool
    }

    /// 「50K/D」→ 50、K、日；拆不乾淨的照原樣顯示。
    static func splitUnit(_ text: String) -> Parts {
        let raw = text.trimmingCharacters(in: .whitespaces)
        let pattern = #"^([\d.,]+)\s*([KkMm]?)\s*(?:pcs|PCS)?\s*[/／]\s*([A-Za-z\x{4E00}-\x{9FFF}]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let num = Range(match.range(at: 1), in: raw), let mag = Range(match.range(at: 2), in: raw), let unitRange = Range(match.range(at: 3), in: raw) else {
            return Parts(num: raw, mag: "", unit: "", ok: false)
        }
        let unit = normalizeUnit(String(raw[unitRange]))
        guard !unit.isEmpty else { return Parts(num: raw, mag: "", unit: "", ok: false) }
        return Parts(num: String(raw[num]), mag: raw[mag].uppercased(), unit: unit, ok: true)
    }

    private static func parenContent(_ name: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[（(]([^）)]+)[）)]"#),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return "" }
        return name[range].trimmingCharacters(in: .whitespaces)
    }

    private static func isOrdinal(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { "一二三四五六七八九十壹貳參0123456789".contains($0) }
    }

    /// 沖壓(AP01) -> 沖壓（括號是機台）；外觀全檢(一) 不變（括號是序號）
    static func stationBase(_ name: String) -> String {
        let raw = name.trimmingCharacters(in: .whitespaces)
        if isOrdinal(parenContent(raw)) { return raw }
        return raw.replacingOccurrences(of: #"[（(][^）)]*[）)]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static let stampingAliases: Set<String> = ["下料", "下料+沖壓"]
    /// 永遠不開欄的站別
    static let skippedColumns: Set<String> = ["出貨包裝"]
    /// 預設收起來的站別
    static let cncColumn = "CNC產能"

    static func columnID(for station: CapacityStation) -> String {
        let base = stationBase(station.station)
        if stampingAliases.contains(base) { return "沖壓" }
        if base.contains("->"), station.key == "stamping" || base.contains("沖壓") { return "沖壓" }
        return base
    }

    /// 站名括號裡的機台：沖壓(AP01) -> AP01
    static func machine(of name: String) -> String {
        let inner = parenContent(name)
        return isOrdinal(inner) ? "" : inner
    }

    static func machines(for capacity: CapacityItem?, column: String) -> [String] {
        var result: [String] = []
        for station in capacity?.stations ?? [] where columnID(for: station) == column {
            let machine = machine(of: station.station)
            if !machine.isEmpty, !result.contains(machine) { result.append(machine) }
        }
        if let header = capacity?.machines[column], !result.contains(header) { result.append(header) }
        return result
    }

    static let legacyStationLabels: [(key: String, label: String)] = [
        ("stamping", "沖壓"), ("machining", "車削"), ("trimming", "外剪"), ("surface_clean", "清洗噴砂"),
        ("plating", "電鍍"), ("marking", "雷刻"), ("plasma", "電漿"), ("packaging", "包裝"),
    ]
    private static let legacyOrder = ["沖壓", "車削", "外剪", "清洗噴砂", "電鍍", "雷刻", "電漿", "包裝"]

    /// 長流程（下料->拍平->…）標題縮成「頭→尾」
    static func label(for id: String) -> String {
        guard id.contains("->") else { return id }
        let parts = id.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.count > 1 ? "\(parts[0])→\(parts[parts.count - 1])" : id
    }

    /// 站別欄位：從 PO LIST 資料長出來，依「誰在誰前面」的多數決排出製程順序。
    static func columns(models: [DrawingModel], capacity: [String: CapacityItem], showCNC: Bool = false) -> [StationColumn] {
        var skip = skippedColumns
        if !showCNC { skip.insert(cncColumn) }
        var ids: [String] = []
        var idSet = Set<String>()
        var positions: [String: (sum: Double, count: Int)] = [:]
        var unitVotes: [String: [String: Int]] = [:]
        var before: [String: [String: Int]] = [:]

        func add(_ id: String) {
            if idSet.insert(id).inserted { ids.append(id) }
        }

        for item in capacity.values.sorted(by: { $0.dwg < $1.dwg }) {
            var sequence: [String] = []
            let last = Double(max(1, item.stations.count - 1))
            for (index, station) in item.stations.enumerated() {
                let base = columnID(for: station)
                guard !base.isEmpty, !skip.contains(base) else { continue }
                add(base)
                let parts = splitUnit(station.capacity)
                if parts.ok { unitVotes[base, default: [:]]["\(parts.mag)|\(parts.unit)", default: 0] += 1 }
                let position = Double(station.order ?? index) / last
                positions[base, default: (0, 0)].sum += position
                positions[base, default: (0, 0)].count += 1
                if !sequence.contains(base) { sequence.append(base) }
            }
            for i in sequence.indices {
                for j in sequence.indices where j > i {
                    before[sequence[i], default: [:]][sequence[j], default: 0] += 1
                }
            }
        }

        // catalog 才有資料的機種也要有欄位
        for model in models where capacity[model.dwg.uppercased()] == nil {
            for (key, label) in legacyStationLabels where !model.legacyStation(key).isEmpty {
                add(label)
            }
        }

        func averagePosition(_ id: String) -> Double {
            if let entry = positions[id], entry.count > 0 { return entry.sum / Double(entry.count) }
            let index = legacyOrder.firstIndex(of: id) ?? legacyOrder.count
            return 10 + Double(index)
        }

        var edges: [String: Set<String>] = [:]
        var indegree: [String: Int] = [:]
        for id in ids {
            edges[id] = []
            indegree[id] = 0
        }
        for a in ids {
            for b in ids where a != b {
                let ab = before[a]?[b] ?? 0
                let ba = before[b]?[a] ?? 0
                if ab > ba, !(edges[a]?.contains(b) ?? false) {
                    edges[a, default: []].insert(b)
                    indegree[b, default: 0] += 1
                }
            }
        }

        var remaining = Set(ids)
        var ordered: [String] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { indegree[$0, default: 0] == 0 }
            var pool = Array(ready.isEmpty ? remaining : ready)
            pool.sort { averagePosition($0) != averagePosition($1) ? averagePosition($0) < averagePosition($1) : $0 < $1 }
            let pick = pool[0]
            ordered.append(pick)
            remaining.remove(pick)
            for next in edges[pick] ?? [] where remaining.contains(next) {
                indegree[next, default: 1] -= 1
            }
        }

        let legacyByLabel = Dictionary(uniqueKeysWithValues: legacyStationLabels.map { ($0.label, $0.key) })
        return ordered.map { id in
            var column = StationColumn(id: id, label: label(for: id), legacyKey: legacyByLabel[id])
            if let tally = unitVotes[id], let top = tally.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).first?.key {
                let parts = top.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                column.mag = parts.first ?? ""
                column.timeUnit = parts.count > 1 ? parts[1] : ""
                column.unit = "\(column.mag ?? "")/\(column.timeUnit ?? "")"
            }
            return column
        }
    }

    /// 某機種在某一欄要顯示什麼：PO LIST 優先，這個機種 PO LIST 完全沒資料時才用 catalog。
    static func cell(model: DrawingModel, capacity: CapacityItem?, column: StationColumn) -> StationCell {
        let hits = (capacity?.stations ?? []).filter { columnID(for: $0) == column.id }
        var fromCatalog = ""
        if let key = column.legacyKey {
            for candidate in key == "packaging" ? ["packaging_capacity", "packaging"] : [key] {
                fromCatalog = model.legacyStation(candidate)
                if !fromCatalog.isEmpty { break }
            }
        }
        let note = hits.map { [$0.station, $0.note].filter { !$0.isEmpty }.joined(separator: "｜") }.joined(separator: "\n")

        if !hits.isEmpty {
            let withCapacity = hits.filter { !$0.capacity.isEmpty }
            guard !withCapacity.isEmpty else {
                return StationCell(text: "✓", note: note, source: .present, catalogText: "")
            }
            let items = withCapacity.map { StationCell.Item(label: stationBase($0.station), text: $0.capacity, machine: machine(of: $0.station)) }
            let text = items.count > 1 ? items.map { "\($0.label) \($0.text)" }.joined(separator: "／") : items.map(\.text).joined(separator: " / ")
            return StationCell(text: text, note: note, items: items, source: .po, catalogText: fromCatalog)
        }
        let hasPoStations = !(capacity?.stations.isEmpty ?? true)
        if !hasPoStations, !fromCatalog.isEmpty {
            return StationCell(text: fromCatalog, note: "", source: .catalog, catalogText: "")
        }
        return StationCell(text: "-", note: "", source: .missing, catalogText: "")
    }

    /// 儲存格顯示的文字：量級與時間單位跟表頭一樣時只留數字。
    static func displayText(_ text: String, column: StationColumn) -> String {
        let parts = splitUnit(text)
        guard parts.ok, let mag = column.mag, let unit = column.timeUnit, parts.mag == mag, parts.unit == unit else { return text }
        return parts.num
    }

    /// 未結量以 PO LIST 為準。
    static func openQty(model: DrawingModel, capacity: CapacityItem?) -> (qty: Double, fromPoList: Bool, catalogQty: Double, lines: Int) {
        if let orders = capacity?.orders {
            return (orders.openQty, true, model.openQty, orders.openLines)
        }
        return (model.openQty, false, model.openQty, 0)
    }

    /// 製程：蝕刻 / CNC / 沖壓（catalog 手動欄位優先）。
    static func process(model: DrawingModel, capacity: CapacityItem?) -> String {
        let manual = model.manualProcess.trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty { return manual }
        let note = capacity?.processNote ?? ""
        if note.contains("蝕刻") { return "蝕刻" }
        if note.uppercased().contains("CNC") { return "CNC" }
        if note.contains("沖壓") { return "沖壓" }
        let bases = (capacity?.stations ?? []).map(columnID(for:))
        if bases.contains(where: { $0.contains("蝕刻") }) { return "蝕刻" }
        if bases.contains(where: { $0.uppercased().contains("CNC") }) { return "CNC" }
        if bases.contains(where: { $0.contains("沖壓") }) { return "沖壓" }
        if !bases.isEmpty { return "CNC" }
        let cases = capacity?.orders?.cases ?? []
        if cases.contains(where: { $0.uppercased().hasPrefix("T") }) { return "沖壓" }
        if capacity?.orders?.refCNC == true { return "CNC" }
        return ""
    }

    static func latestPo(model: DrawingModel, capacity: CapacityItem?) -> String {
        if let po = capacity?.orders?.latestPo, !po.isEmpty { return po }
        return model.latestPo
    }

    /// 只取真正的站產能數字（括號裡的機台備註拿掉），大小寫與順序不計較。
    static func capacityNumbers(_ text: String) -> [String] {
        let stripped = text.replacingOccurrences(of: #"[（(][^）)]*[）)]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"[\d.~]+[KkMm]?/[DdWwMmHh]"#) else { return [] }
        let found = regex.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)).compactMap { Range($0.range, in: stripped).map { stripped[$0].uppercased() } }
        return Array(Set(found)).sorted()
    }

    /// 兩邊都只有一個產能數字、而且不同才算不一致。
    static func isDifferent(_ cell: StationCell) -> Bool {
        guard cell.source == .po, !cell.catalogText.isEmpty else { return false }
        let a = capacityNumbers(cell.text)
        let b = capacityNumbers(cell.catalogText)
        guard a.count == 1, b.count == 1 else { return false }
        return a[0] != b[0]
    }
}

// MARK: - 理論產能

enum DrawingTheory {
    /// 同一機種列在兩個廠時保留理論產能高的那一筆。
    static func index(_ items: [TheoryItem]) -> [String: TheoryItem] {
        var result: [String: TheoryItem] = [:]
        for item in items {
            let key = item.dwg.uppercased()
            if let current = result[key], current.dailyQty >= item.dailyQty { continue }
            result[key] = item
        }
        return result
    }

    static func description(_ item: TheoryItem, sourceMtime: String?) -> String {
        let n = { (value: Double) in value > 0 ? DrawingFormat.qty(value) : "-" }
        var lines = ["\(item.plant)｜\(item.mold.isEmpty ? "模具未填" : item.mold)｜SPH \(n(item.sphUsed))（SPM \(item.spm > 0 ? DrawingFormat.trim(item.spm, digits: 2) : "-")）"]
        let pct = item.util > 0 ? Int((item.util * 100).rounded()) : 0
        let util = pct > 0 && pct < 100 ? " × \(pct)%" : ""
        if item.dayHours > 0 { lines.append("日班 \(DrawingFormat.trim(item.dayHours, digits: 1))h × \(n(item.sphUsed))\(util) = \(n(item.dayQty))") }
        if item.nightHours > 0 { lines.append("夜班 \(DrawingFormat.trim(item.nightHours, digits: 1))h × \(n(item.sphUsed))\(util) = \(n(item.nightQty))") }
        lines.append("合計 \(n(item.dailyQty)) pcs/日" + (pct > 0 ? (pct < 100 ? "（已含 \(pct)% 稼動率）" : "（未打稼動折扣）") : ""))
        if !item.pressPn.isEmpty { lines.append("沖壓品號 \(item.pressPn)") }
        if !item.note.isEmpty { lines.append("備註：\(item.note)") }
        if item.mismatch { lines.append("⚠ 日夜班稼動率對不起來") }
        if let sourceMtime, !sourceMtime.isEmpty { lines.append("來源：理論產能表 \(sourceMtime)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 格式與搜尋

enum DrawingFormat {
    /// 「22.40 mm」-> 22.4；抓不到數字就 0
    static func dimension(_ text: String) -> Double {
        guard let range = text.range(of: #"[\d.]+"#, options: .regularExpression) else { return 0 }
        return Double(text[range]) ?? 0
    }

    static func qty(_ value: Double) -> String {
        guard value != 0 else { return "0" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value))
    }

    /// 去掉多餘的小數位（22.400 -> 22.4）
    static func trim(_ value: Double, digits: Int) -> String {
        guard value != 0 else { return "-" }
        var text = String(format: "%.\(digits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    /// 搜尋：輸入拆成詞，每個詞都要中（從 PO LIST 複製一格貼過來也查得到）。
    static func matches(_ query: String, in parts: [String]) -> Bool {
        let haystack = parts.filter { !$0.isEmpty }.joined(separator: " ").lowercased()
        let tokens = query.lowercased().components(separatedBy: CharacterSet(charactersIn: " \t\n,;|/\\_")).filter { !$0.isEmpty }
        return tokens.allSatisfy { haystack.contains($0) }
    }
}
