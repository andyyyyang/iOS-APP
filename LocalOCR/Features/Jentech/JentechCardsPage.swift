import SwiftUI

/// 編輯卡片：建立或修改人員卡（03 人員/部門/）與客戶卡（04 客戶/）的屬性（frontmatter），同插件的「編輯卡片」頁籤。
/// 修改時只改動有變的欄位，其他內容（含巢狀屬性與筆記內文）原樣保留。
struct JentechCardsPage: View {
    private struct Field: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
        var isList: Bool
        /// 索引中是巢狀或空白的值：沒改就不動。
        var original: String?
    }

    @Environment(Workspace.self) private var workspace
    @State private var store = JentechStore.shared
    @State private var kind: JentechCard.Kind = .person
    @State private var query = ""
    @State private var editingPath: String?
    @State private var fields: [Field] = []
    @State private var removed: Set<String> = []
    @State private var newKey = ""
    @State private var isSaving = false
    @State private var toast: String?

    static let depts = ["業務處", "技術服務課", "業務一課", "業務二課", "業務三課", "業務四課", "業務五課", "業務六課", "品保處", "生管處", "製造處", "研發處"]

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar("編輯卡片", subtitle: editingPath == nil ? "新卡片" : "編輯中", query: $query, searchPlaceholder: kind == .person ? "載入現有人員卡（姓名、英文名）" : "載入現有客戶卡（名稱、英文名）", pinnedSearch: true) {
                Button {
                    reset()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(CircleIconButtonStyle())
                .accessibilityLabel("開新卡片")
            } chips: {
                SegmentedPills(options: [(value: JentechCard.Kind.person, title: "人員卡"), (value: JentechCard.Kind.customer, title: "客戶卡")], selection: $kind)
            }
            ToolScroll {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    existingList
                }
                form
            }
        }
        .background(DS.pane)
        .task {
            await store.ensureIndex()
            if fields.isEmpty { reset() }
        }
        .onChange(of: kind) { reset() }
        .toast($toast)
    }

    // MARK: 現有卡片

    @ViewBuilder
    private var existingList: some View {
        let matches = store.cards.filter { $0.kind == kind && JentechLogic.matches(query, [$0.name, $0.english, $0.path]) }.prefix(10)
        if matches.isEmpty {
            Text("沒有相符的卡片").font(.footnote).foregroundStyle(DS.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(matches)) { card in
                    Button {
                        load(card)
                    } label: {
                        HStack {
                            Text(card.english.isEmpty ? card.name : "\(card.name)（\(card.english)）")
                                .font(.subheadline)
                                .foregroundStyle(DS.text)
                            Spacer()
                            Text((card.path as NSString).deletingLastPathComponent)
                                .font(.caption2)
                                .foregroundStyle(DS.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .card(padding: 12)
        }
    }

    // MARK: 表單

    private var values: [String: String] {
        Dictionary(fields.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private var targetPath: String? {
        editingPath ?? JentechLogic.cardPath(kind: kind, values: values)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($fields) { $field in
                HStack(spacing: 8) {
                    Text(field.key)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(DS.link)
                        .frame(width: 104, alignment: .leading)
                        .lineLimit(1)
                    if field.key == "dept", kind == .person {
                        Menu {
                            ForEach(Self.depts, id: \.self) { dept in
                                Button(dept) { field.value = dept }
                            }
                        } label: {
                            HStack {
                                Text(field.value.isEmpty ? "選擇部門" : field.value)
                                    .foregroundStyle(field.value.isEmpty ? DS.textTertiary : DS.text)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(DS.textSecondary)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .background(DS.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    } else {
                        TextField(field.isList ? "以逗號分隔" : "", text: $field.value)
                            .font(.subheadline)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .background(DS.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    Button {
                        removed.insert(field.key)
                        fields.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .accessibilityLabel("刪除欄位 \(field.key)")
                }
            }
            HStack(spacing: 8) {
                TextField("新增欄位名稱（例如 mvpn、phone）", text: $newKey)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(DS.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onSubmit(addField)
                Button("加欄位", action: addField)
                    .buttonStyle(SmallPillStyle())
                    .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Divider().padding(.vertical, 4)
            Group {
                if let editingPath {
                    Text("正在編輯：\(editingPath)")
                } else if let targetPath {
                    Text("將建立於：\(targetPath)")
                } else {
                    Text(kind == .person ? "請先填寫 name（並選擇 dept）" : "請先填寫 name")
                }
            }
            .font(.footnote)
            .foregroundStyle(DS.textSecondary)
            HStack(spacing: 8) {
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().tint(DS.onPrimary) }
                        Text(editingPath == nil ? "建立卡片" : "更新卡片")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                .disabled(targetPath == nil || isSaving)
                Button {
                    UIPasteboard.general.string = frontmatterText
                    toast = "已複製 Frontmatter"
                } label: {
                    Text("複製 Frontmatter")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            }
        }
        .card(padding: 14)
    }

    private var frontmatterText: String {
        var lines = ["---", "type: \(kind.rawValue)"]
        for field in fields where !field.value.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("\(field.key): \(JentechLogic.yamlValue(field.value, isList: field.isList))")
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    // MARK: 動作

    private func reset() {
        editingPath = nil
        removed = []
        query = ""
        switch kind {
        case .person:
            fields = ["name", "english_name", "dept", "title", "ext", "employee_id"].map { Field(key: $0, value: "", isList: false) }
                + [Field(key: "tags", value: "people", isList: true)]
        case .customer:
            fields = ["name", "english_name", "alias", "credit_account", "industry", "region"].map { Field(key: $0, value: "", isList: false) }
                + [Field(key: "tags", value: "customer", isList: true)]
        }
    }

    private func load(_ card: JentechCard) {
        guard let note = VaultIndexStore.shared.notes[card.path] else { return }
        editingPath = card.path
        removed = []
        query = ""
        fields = note.properties.keys.sorted().compactMap { key -> Field? in
            guard key != "type", key != "position" else { return nil }
            switch note.properties[key] {
            case .text(let value): return Field(key: key, value: value, isList: false, original: value)
            case .list(let values): return Field(key: key, value: values.joined(separator: ", "), isList: true, original: values.joined(separator: ", "))
            case .empty, .none: return Field(key: key, value: "", isList: false, original: "")
            }
        }
        // name 放最前面
        if let index = fields.firstIndex(where: { $0.key == "name" }) { fields.insert(fields.remove(at: index), at: 0) }
    }

    private func addField() {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !fields.contains(where: { $0.key == key }), key.range(of: #"^[A-Za-z0-9_\-\p{Han}]+$"#, options: .regularExpression) != nil else {
            toast = "欄位名稱只能用英數字、底線或中文，且不能重複"
            return
        }
        fields.append(Field(key: key, value: "", isList: false))
        removed.remove(key)
        newKey = ""
    }

    private func save() async {
        guard let path = targetPath else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if let editingPath {
                let text = String(decoding: try await DataviewData.read(editingPath), as: UTF8.self)
                // 只寫有變動的欄位；原本是空白或巢狀、沒有改的欄位不動
                let changed = fields.filter { $0.original == nil || $0.value != $0.original }
                let updated = JentechLogic.updateFrontmatter(
                    text,
                    set: changed.map { (key: $0.key, value: $0.value, isList: $0.isList) },
                    remove: removed.subtracting(fields.map(\.key))
                )
                try DataviewData.write(updated, to: editingPath)
                toast = "已更新 \(editingPath)"
            } else {
                if DataviewData.exists(path) {
                    toast = "檔案已存在：\(path)"
                    return
                }
                let content = JentechLogic.newCard(fields: [(key: "type", value: kind.rawValue, isList: false)] + fields.map { (key: $0.key, value: $0.value, isList: $0.isList) })
                try DataviewData.write(content, to: path)
                toast = "已建立 \(path)"
            }
            await NotesStore.shared.reload()
            VaultIndexStore.shared.scheduleRefresh(after: 3)
            workspace.open(.note(path))
        } catch {
            toast = "儲存失敗：\(error.localizedDescription)"
        }
    }
}
