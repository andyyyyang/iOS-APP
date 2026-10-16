import SwiftUI

/// 指令面板（⌘K、頂部列的放大鏡）：全域搜尋。筆記、指令，以及業務快查的通訊錄、客戶與代碼、機種、開案案件、
/// BPM、人員、SOP、物流單號都在這裡直接找，結果分區列出，列上就能複製、撥打或開啟。上下鍵選擇、Return 執行、Esc 關閉。
/// iPad 右側欄打開時，頂部列的搜尋欄可以直接打字或用 Apple Pencil 手寫，結果列表接在搜尋欄下面展開（`attached`）。
struct CommandPalette: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    @State private var store = NotesStore.shared
    @State private var jentech = JentechStore.shared
    @State private var logistics = LogisticsStore.shared
    @State private var index = VaultIndexStore.shared
    @State private var sources = GlobalSearch.Sources()
    /// 搜尋的狀態（頂部列的搜尋欄也用同一份）。
    @State private var model = PaletteModel.shared
    @AppStorage(PaletteModel.recentKey) private var recentKeywordsRaw = ""

    /// 輸入中的文字（打空白或逗號就變成一個關鍵字）。
    private var query: String {
        get { model.query }
        nonmutating set { model.query = newValue }
    }

    /// 已經加入的關鍵字：每一個都要符合，越加越精確。
    private var keywords: [String] {
        get { model.keywords }
        nonmutating set { model.keywords = newValue }
    }

    private var scope: Scope? {
        get { model.scope }
        nonmutating set { model.scope = newValue }
    }

    private var selection: Int {
        get { model.selection }
        nonmutating set { model.selection = newValue }
    }

    /// 結果列表接在頂部列的搜尋欄下面。
    private var isAttached: Bool { model.presentation == .attached }

    /// 只看某一類結果。
    enum Scope: Hashable {
        case section(GlobalSearch.Section)
        case notes

        static let all: [Scope] = GlobalSearch.Section.allCases.map(Scope.section) + [.notes]

        var title: String {
            switch self {
            case .section(let section): return section.title
            case .notes: return "筆記"
            }
        }

        var section: GlobalSearch.Section? {
            if case .section(let section) = self { return section }
            return nil
        }
    }

    /// 搜尋欄下方的建議：加入輸入中的字、只看某一類、再加一個篩選關鍵字、最近用過的關鍵字。
    private struct Suggestion: Identifiable {
        enum Action {
            case add(String)
            case scope(Scope)
            case keyword(String)
        }

        let id: String
        let title: String
        var count: Int?
        var systemImage: String?
        let action: Action
    }

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
        let results = self.results
        let sections = results.sections
        let items = sections.flatMap(\.items)
        let rows = Self.rows(sections)
        Group {
            if isAttached {
                // 不蓋住頂部列：搜尋欄要能繼續打字或手寫
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 52)
                        .allowsHitTesting(false)
                    ZStack(alignment: .topTrailing) {
                        Color.black.opacity(0.12)
                            .ignoresSafeArea(edges: .bottom)
                            .onTapGesture { close() }
                        panel(results: results, items: items, rows: rows, maxHeight: 460)
                            .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
                            .frame(maxWidth: 560)
                            .padding(.leading, 12)
                            .padding(.trailing, 10)
                            .padding(.top, 4)
                    }
                    // 手寫時列表不接受點擊（筆畫不會誤點到結果或關掉列表）
                    .allowsHitTesting(!model.isWriting)
                }
            } else {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture { close() }

                    VStack(spacing: 0) {
                        fieldRow(items: items)
                        panel(results: results, items: items, rows: rows, maxHeight: sizeClass == .compact ? 440 : 560)
                    }
                    .frame(maxWidth: 680)
                    .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
                    .padding(.horizontal, 12)
                    .padding(.top, sizeClass == .compact ? 8 : 64)
                }
            }
        }
        .onAppear {
            // 從頂部列的搜尋欄打開時保留已經寫的字
            if !isAttached { model.reset() }
        }
        // 頂部列的搜尋欄按了 Return
        .onChange(of: model.submitToken) { _, _ in run(items) }
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
        .onChange(of: keywords) { _, _ in selection = 0 }
        .onChange(of: scope) { _, _ in selection = 0 }
        // 頂部列的上下鍵不知道有幾列：超出時拉回來
        .onChange(of: selection) { _, value in
            let clamped = min(max(value, 0), max(items.count - 1, 0))
            if clamped != value { selection = clamped }
        }
        // 頂部列的搜尋欄不見了（收起右側欄、全螢幕、視窗變窄）
        .onChange(of: workspace.isRightOpen) { _, _ in if isAttached { close() } }
        .onChange(of: workspace.isFullScreen) { _, _ in if isAttached { close() } }
        .onChange(of: sizeClass) { _, _ in if isAttached { close() } }
    }

    /// 置中面板上方的搜尋欄。
    private func fieldRow(items: [Item]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DS.textSecondary)
            PaletteSearchField(
                text: Binding(get: { model.query }, set: { model.query = $0 }),
                placeholder: keywords.isEmpty && scope == nil ? "搜尋筆記、人名分機、客戶、機種、案件或指令" : "再加一個關鍵字…",
                focusToken: model.focusToken,
                onSubmit: { run(items) },
                onSeparator: { model.commit($0) },
                onDeleteWhenEmpty: { model.removeLastCondition() },
                onArrow: { delta in selection = min(max(selection + delta, 0), max(items.count - 1, 0)) },
                onTab: { model.commitTyping() },
                onEscape: { close() }
            )
            .frame(height: 52)
            Button("取消") { close() }
                .font(.subheadline)
                .foregroundStyle(DS.textSecondary)
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var hint: String {
        if isAttached {
            return "可以直接打字或用 Apple Pencil 寫：人名、分機、客戶、機種、開案號、BPM、SOP、物流單號；空一格再加一個關鍵字"
        }
        return "可以直接搜尋人名、分機、客戶、客代、T-Code、機種、開案號、SAP 品號、BPM、SOP、物流單號；打空白就能再加一個關鍵字"
    }

    /// 建議與結果列表（置中的面板與頂部列下面的列表共用）。
    private func panel(results: (sections: [Section], suggestions: [Suggestion]), items: [Item], rows: [Row], maxHeight: CGFloat) -> some View {
        let showsChips = scope != nil || !keywords.isEmpty || !results.suggestions.isEmpty
        return VStack(spacing: 0) {
            if showsChips {
                chipRow(results.suggestions)
                    .padding(.top, isAttached ? 8 : 0)
            }
            if showsChips || !isAttached {
                Rectangle().fill(DS.hairline).frame(height: 1)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    // 結果最多幾十列：不用 LazyVStack，每次輸入整個重建（列不會沿用上一次的內容）
                    VStack(alignment: .leading, spacing: 1) {
                        if searchText.isEmpty && scope == nil {
                            Text(hint)
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
                                    .id(item.id)
                                    .onTapGesture {
                                        selection = index
                                        run(items)
                                    }
                            }
                        }
                        if items.isEmpty {
                            Text(searchText.isEmpty ? "沒有資料" : "找不到「\(searchText)」")
                                .font(.subheadline)
                                .foregroundStyle(DS.textTertiary)
                                .padding(16)
                        }
                    }
                    .padding(6)
                    .id(searchText + "|" + (scope?.title ?? ""))
                }
                .frame(maxHeight: maxHeight)
                .onChange(of: selection) { _, value in
                    guard items.indices.contains(value) else { return }
                    withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(items[value].id) }
                }
            }
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

    /// 所有關鍵字加上輸入中的字。
    private var searchText: String {
        (keywords + [query]).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private var recentKeywords: [String] {
        recentKeywordsRaw.split(separator: "\n").map(String.init)
    }

    /// 結果與建議一起算（同一份比對）。
    private var results: (sections: [Section], suggestions: [Suggestion]) {
        let text = searchText
        let prepared = GlobalSearch.Query(text)
        let typing = query.trimmingCharacters(in: .whitespaces)
        var suggestions: [Suggestion] = []
        if !typing.isEmpty {
            suggestions.append(Suggestion(id: "add", title: "加入「\(typing)」", systemImage: "plus", action: .add(typing)))
        }

        // 什麼都還沒輸入：最近的筆記與指令，建議列出各類與最近用過的關鍵字
        if prepared.tokens.isEmpty && scope == nil {
            for scope in Scope.all {
                suggestions.append(Suggestion(id: "scope:" + scope.title, title: scope.title, action: Suggestion.Action.scope(scope)))
            }
            for keyword in recentKeywords {
                suggestions.append(Suggestion(id: "recent:" + keyword, title: keyword, systemImage: "clock.arrow.circlepath", action: Suggestion.Action.keyword(keyword)))
            }
            return ([
                Section(id: "recent", title: "最近的筆記", items: store.notes.prefix(8).map(noteItem)),
                Section(id: "commands", title: "指令", items: commands),
            ], suggestions)
        }

        var ranked: [(score: Int, order: Int, section: Section)] = []
        var counts: [(scope: Scope, count: Int)] = []
        if scope != .notes {
            for group in GlobalSearch.search(text, in: sources, scope: scope?.section) {
                ranked.append((group.best, ranked.count, Section(id: group.section.rawValue, title: group.section.title, count: group.total, items: group.hits.map(hitItem))))
                counts.append((Scope.section(group.section), group.total))
            }
        }
        if scope == nil || scope == .notes {
            let notes = matchingNotes(prepared, limit: scope == .notes ? GlobalSearch.scopedLimit : 20)
            if !notes.items.isEmpty {
                ranked.append((notes.best, ranked.count, Section(id: "notes", title: "筆記", count: notes.total, items: notes.items.map(noteItem))))
                counts.append((Scope.notes, notes.total))
            }
        }

        var sections: [Section] = []
        let commands = self.commands
        if scope == nil {
            // 指令名稱含有每個關鍵字才列（例如「通訊錄」「BPM」）
            let matching = commands.filter { GlobalSearch.rank(prepared, [$0.title, $0.detail]) != nil }
            if !matching.isEmpty { sections.append(Section(id: "commands", title: "指令", items: Array(matching.prefix(3)))) }
        }
        let ordered = ranked.sorted { (a: (score: Int, order: Int, section: Section), b: (score: Int, order: Int, section: Section)) -> Bool in
            if a.score != b.score { return a.score > b.score }
            return a.order < b.order
        }
        sections += ordered.map(\.section)
        if sections.isEmpty, scope == nil, keywords.isEmpty {
            let fuzzy = commands.filter { Self.score($0.title, query: text) != nil }
            if !fuzzy.isEmpty { sections.append(Section(id: "more-commands", title: "其他指令", items: fuzzy)) }
        }

        // 建議：結果分在哪幾類（點了只看那一類）、可以再加的篩選關鍵字（依目前的結果算）
        if scope == nil, counts.count > 1 {
            for (scope, count) in counts {
                suggestions.append(Suggestion(id: "scope:" + scope.title, title: scope.title, count: count, action: Suggestion.Action.scope(scope)))
            }
        }
        if scope != .notes {
            for facet in GlobalSearch.facets(text, in: sources, scope: scope?.section) {
                suggestions.append(Suggestion(id: "facet:" + facet.text, title: facet.text, count: facet.count, systemImage: "plus.circle", action: Suggestion.Action.keyword(facet.text)))
            }
        }
        return (sections, suggestions)
    }

    /// 筆記：標題、資料夾或標籤含有每一個關鍵字（新的在前）；只有一個關鍵字而且找到的很少時，再加上字依序出現的。
    private func matchingNotes(_ prepared: GlobalSearch.Query, limit: Int) -> (items: [NoteSummary], total: Int, best: Int) {
        if prepared.tokens.isEmpty {
            return (Array(store.notes.prefix(limit)), store.notes.count, 0)
        }
        var hits: [(note: NoteSummary, score: Int)] = []
        for note in store.notes {
            if let score = GlobalSearch.rank(prepared, [note.title, note.folder] + note.tags) { hits.append((note, score)) }
        }
        hits.sort { (a: (note: NoteSummary, score: Int), b: (note: NoteSummary, score: Int)) -> Bool in
            if a.score != b.score { return a.score > b.score }
            return a.note.mtime > b.note.mtime
        }
        let best = hits.first?.score ?? 0
        if prepared.tokens.count == 1, hits.count < 5 {
            let found = Set(hits.map(\.note.path))
            let word = prepared.tokens[0].text
            var fuzzy: [(note: NoteSummary, score: Int)] = []
            for note in store.notes where !found.contains(note.path) {
                if let score = Self.score(note.title, query: word) { fuzzy.append((note, score)) }
            }
            fuzzy.sort { $0.score > $1.score }
            for item in fuzzy.prefix(10) { hits.append((item.note, 0)) }
        }
        return (hits.prefix(limit).map(\.note), hits.count, best)
    }

    /// 已加入的條件（深色，可以移除）與建議（框線，點了加入）。
    private func chipRow(_ suggestions: [Suggestion]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let scope {
                    activeChip("只看 \(scope.title)") { self.scope = nil }
                }
                ForEach(Array(keywords.enumerated()), id: \.offset) { index, keyword in
                    activeChip(keyword) {
                        if keywords.indices.contains(index) { keywords.remove(at: index) }
                    }
                }
                if (scope != nil || !keywords.isEmpty) && !suggestions.isEmpty {
                    Rectangle().fill(DS.hairline).frame(width: 1, height: 18)
                }
                ForEach(suggestions) { suggestion in
                    Button { apply(suggestion) } label: {
                        HStack(spacing: 4) {
                            if let image = suggestion.systemImage {
                                Image(systemName: image).font(.system(size: 10, weight: .semibold))
                            }
                            Text(suggestion.title).font(.footnote.weight(.medium)).lineLimit(1)
                            if let count = suggestion.count {
                                Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(DS.textTertiary)
                            }
                        }
                        .foregroundStyle(DS.text)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().strokeBorder(DS.cardBorder, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if scope != nil || !keywords.isEmpty {
                    Button("清除") {
                        keywords = []
                        scope = nil
                        query = ""
                        model.focusToken += 1
                    }
                    .font(.footnote)
                    .foregroundStyle(DS.textSecondary)
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func activeChip(_ title: String, onRemove: @escaping () -> Void) -> some View {
        Button(action: onRemove) {
            HStack(spacing: 4) {
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(DS.onPrimary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(DS.primary, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("移除 \(title)")
    }

    private func apply(_ suggestion: Suggestion) {
        switch suggestion.action {
        case .add(let text):
            model.commit(text)
        case .scope(let scope):
            self.scope = scope
        case .keyword(let keyword):
            if !keywords.contains(keyword) { keywords.append(keyword) }
            model.remember(keyword)
        }
        model.focusToken += 1
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
            let searched = searchText
            let ext: String = contact.ext.isEmpty ? "" : "分機 " + contact.ext
            let mvpn: String = contact.mvpn.isEmpty ? "" : "MVPN " + contact.mvpn
            let detail = Self.joined([ext, mvpn, contact.dept, contact.plant])
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
            let name: String = code.kind == .customer ? code.fullName : code.name
            return Item(
                id: hit.id, title: code.displayCode + "  " + name,
                detail: Self.joined([code.kind.rawValue, code.detail]),
                systemImage: code.kind == .customer ? "building.2" : "number",
                trailing: AnyView(CopyButton(value: code.code))
            ) { workspace.openNote(code.path) }
        case .model(let entry):
            return Item(
                id: hit.id, title: entry.code,
                detail: Self.joined(["機種主卡", entry.customer, entry.detail]),
                systemImage: "cpu",
                trailing: AnyView(CopyButton(value: entry.code))
            ) { workspace.openNote(entry.path) }
        case .caseItem(let item):
            let number: String = item.caseNo.isEmpty ? item.file : item.caseNo
            let sap: String = item.sapNo.isEmpty ? "" : "SAP " + item.sapNo
            return Item(
                id: hit.id, title: Self.joined([number, item.product], separator: "  "),
                detail: Self.joined([sap, item.customer, item.created]),
                systemImage: WorkspaceTab.cases.systemImage,
                trailing: AnyView(CopyButton(value: item.caseNo.isEmpty ? item.sapNo : item.caseNo))
            ) { workspace.openNote(item.path) }
        case .bpm(let item):
            let days = item.daysStuck ?? 0
            let stuck: String = days > 0 ? "卡 \(days) 天" : ""
            let title: String = item.subject.isEmpty ? item.processName : item.subject
            return Item(
                id: hit.id, title: title,
                detail: Self.joined([item.processName, item.currentStep, stuck]),
                systemImage: WorkspaceTab.bpm.systemImage
            ) { workspace.open(.bpm) }
        case .person(let card):
            return Item(
                id: hit.id, title: Self.joined([card.name, card.english], separator: "  "),
                detail: "人員卡", systemImage: "person.text.rectangle"
            ) { workspace.openNote(card.path) }
        case .sop(let sop):
            return Item(
                id: hit.id, title: sop.name,
                detail: Self.joined([sop.stage] + Array(sop.tags.prefix(3))),
                systemImage: WorkspaceTab.sop.systemImage
            ) {
                if let path = jentech.path(forNote: sop.file) { workspace.openNote(path) } else { workspace.openLink(sop.file) }
            }
        case .parcel(let item):
            return Item(
                id: hit.id, title: Self.joined([item.courierName, item.trackingNumber], separator: " "),
                detail: Self.joined([item.note, item.latestEvent]),
                systemImage: WorkspaceTab.logistics.systemImage,
                trailing: AnyView(CopyButton(value: item.trackingNumber))
            ) { workspace.open(.logistics) }
        }
    }

    /// 非空的部分用「 · 」連起來。
    private static func joined(_ parts: [String], separator: String = " · ") -> String {
        parts.filter { !$0.isEmpty }.joined(separator: separator)
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
            Item(id: "fullscreen", title: workspace.isFullScreen ? "結束全螢幕" : "全螢幕", detail: "收起頂部列、功能列與側欄（⌃⌘F）", systemImage: workspace.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", isCommand: true, action: { workspace.toggleFullScreen() }),
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

// MARK: - 搜尋狀態

/// 全域搜尋的狀態：置中的指令面板與頂部列的搜尋欄共用（在頂部列輸入，下面展開的列表顯示結果）。
/// 面板關閉時（`Workspace.showsPalette` 變成 false）由工作區呼叫 `reset()`。
@MainActor
@Observable
final class PaletteModel {
    enum Presentation {
        /// 置中的面板（⌘K、放大鏡、iPhone）。
        case centered
        /// 接在頂部列搜尋欄下面的列表（iPad 右側欄打開時，可以直接打字或用 Apple Pencil 手寫）。
        case attached
    }

    static let shared = PaletteModel()
    nonisolated static let recentKey = "search.recentKeywords"

    var presentation = Presentation.centered
    /// 輸入中的文字（打空白或逗號就變成一個關鍵字）。
    var query = ""
    /// 已經加入的關鍵字：每一個都要符合，越加越精確。
    var keywords: [String] = []
    var scope: CommandPalette.Scope?
    var selection = 0
    /// 改變時讓搜尋欄重新成為輸入焦點（點了建議之後接著打字）。
    var focusToken = 0
    /// 頂部列的搜尋欄按了 Return：面板執行選取的那一列。
    var submitToken = 0
    /// 正在用 Apple Pencil 在頂部列的搜尋欄手寫。
    var isWriting = false

    func reset() {
        presentation = .centered
        query = ""
        keywords = []
        scope = nil
        selection = 0
        isWriting = false
    }

    /// 輸入中的字變成關鍵字（可以一次好幾個，用空白或逗號分開），輸入欄清空接著打下一個。
    func commit(_ text: String) {
        let words = text.split { PaletteSearchField.separators.contains($0) }.map(String.init)
        for word in words where !keywords.contains(word) {
            keywords.append(word)
            remember(word)
        }
        query = ""
    }

    /// Tab：輸入中的字變成關鍵字。
    func commitTyping() {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { commit(query) }
    }

    /// 搜尋欄是空的時按刪除鍵：拿掉最後一個關鍵字（沒有關鍵字時拿掉「只看」）。
    func removeLastCondition() {
        if !keywords.isEmpty {
            keywords.removeLast()
        } else if scope != nil {
            scope = nil
        }
    }

    /// 最近用過的關鍵字（最多 8 個）。
    func remember(_ keyword: String) {
        let defaults = UserDefaults.standard
        var list = (defaults.string(forKey: Self.recentKey) ?? "").split(separator: "\n").map(String.init).filter { $0 != keyword }
        list.insert(keyword, at: 0)
        defaults.set(list.prefix(8).joined(separator: "\n"), forKey: Self.recentKey)
    }
}

// MARK: - 搜尋欄

/// 指令面板的搜尋欄（UIKit 的文字欄）：注音、拼音等輸入法還在組字時不搜尋、也不把空白當成分隔，選好字才更新結果；
/// 打空白或逗號把前面的字變成關鍵字，空的時按刪除鍵拿掉最後一個關鍵字；上下鍵選擇、Tab 加入關鍵字、Esc 關閉。
/// UIKit 的文字欄本來就能用 Apple Pencil 手寫（隨手寫），寫好的字和打字一樣更新結果。
struct PaletteSearchField: UIViewRepresentable {
    enum Tone {
        /// 白色面板上。
        case card
        /// 黑色頂部列上。
        case ink
    }

    @Binding var text: String
    var placeholder: String
    var focusToken: Int
    var onSubmit: () -> Void
    var onSeparator: (String) -> Void
    var onDeleteWhenEmpty: () -> Void
    var onArrow: (Int) -> Void
    var onTab: () -> Void
    var onEscape: () -> Void
    /// 出現時就開始輸入（置中的面板）；頂部列的搜尋欄要點了或寫了才開始。
    var autofocus = true
    /// 變成 false 時結束輸入（頂部列的搜尋欄在列表關閉時）；`focusToken` 只在 true 時有作用。
    var isActive = true
    var tone = Tone.card
    /// 開始輸入或手寫（頂部列的搜尋欄在這時展開列表）。
    var onBegin: (() -> Void)?
    /// Apple Pencil 開始、結束手寫。
    var onWriting: ((Bool) -> Void)?

    static let separators: Set<Character> = [" ", "　", ",", "，", "、"]

    func makeUIView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        let textColor = tone == .ink ? UIColor(DS.onInk) : UIColor(DS.text)
        field.font = .systemFont(ofSize: tone == .ink ? 15 : 17)
        field.textColor = textColor
        field.tintColor = textColor
        if tone == .ink { field.keyboardAppearance = .dark }
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.coordinator = context.coordinator
        if onWriting != nil {
            field.addInteraction(UIScribbleInteraction(delegate: context.coordinator))
        }
        context.coordinator.focusToken = focusToken
        context.coordinator.wasActive = isActive
        if autofocus {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        }
        return field
    }

    func updateUIView(_ field: SearchTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.placeholder != placeholder {
            coordinator.placeholder = placeholder
            if tone == .ink {
                field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor(DS.onInkDim)])
            } else {
                field.placeholder = placeholder
            }
        }
        // 組字中不動文字（會打斷輸入法）
        if field.markedTextRange == nil, field.text != text {
            field.text = text
        }
        if coordinator.focusToken != focusToken {
            coordinator.focusToken = focusToken
            if isActive {
                DispatchQueue.main.async { field.becomeFirstResponder() }
            }
        }
        if coordinator.wasActive != isActive {
            coordinator.wasActive = isActive
            if !isActive, field.isFirstResponder {
                field.resignFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate, UIScribbleInteractionDelegate {
        var parent: PaletteSearchField
        var focusToken = 0
        var wasActive = true
        var placeholder: String?

        init(parent: PaletteSearchField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            // 輸入法還在組字（注音、拼音）：選好字才算
            guard field.markedTextRange == nil else { return }
            // 還沒開始輸入就寫進字（Apple Pencil 隨手寫）：先展開列表，字才不會被清掉
            if !parent.isActive { parent.onBegin?() }
            let value = field.text ?? ""
            if let last = value.last, PaletteSearchField.separators.contains(last) {
                parent.onSeparator(value)
                field.text = ""
                parent.text = ""
                return
            }
            if parent.text != value { parent.text = value }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onBegin?()
        }

        func scribbleInteractionWillBeginWriting(_ interaction: UIScribbleInteraction) {
            parent.onWriting?(true)
        }

        func scribbleInteractionDidFinishWriting(_ interaction: UIScribbleInteraction) {
            parent.onWriting?(false)
        }
    }
}

/// 搜尋欄的文字欄：空的時按刪除鍵、外接鍵盤的上下鍵、Tab 與 Esc 交給指令面板。
final class SearchTextField: UITextField {
    weak var coordinator: PaletteSearchField.Coordinator?

    override func deleteBackward() {
        if (text ?? "").isEmpty, markedTextRange == nil {
            coordinator?.parent.onDeleteWhenEmpty()
        }
        super.deleteBackward()
    }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(moveUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(moveDown)),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tab)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape)),
        ]
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func moveUp() { coordinator?.parent.onArrow(-1) }
    @objc private func moveDown() { coordinator?.parent.onArrow(1) }
    @objc private func tab() { coordinator?.parent.onTab() }
    @objc private func escape() { coordinator?.parent.onEscape() }
}
