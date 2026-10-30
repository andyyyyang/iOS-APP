import SwiftUI
import UIKit

/// 手寫筆記與日誌上方的「@」：手寫辨識出來的人（撥打或複製號碼）與提醒；都沒有時不顯示。
struct HandwritingMentionsMenu: View {
    /// 辨識出來的文字（已補上號碼、換成提醒）。
    let text: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        let people = HandwritingMentions.people(in: text)
        let reminders = NoteReminderParser.reminders(in: text, path: "", title: "")
        if !people.isEmpty || !reminders.isEmpty {
            Menu {
                if !people.isEmpty {
                    Section("人") {
                        ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                            Menu("\(person.name)　\(person.numberLabel) \(person.number)") {
                                if let digits = JentechLogic.dialable(person.number), let url = URL(string: "tel:\(digits)") {
                                    Button {
                                        openURL(url)
                                    } label: {
                                        Label("撥打", systemImage: "phone")
                                    }
                                }
                                Button {
                                    UIPasteboard.general.string = person.number
                                } label: {
                                    Label("複製號碼", systemImage: "doc.on.doc")
                                }
                            }
                        }
                    }
                }
                if !reminders.isEmpty {
                    Section("提醒") {
                        ForEach(Array(reminders.enumerated()), id: \.offset) { _, reminder in
                            Label(ReminderTime.label(reminder.date, now: Date()) + (reminder.text.isEmpty ? "" : "　" + reminder.text), systemImage: "bell")
                        }
                    }
                }
            } label: {
                Image(systemName: "at")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .frame(width: 32, height: 32)
                    .background(DS.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel("提到的人與提醒")
        }
    }
}
