import Foundation
import Observation

/// 物流追蹤頁的狀態：清單、物流商、筆記單號，以及進行中的操作。
@MainActor
@Observable
final class LogisticsStore {
    static let shared = LogisticsStore()

    typealias Item = LogisticsClient.Item

    private(set) var items: [Item] = []
    /// 讀到伺服器的清單前先用工具的預設（同伺服器）。
    private(set) var couriers: [LogisticsClient.Courier] = LogisticsStore.defaultCouriers
    private(set) var statuses: [LogisticsClient.Status] = LogisticsStore.defaultStatuses
    private(set) var dhl = false
    private(set) var track17 = false
    private(set) var refreshInfo: LogisticsClient.Refresh?
    private(set) var path = "06 日誌/物流追蹤/watchlist.json"
    private(set) var linked: [LogisticsClient.LinkedNote] = []
    private(set) var isLoading = false
    private(set) var isLoadingLinked = false
    private(set) var loadedAt: Date?
    private(set) var error: String?
    /// 正在新增或刷新的單號。
    private(set) var busy: Set<String> = []
    private(set) var isRefreshingAll = false
    /// 底部的短暫提示。
    var toast: String?

    static let defaultCouriers: [LogisticsClient.Courier] = [
        .init(code: "t-cat", name: "黑貓宅急便", url: "https://www.t-cat.com.tw/Inquire/Trace.aspx?BillID={number}", live: true),
        .init(code: "dhl", name: "DHL Express", url: "https://www.dhl.com/tw-zh/home/tracking/tracking-express.html?submit=1&tracking-id={number}", live: false),
        .init(code: "fedex", name: "FedEx 聯邦快遞", url: "https://www.fedex.com/fedextrack/?trknbr={number}", live: false),
        .init(code: "ups", name: "UPS 優比速", url: "https://www.ups.com/track?tracknum={number}&loc=zh_TW", live: false),
        .init(code: "sf-express", name: "順豐速運", url: "https://www.sf-express.com/tw/tc/dynamic_function/waybill/waybill_query_by_bill_no.html?billNo={number}", live: true),
        .init(code: "tw-hct-logistics", name: "新竹物流", url: "https://www.hct.com.tw/searchgoods.aspx", live: false),
        .init(code: "kerry-tj", name: "嘉里大榮", url: "https://www.kerrytj.com/ZH/search/search_sort.aspx", live: false),
        .init(code: "taiwan-post", name: "中華郵政", url: "https://postserv.post.gov.tw/pstmail/main_mail.html", live: false),
    ]

    static let defaultStatuses: [LogisticsClient.Status] = [
        .init(id: "transit", label: "運送中", color: "#2563eb"),
        .init(id: "delivered", label: "已送達", color: "#059669"),
        .init(id: "pickup", label: "已攬收", color: "#d97706"),
        .init(id: "exception", label: "異常", color: "#dc2626"),
        .init(id: "pending", label: "待處理", color: "#7c3aed"),
        .init(id: "notfound", label: "查無資料", color: "#6b7280"),
    ]

    var active: [Item] { items.filter { !$0.isArchived } }
    var archived: [Item] { items.filter(\.isArchived) }

    func status(_ id: String) -> LogisticsClient.Status? {
        statuses.first { $0.id == id }
    }

    func courier(_ code: String) -> LogisticsClient.Courier? {
        couriers.first { $0.code == code }
    }

    func trackingURL(for item: Item) -> URL? {
        LogisticsLogic.trackingURL(template: courier(item.courierCode)?.url, number: item.trackingNumber)
    }

    private func client() -> LogisticsClient? {
        guard let client = LogisticsClient.configured() else {
            error = "還沒有連接伺服器"
            return nil
        }
        return client
    }

    func load() async {
        guard !isLoading, let client = client() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            apply(try await client.list())
            error = nil
            loadedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func ensureLoaded() async {
        if loadedAt == nil || Date().timeIntervalSince(loadedAt ?? .distantPast) > 60 { await load() }
    }

    private func apply(_ list: LogisticsClient.List) {
        items = list.items
        couriers = list.couriers
        statuses = list.statuses
        dhl = list.dhl
        track17 = list.track17
        refreshInfo = list.refresh
        path = list.path
    }

    func loadLinked() async {
        guard !isLoadingLinked, let client = client() else { return }
        isLoadingLinked = true
        defer { isLoadingLinked = false }
        do {
            linked = try await client.linked()
        } catch {
            toast = "讀取筆記單號失敗：\(error.localizedDescription)"
        }
    }

    private func replace(_ item: Item) {
        if let index = items.firstIndex(where: { $0.trackingNumber == item.trackingNumber }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }
        if let index = linked.firstIndex(where: { $0.trackingNumber == item.trackingNumber }) {
            linked[index].tracked = true
        }
    }

    /// 新增追蹤；成功時回傳 true。
    @discardableResult
    func add(courier: String, number rawNumber: String, note: String) async -> Bool {
        let number = LogisticsLogic.normalize(rawNumber)
        guard !number.isEmpty, let client = client() else { return false }
        busy.insert(number)
        defer { busy.remove(number) }
        do {
            let item = try await client.add(courier: courier, number: number, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            replace(item)
            toast = "已加入追蹤：\(item.latestEvent)"
            return true
        } catch {
            toast = "新增失敗：\(error.localizedDescription)"
            return false
        }
    }

    func update(_ item: Item, note: String? = nil, status: String? = nil, archived: Bool? = nil) async {
        guard let client = client() else { return }
        do {
            replace(try await client.update(item.trackingNumber, note: note, status: status, archived: archived))
        } catch {
            toast = "修改失敗：\(error.localizedDescription)"
        }
    }

    func remove(_ item: Item) async {
        guard let client = client() else { return }
        do {
            try await client.delete(item.trackingNumber)
            items.removeAll { $0.trackingNumber == item.trackingNumber }
            if let index = linked.firstIndex(where: { $0.trackingNumber == item.trackingNumber }) { linked[index].tracked = false }
        } catch {
            toast = "刪除失敗：\(error.localizedDescription)"
        }
    }

    func refresh(_ item: Item) async {
        guard let client = client() else { return }
        busy.insert(item.trackingNumber)
        defer { busy.remove(item.trackingNumber) }
        do {
            let updated = try await client.refresh(item.trackingNumber)
            replace(updated)
            toast = updated.latestEvent == item.latestEvent ? "沒有新的動態" : "最新動態：\(updated.latestEvent)"
        } catch {
            toast = "刷新失敗：\(error.localizedDescription)"
        }
    }

    func refreshAll() async {
        guard !isRefreshingAll, let client = client() else { return }
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        do {
            let result = try await client.refreshAll()
            items = result.items
            toast = result.refreshed == 0 ? "沒有追蹤中的單號" : "已刷新 \(result.refreshed) 筆"
            await load()
        } catch {
            toast = "批次刷新失敗：\(error.localizedDescription)"
        }
    }

    func archiveDelivered() async {
        guard let client = client() else { return }
        do {
            let count = try await client.archiveDelivered()
            toast = count == 0 ? "目前沒有狀態為已送達的單號" : "已結案 \(count) 筆"
            if count > 0 { await load() }
        } catch {
            toast = "結案失敗：\(error.localizedDescription)"
        }
    }

    func clearArchived() async {
        guard let client = client() else { return }
        do {
            let count = try await client.clearArchived()
            items.removeAll(where: \.isArchived)
            toast = "已清空 \(count) 筆結案單號"
        } catch {
            toast = "清空失敗：\(error.localizedDescription)"
        }
    }

    /// 筆記單號關聯 → 加入追蹤（備註＝客戶＋案件編號，同電腦上的工具）。
    func track(_ note: LogisticsClient.LinkedNote) async {
        let remark = [note.customer, note.caseNo].filter { !$0.isEmpty }.joined(separator: " ")
        await add(courier: note.courier, number: note.trackingNumber, note: remark)
    }
}
