import Foundation

/// 全域搜尋（指令面板）裡的業務快查：通訊錄、客戶與代碼、機種、開案案件、BPM、人員、SOP、物流單號，
/// 跟筆記、指令一起搜尋，不必先打開各個工具頁。
enum GlobalSearch {
    enum Section: String, CaseIterable, Sendable {
        case contacts, codes, models, cases, bpm, people, sops, parcels

        var title: String {
            switch self {
            case .contacts: return "通訊錄"
            case .codes: return "客戶與代碼"
            case .models: return "機種"
            case .cases: return "開案案件"
            case .bpm: return "BPM 簽核"
            case .people: return "人員"
            case .sops: return "SOP"
            case .parcels: return "物流單號"
            }
        }

        /// 每一區最多列幾筆。
        var limit: Int {
            switch self {
            case .contacts: return 8
            case .codes, .models, .cases: return 5
            case .bpm, .people: return 4
            case .sops, .parcels: return 3
            }
        }
    }

    enum Target: Equatable, Sendable {
        case contact(JentechContact)
        case code(JentechCode)
        case model(ModelEntry)
        case caseItem(JentechCase)
        case bpm(JentechBpm.Item)
        case person(JentechCard)
        case sop(JentechSop)
        case parcel(LogisticsClient.Item)
    }

    struct Hit: Identifiable, Equatable, Sendable {
        let section: Section
        let target: Target
        let score: Int

        var id: String {
            switch target {
            case .contact(let contact): return "contact:\(contact.id)"
            case .code(let code): return "code:\(code.id)"
            case .model(let entry): return "model:\(entry.id)"
            case .caseItem(let item): return "case:\(item.id)"
            case .bpm(let item): return "bpm:\(item.id)"
            case .person(let card): return "person:\(card.id)"
            case .sop(let sop): return "sop:\(sop.id)"
            case .parcel(let item): return "parcel:\(item.id)"
            }
        }
    }

    struct Group: Identifiable, Equatable, Sendable {
        let section: Section
        let hits: [Hit]
        /// 符合的總筆數（hits 只有前幾筆）。
        let total: Int

        var id: String { section.rawValue }
        var best: Int { hits.first?.score ?? 0 }
    }

    /// 要搜尋的資料（開啟指令面板時從各工具的資料取一次）。
    struct Sources: Sendable {
        var contacts: [JentechContact] = []
        var codes: [JentechCode] = []
        var models: [ModelEntry] = []
        var cases: [JentechCase] = []
        var bpm: [JentechBpm.Item] = []
        var people: [JentechCard] = []
        var sops: [JentechSop] = []
        var parcels: [LogisticsClient.Item] = []
    }

    /// 依最符合的一筆排序各區（一樣時照固定順序：通訊錄、客戶與代碼、機種…）。
    static func search(_ query: String, in sources: Sources) -> [Group] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let prepared = Query(text)
        guard !prepared.tokens.isEmpty else { return [] }
        var groups: [Group] = []

        func append(_ section: Section, _ hits: [(hit: Hit, order: Int)]) {
            guard !hits.isEmpty else { return }
            let sorted = hits.sorted { $0.hit.score != $1.hit.score ? $0.hit.score > $1.hit.score : $0.order < $1.order }
            groups.append(Group(section: section, hits: sorted.prefix(section.limit).map(\.hit), total: hits.count))
        }

        func add<Item>(_ section: Section, _ items: [Item], target: (Item) -> Target, fields: (Item) -> [String]) {
            var hits: [(hit: Hit, order: Int)] = []
            for (order, item) in items.enumerated() {
                if let score = rank(prepared, fields(item)) {
                    hits.append((Hit(section: section, target: target(item), score: score), order))
                }
            }
            append(section, hits)
        }

        add(.contacts, sources.contacts, target: Target.contact) { [$0.name, $0.ext, $0.mvpn, $0.dept, $0.plant] }
        add(.codes, sources.codes, target: Target.code) { [$0.code, $0.alias, $0.name, $0.fullName, $0.detail] }
        add(.cases, sources.cases, target: Target.caseItem) { [$0.caseNo, $0.sapNo, $0.product, $0.customer, $0.bpmRdmn, $0.file] }
        add(.bpm, sources.bpm, target: Target.bpm) { [$0.idx, $0.subject, $0.processName, $0.currentStep] }
        add(.people, sources.people, target: Target.person) { [$0.name, $0.english] }
        add(.sops, sources.sops, target: Target.sop) { [$0.name, $0.file, $0.stage] + $0.tags + $0.tags.map { String($0.dropFirst()) } }
        add(.parcels, sources.parcels, target: Target.parcel) { [$0.trackingNumber, $0.note, $0.courierName, $0.latestEvent] }

        // 機種：代號、別名（開案號、SAP 料號、客戶料號…），再加上容錯比對（少打後綴、O/0 打錯）
        var models: [(hit: Hit, order: Int)] = []
        for (order, entry) in sources.models.enumerated() {
            if let score = rank(prepared, [entry.code] + entry.aliases + [entry.customer, entry.detail]) {
                models.append((Hit(section: .models, target: .model(entry), score: score), order))
            }
        }
        if !text.contains(where: \.isWhitespace) {
            for match in ModelCatalog.match(text, in: sources.models, limit: 5) where match.score >= 0.8 {
                guard !models.contains(where: { $0.hit.target == .model(match.entry) }) else { continue }
                models.append((Hit(section: .models, target: .model(match.entry), score: Int(match.score * 100)), sources.models.count))
            }
        }
        append(.models, models)

        let order = Dictionary(uniqueKeysWithValues: Section.allCases.enumerated().map { ($1, $0) })
        return groups.sorted { $0.best != $1.best ? $0.best > $1.best : order[$0.section, default: 0] < order[$1.section, default: 0] }
    }

    /// 比對分數；不符合時 nil。空白分開的每個關鍵字都要出現在某個欄位（「大園 業務」），
    /// 完全相同 > 開頭相同 > 包含，前面的欄位稍微優先。代號忽略大小寫、-、空白與全形（0851-563hs 找得到 0851563HS）。
    static func rank(_ query: String, _ fields: [String]) -> Int? {
        rank(Query(query), fields)
    }

    /// 搜尋字串先處理一次（每一筆資料都用同一個）。
    struct Query: Sendable {
        let tokens: [(text: String, compact: String)]

        init(_ text: String) {
            tokens = text.lowercased().split(whereSeparator: \.isWhitespace).map { token -> (text: String, compact: String) in
                let raw = String(token)
                return (text: raw, compact: GlobalSearch.compact(raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw))
            }
        }
    }

    static func rank(_ query: Query, _ fields: [String]) -> Int? {
        guard !query.tokens.isEmpty else { return nil }
        let lowered = fields.map { $0.lowercased() }
        var compacted: [String?] = Array(repeating: nil, count: fields.count)
        var total = 0
        for (token, compactToken) in query.tokens {
            var best = 0
            for (index, field) in lowered.enumerated() where !field.isEmpty {
                var score = 0
                if field == token {
                    score = 300
                } else if field.hasPrefix(token) {
                    score = 200
                } else if field.contains(token) {
                    score = 100
                } else if compactToken.count >= 3 {
                    let key = compacted[index] ?? compact(field)
                    compacted[index] = key
                    if key == compactToken {
                        score = 290
                    } else if key.hasPrefix(compactToken) {
                        score = 190
                    } else if key.contains(compactToken) {
                        score = 90
                    }
                }
                if score > 0 { best = max(best, score + max(0, 10 - index)) }
            }
            guard best > 0 else { return nil }
            total += best
        }
        return total
    }

    /// 只留英數字（小寫）。
    static func compact(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) })
    }
}
