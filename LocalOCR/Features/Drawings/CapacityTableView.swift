import SwiftUI

/// 產能清單的一列。
struct CapacityRow: Identifiable {
    let model: DrawingModel
    let capacity: CapacityItem?
    let process: String
    /// 有外剪站（外剪較難，試作時間長）
    let trimming: StationCell?
    let open: (qty: Double, fromPoList: Bool, catalogQty: Double, lines: Int)
    let cells: [String: StationCell]
    let theory: TheoryItem?
    let hasDiff: Bool

    var id: String { model.id }
    var archived: Bool { capacity?.archived ?? false }
    var length: Double { DrawingFormat.dimension(model.spec.length) }
    var width: Double { DrawingFormat.dimension(model.spec.width) }
    var thickness: Double { DrawingFormat.dimension(model.spec.thickness) }
    var openQtyDiffers: Bool { open.fromPoList && open.qty != open.catalogQty }
}

/// 產能清單的一欄。
struct CapacityColumn: Identifiable, Hashable {
    enum Kind: Hashable {
        case number, process, endUser, dwg, size, thickness, sid, sap, type
        case station(StationColumn)
        case theory(TheoryField)
        case openQty, openLines
    }

    enum TheoryField: String, Hashable {
        case mold, plant, spm, sph, util, day, night, daily
    }

    let kind: Kind
    let title: String
    let unit: String
    let width: CGFloat

    var id: String {
        switch kind {
        case .station(let column): return "station:" + column.id
        case .theory(let field): return "theory:" + field.rawValue
        default: return title
        }
    }

    var isFilterable: Bool {
        switch kind {
        case .process, .endUser, .type, .theory(.mold): return true
        default: return false
        }
    }

    /// 新選的欄位先由大到小排的（數字欄）。
    var startsDescending: Bool {
        switch kind {
        case .openQty, .openLines, .size, .thickness, .station: return true
        case .theory(let field): return field != .mold && field != .plant
        default: return false
        }
    }
}

/// 產能清單：一個機種一列，站別欄位依 PO LIST 的製程順序長出來，沖壓旁邊是理論產能。
/// 產能與未結量以 PO LIST 為準，和 catalog 不一致時標 ≠。
struct CapacityTableView: View {
    var onOpen: (DrawingModel) -> Void

    @State private var library = DrawingsLibrary.shared
    @State private var query = ""
    @State private var onlyDiff = false
    @State private var showArchived = false
    @State private var showCNC = false
    @State private var sortID = "未結量"
    @State private var ascending = false
    @State private var filters: [String: String] = [:]
    @State private var exportURL: URL?
    @State private var notice: String?

    var body: some View {
        let stationColumns = DrawingCapacity.columns(models: library.models, capacity: library.snapshot.capacity, showCNC: showCNC)
        let allRows = rows(stationColumns: stationColumns)
        let columns = columns(stations: stationColumns)
        let visible = sorted(filtered(allRows, columns: columns), columns: columns)
        VStack(spacing: 0) {
            toolbar(all: allRows, visible: visible, columns: columns)
            Divider().overlay(DS.hairline)
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(DS.textSecondary)
                    .padding(.vertical, 6)
                    .onTapGesture { self.notice = nil }
            }
            table(rows: visible, allRows: allRows, columns: columns)
        }
        .sheet(item: Binding(get: { exportURL.map(ExportFile.init) }, set: { exportURL = $0?.url })) { file in
            ShareSheet(items: [file.url])
        }
    }

    // MARK: 資料

    private func rows(stationColumns: [StationColumn]) -> [CapacityRow] {
        let hasPoData = !library.snapshot.capacity.isEmpty
        return library.models.compactMap { model in
            let capacity = library.capacity(for: model)
            // 有 PO LIST 資料時只列 PO LIST 收錄的機種
            if hasPoData && capacity == nil { return nil }
            var cells: [String: StationCell] = [:]
            for column in stationColumns {
                cells[column.id] = DrawingCapacity.cell(model: model, capacity: capacity, column: column)
            }
            let trimming = stationColumns.first { $0.id.contains("外剪") && cells[$0.id]?.source != StationCell.Source.missing }.flatMap { cells[$0.id] }
            let open = DrawingCapacity.openQty(model: model, capacity: capacity)
            let diff = cells.values.contains(where: DrawingCapacity.isDifferent) || (open.fromPoList && open.qty != open.catalogQty && model.hasCatalog)
            return CapacityRow(
                model: model,
                capacity: capacity,
                process: DrawingCapacity.process(model: model, capacity: capacity),
                trimming: trimming,
                open: open,
                cells: cells,
                theory: library.theory(for: model),
                hasDiff: diff
            )
        }
    }

    private func columns(stations: [StationColumn]) -> [CapacityColumn] {
        var result: [CapacityColumn] = [
            CapacityColumn(kind: .number, title: "No.", unit: "", width: 40),
            CapacityColumn(kind: .process, title: "製程", unit: "", width: 92),
            CapacityColumn(kind: .endUser, title: "END USER", unit: "", width: 90),
            CapacityColumn(kind: .dwg, title: "機種圖號", unit: "", width: 150),
            CapacityColumn(kind: .size, title: "尺寸 L×W", unit: "mm", width: 100),
            CapacityColumn(kind: .thickness, title: "厚度", unit: "mm", width: 56),
            CapacityColumn(kind: .sid, title: "SID", unit: "", width: 86),
            CapacityColumn(kind: .sap, title: "SAP 品號", unit: "", width: 80),
            CapacityColumn(kind: .type, title: "型態", unit: "", width: 64),
        ]
        let theoryColumns: [CapacityColumn] = library.snapshot.theory.isEmpty ? [] : [
            CapacityColumn(kind: .theory(.mold), title: "模具", unit: "", width: 72),
            CapacityColumn(kind: .theory(.plant), title: "沖壓廠", unit: "", width: 56),
            CapacityColumn(kind: .theory(.spm), title: "SPM", unit: "次/分", width: 56),
            CapacityColumn(kind: .theory(.sph), title: "SPH", unit: "次/時", width: 64),
            CapacityColumn(kind: .theory(.util), title: "稼動", unit: "%", width: 48),
            CapacityColumn(kind: .theory(.day), title: "日班", unit: "pcs", width: 92),
            CapacityColumn(kind: .theory(.night), title: "夜班", unit: "pcs", width: 92),
            CapacityColumn(kind: .theory(.daily), title: "理論產能", unit: "pcs/日", width: 92),
        ]
        let stationCols = stations.map { CapacityColumn(kind: .station($0), title: $0.label, unit: $0.unit ?? "", width: 112) }
        if let index = stations.firstIndex(where: { $0.id == "沖壓" }) {
            result += Array(stationCols[...index])
            result += theoryColumns
            result += Array(stationCols[(index + 1)...])
        } else {
            result += theoryColumns + stationCols
        }
        result += [
            CapacityColumn(kind: .openQty, title: "未結量", unit: "pcs", width: 96),
            CapacityColumn(kind: .openLines, title: "未結單", unit: "張", width: 56),
        ]
        return result
    }

    private func filterValue(_ row: CapacityRow, _ column: CapacityColumn) -> String {
        switch column.kind {
        case .process: return row.process.isEmpty ? "未定" : row.process
        case .endUser: return row.model.endUser.isEmpty ? "-" : row.model.endUser
        case .type: return row.model.type.isEmpty ? "-" : row.model.type
        case .theory(.mold): return row.theory?.mold.isEmpty == false ? row.theory!.mold : "-"
        default: return ""
        }
    }

    private func filtered(_ rows: [CapacityRow], columns: [CapacityColumn]) -> [CapacityRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            if row.archived && !showArchived { return false }
            if onlyDiff && !row.hasDiff { return false }
            for column in columns where column.isFilterable {
                if let wanted = filters[column.id], filterValue(row, column) != wanted { return false }
            }
            guard !query.isEmpty else { return true }
            var parts = [row.model.dwg, row.model.sid, row.model.sap, row.model.endUser, row.model.type, row.process,
                         DrawingCapacity.latestPo(model: row.model, capacity: row.capacity)]
            if let theory = row.theory { parts += [theory.mold, theory.plant, theory.pressPn] }
            parts += row.cells.values.map { "\($0.text) \($0.note)" }
            if let orders = row.capacity?.orders { parts += orders.poNumbers + orders.salesDocs + orders.refs + orders.cases }
            return DrawingFormat.matches(query, in: parts)
        }
    }

    private func sortValue(_ row: CapacityRow, _ column: CapacityColumn) -> (Double?, String) {
        switch column.kind {
        case .number: return (nil, "")
        case .process: return (nil, row.process)
        case .endUser: return (nil, row.model.endUser)
        case .dwg: return (nil, row.model.dwg)
        case .size: return (row.length * row.width, "")
        case .thickness: return (row.thickness, "")
        case .sid: return (nil, row.model.sid)
        case .sap: return (nil, row.model.sap)
        case .type: return (nil, row.model.type)
        case .openQty: return (row.open.qty, "")
        case .openLines: return (Double(row.open.lines), "")
        case .station(let station):
            guard let cell = row.cells[station.id] else { return (-1, "") }
            switch cell.source {
            case .missing: return (-1, "")
            case .present: return (0, "")
            default:
                let number = cell.text.range(of: #"[\d.]+"#, options: .regularExpression).flatMap { Double(cell.text[$0]) } ?? 0
                return (number, "")
            }
        case .theory(let field):
            guard let theory = row.theory else { return (field == .mold || field == .plant ? nil : -1, "") }
            switch field {
            case .mold: return (nil, theory.mold)
            case .plant: return (nil, theory.plant)
            case .spm: return (theory.spm, "")
            case .sph: return (theory.sphUsed, "")
            case .util: return (theory.util, "")
            case .day: return (theory.dayQty, "")
            case .night: return (theory.nightQty, "")
            case .daily: return (theory.dailyQty, "")
            }
        }
    }

    private func sorted(_ rows: [CapacityRow], columns: [CapacityColumn]) -> [CapacityRow] {
        guard let column = columns.first(where: { $0.id == sortID }) else { return rows }
        return rows.sorted { a, b in
            let (na, ta) = sortValue(a, column)
            let (nb, tb) = sortValue(b, column)
            if let na, let nb, na != nb { return ascending ? na < nb : na > nb }
            if na == nil, nb == nil, ta != tb {
                let order = ta.localizedStandardCompare(tb)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            return a.open.qty > b.open.qty
        }
    }

    // MARK: 工具列

    private func toolbar(all: [CapacityRow], visible: [CapacityRow], columns: [CapacityColumn]) -> some View {
        let total = visible.reduce(0) { $0 + $1.open.qty }
        let counts = Dictionary(grouping: visible, by: { $0.process.isEmpty ? "未定" : $0.process }).mapValues(\.count)
        let breakdown = ["沖壓", "蝕刻", "CNC", "未定"].compactMap { key in counts[key].map { "\(key) \($0)" } }.joined(separator: "・")
        let diffCount = all.filter(\.hasDiff).count
        let archivedCount = all.filter(\.archived).count
        var extras: [String] = []
        if !onlyDiff && diffCount > 0 { extras.append("不一致 \(diffCount)") }
        if !showArchived && archivedCount > 0 { extras.append("歷史 \(archivedCount) 未顯示") }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                (Text("在手未交 ").foregroundStyle(DS.textSecondary)
                    + Text(DrawingFormat.qty(total)).font(.system(size: 15, weight: .bold)).foregroundStyle(DS.link)
                    + Text(" pcs").foregroundStyle(DS.textSecondary))
                Text("\(visible.count)/\(all.filter { showArchived || !$0.archived }.count) 款\(breakdown.isEmpty ? "" : "（\(breakdown)）")\(extras.isEmpty ? "" : "　" + extras.joined(separator: "・"))")
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                sourceLabel
            }
            .font(.footnote)
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(DS.textTertiary)
                    TextField("搜尋圖號 / SID / SAP / PO 號 / 機台 / 站別產能…", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.subheadline)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1))
                .frame(maxWidth: 360)
                toggleChip("僅不一致", isOn: $onlyDiff)
                toggleChip("歷史機種", isOn: $showArchived)
                toggleChip("CNC 產能", isOn: $showCNC)
                Spacer(minLength: 0)
                Menu {
                    Button { export(visible, columns: columns, toVault: false) } label: { Label("分享 CSV（Excel 可開）", systemImage: "square.and.arrow.up") }
                    Button { export(visible, columns: columns, toVault: true) } label: { Label("存到 vault 的 scratch 資料夾", systemImage: "tray.and.arrow.down") }
                    Divider()
                    Text("「重新抽取」「寫回 catalog」要在電腦的 Obsidian 執行（需要 Python）")
                } label: {
                    Label("匯出", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var sourceLabel: some View {
        if let meta = library.snapshot.capacityMeta {
            Text("PO LIST \(meta.sourceMtime)")
                .font(.caption)
                .foregroundStyle(DS.textTertiary)
                .help(sourceDescription(meta))
        } else {
            Text("尚無 PO LIST 產能檔")
                .font(.caption)
                .foregroundStyle(DS.textTertiary)
        }
    }

    private func sourceDescription(_ meta: CapacityMeta) -> String {
        var lines = [
            "來源：\(DrawingPaths.baseName(meta.source))",
            "PO LIST 更新：\(meta.sourceMtime)",
            "抽取時間：\(meta.extractedAt)（收錄 \(library.snapshot.capacityItemCount) 款）",
        ]
        if meta.dedupRows > 0 { lines.append("已去重 \(meta.dedupRows) 筆重複訂單行") }
        if meta.hiddenTotalOpenQty > 0 { lines.append("隱藏分頁（結案）另有 \(DrawingFormat.qty(meta.hiddenTotalOpenQty)) pcs 未計入") }
        return lines.joined(separator: "\n")
    }

    private func toggleChip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(isOn.wrappedValue ? DS.onPrimary : DS.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isOn.wrappedValue ? DS.primary : DS.control, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 表格

    private func table(rows: [CapacityRow], allRows: [CapacityRow], columns: [CapacityColumn]) -> some View {
        let totalWidth = columns.reduce(0) { $0 + $1.width }
        return ScrollView(.horizontal) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if rows.isEmpty {
                            Text("沒有符合條件的機種")
                                .font(.subheadline)
                                .foregroundStyle(DS.textTertiary)
                                .padding(30)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            HStack(spacing: 0) {
                                ForEach(columns) { column in
                                    cell(row, index: index, column: column)
                                        .frame(width: column.width, alignment: .leading)
                                }
                            }
                            .frame(minHeight: 38)
                            .background(index.isMultiple(of: 2) ? Color.clear : DS.control.opacity(0.45))
                            Divider().overlay(DS.hairline)
                        }
                    } header: {
                        header(columns: columns, rows: allRows)
                    }
                }
                .frame(width: totalWidth, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
        .scrollIndicators(.visible)
        .font(.system(size: 12))
    }

    private func header(columns: [CapacityColumn], rows: [CapacityRow]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                headerCell(column, rows: rows)
                    .frame(width: column.width, alignment: .leading)
            }
        }
        .frame(minHeight: 40)
        .background(DS.sidebar)
        .overlay(alignment: .bottom) { Divider().overlay(DS.cardBorder) }
    }

    private func headerCell(_ column: CapacityColumn, rows: [CapacityRow]) -> some View {
        let isSorted = sortID == column.id
        return HStack(spacing: 2) {
            Button {
                guard column.kind != .number else { return }
                if isSorted {
                    ascending.toggle()
                } else {
                    sortID = column.id
                    ascending = !column.startsDescending
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 2) {
                        Text(column.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                        if isSorted {
                            Text(ascending ? "▲" : "▼")
                                .font(.system(size: 9))
                                .foregroundStyle(DS.link)
                        }
                    }
                    if !column.unit.isEmpty {
                        Text(column.unit)
                            .font(.system(size: 9))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            if column.isFilterable {
                let values = Array(Set(rows.map { filterValue($0, column) })).sorted()
                Menu {
                    Button("全部") { filters[column.id] = nil }
                    ForEach(values, id: \.self) { value in
                        Button(value) { filters[column.id] = value }
                    }
                } label: {
                    Image(systemName: filters[column.id] == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(filters[column.id] == nil ? DS.textTertiary : DS.link)
                }
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func cell(_ row: CapacityRow, index: Int, column: CapacityColumn) -> some View {
        Group {
            switch column.kind {
            case .number:
                Text(String(format: "%02d", index + 1)).foregroundStyle(DS.textTertiary)
            case .process:
                HStack(spacing: 3) {
                    processBadge(row.process)
                    if row.trimming != nil {
                        badge("外剪", color: Color(red: 0.94, green: 0.63, blue: 0.16))
                            .help("有外剪站（\(row.trimming?.text ?? "")）——外剪較難，試作時間長，交期要留意")
                    }
                }
            case .endUser:
                Text(row.model.endUser.isEmpty ? "-" : row.model.endUser)
            case .dwg:
                HStack(spacing: 4) {
                    Button { onOpen(row.model) } label: {
                        Text(row.model.dwg)
                            .fontWeight(.semibold)
                            .foregroundStyle(DS.link)
                            .underline(pattern: .dot)
                    }
                    .buttonStyle(.plain)
                    badge(row.model.drawings.isEmpty ? "無圖" : "圖 \(row.model.drawings.count)", color: DS.textTertiary)
                    if row.archived {
                        badge("歷史", color: DS.textTertiary)
                    }
                }
            case .size:
                Text("\(DrawingFormat.trim(row.length, digits: 3)) × \(DrawingFormat.trim(row.width, digits: 3))").monospacedDigit()
            case .thickness:
                Text(DrawingFormat.trim(row.thickness, digits: 3)).monospacedDigit()
            case .sid:
                Text(row.model.sid.isEmpty ? "-" : row.model.sid).monospacedDigit()
            case .sap:
                Text(row.model.sap.isEmpty ? "-" : row.model.sap).monospacedDigit()
            case .type:
                Text(row.model.type.isEmpty ? "-" : row.model.type)
            case .station(let station):
                stationCell(row.cells[station.id], station: station, capacity: row.capacity)
            case .theory(let field):
                theoryCell(row.theory, field: field)
            case .openQty:
                HStack(spacing: 3) {
                    Text(DrawingFormat.qty(row.open.qty))
                        .fontWeight(row.open.qty > 0 ? .bold : .regular)
                        .foregroundStyle(row.open.qty > 0 ? DS.danger : DS.textTertiary)
                        .monospacedDigit()
                    if row.openQtyDiffers && row.model.hasCatalog {
                        diffPill
                            .help("來源：PO LIST（catalog 舊值 \(DrawingFormat.qty(row.open.catalogQty))）")
                    }
                }
            case .openLines:
                Text(row.open.lines > 0 ? "\(row.open.lines)" : "-").monospacedDigit()
            }
        }
        .foregroundStyle(DS.text)
        .lineLimit(2)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func stationCell(_ cell: StationCell?, station: StationColumn, capacity: CapacityItem?) -> some View {
        switch cell?.source ?? StationCell.Source.missing {
        case .missing:
            Text("-").foregroundStyle(DS.textTertiary)
        case .present:
            Text(cell?.text ?? "✓")
                .fontWeight(.bold)
                .foregroundStyle(DS.success)
                .help(["有這道流程（PO LIST 未填產能）", cell?.note ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"))
        case .catalog:
            Text(cell?.text ?? "")
                .foregroundStyle(DS.textTertiary)
                .help("來源：catalog.json（PO LIST 這一站沒填）")
        case .po:
            if let cell {
                let machines = DrawingCapacity.machines(for: capacity, column: station.id)
                HStack(spacing: 3) {
                    if cell.items.count > 1 {
                        Text(cell.items.map { "\($0.label) \(DrawingCapacity.displayText($0.text, column: station))\($0.machine.isEmpty ? "" : " [\($0.machine)]")" }.joined(separator: "／"))
                            .fontWeight(.semibold)
                    } else {
                        Text(DrawingCapacity.displayText(cell.text, column: station))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                        if !machines.isEmpty {
                            Text(machines.joined(separator: "、"))
                                .font(.system(size: 9))
                                .foregroundStyle(DS.textTertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(DS.control, in: Capsule())
                        }
                    }
                    if DrawingCapacity.isDifferent(cell) {
                        diffPill.help("與 catalog.json 不一致：\(cell.catalogText)")
                    }
                }
                .help([cell.note, cell.catalogText.isEmpty ? "" : "catalog：\(cell.catalogText)"].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
        }
    }

    @ViewBuilder
    private func theoryCell(_ theory: TheoryItem?, field: CapacityColumn.TheoryField) -> some View {
        if let theory {
            let tooltip = DrawingTheory.description(theory, sourceMtime: library.snapshot.theorySourceMtime)
            Group {
                switch field {
                case .mold:
                    if theory.mold.isEmpty { Text("-") } else {
                        Text(theory.mold)
                            .font(.system(size: 10))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(DS.cardBorder, lineWidth: 1))
                    }
                case .plant: Text(theory.plant.isEmpty ? "-" : theory.plant)
                case .spm: Text(DrawingFormat.trim(theory.spm, digits: 2))
                case .sph: Text(theory.sphUsed > 0 ? DrawingFormat.qty(theory.sphUsed) : "-")
                case .util: Text(theory.util > 0 ? "\(Int((theory.util * 100).rounded()))" : "-")
                case .day: shift(theory.dayQty, hours: theory.dayHours)
                case .night: shift(theory.nightQty, hours: theory.nightHours)
                case .daily:
                    HStack(spacing: 3) {
                        Text(theory.dailyQty > 0 ? DrawingFormat.qty(theory.dailyQty) : "未填")
                            .foregroundStyle(DS.textSecondary)
                        if theory.mismatch { diffPill }
                    }
                }
            }
            .monospacedDigit()
            .help(tooltip)
        } else {
            Text("-")
                .foregroundStyle(DS.textTertiary)
                .help("理論產能表沒有收這一款")
        }
    }

    private func shift(_ qty: Double, hours: Double) -> some View {
        HStack(spacing: 3) {
            Text(qty > 0 ? DrawingFormat.qty(qty) : "-")
            if hours > 0 {
                Text("\(DrawingFormat.trim(hours, digits: 1))h")
                    .font(.system(size: 9))
                    .foregroundStyle(DS.textTertiary)
            }
        }
    }

    private var diffPill: some View {
        Text("≠")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(DS.danger)
            .padding(.horizontal, 4)
            .background(DS.danger.opacity(0.15), in: Capsule())
    }

    private func processBadge(_ process: String) -> some View {
        let color: Color
        switch process {
        case "沖壓": color = DS.link
        case "蝕刻": color = DS.success
        case "CNC": color = DS.danger
        default: color = DS.textTertiary
        }
        return badge(process.isEmpty ? "未定" : process, color: color)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .lineLimit(1)
    }

    // MARK: 匯出

    private func export(_ rows: [CapacityRow], columns: [CapacityColumn], toVault: Bool) {
        let table = CapacityExport.table(rows: rows, columns: columns, sourceMtime: library.snapshot.theorySourceMtime)
        let customer = library.snapshot.capacityMeta?.customer ?? library.scopeLabel
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let name = "產能清單_\(customer)_\(formatter.string(from: Date())).csv"
        let data = CapacityExport.csv(table)
        if toVault {
            Task {
                guard let remote = VaultBackend.current() else { return }
                do {
                    try await remote.write("scratch/\(name)", data: data, contentType: "text/csv; charset=utf-8", condition: .createOnly, mtime: .now)
                    notice = "已存到 vault：scratch/\(name)"
                } catch {
                    notice = "存檔失敗：\(error.localizedDescription)"
                }
            }
        } else {
            let url = URL.temporaryDirectory.appending(path: name)
            do {
                try data.write(to: url, options: .atomic)
                exportURL = url
            } catch {
                notice = "匯出失敗：\(error.localizedDescription)"
            }
        }
    }
}

private struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 匯出的表格（與插件的 ExportPayload 相同欄位）。
enum CapacityExport {
    static func table(rows: [CapacityRow], columns: [CapacityColumn], sourceMtime: String?) -> [[String]] {
        var headers = ["No.", "製程", "終端客戶", "機種圖號", "長(mm)", "寬(mm)", "厚(mm)", "SID", "SAP 品號", "型態"]
        let stationColumns = columns.compactMap { column -> StationColumn? in
            if case .station(let station) = column.kind { return station }
            return nil
        }
        let hasTheory = columns.contains { if case .theory = $0.kind { return true } else { return false } }
        let theoryHeaders = ["模具", "沖壓廠", "SPM", "SPH", "稼動率(%)", "日班工時(h)", "日班產能", "夜班工時(h)", "夜班產能", "理論產能(pcs/日)", "沖壓品號", "理論產能備註"]
        let stampingIndex = stationColumns.firstIndex { $0.id == "沖壓" }
        var stationHeaders = stationColumns.map { column in column.unit.map { "\(column.id) (\($0))" } ?? column.id }
        if hasTheory {
            stationHeaders.insert(contentsOf: theoryHeaders, at: stampingIndex.map { $0 + 1 } ?? 0)
        }
        headers += stationHeaders
        headers += ["未結量", "未結單數", "最新 PO", "圖面張數", "產能來源", "歷史機種", "PO LIST 分頁"]

        var result = [headers]
        for (index, row) in rows.enumerated() {
            var values = [
                "\(index + 1)",
                (row.process.isEmpty ? "未定" : row.process) + (row.trimming != nil ? "（含外剪）" : ""),
                row.model.endUser,
                row.model.dwg,
                row.length > 0 ? DrawingFormat.trim(row.length, digits: 3) : "",
                row.width > 0 ? DrawingFormat.trim(row.width, digits: 3) : "",
                row.thickness > 0 ? DrawingFormat.trim(row.thickness, digits: 3) : "",
                row.model.sid, row.model.sap, row.model.type,
            ]
            var stationValues = stationColumns.map { column -> String in
                guard let cell = row.cells[column.id], cell.source != .missing else { return "-" }
                var text = DrawingCapacity.displayText(cell.text, column: column)
                let machines = DrawingCapacity.machines(for: row.capacity, column: column.id)
                if !machines.isEmpty { text += "（\(machines.joined(separator: "、"))）" }
                let notes = cell.note.components(separatedBy: "\n").compactMap { line -> String? in
                    let parts = line.components(separatedBy: "｜")
                    guard parts.count > 1 else { return nil }
                    let station = parts[0]
                    let note = parts.dropFirst().joined(separator: "｜")
                    return DrawingCapacity.columnID(for: CapacityStation(station: station, capacity: "", note: "", order: nil, key: "")) == column.id && !station.contains("->") ? note : line
                }
                if !notes.isEmpty { text += " " + notes.joined(separator: "；") }
                return text
            }
            if hasTheory {
                let theory = row.theory
                let theoryValues: [String] = theory.map { item in
                    [item.mold, item.plant, item.spm > 0 ? DrawingFormat.trim(item.spm, digits: 2) : "", item.sphUsed > 0 ? DrawingFormat.trim(item.sphUsed, digits: 0) : "",
                     item.util > 0 ? "\(Int((item.util * 100).rounded()))" : "", item.dayHours > 0 ? DrawingFormat.trim(item.dayHours, digits: 1) : "",
                     item.dayQty > 0 ? DrawingFormat.trim(item.dayQty, digits: 0) : "", item.nightHours > 0 ? DrawingFormat.trim(item.nightHours, digits: 1) : "",
                     item.nightQty > 0 ? DrawingFormat.trim(item.nightQty, digits: 0) : "", item.dailyQty > 0 ? DrawingFormat.trim(item.dailyQty, digits: 0) : "",
                     item.pressPn, [item.note, item.mismatch ? "日夜班稼動率對不起來" : ""].filter { !$0.isEmpty }.joined(separator: " ")]
                } ?? Array(repeating: "", count: theoryHeaders.count)
                stationValues.insert(contentsOf: theoryValues, at: stampingIndex.map { $0 + 1 } ?? 0)
            }
            values += stationValues
            values += [
                row.open.qty > 0 ? DrawingFormat.trim(row.open.qty, digits: 0) : "0",
                row.open.lines > 0 ? "\(row.open.lines)" : "",
                DrawingCapacity.latestPo(model: row.model, capacity: row.capacity),
                "\(row.model.drawings.count)",
                row.open.fromPoList ? "PO LIST" : "catalog",
                row.archived ? "是" : "",
                row.capacity.map { $0.sheet.isEmpty ? ($0.orders?.sheets ?? []).joined(separator: "、") : $0.sheet } ?? "",
            ]
            result.append(values)
        }
        return result
    }

    /// UTF-8 BOM＋CRLF 的 CSV（Excel 直接開不會亂碼）。
    static func csv(_ table: [[String]]) -> Data {
        let escape = { (value: String) -> String in
            value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) ? "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" : value
        }
        let text = table.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n")
        return Data("\u{FEFF}".utf8) + Data(text.utf8)
    }
}
