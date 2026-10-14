import SwiftUI

/// 機種清單的篩選與排序（只存在記憶體中，換範圍時保留）。
struct DrawingListFilter: Equatable {
    enum Sort: String, CaseIterable, Identifiable {
        case drawings = "圖面數 ↓"
        case openQty = "未結量 ↓"
        case sizeDesc = "尺寸大→小"
        case sizeAsc = "尺寸小→大"
        case thickDesc = "厚度大→小"
        case thickAsc = "厚度小→大"
        case dwg = "圖號 A-Z"

        var id: String { rawValue }
    }

    enum SizeBucket: String, CaseIterable, Identifiable {
        case all = "長寬: 全部"
        case lt30 = "< 30 mm"
        case r30 = "30~50 mm"
        case r50 = "50~70 mm"
        case ge70 = "≥ 70 mm"

        var id: String { rawValue }

        func contains(_ value: Double) -> Bool {
            switch self {
            case .all: return true
            case .lt30: return value > 0 && value < 30
            case .r30: return value >= 30 && value < 50
            case .r50: return value >= 50 && value < 70
            case .ge70: return value >= 70
            }
        }
    }

    enum ThicknessBucket: String, CaseIterable, Identifiable {
        case all = "厚度: 全部"
        case lt15 = "< 1.5 mm"
        case r15 = "1.5~2.5 mm"
        case ge25 = "≥ 2.5 mm"

        var id: String { rawValue }

        func contains(_ value: Double) -> Bool {
            switch self {
            case .all: return true
            case .lt15: return value > 0 && value < 1.5
            case .r15: return value >= 1.5 && value < 2.5
            case .ge25: return value >= 2.5
            }
        }
    }

    static let types = ["FlatTop", "Hat", "Ring"]

    var query = ""
    /// nil = 全部
    var type: String?
    var size = SizeBucket.all
    var thickness = ThicknessBucket.all
    var sort = Sort.drawings
    var onlyWithDrawings = true
    var includeUncatalogued = true

    /// 套用篩選與排序。
    func apply(to models: [DrawingModel], library: DrawingsLibrary) -> [DrawingModel] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = models.filter { model in
            if onlyWithDrawings && model.drawings.isEmpty { return false }
            if !includeUncatalogued && !model.hasCatalog { return false }
            if let type, model.type != type { return false }
            let size = max(DrawingFormat.dimension(model.spec.length), DrawingFormat.dimension(model.spec.width))
            if !self.size.contains(size) { return false }
            if !thickness.contains(DrawingFormat.dimension(model.spec.thickness)) { return false }
            guard !query.isEmpty else { return true }
            return DrawingFormat.matches(query, in: Self.haystack(model, capacity: library.capacity(for: model)))
        }
        func size(_ model: DrawingModel) -> Double {
            max(DrawingFormat.dimension(model.spec.length), DrawingFormat.dimension(model.spec.width))
        }
        func thick(_ model: DrawingModel) -> Double { DrawingFormat.dimension(model.spec.thickness) }
        switch sort {
        case .drawings:
            return filtered.sorted { $0.drawings.count != $1.drawings.count ? $0.drawings.count > $1.drawings.count : $0.dwg < $1.dwg }
        case .openQty:
            return filtered.sorted {
                DrawingCapacity.openQty(model: $0, capacity: library.capacity(for: $0)).qty > DrawingCapacity.openQty(model: $1, capacity: library.capacity(for: $1)).qty
            }
        case .sizeDesc: return filtered.sorted { size($0) > size($1) }
        case .sizeAsc: return filtered.sorted { size($0) < size($1) }
        case .thickDesc: return filtered.sorted { thick($0) > thick($1) }
        case .thickAsc: return filtered.sorted { thick($0) < thick($1) }
        case .dwg: return filtered.sorted { $0.dwg.localizedStandardCompare($1.dwg) == .orderedAscending }
        }
    }

    static func haystack(_ model: DrawingModel, capacity: CapacityItem?) -> [String] {
        var parts = [model.dwg, model.sid, model.sap, model.endUser, model.endUserDwg, model.latestPo, model.type,
                     model.spec.length, model.spec.width, model.spec.thickness, model.spec.unitPrice]
        parts += model.drawings.map { "\($0.label) \($0.title)" }
        if let capacity {
            parts += [capacity.sid, capacity.sap, capacity.sheet]
            if let orders = capacity.orders {
                parts.append(orders.latestPo)
                parts += orders.poNumbers + orders.salesDocs + orders.refs + orders.cases
            }
        }
        return parts
    }
}

/// 左側的機種清單：搜尋、型態／尺寸／厚度篩選、排序，每一款一張卡片。
struct DrawingModelList: View {
    let models: [DrawingModel]
    let selectedID: String?
    @Binding var filter: DrawingListFilter
    var onSelect: (DrawingModel) -> Void
    var onSpec: (DrawingModel) -> Void

    @State private var library = DrawingsLibrary.shared

    var body: some View {
        let visible = filter.apply(to: models, library: library)
        VStack(spacing: 0) {
            header(visible: visible.count)
            Divider().overlay(DS.hairline)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if visible.isEmpty {
                            Text("沒有符合條件的機種")
                                .font(.subheadline)
                                .foregroundStyle(DS.textTertiary)
                                .padding(.top, 40)
                        }
                        ForEach(visible) { model in
                            DrawingModelCard(
                                model: model,
                                capacity: library.capacity(for: model),
                                isSelected: model.id == selectedID,
                                onSelect: { onSelect(model) },
                                onSpec: { onSpec(model) }
                            )
                            .id(model.id)
                        }
                    }
                    .padding(10)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    withAnimation { reader.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(DS.sidebar)
    }

    private func header(visible: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(DS.textTertiary)
                    TextField("搜尋機種 / SID / SAP / 原廠圖號 / PO 號 / 終端客戶…", text: $filter.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.subheadline)
                    if !filter.query.isEmpty {
                        Button { filter.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(DS.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1))
            }
            HStack(spacing: 6) {
                filterMenu(filter.type.map { "型態: \($0)" } ?? "型態: 全部", isActive: filter.type != nil) {
                    Button("全部") { filter.type = nil }
                    ForEach(DrawingListFilter.types, id: \.self) { type in
                        Button(type) { filter.type = type }
                    }
                }
                filterMenu(filter.size.rawValue, isActive: filter.size != .all) {
                    ForEach(DrawingListFilter.SizeBucket.allCases) { bucket in
                        Button(bucket.rawValue) { filter.size = bucket }
                    }
                }
                filterMenu(filter.thickness.rawValue, isActive: filter.thickness != .all) {
                    ForEach(DrawingListFilter.ThicknessBucket.allCases) { bucket in
                        Button(bucket.rawValue) { filter.thickness = bucket }
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    Picker("排序", selection: $filter.sort) {
                        ForEach(DrawingListFilter.Sort.allCases) { sort in
                            Text(sort.rawValue).tag(sort)
                        }
                    }
                    Divider()
                    Toggle("只顯示有圖面", isOn: $filter.onlyWithDrawings)
                    Toggle("含未登錄機種", isOn: $filter.includeUncatalogued)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(DS.text)
                }
                .accessibilityLabel("排序與顯示")
            }
            Text("\(visible)/\(models.count) 機種・\(models.reduce(0) { $0 + $1.drawings.count }) 張\(filter.sort == .drawings ? "" : "・\(filter.sort.rawValue)")")
                .font(.caption)
                .foregroundStyle(DS.textTertiary)
        }
        .padding(10)
    }

    private func filterMenu<Content: View>(_ title: String, isActive: Bool, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(isActive ? DS.onPrimary : DS.text)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isActive ? DS.primary : DS.control, in: Capsule())
        }
    }
}

/// 機種卡片：圖號、張數、終端客戶、型態，原廠圖號、SAP、尺寸、未結量與單價。
struct DrawingModelCard: View {
    let model: DrawingModel
    let capacity: CapacityItem?
    let isSelected: Bool
    var onSelect: () -> Void
    var onSpec: () -> Void

    var body: some View {
        let customerDwg = DrawingCustomers.customerDwg(of: model, capacity: capacity)
        let open = DrawingCapacity.openQty(model: model, capacity: capacity)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(model.dwg)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DS.link)
                tag("\(model.drawings.count) 張")
                if !model.endUser.isEmpty {
                    Text(model.endUser)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.text)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(DS.textTertiary, style: StrokeStyle(lineWidth: 1, dash: model.endUserGuessed ? [3, 2] : [])))
                        .opacity(model.endUserGuessed ? 0.8 : 1)
                        .help(model.endUserGuessed ? "catalog 沒登錄終端客戶，這是依客戶圖號字頭推定的（CV90 → Qualcomm）" : "")
                }
                DrawingTypeBadge(type: model.type)
                Spacer(minLength: 0)
            }
            HStack {
                Text("原廠：").foregroundStyle(DS.textTertiary)
                    + Text(customerDwg.value.isEmpty ? "-" : customerDwg.value).fontWeight(.semibold).foregroundStyle(DS.text)
                Spacer(minLength: 8)
                Text("SAP: \(model.sap.isEmpty ? "-" : model.sap)")
                    .foregroundStyle(DS.textSecondary)
            }
            .font(.caption)
            .lineLimit(1)
            Text("LWT: ").foregroundStyle(DS.textTertiary)
                + Text("\(dash(model.spec.length)) × \(dash(model.spec.width)) × \(dash(model.spec.thickness))").foregroundStyle(DS.link)
            HStack {
                if open.qty > 0 {
                    (Text("未結：").foregroundStyle(DS.textTertiary) + Text(DrawingFormat.qty(open.qty)).fontWeight(.bold).foregroundStyle(DS.danger))
                    if open.fromPoList { tag("PO") }
                } else {
                    Text(model.hasCatalog ? "已出清 / NPI" : "未登錄 catalog")
                        .foregroundStyle(model.hasCatalog ? DS.success : DS.textTertiary)
                }
                Spacer(minLength: 8)
                Text(model.spec.unitPrice)
                    .foregroundStyle(DS.danger)
                    .lineLimit(1)
            }
            .font(.caption)
            HStack(spacing: 6) {
                Button(isSelected ? "檢視中" : "開啟圖面", action: onSelect)
                    .buttonStyle(PillButtonStyle(kind: isSelected ? .primary : .secondary, compact: true))
                Button("規格", action: onSpec)
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            }
            .font(.caption)
        }
        .font(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? DS.control : DS.card, in: RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(isSelected ? DS.link : DS.cardBorder, lineWidth: isSelected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
        .onTapGesture(perform: onSelect)
    }

    private func dash(_ text: String) -> String { text.isEmpty ? "-" : text }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(DS.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(DS.control, in: Capsule())
    }
}

/// 結構型態的色票（Hat 藍、FlatTop 綠、Ring 橘，未登錄灰）。
struct DrawingTypeBadge: View {
    let type: String

    var body: some View {
        let colors = Self.colors(for: type)
        Text(type.isEmpty ? "未登錄" : type)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(colors.background, in: Capsule())
            .overlay(Capsule().strokeBorder(colors.border, lineWidth: 1))
    }

    static func colors(for type: String) -> (background: Color, foreground: Color, border: Color) {
        switch type {
        case "Hat": return (Color(hex: 0x1E3A8A), Color(hex: 0x93C5FD), Color(hex: 0x3B82F6))
        case "FlatTop": return (Color(hex: 0x064E3B), Color(hex: 0x6EE7B7), Color(hex: 0x10B981))
        case "Ring": return (Color(hex: 0x78350F), Color(hex: 0xFCD34D), Color(hex: 0xF59E0B))
        default: return (DS.control, DS.textSecondary, DS.cardBorder)
        }
    }
}
