import SwiftUI
import UIKit

/// 筆記畫面的柔和色系（淺色是粉彩，深色模式改用低飽和的深色）。
enum Pastel: CaseIterable {
    case sky
    case mint
    case lavender
    case butter
    case blush

    private var components: (light: UIColor, dark: UIColor, accent: UIColor) {
        switch self {
        case .sky:
            return (UIColor(red: 0.86, green: 0.95, blue: 0.99, alpha: 1), UIColor(red: 0.12, green: 0.22, blue: 0.27, alpha: 1), .systemTeal)
        case .mint:
            return (UIColor(red: 0.84, green: 0.96, blue: 0.85, alpha: 1), UIColor(red: 0.12, green: 0.24, blue: 0.15, alpha: 1), .systemGreen)
        case .lavender:
            return (UIColor(red: 0.93, green: 0.86, blue: 0.99, alpha: 1), UIColor(red: 0.23, green: 0.16, blue: 0.29, alpha: 1), .systemPurple)
        case .butter:
            return (UIColor(red: 0.99, green: 0.93, blue: 0.76, alpha: 1), UIColor(red: 0.29, green: 0.24, blue: 0.11, alpha: 1), .systemOrange)
        case .blush:
            return (UIColor(red: 0.99, green: 0.86, blue: 0.91, alpha: 1), UIColor(red: 0.30, green: 0.14, blue: 0.20, alpha: 1), .systemPink)
        }
    }

    var fill: Color {
        let (light, dark, _) = components
        return Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    var accent: Color { Color(components.accent) }

    /// 依字串穩定地挑一個顏色（同一則筆記每次顏色相同）。
    static func stable(for key: String) -> Pastel {
        let sum = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return allCases[sum % allCases.count]
    }
}

/// 卡片底色：淺色為白色，深色為次要背景。
extension View {
    func noteCard(cornerRadius: CGFloat = 26) -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }
}

/// 統計卡（像參考圖的 26 Total／2 Completed／23 Upcoming）。
struct StatTile: View {
    let value: Int
    let title: String
    var color: Pastel?

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background {
            if let color {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(color.fill)
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 資料夾圖示：後片＋露出的紙張＋前片（參考圖的知識庫資料夾）。
struct FolderIllustration: View {
    var tint: Color = Color(.systemGray)
    var hasFiles = true

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .bottom) {
                FolderBackShape()
                    .fill(tint.opacity(0.85))
                if hasFiles {
                    paper(rotation: -6, offset: CGSize(width: -size.width * 0.12, height: -size.height * 0.38), size: size)
                    paper(rotation: 4, offset: CGSize(width: size.width * 0.1, height: -size.height * 0.34), size: size)
                }
                RoundedRectangle(cornerRadius: size.width * 0.08, style: .continuous)
                    .fill(
                        LinearGradient(colors: [tint, tint.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    )
                    .frame(height: size.height * 0.72)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: -1)
            }
        }
        .aspectRatio(1.35, contentMode: .fit)
    }

    private func paper(rotation: Double, offset: CGSize, size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.white)
            .overlay(alignment: .top) {
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(Color.black.opacity(0.08)).frame(height: 2)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            .frame(width: size.width * 0.5, height: size.height * 0.55)
            .rotationEffect(.degrees(rotation))
            .offset(offset)
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }
}

/// 資料夾後片（左上有標籤頁）。
private struct FolderBackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width * 0.08
        let tabWidth = rect.width * 0.4
        let tabHeight = rect.height * 0.12
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + tabWidth - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + tabWidth + radius * 0.6, y: rect.minY + tabHeight), control: CGPoint(x: rect.minX + tabWidth, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY + tabHeight))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tabHeight + radius), control: CGPoint(x: rect.maxX, y: rect.minY + tabHeight))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 小標籤（「手寫」「#會議」…）。
struct NoteChip: View {
    let text: String
    var systemImage: String?
    var color: Pastel = .mint

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.fill, in: Capsule())
    }
}

/// 底部浮動的工具列：彩色圓形按鈕（新增筆記、手寫、待辦、資料夾、掃描）。
struct NoteToolPalette: View {
    struct Tool: Identifiable {
        let id: String
        let systemImage: String
        let title: String
        let color: Pastel
        let action: () -> Void
    }

    let tools: [Tool]
    var more: [Tool] = []

    var body: some View {
        HStack(spacing: 10) {
            ForEach(tools) { tool in
                Button(action: tool.action) {
                    Image(systemName: tool.systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 44, height: 44)
                        .background(tool.color.fill, in: Circle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.lift)
                .accessibilityLabel(tool.title)
                .help(tool.title)
            }
            if !more.isEmpty {
                Menu {
                    ForEach(more) { tool in
                        Button(action: tool.action) {
                            Label(tool.title, systemImage: tool.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 44, height: 44)
                        .background(Color.primary, in: Circle())
                }
                .accessibilityLabel("更多")
            }
        }
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}
