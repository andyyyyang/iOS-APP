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
                VStack(alignment: .leading, spacing: 14) {
                    header
                    stats
                    box([
                        ("結構類型 (Type)", model.spec.type.isEmpty ? model.type : model.spec.type),
                        ("Cavity 腔體/開窗", model.spec.cavity),
                        ("Foot Width 腳寬", model.spec.footWidth),
                        ("主要材質", model.spec.material),
                    ])
                    box([
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
            .navigationTitle(model.dwg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "儲存中…" : "儲存筆記") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
        }
        .onAppear {
            let saved = library.note(for: model)
            note = saved.isEmpty ? model.spec.notes : saved
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(model.dwg)
                .font(.title3.weight(.bold))
                .foregroundStyle(DS.link)
            if !model.endUserDwg.isEmpty {
                Text("｜" + model.endUserDwg)
                    .font(.headline)
                    .foregroundStyle(DS.text)
            }
            if !model.endUser.isEmpty {
                Text("(\(model.endUser))")
                    .font(.subheadline)
                    .foregroundStyle(DS.textSecondary)
            }
            DrawingTypeBadge(type: model.type)
            Spacer(minLength: 0)
        }
    }

    private var stats: some View {
        HStack(spacing: 10) {
            stat("Length (長度)", model.spec.length, color: DS.link)
            stat("Width (寬度)", model.spec.width, color: DS.link)
            stat("Thickness (厚度)", model.spec.thickness, color: DS.danger)
        }
    }

    private func stat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(DS.textTertiary)
            Text(value.isEmpty ? "-" : value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }

    private func box(_ rows: [(String, String)], accent: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let label = row.0
                let value = row.1
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(DS.textSecondary)
                    Spacer(minLength: 12)
                    Text(value.isEmpty ? "-" : value)
                        .font(.subheadline.weight(label == accent ? .bold : .regular))
                        .foregroundStyle(label == accent ? DS.danger : DS.text)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }

    private var orderBox: some View {
        let open = DrawingCapacity.openQty(model: model, capacity: capacity)
        let process = DrawingCapacity.process(model: model, capacity: capacity)
        let status = model.hasCatalog ? (model.status.isEmpty ? "-" : model.status) : "未登錄 catalog"
        return box([
            ("SAP / SID", "\(model.sap.isEmpty ? "-" : model.sap) / \(model.sid.isEmpty ? "-" : model.sid)"),
            ("最新 PO", DrawingCapacity.latestPo(model: model, capacity: capacity)),
            (open.fromPoList ? "未結數量（PO LIST）" : "未結數量（catalog）", open.fromPoList ? "\(DrawingFormat.qty(open.qty))（\(open.lines) 張未結單）" : DrawingFormat.qty(open.qty)),
            ("Lead Time（人工填）", model.leadTime),
            ("製程", process.isEmpty ? "（未標）" : process),
            ("狀態（人工）", status),
            ("圖面張數", "\(model.drawings.count) 張（可預覽 \(model.previewCount) 張）"),
        ], accent: open.fromPoList ? "未結數量（PO LIST）" : "未結數量（catalog）")
    }

    /// 各站產能（PO LIST 為準，和 catalog 不一致時標出）與沖壓理論產能。
    @ViewBuilder
    private var stationBox: some View {
        let columns = DrawingCapacity.columns(models: [model], capacity: capacity.map { [model.dwg.uppercased(): $0] } ?? [:], showCNC: true)
        let cells = columns.map { ($0, DrawingCapacity.cell(model: model, capacity: capacity, column: $0)) }.filter { $0.1.source != .missing }
        let theory = library.theory(for: model)
        if !cells.isEmpty || theory != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("各站產能")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.text)
                ForEach(Array(cells.enumerated()), id: \.offset) { _, entry in
                    let column = entry.0
                    let cell = entry.1
                    HStack(alignment: .firstTextBaseline) {
                        Text(column.label)
                            .font(.subheadline)
                            .foregroundStyle(DS.textSecondary)
                        Spacer(minLength: 12)
                        let machines = DrawingCapacity.machines(for: capacity, column: column.id)
                        Text(cell.text + (machines.isEmpty ? "" : "（\(machines.joined(separator: "、"))）"))
                            .font(.subheadline.weight(cell.source == .po ? .semibold : .regular))
                            .foregroundStyle(cell.source == .present ? DS.success : (cell.source == .catalog ? DS.textSecondary : DS.text))
                            .multilineTextAlignment(.trailing)
                        if DrawingCapacity.isDifferent(cell) {
                            Text("≠")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(DS.danger)
                                .help("與 catalog.json 不一致：\(cell.catalogText)")
                        }
                    }
                }
                if let theory {
                    Divider().overlay(DS.hairline)
                    Text("沖壓理論產能")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.text)
                    Text(DrawingTheory.description(theory, sourceMtime: library.snapshot.theorySourceMtime))
                        .font(.footnote)
                        .foregroundStyle(DS.textSecondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 14)
        }
    }

    private var noteBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("規格與商務自訂筆記：")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.text)
            TextField("", text: $note, axis: .vertical)
                .lineLimit(3...10)
                .font(.body)
                .padding(10)
                .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1))
            HStack {
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
