import Foundation

// MARK: - 圖面瀏覽器的資料（移植自 Obsidian 插件「Jentech 圖面瀏覽器」）
//
// 資料都在 vault 裡、透過伺服器在線上讀取（不下載整個資料夾）：
//   assets/data/<客戶>/catalog.json          機種、規格、圖面清單
//   assets/data/<客戶>/capacity.json         PO LIST 抽出的站別產能與未結量（以這份為準）
//   assets/data/<客戶>/theory_capacity.json  沖壓理論產能
//   assets/drawings/<客戶>/<機種>/…           圖面（png / pdf / cad），可含 meta.json
//   assets/drawings/<客戶>/<機種>_<名稱>.pdf  客戶根目錄的平鋪檔

/// 一張圖面：同一主幹的 png / pdf / cad 併成一筆。
struct DrawingRef: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable {
        /// catalog.json 登錄的
        case catalog
        /// 機種資料夾的 meta.json
        case meta
        /// 掃描資料夾補進來的
        case disk
    }

    /// 顯示用短標籤（已去掉機種號前綴）
    var label: String
    /// 完整檔名主幹
    var title: String
    var png: String
    var pdf: String
    var cad: String
    var source: Source

    var id: String { [png, pdf, cad, title].joined(separator: "|") }
    var isViewable: Bool { !pdf.isEmpty || !png.isEmpty }
    var displayLabel: String { label.isEmpty ? (title.isEmpty ? DrawingPaths.stem(of: pdf.isEmpty ? (png.isEmpty ? cad : png) : pdf) : title) : label }
}

/// catalog.json 的規格區塊。
struct ModelSpec: Hashable, Sendable {
    var type = ""
    var length = ""
    var width = ""
    var thickness = ""
    var cavity = ""
    var footWidth = ""
    var material = ""
    var unitPrice = ""
    var quoteDate = ""
    var quoteRef = ""
    var notes = ""

    init() {}

    init(_ object: [String: Any]?) {
        let value = { (key: String) in DrawingJSON.string(object?[key]) }
        type = value("type")
        length = value("length")
        width = value("width")
        thickness = value("thickness")
        cavity = value("cavity")
        footWidth = value("foot_width")
        material = value("material")
        unitPrice = value("unit_price")
        quoteDate = value("quote_date")
        quoteRef = value("quote_ref")
        notes = value("notes")
    }

    var isEmpty: Bool {
        [type, length, width, thickness, cavity, footWidth, material, unitPrice, quoteDate, quoteRef, notes].allSatisfy(\.isEmpty)
    }

    /// 規格表的列（空的不列）。
    var rows: [(label: String, value: String)] {
        [
            ("結構", type), ("長", length), ("寬", width), ("厚", thickness), ("凹槽", cavity), ("腳寬", footWidth),
            ("材質", material), ("單價", unitPrice), ("報價日", quoteDate), ("報價單號", quoteRef),
        ].filter { !$0.1.isEmpty }
    }
}

/// 一個機種：catalog 欄位 + 掃描補齊的圖面。
struct DrawingModel: Identifiable, Hashable, Sendable {
    var dwg: String
    /// 出貨客戶（資料夾）
    var customer = ""
    var sid = ""
    var sap = ""
    var endUser = ""
    /// 終端客戶是用客戶圖號字頭推定的（catalog 沒填）
    var endUserGuessed = false
    var endUserDwg = ""
    var type = ""
    var status = ""
    var openQty: Double = 0
    var latestPo = ""
    var leadTime = ""
    /// catalog 手動填的製程（蝕刻 / CNC / 沖壓）
    var manualProcess = ""
    var spec = ModelSpec()
    var processStations: [String: String] = [:]
    /// catalog 最上層的其他文字欄位（舊版把站別產能放在這裡）
    var fields: [String: String] = [:]
    var drawings: [DrawingRef] = []
    /// catalog.json 有沒有這一筆（沒有＝只在資料夾裡看到圖）
    var hasCatalog = false

    var id: String { customer + "/" + dwg }
    var previewCount: Int { drawings.filter(\.isViewable).count }

    init(dwg: String) {
        self.dwg = dwg
    }

    /// 從 catalog.json 的一筆建立。
    init?(catalog object: [String: Any]) {
        let dwg = DrawingJSON.string(object["dwg"]).trimmingCharacters(in: .whitespaces)
        guard !dwg.isEmpty else { return nil }
        self.dwg = dwg
        hasCatalog = true
        apply(object, onlyMissing: false)
        drawings = (object["drawings"] as? [[String: Any]] ?? []).map { DrawingRef(object: $0, source: .catalog) }
    }

    /// 套用 catalog 或 meta.json 的欄位；`onlyMissing` 時只補空的欄位。
    mutating func apply(_ object: [String: Any], onlyMissing: Bool) {
        func set(_ keyPath: WritableKeyPath<DrawingModel, String>, _ key: String) {
            let value = DrawingJSON.string(object[key])
            guard !value.isEmpty, !onlyMissing || self[keyPath: keyPath].isEmpty else { return }
            self[keyPath: keyPath] = value
        }
        set(\.sid, "sid")
        set(\.sap, "sap")
        set(\.endUser, "end_user")
        set(\.endUserDwg, "end_user_dwg")
        set(\.type, "type")
        set(\.status, "status")
        set(\.latestPo, "latest_po")
        set(\.leadTime, "lead_time")
        set(\.manualProcess, "process")
        if let qty = DrawingJSON.number(object["open_qty"]), !onlyMissing || openQty == 0 { openQty = qty }
        if let spec = object["spec"] as? [String: Any], !onlyMissing || self.spec.isEmpty { self.spec = ModelSpec(spec) }
        if let stations = object["process_stations"] as? [String: Any] {
            for (key, value) in stations where !onlyMissing || processStations[key] == nil {
                let text = DrawingJSON.string(value)
                if !text.isEmpty { processStations[key] = text }
            }
        }
        for (key, value) in object where !["dwg", "spec", "drawings", "process_stations"].contains(key) {
            let text = DrawingJSON.string(value)
            if !text.isEmpty, !onlyMissing || fields[key] == nil { fields[key] = text }
        }
    }

    /// catalog 的舊站別欄位（process_stations 或最上層）。
    func legacyStation(_ key: String) -> String {
        let value = (processStations[key] ?? fields[key] ?? "").trimmingCharacters(in: .whitespaces)
        return value == "-" ? "" : value
    }
}

extension DrawingRef {
    init(object: [String: Any], source: Source) {
        label = DrawingJSON.string(object["label"])
        title = DrawingJSON.string(object["title"])
        png = DrawingJSON.string(object["png"])
        pdf = DrawingJSON.string(object["pdf"])
        cad = DrawingJSON.string(object["cad"])
        self.source = source
    }
}

/// capacity.json 的單一站別。
struct CapacityStation: Hashable, Sendable {
    var station: String
    /// 空字串＝PO LIST 有這一站但沒填產能
    var capacity: String
    var note: String
    /// 在 PO LIST 表頭的先後（製程順序）
    var order: Int?
    var key: String
}

/// capacity.json 的訂單彙總。
struct CapacityOrders: Hashable, Sendable {
    var openQty: Double = 0
    var orderedQty: Double = 0
    var shippedQty: Double = 0
    var openLines = 0
    var latestPo = ""
    var unitPrice = ""
    var sheets: [String] = []
    /// 開案單號：T＝模具案、S＝樣品單
    var cases: [String] = []
    /// 物料號碼寫成 _CNC
    var refCNC = false
    var poNumbers: [String] = []
    var salesDocs: [String] = []
    var refs: [String] = []
}

struct HiddenOrders: Hashable, Sendable {
    var openQty: Double
    var openLines: Int
    var latestPo: String
    var sheets: [String]
}

/// capacity.json 的單一機種。
struct CapacityItem: Hashable, Sendable {
    var dwg: String
    var sid = ""
    var sap = ""
    var endUser = ""
    var sheet = ""
    var stations: [CapacityStation] = []
    /// 表頭左側另外列的機台（站別名 -> 機台）
    var machines: [String: String] = [:]
    var processNote = ""
    /// PO LIST 的分頁已隱藏＝已結案的歷史機種
    var archived = false
    var archivedReason = ""
    var hiddenOrders: HiddenOrders?
    var orders: CapacityOrders?

    init(dwg: String) {
        self.dwg = dwg
    }

    init?(object: [String: Any]) {
        let dwg = DrawingJSON.string(object["dwg"]).trimmingCharacters(in: .whitespaces)
        guard !dwg.isEmpty else { return nil }
        self.dwg = dwg
        sid = DrawingJSON.string(object["sid"])
        sap = DrawingJSON.string(object["sap"])
        endUser = DrawingJSON.string(object["end_user"])
        sheet = DrawingJSON.string(object["sheet"])
        stations = (object["stations"] as? [[String: Any]] ?? []).map { station in
            CapacityStation(
                station: DrawingJSON.string(station["station"]),
                capacity: DrawingJSON.string(station["capacity"]),
                note: DrawingJSON.string(station["note"]),
                order: DrawingJSON.number(station["order"]).map { Int($0) },
                key: DrawingJSON.string(station["key"])
            )
        }
        machines = (object["machines"] as? [String: Any] ?? [:]).compactMapValues { value in
            let text = DrawingJSON.string(value)
            return text.isEmpty ? nil : text
        }
        processNote = DrawingJSON.string(object["process_note"])
        archived = object["archived"] as? Bool ?? false
        archivedReason = DrawingJSON.string(object["archived_reason"])
        if let hidden = object["hidden_orders"] as? [String: Any] {
            hiddenOrders = HiddenOrders(
                openQty: DrawingJSON.number(hidden["open_qty"]) ?? 0,
                openLines: Int(DrawingJSON.number(hidden["open_lines"]) ?? 0),
                latestPo: DrawingJSON.string(hidden["latest_po"]),
                sheets: DrawingJSON.strings(hidden["sheets"])
            )
        }
        if let orders = object["orders"] as? [String: Any] {
            self.orders = CapacityOrders(
                openQty: DrawingJSON.number(orders["open_qty"]) ?? 0,
                orderedQty: DrawingJSON.number(orders["ordered_qty"]) ?? 0,
                shippedQty: DrawingJSON.number(orders["shipped_qty"]) ?? 0,
                openLines: Int(DrawingJSON.number(orders["open_lines"]) ?? 0),
                latestPo: DrawingJSON.string(orders["latest_po"]),
                unitPrice: DrawingJSON.string(orders["unit_price"]),
                sheets: DrawingJSON.strings(orders["sheets"]),
                cases: DrawingJSON.strings(orders["cases"]),
                refCNC: orders["ref_cnc"] as? Bool ?? false,
                poNumbers: DrawingJSON.strings(orders["po_numbers"]),
                salesDocs: DrawingJSON.strings(orders["sales_docs"]),
                refs: DrawingJSON.strings(orders["refs"])
            )
        }
    }
}

/// capacity.json 的檔頭（資料來源）。
struct CapacityMeta: Hashable, Sendable {
    var customer = ""
    var source = ""
    var sourceMtime = ""
    var extractedAt = ""
    var dedupRows = 0
    var dedupQty: Double = 0
    var hiddenNote = ""
    var hiddenTotalOpenQty: Double = 0
    var hiddenModels: [String: Double] = [:]

    init(object: [String: Any]) {
        customer = DrawingJSON.string(object["customer"])
        source = DrawingJSON.string(object["source"])
        sourceMtime = DrawingJSON.string(object["source_mtime"])
        extractedAt = DrawingJSON.string(object["extracted_at"])
        dedupRows = Int(DrawingJSON.number(object["dedup_rows"]) ?? 0)
        dedupQty = DrawingJSON.number(object["dedup_qty"]) ?? 0
        if let hidden = object["hidden_summary"] as? [String: Any] {
            hiddenNote = DrawingJSON.string(hidden["note"])
            hiddenTotalOpenQty = DrawingJSON.number(hidden["total_open_qty"]) ?? 0
            hiddenModels = (hidden["models"] as? [String: Any] ?? [:]).compactMapValues { DrawingJSON.number($0) }
        }
    }
}

/// theory_capacity.json 的一列：某機種在某廠的沖壓理論產能。
struct TheoryItem: Hashable, Sendable {
    var dwg: String
    /// 廠別（華亞／無錫）
    var plant: String
    var pressPn: String
    /// 連續模／傳送模／工程模
    var mold: String
    var sph: Double
    var spm: Double
    var sphUsed: Double
    var dayHours: Double
    var dayQty: Double
    var nightHours: Double
    var nightQty: Double
    /// 日班 + 夜班
    var dailyQty: Double
    /// 稼動率：華亞 0.8、無錫 1.0
    var util: Double
    var mismatch: Bool
    var note: String

    init?(object: [String: Any]) {
        let dwg = DrawingJSON.string(object["dwg"]).trimmingCharacters(in: .whitespaces)
        guard !dwg.isEmpty else { return nil }
        self.dwg = dwg
        let number = { (key: String) in DrawingJSON.number(object[key]) ?? 0 }
        plant = DrawingJSON.string(object["plant"])
        pressPn = DrawingJSON.string(object["press_pn"])
        mold = DrawingJSON.string(object["mold"])
        sph = number("sph")
        spm = number("spm")
        sphUsed = number("sph_used")
        dayHours = number("day_hours")
        dayQty = number("day_qty")
        nightHours = number("night_hours")
        nightQty = number("night_qty")
        dailyQty = number("daily_qty")
        util = number("util")
        mismatch = object["mismatch"] as? Bool ?? false
        note = DrawingJSON.string(object["note"])
    }
}

/// 某機種某一站要顯示的產能。
struct StationCell: Hashable, Sendable {
    enum Source: String, Sendable {
        /// PO LIST 有產能
        case po
        /// 有這一站但沒填產能
        case present
        /// catalog 後備
        case catalog
        /// 沒有這一站
        case missing
    }

    struct Item: Hashable, Sendable {
        var label: String
        var text: String
        var machine: String
    }

    var text: String
    var note: String
    /// 併到同一欄的多個站（下料 + 沖壓）
    var items: [Item] = []
    var source: Source
    /// source = po 時，catalog 舊值（用來標 ≠）
    var catalogText: String
}

/// 產能清單的一欄（一個站別）。
struct StationColumn: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    /// 多數機種用的量級＋時間單位（K/日），寫在表頭
    var unit: String?
    var mag: String?
    var timeUnit: String?
    /// 對得上 catalog 舊欄位的鍵
    var legacyKey: String?
}

/// 客戶選單的一項：全部、出貨客戶（資料夾）、終端客戶（機種上的 end_user）。
struct DrawingScope: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case all, ship, end
    }

    /// all｜ship:<資料夾>｜end:<終端客戶>
    var id: String
    var label: String
    var kind: Kind
    var count: Int
}

/// JSON 值轉成字串／數字（catalog 的欄位型別不一定）。
enum DrawingJSON {
    static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let double = number.doubleValue
            return double == double.rounded() && abs(double) < 1e15 ? String(Int64(double)) : String(double)
        default: return ""
        }
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : number.doubleValue
        case let text as String:
            return Double(text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).map { string($0) }.filter { !$0.isEmpty }
    }
}
