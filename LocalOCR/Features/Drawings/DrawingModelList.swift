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
    @MainActor
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

/// 機種卡片清單（搜尋與篩選在頁面上方的工具列）；往下拉重新掃描。
struct DrawingModelList: View {
    let models: [DrawingModel]
    let selectedID: String?
    let filter: DrawingListFilter
    var onSelect: (DrawingModel) -> Void
    var onSpec: (DrawingModel) -> Void
    var onRefresh: () async -> Void

    @State private var library = DrawingsLibrary.shared

    var body: some View {
        let visible = filter.apply(to: models, library: library)
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if visible.isEmpty {
                        EmptyStateView(title: "沒有符合條件的機種", message: models.isEmpty ? nil : "調整搜尋或篩選條件試試看。")
                            .padding(.top, 30)
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
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await onRefresh() }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation { reader.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// 機種清單的篩選膠囊（放在頁面工具列的第二列）。
struct DrawingFilterChips: View {
    @Binding var filter: DrawingListFilter

    var body: some View {
        Menu {
            Button("全部") { filter.type = nil }
            ForEach(DrawingListFilter.types, id: \.self) { type in
                Button(type) { filter.type = type }
            }
        } label: {
            FilterChip(title: filter.type ?? "型態", isActive: filter.type != nil)
        }
        Menu {
            ForEach(DrawingListFilter.SizeBucket.allCases) { bucket in
                Button(bucket.rawValue) { filter.size = bucket }
            }
        } label: {
            FilterChip(title: filter.size == .all ? "長寬" : filter.size.rawValue, isActive: filter.size != .all)
        }
        Menu {
            ForEach(DrawingListFilter.ThicknessBucket.allCases) { bucket in
                Button(bucket.rawValue) { filter.thickness = bucket }
            }
        } label: {
            FilterChip(title: filter.thickness == .all ? "厚度" : filter.thickness.rawValue, isActive: filter.thickness != .all)
        }
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
            FilterChip(title: filter.sort.rawValue, systemImage: "arrow.up.arrow.down")
        }
    }
}

/// 機種卡片：圖號、型態、終端客戶，原廠圖號、尺寸、未結量與單價。選取中的卡片是粉紫色（同首頁的手寫筆記卡）。
struct DrawingModelCard: View {
    let model: DrawingModel
    let capacity: CapacityItem?
    let isSelected: Bool
    var onSelect: () -> Void
    var onSpec: () -> Void

    var body: some View {
        let customerDwg = DrawingCustomers.customerDwg(of: model, capacity: capacity)
        let open = DrawingCapacity.openQty(model: model, capacity: capacity)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.dwg)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DS.text)
                    Text(customerDwg.value.isEmpty ? (model.sap.isEmpty ? "—" : "SAP \(model.sap)") : customerDwg.value)
                        .font(.caption)
                        .foregroundStyle(isSelected ? DS.onPastelSecondary : DS.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Button(action: onSpec) {
                    Image(systemName: "info")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(CircleIconButtonStyle(size: 28))
                .accessibilityLabel("規格與筆記")
            }
            HStack(spacing: 6) {
                DrawingTypeBadge(type: model.type)
                if !model.endUser.isEmpty {
                    Chip(text: model.endUser + (model.endUserGuessed ? "?" : ""))
                        .help(model.endUserGuessed ? "catalog 沒登錄終端客戶，這是依客戶圖號字頭推定的（CV90 → Qualcomm）" : "")
                }
                Chip(text: "\(model.drawings.count) 張")
            }
            Text("\(dash(model.spec.length)) × \(dash(model.spec.width)) × \(dash(model.spec.thickness))")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(DS.text)
            HStack(alignment: .firstTextBaseline) {
                if open.qty > 0 {
                    Text("未結 \(DrawingFormat.qty(open.qty))")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(DS.danger)
                } else {
                    Text(model.hasCatalog ? "已出清 / NPI" : "未登錄 catalog")
                        .font(.footnote)
                        .foregroundStyle(model.hasCatalog ? DS.success : DS.textTertiary)
                }
                Spacer(minLength: 8)
                if !model.spec.unitPrice.isEmpty {
                    Text(model.spec.unitPrice)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isSelected ? DS.onPastelSecondary : DS.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14, fill: isSelected ? DS.Pastel.lavender.color : DS.card, bordered: !isSelected)
        .contentShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
        .onTapGesture(perform: onSelect)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func dash(_ text: String) -> String { text.isEmpty ? "-" : text }
}

/// 結構型態：粉彩膠囊（Hat 藍、FlatTop 綠、Ring 黃，未登錄只有框線）。
struct DrawingTypeBadge: View {
    let type: String

    var body: some View {
        Chip(text: type.isEmpty ? "未登錄" : type, pastel: Self.pastel(for: type))
    }

    static func pastel(for type: String) -> DS.Pastel? {
        switch type {
        case "Hat": return .sky
        case "FlatTop": return .mint
        case "Ring": return .butter
        default: return nil
        }
    }
}
