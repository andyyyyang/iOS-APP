import XCTest
@testable import LocalOCR

/// 筆記中的「@人名」與「@時間」提醒。
final class NoteMentionsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }

    /// 2026-10-30（週五）10:00。
    private var now: Date { date(2026, 10, 30, 10, 0) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func parse(_ text: String) -> Date? {
        ReminderTime.parse(text, now: now, calendar: calendar)
    }

    // MARK: - 輸入中的 @

    func testOpenQueryFindsTheMentionBeingTyped() {
        let text = "聯絡 @王小"
        let query = NoteMentions.openQuery(in: text, cursor: NSRange(location: (text as NSString).length, length: 0))
        XCTAssertEqual(query?.text, "王小")
        XCTAssertEqual(query?.range, NSRange(location: 3, length: 3))

        let bare = "提醒我 @"
        XCTAssertEqual(NoteMentions.openQuery(in: bare, cursor: NSRange(location: (bare as NSString).length, length: 0))?.text, "")

        let time = "@明天 3點"
        XCTAssertEqual(NoteMentions.openQuery(in: time, cursor: NSRange(location: (time as NSString).length, length: 0))?.text, "明天 3點")
    }

    func testOpenQueryIgnoresEmailsAndFinishedMentions() {
        for text in ["寄到 andy@example", "打給 @王小明 MVPN 61234 ", "開會 (@2026-10-31 15:00) ", "@王小明 要報價 明天"] {
            XCTAssertNil(NoteMentions.openQuery(in: text, cursor: NSRange(location: (text as NSString).length, length: 0)), text)
        }
    }

    // MARK: - @人名

    func testPeopleUseMVPNFirstThenExtension() {
        let contacts = [
            JentechContact(order: 0, plant: "大園一廠", dept: "陳王課", rawName: "陳王明", ext: "", mvpn: ""),
            JentechContact(order: 1, plant: "大園一廠", dept: "業務課", rawName: "[[王小明]]", ext: "1234", mvpn: "61234"),
            JentechContact(order: 2, plant: "華亞廠", dept: "品保課", rawName: "王小美", ext: "2345", mvpn: "-"),
            JentechContact(order: 3, plant: "大園一廠", dept: "專案課", rawName: "王小明", ext: "1234", mvpn: "61234"),
        ]
        let people = NoteMentions.people(matching: "王", in: contacts)
        XCTAssertEqual(people.map(\.name), ["王小明", "王小美", "陳王明"], "開頭相同的在前，同一人只列一次")
        XCTAssertEqual(people[0].insertText, "@王小明 MVPN 61234")
        XCTAssertEqual(people[1].insertText, "@王小美 分機 2345", "沒有 MVPN 時用分機")
        XCTAssertEqual(people[2].insertText, "@陳王明")
        XCTAssertEqual(NoteMentions.people(matching: "王小明", in: contacts).first?.numberLabel, "MVPN")
        XCTAssertTrue(NoteMentions.people(matching: "", in: contacts).isEmpty)
    }

    // MARK: - @時間

    func testParsesDaysAndTimes() {
        XCTAssertEqual(parse("明天3點"), date(2026, 10, 31, 15, 0), "沒寫上午下午的 1–6 點是下午")
        XCTAssertEqual(parse("明天 下午3點半"), date(2026, 10, 31, 15, 30))
        XCTAssertEqual(parse("下午3點"), date(2026, 10, 30, 15, 0))
        XCTAssertEqual(parse("14:00"), date(2026, 10, 30, 14, 0))
        XCTAssertEqual(parse("3pm"), date(2026, 10, 30, 15, 0))
        XCTAssertEqual(parse("中午"), date(2026, 10, 30, 12, 0))
        XCTAssertEqual(parse("今晚"), date(2026, 10, 30, 20, 0))
        XCTAssertEqual(parse("明早"), date(2026, 10, 31, 9, 0))
        XCTAssertEqual(parse("後天 10點15分"), date(2026, 11, 1, 10, 15))
    }

    func testTimeThatAlreadyPassedMovesForward() {
        XCTAssertEqual(parse("9點"), date(2026, 10, 30, 21, 0), "早上的鐘點過了、晚上還沒到：今晚")
        XCTAssertEqual(parse("早上8點"), date(2026, 10, 31, 8, 0), "寫了早上就是明天早上")
    }

    func testParsesDatesAndWeekdays() {
        XCTAssertEqual(parse("10/31"), date(2026, 10, 31, 9, 0), "只有日期是早上 9 點")
        XCTAssertEqual(parse("11/3 9:00"), date(2026, 11, 3, 9, 0))
        XCTAssertEqual(parse("11月5號 下午2點"), date(2026, 11, 5, 14, 0))
        XCTAssertEqual(parse("2026/11/5 14:30"), date(2026, 11, 5, 14, 30))
        XCTAssertEqual(parse("10/29"), date(2027, 10, 29, 9, 0), "今年已經過了：明年")
        XCTAssertEqual(parse("週一 10點"), date(2026, 11, 2, 10, 0))
        XCTAssertEqual(parse("週五"), date(2026, 11, 6, 9, 0), "今天週五、9 點已經過了：下週五")
        XCTAssertEqual(parse("週五下午4點"), date(2026, 10, 30, 16, 0))
        XCTAssertEqual(parse("下週三"), date(2026, 11, 4, 9, 0))
    }

    func testParsesRelativeTimes() {
        XCTAssertEqual(parse("30分鐘後"), date(2026, 10, 30, 10, 30))
        XCTAssertEqual(parse("2小時後"), date(2026, 10, 30, 12, 0))
        XCTAssertEqual(parse("半小時後"), date(2026, 10, 30, 10, 30))
        XCTAssertEqual(parse("3天後"), date(2026, 11, 2, 9, 0))
    }

    func testRejectsTextThatIsNotATime() {
        for text in ["王小明", "明天吃飯", "13/40", "25:00", "", "MVPN"] {
            XCTAssertNil(parse(text), text)
        }
    }

    func testTokenAndLabel() {
        XCTAssertEqual(ReminderTime.token(for: date(2026, 10, 31, 15, 0), calendar: calendar), "(@2026-10-31 15:00)")
        XCTAssertEqual(ReminderTime.label(date(2026, 10, 30, 15, 0), now: now, calendar: calendar), "今天 15:00")
        XCTAssertEqual(ReminderTime.label(date(2026, 10, 31, 9, 0), now: now, calendar: calendar), "明天 09:00")
        XCTAssertEqual(ReminderTime.label(date(2026, 11, 3, 14, 0), now: now, calendar: calendar), "11/3（二）14:00")
        let presets = ReminderTime.presets(now: now, calendar: calendar)
        XCTAssertEqual(presets, [date(2026, 10, 30, 11, 0), date(2026, 10, 30, 20, 0), date(2026, 10, 31, 9, 0)])
    }

    // MARK: - 筆記中的提醒

    func testRemindersInANote() {
        let markdown = """
        ---
        due: (@2026-11-01 09:00)
        ---
        - [ ] 打給 @王小明 MVPN 61234 (@2026-10-31 15:00)
        - [x] 已完成 (@2026-10-31 16:00)
        ## 會議 (@2026-11-02)
        ```
        程式碼 (@2026-11-03 10:00)
        ```
        純文字 (@2026-11-04 08:30) 跟 (@2026-11-05 08:30)
        日期不對 (@2026-02-30 10:00)
        """
        let reminders = NoteReminderParser.reminders(in: markdown, path: "工作/週報.md", title: "週報", calendar: calendar)
        XCTAssertEqual(reminders.map(\.date), [
            date(2026, 10, 31, 15, 0), date(2026, 11, 2, 9, 0), date(2026, 11, 4, 8, 30), date(2026, 11, 5, 8, 30),
        ], "略過 frontmatter、完成的待辦、程式碼與不存在的日期")
        XCTAssertEqual(reminders.map(\.text), ["打給 @王小明 MVPN 61234", "會議", "純文字 跟", "純文字 跟"])
        XCTAssertEqual(Set(reminders.map(\.id)).count, 4)
        XCTAssertTrue(reminders.allSatisfy { $0.path == "工作/週報.md" && $0.title == "週報" })

        let bare = NoteReminderParser.reminders(inLine: "- [ ] (@2026-10-31 15:00)", path: "a.md", title: "a", calendar: calendar)
        XCTAssertEqual(bare.first?.text, "", "只有時間的行：通知用筆記標題")
    }
}
