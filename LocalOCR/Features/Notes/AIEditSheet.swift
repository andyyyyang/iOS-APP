import SwiftUI

/// 要請 AI 修改的文字（選取的段落或整則筆記的內文）。
struct AIEditRequest: Identifiable {
    let id = UUID()
    let range: NSRange
    let original: String
    let wholeNote: Bool
}

/// 請 AI 修改 Markdown：選一個常用的要求或自己輸入，先看修改後的結果再套用（套用後可以復原）。
struct AIEditSheet: View {
    let request: AIEditRequest
    var onApply: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var instruction = ""
    @State private var lastInstruction = ""
    @State private var phase: Phase = .idle
    @FocusState private var fieldFocused: Bool

    enum Phase: Equatable {
        case idle
        case working
        case done(String)
        case failed(String)
    }

    private static let presets: [(title: String, instruction: String)] = [
        ("修正錯字", "修正錯字、標點與不通順的句子，不改變意思與 Markdown 格式"),
        ("改寫得更清楚", "改寫得更清楚易讀，保留所有重點與格式"),
        ("整理成條列", "整理成 Markdown 條列重點"),
        ("做成表格", "把內容整理成 Markdown 表格"),
        ("加上標題", "依內容加上適當的 Markdown 標題並分段"),
        ("精簡", "精簡成大約一半的長度，保留重點"),
        ("列出待辦", "把內容中要做的事整理成 Markdown 待辦清單（- [ ] ），放在最後，其餘內容不變"),
        ("翻成英文", "翻譯成自然的英文，保留 Markdown 格式"),
        ("翻成繁體中文", "翻譯成自然的繁體中文，保留 Markdown 格式"),
    ]

    private var isTooLong: Bool { request.original.count > NoteIntelligence.editCharacterLimit }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(request.wholeNote ? "整則筆記 · \(request.original.count) 字" : "選取的文字 · \(request.original.count) 字")
                        .font(.footnote)
                        .foregroundStyle(DS.textSecondary)
                    if isTooLong {
                        Text("內容太長，請先在筆記中選取要修改的段落（\(NoteIntelligence.editCharacterLimit) 字以內）。")
                            .font(.subheadline)
                            .foregroundStyle(DS.warning)
                    }
                    switch phase {
                    case .idle, .failed:
                        requestForm
                        if case .failed(let message) = phase {
                            Text(message)
                                .font(.subheadline)
                                .foregroundStyle(DS.warning)
                        }
                    case .working:
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Apple Intelligence 正在修改…")
                                .foregroundStyle(DS.textSecondary)
                        }
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                    case .done(let result):
                        resultView(result)
                    }
                }
                .padding(20)
            }
            .background(DS.pane)
            .navigationTitle("請 AI 修改")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var requestForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            FlowLayout(spacing: 8) {
                ForEach(Self.presets, id: \.title) { preset in
                    Button(preset.title) { run(preset.instruction) }
                        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                        .disabled(isTooLong)
                }
            }
            HStack(spacing: 8) {
                TextField("或告訴 AI 要怎麼改…", text: $instruction, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($fieldFocused)
                    .submitLabel(.send)
                    .onSubmit { run(instruction) }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(DS.control, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
                Button("送出") { run(instruction) }
                    .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                    .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTooLong)
            }
            Text("在裝置上用 Apple Intelligence 修改，內容不會上傳。套用後可以用復原（三指左滑或 ⌘Z）還原。")
                .font(.caption)
                .foregroundStyle(DS.textTertiary)
        }
    }

    private func resultView(_ result: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("修改後")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DS.textSecondary)
            Text(result)
                .font(.system(.body, design: .default))
                .foregroundStyle(DS.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 14)
            HStack(spacing: 8) {
                Button("套用") {
                    onApply(result)
                    dismiss()
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                Button("重新產生") { run(lastInstruction) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Button("換個要求") { phase = .idle }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
    }

    private func run(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isTooLong, phase != .working else { return }
        lastInstruction = trimmed
        fieldFocused = false
        phase = .working
        Task {
            do {
                phase = .done(try await NoteIntelligence.editMarkdown(request.original, instruction: trimmed))
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
