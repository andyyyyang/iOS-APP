import SwiftUI

/// 情境樣板管理：內建、伺服器同步與自訂情境。
struct TemplateListView: View {
    @Environment(TemplateLibrary.self) private var library
    @State private var editing: ScanTemplate?

    var body: some View {
        List {
            section("內建", templates: library.all.filter { $0.origin == .builtIn })
            section("伺服器", templates: library.all.filter { $0.origin == .server })
            section("自訂", templates: library.all.filter { $0.origin == .custom })
        }
        .navigationTitle("情境樣板")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = ScanTemplate(
                        id: ScanTemplate.makeCustomID(),
                        name: "",
                        description: "",
                        sampleJSON: "{\n  \"title\": \"範例標題\",\n  \"amount\": 100\n}",
                        origin: .custom
                    )
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新增情境")
            }
        }
        .sheet(item: $editing) { template in
            NavigationStack {
                TemplateEditorView(template: template)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, templates: [ScanTemplate]) -> some View {
        if !templates.isEmpty {
            Section(title) {
                ForEach(templates) { template in
                    NavigationLink {
                        TemplateDetailView(template: template)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name)
                            Text(template.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct TemplateDetailView: View {
    let template: ScanTemplate

    @Environment(TemplateLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ScanTemplate?
    @State private var toast: String?
    @State private var confirmsDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(title: template.origin.displayName, systemImage: "square.stack.3d.up", trailing: template.id)
                    Text(template.name)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text(template.description)
                        .foregroundStyle(.secondary)
                }
                .card()

                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: "輸出樣式", systemImage: "curlybraces")
                    JSONBlock(json: template.sample.prettyPrinted())
                }
                .card()

                if !template.rules.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(title: "計算規則", systemImage: "function", trailing: "\(template.rules.count) 條")
                        JSONBlock(json: JSONValue.array(template.rules).prettyPrinted())
                    }
                    .card()
                }

                if !template.instructions.isEmpty || !template.keywords.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        CardHeader(title: "規則", systemImage: "list.bullet")
                        if !template.instructions.isEmpty {
                            Text(template.instructions)
                        }
                        if !template.keywords.isEmpty {
                            Text("關鍵字：" + template.keywords.joined(separator: "、"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .card()
                }

                actions
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { template in
            NavigationStack {
                TemplateEditorView(template: template)
            }
        }
        .confirmationDialog("刪除這個自訂情境？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                library.deleteCustom(id: template.id)
                dismiss()
            }
        }
        .toast($toast)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if template.origin == .custom {
                Button {
                    editing = template
                } label: {
                    Label("編輯", systemImage: "pencil").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    var copy = template
                    copy.origin = .custom
                    editing = copy
                } label: {
                    Label("自訂這個情境的輸出樣式", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if template.origin == .custom, ServerSettings.isConfigured {
                Button {
                    Task { await uploadToServer() }
                } label: {
                    Label("上傳到伺服器，讓所有 harness 共用", systemImage: "icloud.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if template.origin == .custom {
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    Label("刪除", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func uploadToServer() async {
        guard let client = ServerClient.configured() else { return }
        do {
            try await client.upsertTemplate(template)
            toast = "已上傳到伺服器"
        } catch {
            toast = error.localizedDescription
        }
    }
}
