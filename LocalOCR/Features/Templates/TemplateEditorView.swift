import SwiftUI

/// 編輯自訂情境：貼上想要的 JSON 範例，輸出就會照這個結構與欄位順序。
struct TemplateEditorView: View {
    @Environment(TemplateLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ScanTemplate
    @State private var keywordsText: String
    @State private var rulesText: String

    init(template: ScanTemplate) {
        _draft = State(initialValue: template)
        _keywordsText = State(initialValue: template.keywords.joined(separator: "、"))
        _rulesText = State(initialValue: template.rules.isEmpty ? "" : JSONValue.array(template.rules).prettyPrinted())
    }

    private var rulesError: String? {
        let trimmed = rulesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            return TemplateRules.validate(try JSONValue.parse(trimmed))
        } catch {
            return error.localizedDescription
        }
    }

    private var sampleResult: Result<JSONValue, Error> {
        Result { try JSONValue.parse(draft.sampleJSON) }
    }

    private var sampleError: String? {
        switch sampleResult {
        case .success(.object(let members)) where !members.isEmpty: return nil
        case .success: return "需要至少一個欄位的 JSON 物件"
        case .failure(let error): return error.localizedDescription
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && ScanTemplate.isValidID(draft.id)
            && sampleError == nil
            && rulesError == nil
    }

    var body: some View {
        Form {
            Section {
                TextField("名稱", text: $draft.name)
                TextField("描述", text: $draft.description, axis: .vertical)
                    .lineLimit(2...4)
            } header: {
                Text("情境")
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
                Text("輸出樣式")
            }

            Section {
                TextField("指示", text: $draft.instructions, axis: .vertical)
                    .lineLimit(2...6)
                TextField("關鍵字", text: $keywordsText, axis: .vertical)
            } header: {
                Text("規則")
            }

            Section {
                TextEditor(text: $rulesText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 120)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let rulesError {
                    Label(rulesError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("計算規則")
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
            }
        }
        .canvasList()
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
                    let rules = rulesText.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.rulesJSON = rules.isEmpty ? nil : (try? JSONValue.parse(rules))?.compactString
                    library.saveCustom(draft)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}
