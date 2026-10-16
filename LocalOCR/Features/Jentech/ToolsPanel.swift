import SwiftUI

/// 左側欄的「業務快查」：上方固定的快速查詢框（人名、分機、客戶、代碼、案件、單號一次查），
/// 沒有輸入時是工具選單（看板、JT 業務追蹤、物流追蹤、通訊錄、代碼查詢、案件查詢、BPM 追蹤、編輯卡片、SOP 導覽）。
struct ToolsPanel: View {
    @Environment(Workspace.self) private var workspace
    @State private var store = JentechStore.shared
    @State private var logistics = LogisticsStore.shared
    @State private var jt = JtSyncStore.shared
    @State private var query = ""
    @State private var toast: String?

    private static let menu: [WorkspaceTab] = [.hub, .jt, .logistics, .contacts, .codes, .cases, .bpm, .cards, .sop]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "業務快查", subtitle: "通訊錄、代碼、案件、物流") { EmptyView() }
            SearchField(placeholder: "快速查詢：人名、分機、客戶、代碼、單號", text: $query)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(Self.menu, id: \.id) { tab in
                            menuRow(tab)
                        }
                    } else {
                        results
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .task {
            await store.ensureIndex()
            await store.loadContacts()
        }
        .toast($toast)
    }

    // MARK: 選單

    private func detail(for tab: WorkspaceTab) -> String {
        switch tab {
        case .hub: return "七個工具的總覽"
        case .logistics: return logistics.loadedAt == nil ? "快遞單號背景追蹤" : "追蹤中 \(logistics.active.count)"
        case .jt: return jt.detailLine
        case .contacts: return store.contacts.isEmpty ? "分機與 MVPN" : "\(store.contacts.count) 筆"
        case .codes: return "客戶客代與 SAP T-Code"
        case .cases: return "開案 Checklist"
        case .bpm: return store.bpm.map { "要催 \($0.stuck.count)" } ?? "流程簽核進度"
        case .cards: return "人員卡與客戶卡"
        case .sop: return "\(JentechLogic.sops.count) 個流程"
        default: return ""
        }
    }

    private func menuRow(_ tab: WorkspaceTab) -> some View {
        let isActive = workspace.active == tab
        return Button {
            workspace.open(tab)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DS.text)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab == .hub ? "業務看板" : tab.title)
                        .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(DS.text)
                    Text(detail(for: tab))
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isActive ? DS.control : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 快速查詢

    @ViewBuilder
    private var results: some View {
        let text = query
        let contacts = store.contacts.filter { JentechLogic.matches(text, [$0.plant, $0.dept, $0.name, $0.ext, $0.mvpn]) }.prefix(12)
        let codes = store.codes.filter { JentechLogic.matches(text, [$0.code, $0.alias, $0.name, $0.fullName, $0.detail]) }.prefix(8)
        let cases = store.cases.filter { JentechLogic.matches(text, [$0.caseNo, $0.sapNo, $0.product, $0.customer, $0.bpmRdmn, $0.file]) }.prefix(6)
        let parcels = logistics.items.filter { JentechLogic.matches(text, [$0.trackingNumber, $0.note]) }.prefix(4)
        if contacts.isEmpty && codes.isEmpty && cases.isEmpty && parcels.isEmpty {
            Text(store.isLoadingContacts ? "通訊錄讀取中…" : "沒有符合的結果")
                .font(.footnote)
                .foregroundStyle(DS.textTertiary)
                .padding(10)
        }
        if !contacts.isEmpty {
            sectionTitle("通訊錄")
            ForEach(Array(contacts)) { contact in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(contact.name).font(.system(size: 14, weight: .medium)).foregroundStyle(DS.text).lineLimit(1)
                        Text("\(contact.dept) · \(contact.plant)").font(.caption2).foregroundStyle(DS.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(contact.ext.isEmpty ? "—" : contact.ext).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(DS.text)
                        Text(contact.mvpn.isEmpty ? "—" : contact.mvpn).font(.caption2.monospacedDigit()).foregroundStyle(DS.textSecondary)
                    }
                    Button {
                        UIPasteboard.general.string = contact.copyValue
                        toast = "已複製：\(contact.name) \(contact.copyValue)"
                        store.remember(text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .disabled(contact.copyValue.isEmpty)
                    .accessibilityLabel("複製 \(contact.name) 的分機")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        if !codes.isEmpty {
            sectionTitle("客戶與代碼")
            ForEach(Array(codes)) { code in
                HStack(spacing: 8) {
                    Button {
                        workspace.open(.note(code.path))
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(code.displayCode).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(DS.text)
                            Text(code.kind == .customer ? code.fullName : code.name).font(.caption2).foregroundStyle(DS.textSecondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        UIPasteboard.general.string = code.code
                        toast = "已複製代碼：\(code.code)"
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .disabled(code.code.isEmpty)
                    .accessibilityLabel("複製代碼 \(code.code)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        if !cases.isEmpty {
            sectionTitle("開案案件")
            ForEach(Array(cases)) { item in
                Button {
                    workspace.open(.note(item.path))
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.caseNo.isEmpty ? item.file : item.caseNo).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(DS.text)
                        Text([item.customer, item.product].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption2).foregroundStyle(DS.textSecondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        if !parcels.isEmpty {
            sectionTitle("物流單號")
            ForEach(Array(parcels)) { item in
                Button {
                    workspace.open(.logistics)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(item.courierName) \(item.trackingNumber)").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
                        Text(item.latestEvent.isEmpty ? item.note : item.latestEvent).font(.caption2).foregroundStyle(DS.textSecondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(DS.textTertiary)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}
