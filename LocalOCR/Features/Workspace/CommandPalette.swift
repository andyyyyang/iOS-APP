import SwiftUI

/// 指令面板（⌘K、頂部列的放大鏡）：全域搜尋。筆記、指令，以及業務快查的通訊錄、客戶與代碼、機種、開案案件、
/// BPM、人員、SOP、物流單號都在這裡直接找，結果分區列出，列上就能複製、撥打或開啟。上下鍵選擇、Return 執行、Esc 關閉。
struct CommandPalette: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    @State private var store = NotesStore.shared
    @State private var jentech = JentechStore.shared
    @State private var logistics = LogisticsStore.shared
    @State private var index = VaultIndexStore.shared
    @State private var sources = GlobalSearch.Sources()
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String
        let title: String
        var detail: String = ""
        let systemImage: String
        var isCommand = false
        /// 列右側的按鈕（複製、撥打、開啟筆記）。
        var trailing: AnyView?
        let action: () -> Void
    }

    private struct Section: Identifiable {
        let id: String
        var title: String?
        var count: Int?
        let items: [Item]
    }

    private enum Row: Identifiable {
        case header(String, title: String, count: Int?)
        case item(Item, index: Int)

        var id: String {
            switch self {
            case .header(let id, _, _): return "header:" + id
            case .item(let item, _): return item.id
            }
        }
    }

    var body: some View {
        let sections = self.sections
        let items = sections.flatMap(\.items)
        let rows = Self.rows(sections)
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(DS.textSecondary)
                    TextField("搜尋筆記、人名分機、客戶、機種、案件或指令", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($focused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .onSubmit { run(items) }
                    Button("取消") { close() }
                        .font(.subheadline)
                        .foregroundStyle(DS.textSecondary)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)

                Rectangle().fill(DS.hairline).frame(height: 1)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                                Text("可以直接搜尋人名、分機、客戶、客代、T-Code、機種、開案號、SAP 品號、BPM、SOP、物流單號")
                                    .font(.caption)
                                    .foregroundStyle(DS.textTertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 6)
                            }
                            ForEach(rows) { row in
                                switch row {
                                case .header(_, let title, let count):
                                    sectionHeader(title, count: count)
                                case .item(let item, let index):
                                    self.row(item, isSelected: index == selection)
                                        .id(index)
                                        .onTapGesture {
                                            selection = index
                                            run(items)
                                        }
                                }
                            }
                            if items.isEmpty {
                                Text("找不到「\(query)」")
                                    .font(.subheadline)
                                    .foregroundStyle(DS.textTertiary)
                                    .padding(16)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: sizeClass == .compact ? 440 : 560)
                    .onChange(of: selection) { _, value in
                        withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(value) }
                    }
                }
            }
            .frame(maxWidth: 680)
            .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .padding(.horizontal, 12)
            .padding(.top, sizeClass == .compact ? 8 : 64)
        }
        .onAppear {
            query = ""
            selection = 0
            focused = true
        }
        // 業務快查的資料：通訊錄與 BPM 讀一次後留著，索引與物流超過一分鐘才重新取得
        .task {
            async let index: Void = jentech.ensureIndex()
            async let contacts: Void = jentech.loadContacts()
            async let parcels: Void = logistics.ensureLoaded()
            _ = await (index, contacts, parcels)
            if jentech.bpm == nil { await jentech.loadBpm() }
        }
        .task(id: sourcesVersion) { sources = currentSources() }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(items.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
    }

    private static func rows(_ sections: [Section]) -> [Row] {
        var rows: [Row] = []
        var index = 0
        for section in sections where !section.items.isEmpty {
            if let title = section.title { rows.append(.header(section.id, title: title, count: section.count)) }
            for item in section.items {
                rows.append(.item(item, index: index))
                index += 1
            }
        }
        return rows
    }

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.textSecondary)
            if let count {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(DS.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    private func row(_ item: Item, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? DS.onPrimary : DS.textSecondary)
                .frame(width: 30, height: 30)
                .background(isSelected ? DS.primary : DS.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let trailing = item.trailing {
                trailing
            }
            if item.isCommand {
                Text("指令")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(DS.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? DS.control : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: - 結果

    /// 沒有輸入時：最近的筆記與指令。有輸入時：符合的指令在最上面，筆記與業務快查各區依最符合的一筆排序。
    private var sections: [Section] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let commands = self.commands
        if trimmed.isEmpty {
            return [
                Section(id: "recent", title: "最近的筆記", items: store.notes.prefix(8).map(noteItem)),
                Section(id: "commands", title: "指令", items: commands),
            ]
        }
        let strong = commands.filter { GlobalSearch.rank(trimmed, [$0.title, $0.detail]) != nil }
        let strongIDs = Set(strong.map(\.id))
        let weak = commands.filter { !strongIDs.contains($0.id) && Self.score($0.title, query: trimmed) != nil }

        let noteMatches = store.notes
            .compactMap { note in Self.score(note.title, query: trimmed).map { (note, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(20)
        var ranked: [(score: Int, order: Int, section: Section)] = []
        for (order, group) in GlobalSearch.search(trimmed, in: sources).enumerated() {
            ranked.append((group.best, order, Section(id: group.section.rawValue, title: group.section.title, count: group.total, items: group.hits.map(hitItem))))
        }
        if !noteMatches.isEmpty {
            // 標題含有關鍵字的筆記跟業務快查一起排；只有字依序出現（模糊）的排在後面
            let best = noteMatches.compactMap { GlobalSearch.rank(trimmed, [$0.0.title]) }.max() ?? 0
            ranked.append((best, ranked.count, Section(id: "notes", title: "筆記", items: noteMatches.map { noteItem($0.0) })))
        }

        var result: [Section] = []
        if !strong.isEmpty { result.append(Section(id: "commands", title: "指令", items: Array(strong.prefix(3)))) }
        result += ranked.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.map(\.section)
        let rest = Array(strong.dropFirst(3)) + weak
        if !rest.isEmpty { result.append(Section(id: "more-commands", title: "其他指令", items: rest)) }
        return result
    }

    /// 資料有變（索引更新、通訊錄或 BPM 讀到了、物流清單更新）時重新取一次要搜尋的資料。
    private var sourcesVersion: String {
        "\(index.updatedAt?.timeIntervalSince1970 ?? 0)|\(index.notes.count)|\(jentech.contacts.count)|\(jentech.bpm?.fetchedAt ?? "")|\(logistics.items.count)"
    }

    private func currentSources() -> GlobalSearch.Sources {
        GlobalSearch.Sources(
            contacts: jentech.contacts,
            codes: jentech.codes,
            models: ModelCatalog.entries(from: Array(index.notes.values)),
            cases: jentech.cases,
            bpm: jentech.bpm?.items ?? [],
            people: jentech.cards.filter { $0.kind == .person },
            sops: JentechLogic.sops,
            parcels: logistics.items
        )
    }

    /// 業務快查的一筆：點一下做最常用的事（複製分機、開啟筆記或工具頁），右側有複製與撥打。
    private func hitItem(_ hit: GlobalSearch.Hit) -> Item {
        switch hit.target {
        case .contact(let contact):
            let number = contact.copyValue
            let searched = query
            let detail = [
                contact.ext.isEmpty ? "" : "分機 \(contact.ext)",
                contact.mvpn.isEmpty ? "" : "MVPN \(contact.mvpn)",
                contact.dept,
                contact.plant,
            ].filter { !$0.isEmpty }.joined(separator: " · ")
            return Item(id: hit.id, title: contact.name, detail: detail, systemImage: "person.crop.circle", trailing: AnyView(contactButtons(contact))) {
                if !number.isEmpty {
                    UIPasteboard.general.string = number
                    jentech.remember(searched)
                    workspace.toast = "已複製：\(contact.name) \(number)"
                } else if let target = contact.linkTarget {
                    workspace.openLink(target)
                }
            }
        case .code(let code):
            let name = code.kind == .customer ? code.fullName : code.name
            return Item(
                id: hit.id, title: "\(code.displayCode)  \(name)",
                detail: ([code.kind.rawValue] + (code.detail.isEmpty ? [] : [code.detail])).joined(separator: " · "),
                systemImage: code.kind == .customer ? "building.2" : "number",
                trailing: AnyView(CopyButton(value: code.code))
            ) { workspace.openNote(code.path) }
        case .model(let entry):
            return Item(
                id: hit.id, title: entry.code,
                detail: (["機種主卡", entry.customer, entry.detail].filter { !$0.isEmpty }).joined(separator: " · "),
                systemImage: "cpu",
                trailing: AnyView(CopyButton(value: entry.code))
            ) { workspace.openNote(entry.path) }
        case .caseItem(let item):
            return Item(
                id: hit.id, title: [item.caseNo.isEmpty ? item.file : item.caseNo, item.product].filter { !$0.isEmpty }.joined(separator: "  "),
                detail: [item.sapNo.isEmpty ? "" : "SAP \(item.sapNo)", item.customer, item.created].filter { !$0.isEmpty }.joined(separator: " · "),
                systemImage: WorkspaceTab.cases.systemImage,
                trailing: AnyView(CopyButton(value: item.caseNo.isEmpty ? item.sapNo : item.caseNo))
            ) { workspace.openNote(item.path) }
        case .bpm(let item):
            let stuck = item.daysStuck.map { $0 > 0 ? "卡 \($0) 天" : "" } ?? ""
            return Item(
                id: hit.id, title: item.subject.isEmpty ? item.processName : item.subject,
                detail: [item.processName, item.currentStep, stuck].filter { !$0.isEmpty }.joined(separator: " · "),
                systemImage: WorkspaceTab.bpm.systemImage
            ) { workspace.open(.bpm) }
        case .person(let card):
            return Item(
                id: hit.id, title: card.english.isEmpty ? card.name : "\(card.name)  \(card.english)",
                detail: "人員卡", systemImage: "person.text.rectangle"
            ) { workspace.openNote(card.path) }
        case .sop(let sop):
            return Item(
                id: hit.id, title: sop.name,
                detail: ([sop.stage] + sop.tags.prefix(3)).joined(separator: " · "),
                systemImage: WorkspaceTab.sop.systemImage
            ) {
                if let path = jentech.path(forNote: sop.file) { workspace.openNote(path) } else { workspace.openLink(sop.file) }
            }
        case .parcel(let item):
            return Item(
                id: hit.id, title: "\(item.courierName) \(item.trackingNumber)",
                detail: [item.note, item.latestEvent].filter { !$0.isEmpty }.joined(separator: " · "),
                systemImage: WorkspaceTab.logistics.systemImage,
                trailing: AnyView(CopyButton(value: item.trackingNumber))
            ) { workspace.open(.logistics) }
        }
    }

    /// 聯絡人右側：有人員筆記時開啟、撥打 MVPN、複製分機（沒有分機時複製 MVPN）。
    private func contactButtons(_ contact: JentechContact) -> some View {
        HStack(spacing: 6) {
            if let target = contact.linkTarget {
                Button {
                    close()
                    workspace.openLink(target)
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(CircleIconButtonStyle(size: 30))
                .accessibilityLabel("開啟 \(contact.name) 的筆記")
            }
            if let number = JentechLogic.dialable(contact.mvpn), let url = URL(string: "tel:\(number)") {
                Button {
                    openURL(url)
                } label: {
                    Image(systemName: "phone.fill")
                }
                .buttonStyle(CircleIconButtonStyle(size: 30))
                .accessibilityLabel("撥打 MVPN \(contact.mvpn)")
            }
            CopyButton(value: contact.copyValue)
        }
    }

    private func noteItem(_ note: NoteSummary) -> Item {
        Item(
            id: "note:" + note.path,
            title: note.title,
            detail: note.folder.isEmpty ? "最上層" : note.folder,
            systemImage: note.isJournal ? "book.closed" : (note.isNotebook ? "pencil" : "doc.text"),
            isCommand: false,
            action: { workspace.openNote(note.path) }
        )
    }

    private var commands: [Item] {
        var items: [Item] = [
            Item(id: "journal", title: "打開日誌筆記本", detail: "今天的一頁", systemImage: "book.closed", isCommand: true, action: { workspace.openJournal() }),
            Item(id: "new-note", title: "新增筆記", detail: "", systemImage: "square.and.pencil", isCommand: true, action: { workspace.newTextNote() }),
            Item(id: "new-notebook", title: "新增手寫筆記", detail: "", systemImage: "pencil", isCommand: true, action: { workspace.newNotebook() }),
            Item(id: "new-journal", title: "新增日誌筆記本", detail: "一頁一頁、依日期整理、#機種標記", systemImage: "book.closed", isCommand: true, action: { workspace.newJournal() }),
            Item(id: "new-tasks", title: "新增待辦清單", detail: "", systemImage: "checkmark.square", isCommand: true, action: { workspace.newTaskNote() }),
            Item(id: "graph", title: "開啟關聯圖", detail: "", systemImage: WorkspaceTab.graph.systemImage, isCommand: true, action: { workspace.open(.graph) }),
            Item(id: "tasks", title: "所有待辦", detail: "", systemImage: "checkmark.square", isCommand: true, action: { workspace.open(.tasks) }),
            Item(id: "drawings", title: "圖面瀏覽與產能清單", detail: "", systemImage: WorkspaceTab.drawings.systemImage, isCommand: true, action: { workspace.open(.drawings) }),
            Item(id: "logistics", title: "物流追蹤（快遞單號）", detail: "", systemImage: WorkspaceTab.logistics.systemImage, isCommand: true, action: { workspace.open(.logistics) }),
            Item(id: "hub", title: "業務快查與物流中心", detail: "", systemImage: WorkspaceTab.hub.systemImage, isCommand: true, action: { workspace.open(.hub) }),
            Item(id: "contacts", title: "快速通訊錄查詢（分機、MVPN）", detail: "", systemImage: WorkspaceTab.contacts.systemImage, isCommand: true, action: { workspace.open(.contacts) }),
            Item(id: "codes", title: "代碼查詢（客戶、SAP T-Code）", detail: "", systemImage: WorkspaceTab.codes.systemImage, isCommand: true, action: { workspace.open(.codes) }),
            Item(id: "cases", title: "案件查詢（開案 Checklist）", detail: "", systemImage: WorkspaceTab.cases.systemImage, isCommand: true, action: { workspace.open(.cases) }),
            Item(id: "bpm", title: "BPM 追蹤", detail: "", systemImage: WorkspaceTab.bpm.systemImage, isCommand: true, action: { workspace.open(.bpm) }),
            Item(id: "cards", title: "編輯人員卡／客戶卡", detail: "", systemImage: WorkspaceTab.cards.systemImage, isCommand: true, action: { workspace.open(.cards) }),
            Item(id: "sop", title: "SOP 導覽", detail: "", systemImage: WorkspaceTab.sop.systemImage, isCommand: true, action: { workspace.open(.sop) }),
            Item(id: "vault", title: "瀏覽整個 vault", detail: "", systemImage: "folder", isCommand: true, action: { workspace.open(.folder("")) }),
            Item(id: "scan", title: "掃描文件", detail: "", systemImage: "viewfinder", isCommand: true, action: { workspace.open(.scan) }),
            Item(id: "camera", title: "開啟相機連續拍照", detail: "", systemImage: "camera", isCommand: true, action: { workspace.showsCamera = true }),
            Item(id: "history", title: "掃描紀錄", detail: "", systemImage: "clock", isCommand: true, action: { workspace.open(.history) }),
            Item(id: "left", title: "切換左側欄", detail: "", systemImage: "sidebar.left", isCommand: true, action: { workspace.toggleLeft() }),
            Item(id: "right", title: "切換右側欄", detail: "", systemImage: "sidebar.right", isCommand: true, action: { workspace.toggleRight() }),
            Item(id: "search", title: "搜尋內文", detail: "", systemImage: "magnifyingglass", isCommand: true, action: { workspace.showLeft(.search) }),
            Item(id: "sync", title: "立即同步", detail: "", systemImage: "arrow.triangle.2.circlepath", isCommand: true, action: { Task { await VaultSyncCenter.shared.syncNow() } }),
            Item(id: "settings", title: "設定", detail: "", systemImage: "slider.horizontal.3", isCommand: true, action: { workspace.open(.settings) }),
        ]
        if !VaultSyncCenter.shared.isConfigured {
            items.insert(Item(id: "pair", title: "與 Obsidian 配對", detail: "", systemImage: "link", isCommand: true, action: { workspace.showsPairing = true }), at: 0)
        }
        if workspace.active != .start {
            items.append(Item(id: "close", title: "關閉目前分頁", detail: "", systemImage: "xmark", isCommand: true, action: { workspace.closeActive() }))
        }
        return items
    }

    /// 模糊比對：字依序出現即可；連續、開頭、越短的標題分數越高。
    nonisolated static func score(_ title: String, query: String) -> Int? {
        let haystack = Array(title.lowercased())
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        var score = 0
        var position = 0
        var previous = -2
        for character in needle {
            guard let found = haystack[position...].firstIndex(of: character) else { return nil }
            score += found == previous + 1 ? 8 : 1
            if found == 0 { score += 10 }
            previous = found
            position = found + 1
        }
        if title.lowercased().contains(query.lowercased()) { score += 20 }
        return score * 100 - haystack.count
    }

    private func run(_ items: [Item]) {
        guard items.indices.contains(selection) else { return }
        let action = items[selection].action
        close()
        action()
    }

    private func close() {
        workspace.showsPalette = false
    }
}
