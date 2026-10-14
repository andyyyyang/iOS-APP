import XCTest
@testable import LocalOCR

final class DrawingsTests: XCTestCase {
    // MARK: - 路徑與合併

    func testDrawingKeysIgnorePrefixAndSeparators() {
        XCTAssertEqual(DrawingPaths.stripDwgPrefix("0850232SF_Rev A", dwg: "0850232SF"), "Rev A")
        XCTAssertEqual(DrawingPaths.stripDwgPrefix("0850232SFX", dwg: "0850232SF"), "0850232SFX", "後面不是分隔符號就不是機種號")
        let a = DrawingPaths.drawingKey("assets/drawings/amkor/0850601SF 09_10_26.pdf", dwg: "0850601SF")
        let b = DrawingPaths.drawingKey("assets/drawings/amkor/0850601SF/0850601SF_09_10_26.png", dwg: "0850601SF")
        XCTAssertEqual(a, "09 10 26")
        XCTAssertEqual(a, b)
        XCTAssertEqual(DrawingPaths.rotationBaseKey(DrawingPaths.drawingKey("x/0850223HS_0850223HSC_rot90.png", dwg: "0850223HS")), "0850223hsc")
        XCTAssertEqual(DrawingPaths.prettyCustomer("amkor"), "Amkor")
        XCTAssertEqual(DrawingPaths.prettyCustomer("AMD-Xilinx"), "AMD-Xilinx")
        XCTAssertEqual(DrawingScanner.flatFileModel("assets/drawings/amkor/0850232SF_4560022532.pdf"), "0850232SF")
        XCTAssertNil(DrawingScanner.flatFileModel("assets/drawings/amkor/notes.txt"))
    }

    func testMergeDiskFilesGroupsFormatsAndSkipsRotatedCopies() {
        var drawings: [DrawingRef] = []
        DrawingScanner.mergeDiskFiles(&drawings, files: [
            "a/0850223HS_0850223HSC.pdf",
            "a/0850223HS_0850223HSC_rot90.png",
            "a/0850223HS_Quote.pdf",
            "a/meta.json",
        ], dwg: "0850223HS")
        XCTAssertEqual(drawings.map(\.label), ["0850223HSC", "Quote"])
        XCTAssertEqual(drawings[0].pdf, "a/0850223HS_0850223HSC.pdf")
        XCTAssertEqual(drawings[0].source, .disk)

        var registered = [DrawingRef(label: "健策圖", title: "", png: "a/0850223HS_0850223HSC.png", pdf: "", cad: "", source: .catalog)]
        DrawingScanner.mergeDiskFiles(&registered, files: ["a/0850223HS_0850223HSC.pdf"], dwg: "0850223HS")
        XCTAssertEqual(registered.count, 1, "已登錄的同一張圖只補上缺的格式")
        XCTAssertEqual(registered[0].pdf, "a/0850223HS_0850223HSC.pdf")
    }

    func testFinalizeDropsMissingFilesAndPutsViewableFirst() {
        let drawings = [
            DrawingRef(label: "CAD", title: "", png: "", pdf: "", cad: "x.dwg", source: .disk),
            DrawingRef(label: "登錄但沒有檔案", title: "", png: "missing.png", pdf: "", cad: "", source: .catalog),
            DrawingRef(label: "圖", title: "", png: "missing.png", pdf: "a.pdf", cad: "", source: .catalog),
        ]
        let result = DrawingScanner.finalize(drawings, existing: ["x.dwg", "a.pdf"])
        XCTAssertEqual(result.map(\.label), ["圖", "CAD"])
        XCTAssertEqual(result[0].png, "")
        XCTAssertTrue(result[0].isViewable)
    }

    func testParsesCatalogEntries() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("""
        {"dwg":"0850664HS","sid":"101422224","sap":60010056,"end_user":"Qualcomm","end_user_dwg":"CV90-38258-1A","open_qty":4947454,
         "type":"FlatTop","spec":{"length":"22.40 mm","width":"22.40 mm","thickness":"1.190 mm","unit_price":"USD $0.423"},
         "drawings":[{"label":"健策工程圖","png":"assets/drawings/amkor/0850664HS/a.png","pdf":"assets/drawings/amkor/0850664HS/a.pdf"}],
         "process_stations":{"stamping":"沖壓(無錫): 50K/D (一台50K/D，有2套)","trimming":"-"},"packaging_capacity":"裝管: 80K/D"}
        """.utf8)) as? [String: Any])
        let model = try XCTUnwrap(DrawingModel(catalog: object))
        XCTAssertEqual(model.dwg, "0850664HS")
        XCTAssertEqual(model.sap, "60010056", "數字欄位也轉成文字")
        XCTAssertEqual(model.openQty, 4_947_454)
        XCTAssertEqual(model.spec.thickness, "1.190 mm")
        XCTAssertEqual(model.drawings.first?.source, .catalog)
        XCTAssertTrue(model.hasCatalog)
        XCTAssertEqual(model.legacyStation("trimming"), "", "「-」當成沒有")
        XCTAssertEqual(model.legacyStation("packaging_capacity"), "裝管: 80K/D")
    }

    // MARK: - 終端客戶

    func testGuessesEndUserFromCustomerDrawingNumber() {
        var model = DrawingModel(dwg: "0851564HS")
        model.endUserDwg = "CV90-94312-1A"
        let guess = DrawingCustomers.endUser(of: model, capacity: nil)
        XCTAssertEqual(guess.0, "Qualcomm")
        XCTAssertTrue(guess.1)

        var capacity = CapacityItem(dwg: "0851564HS")
        capacity.orders = CapacityOrders(refs: ["101434673_0851564HS_44.6X57.6T3.038/CV90-94312-1A"])
        let bare = DrawingModel(dwg: "0851564HS")
        XCTAssertEqual(DrawingCustomers.customerDwg(of: bare, capacity: capacity).value, "CV90-94312-1A")
        XCTAssertTrue(DrawingCustomers.customerDwg(of: bare, capacity: capacity).fromPoList)
    }

    // MARK: - 產能

    func testSplitsCapacityUnits() {
        XCTAssertEqual(DrawingCapacity.splitUnit("50K/D"), .init(num: "50", mag: "K", unit: "日", ok: true))
        XCTAssertEqual(DrawingCapacity.splitUnit("1,200 pcs/班").unit, "班")
        XCTAssertFalse(DrawingCapacity.splitUnit("25-30").ok)
        XCTAssertFalse(DrawingCapacity.splitUnit("1.8~2kpcs/班").ok)
    }

    func testStationNamesAndColumns() {
        XCTAssertEqual(DrawingCapacity.stationBase("沖壓(AP01)"), "沖壓")
        XCTAssertEqual(DrawingCapacity.stationBase("外觀全檢(一)"), "外觀全檢(一)", "括號是序號時保留")
        XCTAssertEqual(DrawingCapacity.machine(of: "沖壓(AP01)"), "AP01")
        XCTAssertEqual(DrawingCapacity.machine(of: "外觀全檢(一)"), "")
        XCTAssertEqual(DrawingCapacity.columnID(for: station("下料(AP06)")), "沖壓")
        XCTAssertEqual(DrawingCapacity.columnID(for: station("下料->拍平->整平(無錫)", key: "stamping")), "沖壓")
        XCTAssertEqual(DrawingCapacity.label(for: "下料->拍平->整平"), "下料→整平")
    }

    func testBuildsColumnsInProcessOrder() {
        let capacity = sampleCapacity()
        let columns = DrawingCapacity.columns(models: [], capacity: capacity)
        XCTAssertEqual(columns.map(\.id), ["沖壓", "車削", "電鍍", "外觀全檢"], "出貨包裝不開欄，順序依多數決")
        XCTAssertEqual(columns.first?.unit, "K/日")
        XCTAssertNil(columns.last?.unit)
        XCTAssertEqual(columns.first?.legacyKey, "stamping")
    }

    func testStationCellsPreferPoListAndFlagDifferences() {
        let capacity = sampleCapacity()
        let columns = DrawingCapacity.columns(models: [], capacity: capacity)
        let stamping = columns[0]
        var model = DrawingModel(dwg: "B")
        model.processStations = ["stamping": "沖壓(無錫): 50K/D (一台50K/D，有2套)"]

        let po = DrawingCapacity.cell(model: model, capacity: capacity["B"], column: stamping)
        XCTAssertEqual(po.source, .po)
        XCTAssertEqual(po.text, "50K/D")
        XCTAssertFalse(DrawingCapacity.isDifferent(po), "括號裡的機台備註不算數字")
        XCTAssertEqual(DrawingCapacity.displayText(po.text, column: stamping), "50")

        model.processStations = ["stamping": "沖壓: 40K/D"]
        XCTAssertTrue(DrawingCapacity.isDifferent(DrawingCapacity.cell(model: model, capacity: capacity["B"], column: stamping)))

        let present = DrawingCapacity.cell(model: model, capacity: capacity["A"], column: columns[3])
        XCTAssertEqual(present.source, .present)
        XCTAssertEqual(present.text, "✓")

        let fallback = DrawingCapacity.cell(model: model, capacity: nil, column: stamping)
        XCTAssertEqual(fallback.source, .catalog, "PO LIST 完全沒有這個機種時才用 catalog")
        XCTAssertEqual(DrawingCapacity.cell(model: DrawingModel(dwg: "C"), capacity: capacity["A"], column: columns[1]).source, .missing)
    }

    func testOpenQuantityAndProcess() {
        var model = DrawingModel(dwg: "B")
        model.openQty = 10
        let capacity = sampleCapacity()
        let open = DrawingCapacity.openQty(model: model, capacity: capacity["B"])
        XCTAssertEqual(open.qty, 1200)
        XCTAssertTrue(open.fromPoList)
        XCTAssertEqual(open.catalogQty, 10)
        XCTAssertEqual(DrawingCapacity.openQty(model: model, capacity: nil).qty, 10)

        XCTAssertEqual(DrawingCapacity.process(model: model, capacity: capacity["B"]), "沖壓")
        var etched = CapacityItem(dwg: "E")
        etched.processNote = "蝕刻→電鍍"
        XCTAssertEqual(DrawingCapacity.process(model: model, capacity: etched), "蝕刻")
        model.manualProcess = "CNC"
        XCTAssertEqual(DrawingCapacity.process(model: model, capacity: etched), "CNC", "catalog 手動欄位優先")
    }

    func testTheoryKeepsTheHigherPlant() throws {
        let objects: [[String: Any]] = [
            ["dwg": "0850167HS", "plant": "華亞", "daily_qty": 69120, "util": 0.8, "sph_used": 3600, "day_hours": 12, "day_qty": 34560],
            ["dwg": "0850167hs", "plant": "無錫", "daily_qty": 40000],
        ]
        let items = try objects.map { try XCTUnwrap(TheoryItem(object: $0)) }
        let index = DrawingTheory.index(items)
        XCTAssertEqual(index["0850167HS"]?.plant, "華亞")
        let text = DrawingTheory.description(try XCTUnwrap(index["0850167HS"]), sourceMtime: "2026-09-20")
        XCTAssertTrue(text.contains("合計 69,120 pcs/日（已含 80% 稼動率）"))
        XCTAssertTrue(text.contains("日班 12h × 3,600 × 80% = 34,560"))
    }

    // MARK: - 搜尋與匯出

    func testSearchNeedsEveryToken() {
        XCTAssertTrue(DrawingFormat.matches("0850664hs flattop", in: ["0850664HS", "FlatTop"]))
        XCTAssertTrue(DrawingFormat.matches("101422224_0850664HS", in: ["0850664HS", "101422224"]))
        XCTAssertFalse(DrawingFormat.matches("0850664hs ring", in: ["0850664HS", "FlatTop"]))
        XCTAssertEqual(DrawingFormat.dimension("22.40 mm"), 22.4)
        XCTAssertEqual(DrawingFormat.trim(22.400, digits: 3), "22.4")
        XCTAssertEqual(DrawingFormat.trim(0, digits: 3), "-")
    }

    func testCSVHasBOMAndEscapes() {
        let data = CapacityExport.csv([["a,b", "c\"d"], ["1", "2"]])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\u{FEFF}\"a,b\",\"c\"\"d\"\r\n1,2")
    }

    // MARK: - 測試資料

    private func station(_ name: String, capacity: String = "", order: Int? = nil, key: String = "") -> CapacityStation {
        CapacityStation(station: name, capacity: capacity, note: "", order: order, key: key)
    }

    private func sampleCapacity() -> [String: CapacityItem] {
        var a = CapacityItem(dwg: "A")
        a.stations = [
            station("沖壓", capacity: "30K/D", order: 0, key: "stamping"),
            station("電鍍", capacity: "100K/D", order: 1, key: "plating"),
            station("外觀全檢", order: 2),
            station("出貨包裝", order: 3, key: "packaging"),
        ]
        var b = CapacityItem(dwg: "B")
        b.stations = [
            station("沖壓", capacity: "50K/D", order: 0, key: "stamping"),
            station("車削", capacity: "10K/D", order: 1, key: "machining"),
            station("電鍍", capacity: "80K/D", order: 2, key: "plating"),
        ]
        b.orders = CapacityOrders(openQty: 1200, openLines: 2)
        return ["A": a, "B": b]
    }
}
