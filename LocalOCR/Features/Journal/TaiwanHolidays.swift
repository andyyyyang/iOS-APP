import Foundation

/// 台灣的國定假日與補班日。App 內附行政院人事行政總處「政府行政機關辦公日曆表」2025–2027 年（TaiwanHolidays.json）；
/// 之後的年份在用到時從政府開放資料的同步（imsyuan/taiwan-holidays，jsDelivr）下載一次並留在這台裝置上。
enum TaiwanHolidays {
    struct Year: Codable, Equatable, Sendable {
        /// 日期（yyyy-MM-dd）→ 名稱（國定假日、補假，週末遇到的節日也列）。
        var holidays: [String: String]
        /// 週末補行上班的日子。
        var workdays: [String: String]
    }

    private struct Document: Decodable {
        let years: [String: Year]
    }

    private static let bundled: [String: Year] = loadBundled()
    nonisolated(unsafe) private static var years: [String: Year] = bundled.merging(loadCached()) { bundled, _ in bundled }
    private static let lock = NSLock()

    /// 這天的假日名稱（不是假日時 nil）。
    static func holiday(on day: String) -> String? {
        year(of: day)?.holidays[day]
    }

    /// 週末補行上班。
    static func isMakeupWorkday(_ day: String) -> Bool {
        year(of: day)?.workdays[day] != nil
    }

    static func hasData(forYear year: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return years[String(year)] != nil
    }

    private static func year(of day: String) -> Year? {
        lock.lock()
        defer { lock.unlock() }
        return years[String(day.prefix(4))]
    }

    // MARK: 資料

    private static func loadBundled() -> [String: Year] {
        guard let url = Bundle.main.url(forResource: "TaiwanHolidays", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return [:] }
        return document.years
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TaiwanHolidays.json")
    }

    private static func loadCached() -> [String: Year] {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Year].self, from: data)) ?? [:]
    }

    /// App 沒有附的年份（例如 2028 年）：下載一次留著。政府通常在前一年年中公布，還沒公布時下次再試。
    static func fetchIfNeeded(year: Int) async {
        guard !hasData(forYear: year) else { return }
        let base = "https://cdn.jsdelivr.net/gh/imsyuan/taiwan-holidays/data/\(year)"
        struct Entry: Decodable {
            let date: String
            let description: String?
        }
        func entries(_ name: String) async -> [Entry]? {
            guard let url = URL(string: "\(base)/\(name).json"),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode([Entry].self, from: data)
        }
        guard let holidays = await entries("holidays"), !holidays.isEmpty else { return }
        let workdays = await entries("makeup-workdays") ?? []
        func iso(_ compact: String) -> String? {
            guard compact.count == 8 else { return nil }
            let chars = Array(compact)
            return "\(String(chars[0..<4]))-\(String(chars[4..<6]))-\(String(chars[6..<8]))"
        }
        let fetched = Year(
            holidays: Dictionary(holidays.compactMap { entry in iso(entry.date).map { ($0, entry.description ?? "放假") } }) { first, _ in first },
            workdays: Dictionary(workdays.compactMap { entry in iso(entry.date).map { ($0, entry.description ?? "補行上班") } }) { first, _ in first }
        )
        lock.lock()
        years[String(year)] = fetched
        let cached = years.filter { key, _ in bundled[key] == nil }
        lock.unlock()
        if let url = cacheURL, let data = try? JSONEncoder().encode(cached) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// 日誌側欄的月曆：週日開始，前後補空白成整週。日期都是「yyyy-MM-dd」（同日誌頁面）。
enum JournalCalendar {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        return calendar
    }()

    static let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

    /// 這個月的格子（不屬於這個月的是 nil），格數是 7 的倍數。
    static func cells(year: Int, month: Int) -> [String?] {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let count = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let leading = calendar.component(.weekday, from: first) - 1
        var cells: [String?] = Array(repeating: nil, count: leading)
        for day in 1...count {
            cells.append(String(format: "%04d-%02d-%02d", year, month, day))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    static func yearMonth(of day: String) -> (year: Int, month: Int) {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2 else {
            let now = calendar.dateComponents([.year, .month], from: Date())
            return (now.year ?? 2026, now.month ?? 1)
        }
        return (parts[0], parts[1])
    }

    static func shifted(year: Int, month: Int, by offset: Int) -> (year: Int, month: Int) {
        let index = year * 12 + (month - 1) + offset
        return (index / 12, index % 12 + 1)
    }

    static func isWeekend(_ day: String) -> Bool {
        guard let date = JournalLayout.dayFormatter.date(from: day) else { return false }
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    /// 放假：國定假日（含補假），或不用補班的週末。
    static func isDayOff(_ day: String) -> Bool {
        TaiwanHolidays.holiday(on: day) != nil || (isWeekend(day) && !TaiwanHolidays.isMakeupWorkday(day))
    }
}
