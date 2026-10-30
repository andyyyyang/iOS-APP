import Foundation
import Observation
import UserNotifications

/// 筆記中的提醒「(@2026-10-31 15:00)」：時間到了跳出通知，點了打開那則筆記。
/// 這台裝置上的筆記讀檔案（存檔、同步下載時更新）；還沒下載的筆記用伺服器索引中的待辦（例如在電腦寫的提醒）。
/// 依時間先後排最近的 60 個（系統最多 64 個），每次有變動就重新對齊。
@MainActor
@Observable
final class NoteReminderCenter {
    static let shared = NoteReminderCenter()

    /// 點了通知要打開的筆記（ContentView 在工作區打開後清掉）。
    var openRequest: String?

    @ObservationIgnored private var entries: [String: [NoteReminder]] = [:]
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var scheduling: Task<Void, Never>?
    @ObservationIgnored private let delegate = ReminderNotificationDelegate()

    init(fileURL: URL = .applicationSupportDirectory.appending(path: "NoteReminders.json")) {
        self.fileURL = fileURL
        let saved = (try? JSONDecoder().decode([NoteReminder].self, from: Data(contentsOf: fileURL))) ?? []
        entries = Dictionary(grouping: saved, by: \.path)
    }

    /// App 啟動時：接收通知的點擊（點通知打開 App 時也收得到）。
    func activate() {
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// 之後要排的提醒（測試與畫面用）。
    var upcoming: [NoteReminder] {
        let now = Date()
        return entries.values.flatMap { $0 }.filter { $0.date > now }.sorted { $0.date < $1.date }
    }

    /// 筆記存檔或下載了新版本：重新找出這則筆記的提醒。
    func update(path: String, text: String) {
        let path = LocalVault.normalize(path)
        guard path.lowercased().hasSuffix(".md") else { return }
        let found = NoteReminderParser.reminders(in: text, path: path, title: Self.title(of: path))
        if replace(found, for: path) { commit() }
    }

    /// 這台裝置上的檔案改了（同步下載）：讀檔重新找。
    func refresh(paths: [String], vault: LocalVault = .shared) {
        var changed = false
        for path in paths.map(LocalVault.normalize) where path.lowercased().hasSuffix(".md") {
            let found = vault.readText(path).map { NoteReminderParser.reminders(in: $0, path: path, title: Self.title(of: path)) } ?? []
            changed = replace(found, for: path) || changed
        }
        if changed { commit() }
    }

    func remove(path: String) {
        if replace([], for: LocalVault.normalize(path)) { commit() }
    }

    /// 改名或搬移：提醒跟著新位置。
    func move(from oldPath: String, to newPath: String, vault: LocalVault = .shared) {
        _ = replace([], for: LocalVault.normalize(oldPath))
        refresh(paths: [newPath], vault: vault)
        commit()
    }

    /// 伺服器索引更新了：還沒下載到這台裝置的筆記，用索引中沒完成的待辦找提醒；
    /// 已經不在 vault（索引與這台裝置都沒有）的筆記拿掉它的提醒。
    func updateFromIndex(_ notes: [String: VaultIndex.Note], vault: LocalVault = .shared) {
        guard !notes.isEmpty else { return }
        var changed = false
        for (path, note) in notes {
            let open = note.tasks.filter { !$0.done && $0.text.contains("(@") }
            // 只看有提醒、或之前有提醒的筆記；這台裝置上有的筆記讀檔案
            guard !open.isEmpty || entries[path] != nil, !vault.exists(path) else { continue }
            let found = open.flatMap {
                NoteReminderParser.reminders(inLine: "- [ ] " + $0.text, path: path, title: note.title.isEmpty ? Self.title(of: path) : note.title)
            }
            changed = replace(found, for: path) || changed
        }
        for path in entries.keys where notes[path] == nil && !vault.exists(path) {
            changed = replace([], for: path) || changed
        }
        if changed { commit() }
    }

    /// 啟動時掃一次這台裝置上的筆記（例如之前在別處寫好的提醒）。
    func rescanLocalNotes(vault: LocalVault = .shared) async {
        let found = await Task.detached(priority: .utility) { () -> [String: [NoteReminder]] in
            var result: [String: [NoteReminder]] = [:]
            for file in vault.allFiles() where file.path.lowercased().hasSuffix(".md") {
                guard let text = vault.readText(file.path), text.contains("(@") else { continue }
                let title = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
                let reminders = NoteReminderParser.reminders(in: text, path: file.path, title: title)
                if !reminders.isEmpty { result[file.path] = reminders }
            }
            return result
        }.value
        var changed = false
        for path in Set(entries.keys).union(found.keys) where vault.exists(path) {
            changed = replace(found[path] ?? [], for: path) || changed
        }
        if changed {
            commit()
        } else {
            schedule()
        }
    }

    /// 插入提醒時：還沒問過就請使用者允許通知。
    func requestPermissionIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                schedule()
            }
        }
    }

    // MARK: - 排程

    private static func title(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private func replace(_ reminders: [NoteReminder], for path: String) -> Bool {
        guard (entries[path] ?? []) != reminders else { return false }
        entries[path] = reminders.isEmpty ? nil : reminders
        return true
    }

    private func commit() {
        let all = entries.values.flatMap { $0 }.sorted { $0.date < $1.date }
        try? JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
        schedule()
    }

    /// 系統的待發通知對齊目前的提醒：最近的 60 個，過期與拿掉的取消。
    func schedule() {
        scheduling?.cancel()
        let wanted = Array(upcoming.prefix(60))
        scheduling = Task {
            let center = UNUserNotificationCenter.current()
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined, !wanted.isEmpty {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                status = await center.notificationSettings().authorizationStatus
            }
            guard !Task.isCancelled, status == .authorized || status == .provisional || status == .ephemeral else { return }
            let pending = Set(await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(NoteReminderParser.identifierPrefix) })
            let ids = Set(wanted.map(\.id))
            center.removePendingNotificationRequests(withIdentifiers: Array(pending.subtracting(ids)))
            for reminder in wanted where !pending.contains(reminder.id) {
                guard !Task.isCancelled else { return }
                let content = UNMutableNotificationContent()
                content.title = reminder.text.isEmpty ? "提醒" : reminder.title
                content.body = reminder.text.isEmpty ? reminder.title : reminder.text
                content.sound = .default
                content.threadIdentifier = reminder.path
                content.userInfo = ["path": reminder.path]
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
            }
        }
    }
}

/// 通知的點擊：打開那則筆記；App 在前景時也顯示橫幅。
private final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            Task { @MainActor in NoteReminderCenter.shared.openRequest = path }
        }
        completionHandler()
    }
}
