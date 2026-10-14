import SwiftUI

/// 規格與筆記：尺寸、結構、單價、訂單狀態、各站產能與理論產能，下方是自訂筆記（存在 vault，其他裝置也看得到）。
struct DrawingSpecSheet: View {
    let model: DrawingModel

    @Environment(\.dismiss) private var dismiss
    @State private var library = DrawingsLibrary.shared
    @State private var note = ""
    @State private var tip: String?
    @State private var isSaving = false

    private var capacity: CapacityItem? { library.capacity(for: model) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    stats
                    box("規格", [
                        ("結構類型", model.spec.type.isEmpty ? model.type : model.spec.type),
                        ("腔體／開窗", model.spec.cavity),
                        ("腳寬", model.spec.footWidth),
                        ("主要材質", model.spec.material),
                    ])
                    box("報價", [
                        ("目前單價", model.spec.unitPrice.isEmpty ? "商議中" : model.spec.unitPrice),
                        ("報價日期", model.spec.quoteDate),
                        ("報價單號", model.spec.quoteRef),
                    ], accent: "目前單價")
                    orderBox
                    stationBox
                    noteBox
                }
                .padding(16)
            }
            .background(DS.pane)
            .navigationTitle("規格與筆記")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
            }
        }
        .onAppear {
            let saved = library.note(for: model)
            note = saved.isEmpty ? model.spec.notes : saved
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.dwg)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(DS.text)
                DrawingTypeBadge(type: model.type)
                Spacer(minLength: 0)
            }
            let subtitle = [model.endUserDwg, model.endUser.isEmpty ? "" : model.endUser + (model.endUserGuessed ? "（推定）" : ""), DrawingPaths.prettyCustomer(model.customer)]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(DS.textSecondary)
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 10) {
            MetricTile(title: "長度 Length", value: model.spec.length.isEmpty ? "-" : model.spec.length, pastel: .sky)
            MetricTile(title: "寬度 Width", value: model.spec.width.isEmpty ? "-" : model.spec.width, pastel: .sky)
            MetricTile(title: "厚度 Thickness", value: model.spec.thickness.isEmpty ? "-" : model.spec.thickness, pastel: .blush)
        }
    }

    private func box(_ title: String, _ rows: [(String, String)], accent: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    InfoRow(label: row.0, value: row.1, valueColor: row.0 == accent ? DS.danger : DS.text, emphasized: row.0 == accent)
                }
            }
            .card(padding: 14)
        }
    }

    private var orderBox: some View {
        let open = DrawingCapacity.openQty(model: model, capacity: capacity)
        let process = DrawingCapacity.process(model: model, capacity: capacity)
        let status = model.hasCatalog ? (model.status.isEmpty ? "-" : model.status) : "未登錄 catalog"
        let openLabel = open.fromPoList ? "未結數量（PO LIST）" : "未結數量（catalog）"
        return box("訂單與狀態", [
            ("SAP / SID", "\(model.sap.isEmpty ? "-" : model.sap) / \(model.sid.isEmpty ? "-" : model.sid)"),
            ("最新 PO", DrawingCapacity.latestPo(model: model, capacity: capacity)),
            (openLabel, open.fromPoList ? "\(DrawingFormat.qty(open.qty))（\(open.lines) 張未結單）" : DrawingFormat.qty(open.qty)),
            ("Lead Time（人工填）", model.leadTime),
            ("製程", process.isEmpty ? "（未標）" : process),
            ("狀態（人工）", status),
            ("圖面", "\(model.drawings.count) 張（可預覽 \(model.previewCount) 張）"),
        ], accent: openLabel)
    }

    /// 各站產能（PO LIST 為準，和 catalog 不一致時標出）與沖壓理論產能。
    @ViewBuilder
    private var stationBox: some View {
        let columns = DrawingCapacity.columns(models: [model], capacity: capacity.map { [model.dwg.uppercased(): $0] } ?? [:], showCNC: true)
        let cells = columns.map { ($0, DrawingCapacity.cell(model: model, capacity: capacity, column: $0)) }.filter { $0.1.source != .missing }
        let theory = library.theory(for: model)
        if !cells.isEmpty || theory != nil {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("各站產能", trailing: capacity == nil ? "catalog" : "PO LIST")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, entry in
                        let column = entry.0
                        let cell = entry.1
                        let machines = DrawingCapacity.machines(for: capacity, column: column.id)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            InfoRow(
                                label: column.label,
                                value: cell.text + (machines.isEmpty ? "" : "（\(machines.joined(separator: "、"))）"),
                                valueColor: cell.source == .present ? DS.success : (cell.source == .catalog ? DS.textSecondary : DS.text),
                                emphasized: cell.source == .po
                            )
                            if DrawingCapacity.isDifferent(cell) {
                                Text("≠")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(DS.danger)
                                    .padding(.horizontal, 5)
                                    .background(DS.danger.opacity(0.15), in: Capsule())
                                    .help("與 catalog.json 不一致：\(cell.catalogText)")
                            }
                        }
                    }
                    if let theory {
                        if !cells.isEmpty { Divider().overlay(DS.hairline) }
                        Text("沖壓理論產能")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DS.text)
                        Text(DrawingTheory.description(theory, sourceMtime: library.snapshot.theorySourceMtime))
                            .font(.footnote)
                            .foregroundStyle(DS.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                .card(padding: 14)
            }
        }
    }

    private var noteBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("規格與商務筆記")
            TextField("寫下規格、報價或商務備註…", text: $note, axis: .vertical)
                .lineLimit(3...10)
                .font(.body)
                .foregroundStyle(DS.text)
                .card(padding: 12)
            HStack(alignment: .firstTextBaseline) {
                Text("存在 vault 的 \(DrawingsLibrary.dataRoot)/\(DrawingsLibrary.notesFile)，其他裝置也看得到。")
                    .font(.caption)
                    .foregroundStyle(DS.textTertiary)
                Spacer()
                if let tip {
                    Text(tip)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tip == "已儲存" ? DS.success : DS.danger)
                }
            }
            Button(isSaving ? "儲存中…" : "儲存筆記") { Task { await save() } }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                .disabled(isSaving)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await library.saveNote(note, for: model)
            tip = "已儲存"
        } catch {
            tip = "儲存失敗：\(error.localizedDescription)"
        }
        try? await Task.sleep(for: .seconds(2.5))
        tip = nil
    }
}
