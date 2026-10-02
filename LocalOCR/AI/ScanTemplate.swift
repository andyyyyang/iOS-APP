import Foundation

/// 情境樣板：描述一種文件（收據、名片…）以及要輸出的 JSON 樣式。
/// 情境是資料而不是程式碼，新增情境只要新增一筆樣板（內建、伺服器同步或使用者自訂）。
struct ScanTemplate: Identifiable, Hashable, Codable {
    enum Origin: String, Codable {
        case builtIn
        case server
        case custom

        var displayName: String {
            switch self {
            case .builtIn: return "內建"
            case .server: return "伺服器"
            case .custom: return "自訂"
            }
        }
    }

    var id: String
    var name: String
    /// 情境描述，分類器依此判斷文件屬於哪個情境。
    var description: String
    var keywords: [String]
    /// 輸出樣式的範例 JSON（以文字保存，保留欄位順序）。
    var sampleJSON: String
    var instructions: String
    var origin: Origin
    var version: Int
    /// 抽取後套用的規則（JSON 陣列文字，見 TemplateRules）；舊資料沒有此欄位。
    var rulesJSON: String?

    init(
        id: String,
        name: String,
        description: String,
        keywords: [String] = [],
        sampleJSON: String,
        instructions: String = "",
        origin: Origin,
        version: Int = 1,
        rulesJSON: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.keywords = keywords
        self.sampleJSON = sampleJSON
        self.instructions = instructions
        self.origin = origin
        self.version = version
        self.rulesJSON = rulesJSON
    }

    var sample: JSONValue {
        (try? JSONValue.parse(sampleJSON)) ?? .object([])
    }

    var rules: [JSONValue] {
        guard let rulesJSON, case .array(let items)? = try? JSONValue.parse(rulesJSON) else { return [] }
        return items
    }

    static let fallbackID = "document"

    static func isValidID(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil
    }

    static func makeCustomID() -> String {
        "custom-" + UUID().uuidString.prefix(8).lowercased()
    }
}

// MARK: - App 內附的受管理情境（與 server/templates/managed 相同，CI 會檢查）

extension ScanTemplate {
    /// App 套件中的 JSON 情境檔，例如 FV60 請款。未連接伺服器時也能使用；伺服器上的同 id 情境優先。
    static let bundled: [ScanTemplate] = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> ScanTemplate? in
                guard let data = try? Data(contentsOf: url),
                      let value = try? JSONValue.parse(String(decoding: data, as: UTF8.self)),
                      var template = ServerClient.template(from: value) else { return nil }
                template.origin = .builtIn
                return template
            }
    }()
}

// MARK: - 內建情境（與伺服器 server/src/templates/builtin.ts 相同）

extension ScanTemplate {
    static let builtIns: [ScanTemplate] = [
        ScanTemplate(
            id: "receipt",
            name: "收據／發票",
            description: "購物收據、統一發票、消費明細，含商店、日期、品項與金額",
            keywords: ["合計", "總計", "小計", "統一編號", "發票", "收據", "找零", "交易明細", "金額"],
            sampleJSON: #"{"store":"全聯福利中心","date":"2026-10-02","time":"14:30","items":[{"name":"鮮乳","quantity":1,"price":45}],"subtotal":45,"tax":0,"total":45,"currency":"TWD","paymentMethod":"現金","invoiceNumber":"AB-12345678"}"#,
            instructions: "金額使用數字；日期使用 YYYY-MM-DD；時間使用 24 小時制 HH:mm；找不到的欄位填 null。",
            origin: .builtIn
        ),
        ScanTemplate(
            id: "business_card",
            name: "名片",
            description: "個人或公司名片，含姓名、職稱、公司與聯絡方式",
            keywords: ["電話", "手機", "Tel", "Mobile", "E-mail", "Email", "傳真", "Fax", "經理", "總監", "有限公司", "股份有限公司"],
            sampleJSON: #"{"name":"王小明","title":"產品經理","company":"範例科技股份有限公司","phones":["02-1234-5678"],"email":"ming@example.com","website":"https://example.com","address":"台北市信義區市府路1號","social":[{"platform":"LINE","handle":"ming"}]}"#,
            instructions: "電話保留原始格式；找不到的欄位填 null，陣列可為空。",
            origin: .builtIn
        ),
        ScanTemplate(
            id: "event",
            name: "活動／海報",
            description: "活動、展覽、演出或課程的海報與傳單，含名稱、時間與地點",
            keywords: ["活動", "報名", "票價", "入場", "展覽", "演出", "講座", "地點", "時間", "主辦"],
            sampleJSON: #"{"title":"秋季音樂節","date":"2026-10-18","startTime":"18:00","endTime":"21:30","location":"華山1914文化創意產業園區","organizer":"範例文化","price":"免費","description":"戶外音樂演出","url":"https://example.com/event"}"#,
            instructions: "日期使用 YYYY-MM-DD；時間使用 24 小時制 HH:mm；找不到的欄位填 null。",
            origin: .builtIn
        ),
        ScanTemplate(
            id: "document",
            name: "一般文件",
            description: "其他文件、筆記、公告、信件或會議紀錄；無法歸類時使用",
            keywords: ["會議", "紀錄", "公告", "通知", "說明", "摘要"],
            sampleJSON: #"{"title":"會議紀錄","date":"2026-10-02","summary":"討論第四季產品規劃","keyPoints":["確認上線時程"],"people":["王小明"],"actionItems":[{"task":"整理需求文件","owner":"王小明","due":"2026-10-09"}]}"#,
            instructions: "摘要不超過 100 字；找不到的欄位填 null，陣列可為空。",
            origin: .builtIn
        ),
    ]
}
