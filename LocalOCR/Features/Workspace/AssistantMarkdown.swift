import SwiftUI

// MARK: - AI 回答的 Markdown 排版

/// AI 回答整段排版：標題、清單、待辦、引用、callout、程式碼、分隔線與表格。
/// 行內樣式（粗體、程式碼、網址、[[連結]]）交給 AssistantText；字級與顏色沿用外面設定的 font / foregroundStyle。
struct AssistantMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.blocks(from: text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .properties(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("\(item.key): \(item.value)")
                        .font(.caption.monospaced())
                        .foregroundStyle(DS.textSecondary)
                }
            }
        case .heading(let level, let text):
            inline(text)
                .font(Self.headingFont(level))
                .padding(.top, level <= 2 ? 4 : 2)
        case .paragraph(let text):
            inline(text)
        case .listItem(let marker, let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                markerView(marker)
                inline(text)
                    .strikethrough(marker == .task(true))
                    .opacity(marker == .task(true) ? 0.6 : 1)
            }
            .padding(.leading, CGFloat(min(indent, 6)) * 16)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(DS.hairline)
                    .frame(width: 3)
                inline(text)
                    .foregroundStyle(DS.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .callout(let kind, let title, let body):
            VStack(alignment: .leading, spacing: 4) {
                Text(title.isEmpty ? kind.capitalized : title)
                    .font(.subheadline.weight(.semibold))
                if !body.isEmpty {
                    AssistantMarkdownView(text: body)
                }
            }
            .pastelCard(Self.pastel(for: kind), padding: 12, cornerRadius: DS.radiusSmall)
        case .code(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(DS.text)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.control, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
        case .embed(let target):
            inline("[[\(target)]]")
        case .rule:
            Rectangle()
                .fill(DS.hairline)
                .frame(height: 1)
                .padding(.vertical, 4)
        case .table(let rows):
            AssistantTableView(table: MarkdownTableText(rows: rows))
        }
    }

    private func inline(_ text: String) -> Text {
        Text(AssistantText.attributed(text))
    }

    @ViewBuilder
    private func markerView(_ marker: MarkdownBlock.ListMarker) -> some View {
        switch marker {
        case .bullet:
            Text("•").foregroundStyle(DS.textSecondary)
        case .number(let number):
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(DS.textSecondary)
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .foregroundStyle(done ? DS.text : DS.textSecondary)
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    static func pastel(for kind: String) -> DS.Pastel {
        switch kind {
        case "tip", "hint", "important", "success", "check", "done": return .mint
        case "warning", "caution", "attention", "question", "help", "faq", "todo": return .butter
        case "danger", "error", "bug", "failure", "fail", "missing": return .blush
        case "example", "quote", "cite", "abstract", "summary", "tldr": return .lavender
        default: return .sky
        }
    }
}

/// Markdown 表格的儲存格（開頭結尾的「|」可有可無、`\|` 跳脫、<br> 換行，分隔列決定對齊）。
struct MarkdownTableText: Equatable {
    enum Alignment: Equatable {
        case leading, center, trailing
    }

    var hasHeader = false
    var alignments: [Alignment] = []
    var rows: [[String]] = []

    var columns: Int { rows.map(\.count).max() ?? 0 }

    init(rows lines: [String]) {
        let parsed = lines.map(Self.cells)
        if parsed.count > 1, Self.isSeparator(parsed[1]) {
            hasHeader = true
            alignments = parsed[1].map { cell in
                switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
                case (true, true): return .center
                case (false, true): return .trailing
                default: return .leading
                }
            }
            rows = [parsed[0]] + parsed.dropFirst(2)
        } else {
            rows = parsed
        }
        rows = rows.map { row in
            row.map { $0.replacingOccurrences(of: "\\|", with: "|").replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive]) }
        }
    }

    func alignment(of column: Int) -> Alignment {
        column < alignments.count ? alignments[column] : .leading
    }

    /// 一列切成儲存格：不在 `程式碼` 裡、沒有跳脫的「|」才是分隔。
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inCode = false
        var previous: Character?
        for character in line.trimmingCharacters(in: .whitespaces) {
            if character == "`" { inCode.toggle() }
            if character == "|", !inCode, previous != "\\" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        cells.append(current)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|"), !cells.isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }
}

/// AI 回答裡的表格：標題列粗體、列與列之間有細線、外框圓角；放不下時儲存格自動換行。
struct AssistantTableView: View {
    let table: MarkdownTableText

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(DS.hairline)
                        .frame(height: index == 1 && table.hasHeader ? 1.5 : 1)
                        .gridCellUnsizedAxes(.horizontal)
                }
                GridRow {
                    ForEach(0..<table.columns, id: \.self) { column in
                        cell(column < row.count ? row[column] : "", header: table.hasHeader && index == 0, alignment: table.alignment(of: column))
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                .stroke(DS.hairline, lineWidth: 1)
        )
    }

    private func cell(_ text: String, header: Bool, alignment: MarkdownTableText.Alignment) -> some View {
        Text(AssistantText.attributed(text))
            .font(header ? .subheadline.weight(.semibold) : .subheadline)
            .multilineTextAlignment(Self.textAlignment(alignment))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .gridColumnAlignment(Self.horizontalAlignment(alignment))
    }

    static func textAlignment(_ alignment: MarkdownTableText.Alignment) -> TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    static func horizontalAlignment(_ alignment: MarkdownTableText.Alignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
