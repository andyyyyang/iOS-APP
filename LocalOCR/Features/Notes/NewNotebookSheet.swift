import SwiftUI

/// 新增手寫筆記本：名稱、紙張、顏色。
struct NewNotebookSheet: View {
    var onCreate: (String, PaperStyle, NotebookColor) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var paper: PaperStyle = .lined
    @State private var color: NotebookColor = .blue
    @FocusState private var titleFocused: Bool

    private var defaultTitle: String {
        "手寫 " + Date().formatted(.dateTime.month().day().hour().minute())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名稱") {
                    TextField(defaultTitle, text: $title)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit(create)
                }
                Section("紙張") {
                    HStack(spacing: 14) {
                        ForEach(PaperStyle.allCases) { style in
                            Button {
                                paper = style
                            } label: {
                                PaperPreview(style: style, isSelected: paper == style)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("顏色") {
                    HStack(spacing: 14) {
                        ForEach(NotebookColor.allCases) { option in
                            Button {
                                color = option
                            } label: {
                                Circle()
                                    .fill(option.color.gradient)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if color == option {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.rawValue)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .canvasList()
            .navigationTitle("新增手寫筆記本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("建立", action: create)
                }
            }
            .onAppear { titleFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(name.isEmpty ? defaultTitle : name, paper, color)
        dismiss()
    }
}

private struct PaperPreview: View {
    let style: PaperStyle
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                let scale = size.width / NotebookLayout.pageSize.width
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                guard let pattern = PaperRenderer.patternPath(for: style, size: NotebookLayout.pageSize) else { return }
                let path = Path(pattern).applying(CGAffineTransform(scaleX: scale, y: scale))
                let color = Color(PaperRenderer.patternColor(for: style))
                if style == .dotted {
                    context.fill(path, with: .color(color))
                } else {
                    context.stroke(path, with: .color(color), lineWidth: 0.6)
                }
            }
            .aspectRatio(NotebookLayout.pageSize.width / NotebookLayout.pageSize.height, contentMode: .fit)
            .frame(width: 52)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isSelected ? DS.primary : DS.hairline, lineWidth: isSelected ? 2.5 : 1)
            }
            Text(style.title)
                .font(.caption)
                .foregroundStyle(isSelected ? DS.text : DS.textSecondary)
        }
    }
}
