import SwiftUI

/// 介面風格：淺灰底、白色大圓角卡片、大標題與灰色輔助文字。
enum Theme {
    static let cornerRadius: CGFloat = 24
    static let cardPadding: CGFloat = 18
    static let screenBackground = Color(.systemGroupedBackground)
    static let cardBackground = Color(.secondarySystemGroupedBackground)
}

private struct CardModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = Theme.cardPadding) -> some View {
        modifier(CardModifier(padding: padding))
    }

    func screenBackground() -> some View {
        background(Theme.screenBackground.ignoresSafeArea())
    }
}

/// 卡片標題列：圖示、標題、可選的箭頭，以及右側的灰色說明。
struct CardHeader: View {
    let title: String
    let systemImage: String
    var showsChevron = false
    var trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.medium))
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// 大數字搭配小單位，例如「12 份」。
struct StatValue: View {
    let value: String
    var unit: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if let unit {
                Text(unit)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 大標題列，右側為灰色數量與箭頭。
struct ShelfHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.largeTitle.bold())
            Spacer()
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 清單列：粗體標題，右側灰色數量與箭頭。
struct ShelfRow: View {
    let title: String
    var detail: String?
    var systemImage: String?

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// 頂部提示列：圓形圖示、標題與副標題。
struct BannerRow: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 分段弧形量表，用來顯示信心度（0~1）。
struct ConfidenceGauge: View {
    let value: Double
    var size: CGFloat = 64

    private var clamped: Double { min(max(value, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.1, to: 0.9)
                .stroke(Color.accentColor.opacity(0.15), style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [6, 5]))
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: 0.1, to: 0.1 + 0.8 * clamped)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [6, 5]))
                .rotationEffect(.degrees(90))
            VStack(spacing: 0) {
                Text("\(Int((clamped * 100).rounded()))")
                    .font(.system(.headline, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("信心度 \(Int((clamped * 100).rounded()))%")
    }
}

/// 等寬字體顯示的 JSON 區塊。
struct JSONBlock: View {
    let json: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(json)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.screenBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
