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

    /// 篩選建議：從目前符合的資料整理出可以再加的關鍵字（廠區、課別、客戶、流程…），有幾筆。
    struct Facet: Hashable, Sendable {
        let text: String
        let count: Int
    }

    /// 只選某一區（或沒有關鍵字、只選了區）時，一區最多列幾筆。
    static let scopedLimit = 40

    /// 搜尋用的欄位，以及可以拿來再篩選的欄位。
    private struct Entry {
        let target: Target
        let fields: [String]
        let facets: [String]
    }

    private static func entries(_ section: Section, in sources: Sources) -> [Entry] {
        switch section {
        case .contacts:
            return sources.contacts.map { Entry(target: .contact($0), fields: [$0.name, $0.ext, $0.mvpn, $0.dept, $0.plant], facets: [$0.plant, $0.dept]) }
        case .codes:
            return sources.codes.map { Entry(target: .code($0), fields: [$0.code, $0.alias, $0.name, $0.fullName, $0.detail, $0.kind.rawValue], facets: [$0.kind.rawValue]) }
        case .models:
            return sources.models.map { Entry(target: .model($0), fields: [$0.code] + $0.aliases + [$0.customer, $0.detail], facets: [$0.customer]) }
        case .cases:
            return sources.cases.map { Entry(target: .caseItem($0), fields: [$0.caseNo, $0.sapNo, $0.product, $0.customer, $0.bpmRdmn, $0.file], facets: [$0.customer]) }
        case .bpm:
            return sources.bpm.map { Entry(target: .bpm($0), fields: [$0.idx, $0.subject, $0.processName, $0.currentStep], facets: [$0.processName]) }
        case .people:
            return sources.people.map { Entry(target: .person($0), fields: [$0.name, $0.english], facets: []) }
        case .sops:
            return sources.sops.map { Entry(target: .sop($0), fields: [$0.name, $0.file, $0.stage] + $0.tags + $0.tags.map { String($0.dropFirst()) }, facets: [$0.stage]) }
        case .parcels:
            return sources.parcels.map { Entry(target: .parcel($0), fields: [$0.trackingNumber, $0.note, $0.courierName, $0.latestEvent], facets: [$0.courierName]) }
        }
    }

    /// 依最符合的一筆排序各區（一樣時照固定順序：通訊錄、客戶與代碼、機種…）。
    /// `scope`：只找這一區（每區上限放寬）；只選了區、沒有關鍵字時列出這一區的全部（前幾筆）。
    static func search(_ query: String, in sources: Sources, scope: Section? = nil) -> [Group] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let prepared = Query(text)
        guard !prepared.tokens.isEmpty || scope != nil else { return [] }
        var groups: [Group] = []
        for section in scope.map({ [$0] }) ?? Section.allCases {
            var hits: [(hit: Hit, order: Int)] = []
            for (order, entry) in entries(section, in: sources).enumerated() {
                if prepared.tokens.isEmpty {
                    hits.append((Hit(section: section, target: entry.target, score: 0), order))
                } else if let score = rank(prepared, entry.fields) {
                    hits.append((Hit(section: section, target: entry.target, score: score), order))
                }
            }
            // 機種再加上容錯比對（少打後綴、O/0 打錯）
            if section == .models, prepared.tokens.count == 1 {
                for match in ModelCatalog.match(text, in: sources.models, limit: 5) where match.score >= 0.8 {
                    guard !hits.contains(where: { $0.hit.target == .model(match.entry) }) else { continue }
                    hits.append((Hit(section: .models, target: .model(match.entry), score: Int(match.score * 100)), sources.models.count))
                }
            }
            guard !hits.isEmpty else { continue }
            let sorted = hits.sorted { (a: (hit: Hit, order: Int), b: (hit: Hit, order: Int)) -> Bool in
                if a.hit.score != b.hit.score { return a.hit.score > b.hit.score }
                return a.order < b.order
            }
            let limit = scope == nil ? section.limit : scopedLimit
            groups.append(Group(section: section, hits: sorted.prefix(limit).map(\.hit), total: hits.count))
        }
        let order: [Section: Int] = Dictionary(uniqueKeysWithValues: Section.allCases.enumerated().map { index, section in (section, index) })
        return groups.sorted { (a: Group, b: Group) -> Bool in
            if a.best != b.best { return a.best > b.best }
            return order[a.section, default: 0] < order[b.section, default: 0]
        }
    }

    /// 可以再加的關鍵字：目前符合的資料中出現的廠區、課別、客戶、流程…（能縮小範圍的才列，已經用了的不列），多的在前。
    static func facets(_ query: String, in sources: Sources, scope: Section? = nil, limit: Int = 8) -> [Facet] {
        let prepared = Query(query.trimmingCharacters(in: .whitespaces))
        guard !prepared.tokens.isEmpty || scope != nil else { return [] }
        let used = Set(prepared.tokens.map(\.text))
        var best: [String: Int] = [:]
        for section in scope.map({ [$0] }) ?? Section.allCases {
            let matched = entries(section, in: sources).filter { prepared.tokens.isEmpty || rank(prepared, $0.fields) != nil }
            guard matched.count > 1 else { continue }
            var counts: [String: Int] = [:]
            for entry in matched {
                for facet in Set(entry.facets) where !facet.isEmpty {
                    counts[facet, default: 0] += 1
                }
            }
            for (facet, count) in counts where count < matched.count && !used.contains(facet.lowercased()) {
                best[facet] = max(best[facet] ?? 0, count)
            }
        }
        let facets: [Facet] = best.map { key, value in Facet(text: key, count: value) }
        let sorted = facets.sorted(by: Self.facetOrder)
        return Array(sorted.prefix(limit))
    }

    /// 多的在前，一樣多時依名稱。
    private static func facetOrder(_ a: Facet, _ b: Facet) -> Bool {
        if a.count != b.count { return a.count > b.count }
        return a.text.localizedStandardCompare(b.text) == .orderedAscending
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
