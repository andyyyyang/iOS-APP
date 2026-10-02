import SwiftUI

/// 編輯自訂情境：貼上想要的 JSON 範例，輸出就會照這個結構與欄位順序。
struct TemplateEditorView: View {
    @Environment(TemplateLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ScanTemplate
    @State private var keywordsText: String

    init(template: ScanTemplate) {
        _draft = State(initialValue: template)
        _keywordsText = State(initialValue: template.keywords.joined(separator: "、"))
    }

    private var sampleResult: Result<JSONValue, Error> {
        Result { try JSONValue.parse(draft.sampleJSON) }
    }

    private var sampleError: String? {
        switch sampleResult {
        case .success(.object(let members)) where !members.isEmpty: return nil
        case .success: return "範例必須是至少有一個欄位的 JSON 物件 { … }"
        case .failure(let error): return error.localizedDescription
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && ScanTemplate.isValidID(draft.id)
            && sampleError == nil
    }

    var body: some View {
        Form {
            Section {
                TextField("名稱，例如：藥袋", text: $draft.name)
                TextField("描述（判斷情境用），例如：藥局或醫院的藥袋，含藥名、劑量與服用方式", text: $draft.description, axis: .vertical)
                    .lineLimit(2...4)
            } header: {
                Text("情境")
            } footer: {
                Text("描述寫得越具體，自動判斷越準確。")
            }

            Section {
                TextEditor(text: $draft.sampleJSON)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 200)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let sampleError {
                    Label(sampleError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    Button("整理格式") {
                        if case .success(let value) = sampleResult {
                            draft.sampleJSON = value.prettyPrinted()
                        }
                    }
                }
            } header: {
                Text("輸出樣式（JSON 範例）")
            } footer: {
                Text("輸出會有相同的欄位、巢狀結構與順序。範例值會當作欄位提示；數字欄位輸出數字，陣列以第一個元素為格式，null 代表可為空的文字。")
            }

            Section {
                TextField("例如：金額使用數字；日期使用 YYYY-MM-DD", text: $draft.instructions, axis: .vertical)
                    .lineLimit(2...6)
                TextField("關鍵字，以頓號或逗號分隔", text: $keywordsText, axis: .vertical)
            } header: {
                Text("規則（選填）")
            } footer: {
                Text("關鍵字用於離線時的情境判斷備援。")
            }

            Section {
                TextField("代碼", text: $draft.id)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !ScanTemplate.isValidID(draft.id) {
                    Text("只能使用小寫英文、數字、- 與 _")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("代碼")
            } footer: {
                Text("與內建或伺服器情境相同的代碼會覆寫該情境。")
            }
        }
        .navigationTitle(draft.name.isEmpty ? "新增情境" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("儲存") {
                    draft.keywords = keywordsText
                        .split(whereSeparator: { "、,，".contains($0) })
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if case .success(let value) = sampleResult {
                        draft.sampleJSON = value.compactString
                    }
                    library.saveCustom(draft)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}
