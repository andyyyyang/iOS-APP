import Foundation

/// 筆記中的「@」：@人名插入通訊錄上的人與號碼（有 MVPN 用 MVPN，否則分機）；
/// @時間（明天 3點、10/31 14:00、30分鐘後…）插入提醒「(@2026-10-31 15:00)」（同 Obsidian Reminder 插件的寫法），時間到了跳出通知。
enum NoteMentions {
    /// 游標前面輸入中的「@…」：回傳 @ 起到游標的範圍與 @ 後面的文字。email 中的 @、插入過的提醒不算。
    static func openQuery(in text: String, cursor: NSRange) -> (range: NSRange, text: String)? {
        guard cursor.length == 0 else { return nil }
        let ns = text as NSString
        guard cursor.location <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: cursor.location, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: cursor.location - lineStart))
        guard let at = before.range(of: "@", options: .backwards) else { return nil }
        let query = String(before[at.upperBound...])
        // 最多一個空白（「明天 3點」）；插入人名之後（「@王小明 MVPN 61234」）就不再是輸入中的 @
        guard (query as NSString).length <= 16, query.filter({ $0 == " " }).count <= 1,
              !query.hasPrefix(" "), !query.contains("("), !query.contains(")") else { return nil }
        if at.lowerBound > before.startIndex {
            let previous = before[before.index(before: at.lowerBound)]
            if previous.isASCII && (previous.isLetter || previous.isNumber) { return nil }
        }
        let start = lineStart + (String(before[..<at.lowerBound]) as NSString).length
        return (NSRange(location: start, length: cursor.location - start), query)
    }

    /// 通訊錄上的一個人（同一人列在不同課別時只列一次）。
    struct Person: Equatable {
        let name: String
        let dept: String
        let plant: String
        /// 「MVPN」或「分機」；都沒有時是空字串。
        let numberLabel: String
        let number: String

        /// 插入筆記的文字：「@王小明 MVPN 61234」。
        var insertText: String { number.isEmpty ? "@\(name)" : "@\(name) \(numberLabel) \(number)" }
    }

    /// 名字符合的人：完全相同、開頭相同、包含，依序排列；號碼 MVPN 優先，沒有才用分機。
    static func people(matching query: String, in contacts: [JentechContact], limit: Int = 8) -> [Person] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        var seen = Set<String>()
        var ranked: [(person: Person, score: Int, order: Int)] = []
        for contact in contacts {
            let name = contact.name
            let score: Int
            if name == text {
                score = 3
            } else if name.hasPrefix(text) {
                score = 2
            } else if name.localizedCaseInsensitiveContains(text) {
                score = 1
            } else {
                continue
            }
            let mvpn = contact.mvpn.trimmingCharacters(in: .whitespaces)
            let ext = contact.ext.trimmingCharacters(in: .whitespaces)
            let (label, number): (String, String) = JentechLogic.hasNumber(mvpn)
                ? ("MVPN", mvpn)
                : (JentechLogic.hasNumber(ext) ? ("分機", ext) : ("", ""))
            guard seen.insert(name + "|" + number).inserted else { continue }
            ranked.append((Person(name: name, dept: contact.dept, plant: contact.plant, numberLabel: label, number: number), score, ranked.count))
        }
        return ranked
            .sorted { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
            .prefix(limit)
            .map { $0.person }
    }
}

/// 「@」後面的時間：解析、顯示與寫進筆記的格式。
enum ReminderTime {
    private static let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]

    /// 寫進筆記的提醒：「(@2026-10-31 15:00)」。
    static func token(for date: Date, calendar: Calendar = .current) -> String {
        "(@\(stamp(date, calendar: calendar)))"
    }

    /// 「2026-10-31 15:00」。
    static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04ld-%02ld-%02ld %02ld:%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// 顯示用：「今天 15:00」「明天 09:00」「11/3（一）14:00」。
    static func label(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let c = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: date)
        let time = String(format: "%02ld:%02ld", c.hour ?? 0, c.minute ?? 0)
        switch days {
        case 0: return "今天 \(time)"
        case 1: return "明天 \(time)"
        case 2: return "後天 \(time)"
        default:
            let weekday = weekdayNames[((c.weekday ?? 1) - 1) % 7]
            return "\(c.month ?? 0)/\(c.day ?? 0)（\(weekday)）\(time)"
        }
    }

    /// 只打「@」時的建議：一小時後、今晚 8 點、明天早上 9 點。
    static func presets(now: Date, calendar: Calendar = .current) -> [Date] {
        var dates: [Date] = []
        if let hour = calendar.date(byAdding: .hour, value: 1, to: now),
           let rounded = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: hour)) {
            dates.append(rounded)
        }
        if let tonight = at(calendar.startOfDay(for: now), hour: 20, minute: 0, calendar: calendar), tonight > now.addingTimeInterval(3600) {
            dates.append(tonight)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           let morning = at(tomorrow, hour: 9, minute: 0, calendar: calendar) {
            dates.append(morning)
        }
        return dates
    }

    private static func at(_ day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let relativeMinutes = regex(#"^(\d+)\s*(?:分鐘|分|min|m)\s*後?$"#)
    private static let relativeHours = regex(#"^(\d+(?:\.5)?|半)\s*個?(?:小時|鐘頭|h)\s*後?$"#)
    private static let relativeDays = regex(#"^(\d+)\s*天後$"#)
    private static let fullDate = regex(#"^(\d{4})[/\-.](\d{1,2})[/\-.](\d{1,2})"#)
    private static let monthDay = regex(#"^(\d{1,2})(?:[/\-.]|月)(\d{1,2})(?:日|號)?"#)
    private static let weekday = regex(#"^(下)?(?:週|周|星期|禮拜)([一二三四五六日天])"#)
    private static let clock = regex(#"^(\d{1,2})[:：](\d{2})"#)
    private static let hourWord = regex(#"^(\d{1,2})(?:點|時)(半|(\d{1,2})分?)?"#)
    private static let hourSuffix = regex(#"^(\d{1,2})\s*(am|pm)"#)

    private enum Meridiem { case am, noon, pm }

    /// 解析時間：明天 3點、下午3點半、10/31 14:00、週五 10點、下週一、30分鐘後、2小時後；看不懂時 nil。
    /// 只有時間、已經過了就是明天；只有日期就是那天早上 9 點；沒寫上午下午時 1–6 點是下午。
    static func parse(_ query: String, now: Date, calendar: Calendar = .current) -> Date? {
        var text = query.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? query
        text = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        /// 拿掉看懂的開頭（空白是分隔）。
        func consume(_ prefix: String) {
            text.removeFirst(prefix.count)
            text = text.trimmingCharacters(in: .whitespaces)
        }

        // 相對時間
        if let m = match(relativeMinutes, text), let minutes = Int(m[1]), minutes > 0 {
            return calendar.date(byAdding: .minute, value: minutes, to: now)
        }
        if let m = match(relativeHours, text) {
            let hours = m[1] == "半" ? 0.5 : (Double(m[1]) ?? 0)
            guard hours > 0 else { return nil }
            return calendar.date(byAdding: .minute, value: Int(hours * 60), to: now)
        }
        if let m = match(relativeDays, text), let days = Int(m[1]), days > 0,
           let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) {
            return at(day, hour: 9, minute: 0, calendar: calendar)
        }

        let today = calendar.startOfDay(for: now)
        var day: Date?
        /// 一週中的某天（沒寫日期）：時間過了就是下週。
        var weekdayOnly = false
        var meridiem: Meridiem?
        var defaultHour: Int?

        // 日期
        let dayWords: [(String, Int, Meridiem?, Int?)] = [
            ("大後天", 3, nil, nil), ("後天", 2, nil, nil), ("明早", 1, .am, 9), ("明晚", 1, .pm, 20),
            ("明天", 1, nil, nil), ("明日", 1, nil, nil), ("今晚", 0, .pm, 20), ("今天", 0, nil, nil), ("今日", 0, nil, nil),
        ]
        if let word = dayWords.first(where: { text.hasPrefix($0.0) }) {
            day = calendar.date(byAdding: .day, value: word.1, to: today)
            meridiem = word.2
            defaultHour = word.3
            consume(word.0)
        } else if let m = match(fullDate, text), let y = Int(m[1]), let mo = Int(m[2]), let d = Int(m[3]) {
            guard let date = validDate(year: y, month: mo, day: d, calendar: calendar) else { return nil }
            day = date
            consume(m[0])
        } else if let m = match(monthDay, text), let mo = Int(m[1]), let d = Int(m[2]) {
            let year = calendar.component(.year, from: now)
            guard var date = validDate(year: year, month: mo, day: d, calendar: calendar) else { return nil }
            // 今年的這天已經過了：明年
            if date < today, let next = validDate(year: year + 1, month: mo, day: d, calendar: calendar) { date = next }
            day = date
            consume(m[0])
        } else if let m = match(weekday, text) {
            let names = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7]
            guard let target = names[m[2]] else { return nil }
            // 週一 = 1 … 週日 = 7
            let current = (calendar.component(.weekday, from: now) + 5) % 7 + 1
            let ahead = m[1].isEmpty ? (target - current + 7) % 7 : 7 - current + target
            day = calendar.date(byAdding: .day, value: ahead, to: today)
            weekdayOnly = m[1].isEmpty
            consume(m[0])
        }

        // 上午、下午
        let meridiemWords: [(String, Meridiem, Int)] = [
            ("早上", .am, 9), ("上午", .am, 9), ("早", .am, 9), ("中午", .noon, 12),
            ("下午", .pm, 14), ("午後", .pm, 14), ("傍晚", .pm, 18), ("晚上", .pm, 20), ("晚", .pm, 20),
        ]
        if let word = meridiemWords.first(where: { text.hasPrefix($0.0) }) {
            meridiem = word.1
            defaultHour = word.2
            consume(word.0)
        }

        // 時間
        var hour: Int?
        var minute = 0
        if let m = match(clock, text), let h = Int(m[1]), let mi = Int(m[2]) {
            hour = h
            minute = mi
            consume(m[0])
        } else if let m = match(hourWord, text), let h = Int(m[1]) {
            hour = h
            if m[2] == "半" {
                minute = 30
            } else if let mi = Int(m[3]) {
                minute = mi
            }
            consume(m[0])
        } else if let m = match(hourSuffix, text), let h = Int(m[1]) {
            hour = h
            meridiem = m[2] == "am" ? .am : .pm
            consume(m[0])
        }
        if text == "am" || text == "pm" {
            meridiem = text == "am" ? .am : .pm
            text = ""
        }
        // 還有看不懂的字：不是時間
        guard text.isEmpty, day != nil || hour != nil || defaultHour != nil else { return nil }
        guard minute < 60 else { return nil }

        let explicitMeridiem = meridiem != nil
        if var h = hour {
            guard h <= 24 else { return nil }
            switch meridiem {
            case .pm?: if h < 12 { h += 12 }
            case .am?: if h == 12 { h = 0 }
            case .noon?: if h < 6 { h += 12 }
            case nil: if (1...6).contains(h) { h += 12 }
            }
            hour = h == 24 ? 0 : h
        } else {
            hour = defaultHour ?? 9
        }
        guard let finalHour = hour else { return nil }

        if let day {
            guard var date = at(day, hour: finalHour, minute: minute, calendar: calendar) else { return nil }
            if weekdayOnly, date <= now, let next = calendar.date(byAdding: .day, value: 7, to: date) { date = next }
            return date
        }
        // 只有時間：今天還沒過就是今天；沒寫上午下午的早上時間過了、晚上同一個鐘點還沒到就是今晚；否則明天
        guard let todayAt = at(today, hour: finalHour, minute: minute, calendar: calendar) else { return nil }
        if todayAt > now { return todayAt }
        if !explicitMeridiem, finalHour < 12, let evening = at(today, hour: finalHour + 12, minute: minute, calendar: calendar), evening > now {
            return evening
        }
        return calendar.date(byAdding: .day, value: 1, to: todayAt)
    }

    private static func validDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return c.year == year && c.month == month && c.day == day ? date : nil
    }

    /// 符合時回傳每個群組的文字（沒有符合的群組是空字串）。
    private static func match(_ pattern: NSRegularExpression, _ text: String) -> [String]? {
        let ns = text as NSString
        guard let result = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            let range = result.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }
}

/// 筆記中的一個提醒。
struct NoteReminder: Codable, Equatable, Sendable {
    let path: String
    let title: String
    /// 那一行的文字（拿掉提醒與清單符號）；沒有其他文字時是空字串。
    let text: String
    let date: Date

    /// 通知的識別碼：同一則筆記、同一行文字、同一時間只排一次。
    var id: String { "\(NoteReminderParser.identifierPrefix)\(path)|\(ReminderTime.stamp(date))|\(text.prefix(80))" }
}

enum NoteReminderParser {
    static let identifierPrefix = "note-reminder:"
    /// 「(@2026-10-31 15:00)」或只有日期「(@2026-10-31)」（早上 9 點）。
    static let tokenPattern = try! NSRegularExpression(pattern: #"\(@(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2}))?\)"#)
    private static let donePattern = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+[.)])\s+\[[xX]\]"#)
    private static let prefixPattern = try! NSRegularExpression(pattern: #"^\s*(?:(?:[-*+]|\d+[.)])\s+(?:\[[^\]]\]\s+)?|#{1,6}\s+|>\s*)"#)

    /// 整則筆記中的提醒（略過 frontmatter、程式碼區塊與完成的待辦）。
    static func reminders(in markdown: String, path: String, title: String, calendar: Calendar = .current) -> [NoteReminder] {
        guard markdown.contains("(@") else { return [] }
        var result: [NoteReminder] = []
        var inFence = false
        var inFrontmatter = false
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index == 0 && trimmed == "---" {
                inFrontmatter = true
                continue
            }
            if inFrontmatter {
                if trimmed == "---" { inFrontmatter = false }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence, line.contains("(@") else { continue }
            result += reminders(inLine: line, path: path, title: title, calendar: calendar)
        }
        return result
    }

    /// 一行中的提醒（一行可以有好幾個時間）。
    static func reminders(inLine line: String, path: String, title: String, calendar: Calendar = .current) -> [NoteReminder] {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = tokenPattern.matches(in: line, range: full)
        guard !matches.isEmpty, donePattern.firstMatch(in: line, range: full) == nil else { return [] }
        let text = cleanText(line, removing: matches)
        return matches.compactMap { match -> NoteReminder? in
            func number(_ index: Int) -> Int? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
            }
            guard let year = number(1), let month = number(2), let day = number(3) else { return nil }
            let hour = number(4) ?? 9
            let minute = number(5) ?? 0
            guard hour < 24, minute < 60,
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)),
                  calendar.component(.day, from: date) == day else { return nil }
            return NoteReminder(path: path, title: title, text: text, date: date)
        }
    }

    /// 拿掉提醒、清單符號與多餘的空白。
    static func cleanText(_ line: String, removing matches: [NSTextCheckingResult]) -> String {
        let text = NSMutableString(string: line)
        for match in matches.reversed() {
            text.replaceCharacters(in: match.range, with: " ")
        }
        var result = text as String
        let ns = result as NSString
        if let prefix = prefixPattern.firstMatch(in: result, range: NSRange(location: 0, length: ns.length)) {
            result = ns.replacingCharacters(in: prefix.range, with: "")
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// 手寫辨識出來的文字中的「@」：@人名補上號碼（MVPN 優先），@時間換成提醒「(@2026-10-31 15:00)」。
/// 手寫的中文沒有空白：名字取通訊錄中最長的相符名字，時間取最長、看得懂的一段。
enum HandwritingMentions {
    struct Result: Equatable {
        var text: String
        /// 這次換成提醒的原文與時間：存下來，下次重新辨識時沿用（「明天」不會隔天變成後天）。
        var dates: [String: Date]
    }

    static func enrich(_ text: String, contacts: [JentechContact], known: [String: Date], now: Date, calendar: Calendar = .current) -> Result {
        guard text.contains("@") || text.contains("＠") else { return Result(text: text, dates: [:]) }
        let names = Set(contacts.map(\.name).filter { $0.count >= 2 }).sorted { $0.count > $1.count }
        var output = ""
        var dates: [String: Date] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            guard character == "@" || character == "＠" else {
                output.append(character)
                index = next
                continue
            }
            // email 的 @
            if let last = output.last, last.isASCII, last.isLetter || last.isNumber {
                output.append("@")
                index = next
                continue
            }
            let rest = Array(text[next...].prefix { $0 != "\n" }.prefix(16))
            let skipped = rest.prefix { $0 == " " }.count
            let words = String(rest.dropFirst(skipped))
            if let name = names.first(where: { words.hasPrefix($0) }) {
                let person = NoteMentions.people(matching: name, in: contacts).first { $0.name == name }
                output += person?.insertText ?? "@" + name
                index = text.index(next, offsetBy: skipped + name.count)
                // 號碼後面直接接著寫的字：隔開
                if person?.number.isEmpty == false, index < text.endIndex, !text[index].isWhitespace { output.append(" ") }
                continue
            }
            let characters = Array(words)
            var matched: (length: Int, date: Date)?
            for length in stride(from: characters.count, through: 1, by: -1) {
                let phrase = String(characters[0..<length]).trimmingCharacters(in: .whitespaces)
                guard !phrase.isEmpty, let date = known[phrase] ?? ReminderTime.parse(phrase, now: now, calendar: calendar) else { continue }
                matched = (length, date)
                dates[phrase] = date
                break
            }
            if let matched {
                output += ReminderTime.token(for: matched.date, calendar: calendar)
                index = text.index(next, offsetBy: skipped + matched.length)
                if index < text.endIndex, !text[index].isWhitespace { output.append(" ") }
                continue
            }
            output.append("@")
            index = next
        }
        return Result(text: output, dates: dates)
    }

    /// 文字中補上號碼的人（「@王小明 MVPN 61234」），依出現順序、不重複。
    static func people(in text: String) -> [NoteMentions.Person] {
        let ns = text as NSString
        var seen = Set<String>()
        return personPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let name = ns.substring(with: match.range(at: 1))
            let label = ns.substring(with: match.range(at: 2))
            let number = ns.substring(with: match.range(at: 3))
            guard seen.insert(name + number).inserted else { return nil }
            return NoteMentions.Person(name: name, dept: "", plant: "", numberLabel: label, number: number)
        }
    }

    private static let personPattern = try! NSRegularExpression(pattern: #"@(\p{L}[\p{L}\p{N}_]*) (MVPN|分機) ([0-9#*\-]+)"#)
}
