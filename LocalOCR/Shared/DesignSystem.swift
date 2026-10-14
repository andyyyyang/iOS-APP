import SwiftUI
import UIKit

// MARK: - Midnight 設計語言

/// Midnight：石墨深色底、毛玻璃面板、紫→青的光。深色為主，淺色模式改用霧白玻璃。
enum Midnight {
    /// 最底層的畫布。
    static let canvas = Color.adaptive(dark: 0x0A0A0D, light: 0xEEEEF3)
    /// 中間編輯區的紙面：比畫布亮一點的實色，閱讀與書寫最清楚。
    static let pane = Color.adaptive(dark: 0x0F0F14, light: 0xFBFBFD)
    /// 面板與卡片的底色（疊在毛玻璃上）。
    static let surface = Color.adaptive(dark: 0x121217, light: 0xFFFFFF, darkOpacity: 0.62, lightOpacity: 0.72)
    /// 浮起的元素（選取列、輸入框）。
    static let raised = Color.adaptive(dark: 0xFFFFFF, light: 0x0B0B12, darkOpacity: 0.06, lightOpacity: 0.05)
    /// 細線與邊框。
    static let hairline = Color.adaptive(dark: 0xFFFFFF, light: 0x0B0B12, darkOpacity: 0.09, lightOpacity: 0.09)

    static let text = Color.adaptive(dark: 0xEEEEF4, light: 0x14141B)
    static let textSecondary = Color.adaptive(dark: 0x9B9BAA, light: 0x5B5B6A)
    static let textTertiary = Color.adaptive(dark: 0x5F5F6D, light: 0x9A9AA7)

    static let violet = Color(hex: 0x8B5CF6)
    static let cyan = Color(hex: 0x22D3EE)
    static let magenta = Color(hex: 0xD946EF)
    /// 單色強調（文字、圖示、系統元件的 tint）：深色用亮紫，淺色用深紫以維持對比。
    static let accent = Color.adaptive(dark: 0xB197FC, light: 0x6D3FE0)
    static let success = Color.adaptive(dark: 0x4ADE80, light: 0x16A34A)
    static let warning = Color.adaptive(dark: 0xFBBF24, light: 0xC27803)
    static let danger = Color.adaptive(dark: 0xF87171, light: 0xDC2626)

    /// 主要漸層：紫 → 青。
    static let gradient = LinearGradient(colors: [violet, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// 文字用的漸層（淺色模式加深，避免太淡）。
    static let textGradient = LinearGradient(
        colors: [Color.adaptive(dark: 0xC4B5FD, light: 0x6D3FE0), Color.adaptive(dark: 0x67E8F9, light: 0x0E7490)],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let radiusS: CGFloat = 10
    static let radiusM: CGFloat = 16
    static let radiusL: CGFloat = 24

    /// 依字串穩定地挑一個光色（資料夾、標籤、關聯圖節點）。
    static func hue(for key: String) -> Color {
        let palette: [Color] = [Color(hex: 0xA78BFA), Color(hex: 0x67E8F9), Color(hex: 0xF0ABFC), Color(hex: 0x93C5FD), Color(hex: 0x6EE7B7), Color(hex: 0xFCD34D)]
        let sum = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// 深色／淺色模式各自的顏色（未指定時當作深色）。
    static func adaptive(dark: UInt32, light: UInt32, darkOpacity: Double = 1, lightOpacity: Double = 1) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor(hex: light, alpha: lightOpacity)
                : UIColor(hex: dark, alpha: darkOpacity)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// 外觀設定：深色（預設）、淺色、跟隨系統。
enum AppAppearance: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    static let key = "app.appearance"

    var id: Self { self }

    var title: String {
        switch self {
        case .dark: return "深色"
        case .light: return "淺色"
        case .system: return "跟隨系統"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

// MARK: - 背景

/// 石墨畫布上緩慢漂移的極光：左上紫、右下青、中間一抹洋紅。
struct MidnightBackground: View {
    var animated = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let strength = colorScheme == .dark ? 1.0 : 0.55
            ZStack {
                Midnight.canvas
                blob(Midnight.violet, opacity: 0.42 * strength, diameter: max(size.width, size.height) * 0.9)
                    .offset(x: -size.width * (drift ? 0.30 : 0.38), y: -size.height * (drift ? 0.34 : 0.28))
                blob(Midnight.cyan, opacity: 0.30 * strength, diameter: max(size.width, size.height) * 0.8)
                    .offset(x: size.width * (drift ? 0.36 : 0.30), y: size.height * (drift ? 0.30 : 0.38))
                blob(Midnight.magenta, opacity: 0.14 * strength, diameter: max(size.width, size.height) * 0.6)
                    .offset(x: size.width * (drift ? 0.08 : -0.06), y: size.height * (drift ? -0.04 : 0.08))
            }
            .frame(width: size.width, height: size.height)
            .drawingGroup()
        }
        .ignoresSafeArea()
        .onAppear {
            guard animated, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) { drift = true }
        }
        .accessibilityHidden(true)
    }

    private func blob(_ color: Color, opacity: Double, diameter: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(0)], center: .center, startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
    }
}

/// 中間編輯區的底：實色紙面＋上方一抹紫光。
struct PaneBackdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            Midnight.pane
            RadialGradient(colors: [Midnight.violet.opacity(0.14), Midnight.violet.opacity(0)], center: .top, startRadius: 0, endRadius: 560)
                .frame(height: 560)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// 淡淡的點陣格線（關聯圖、首頁英雄區）。
struct DotGrid: View {
    var spacing: CGFloat = 22
    var opacity: Double = 0.10

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
                    x += spacing
                }
                y += spacing
            }
            context.fill(path, with: .color(Midnight.text.opacity(opacity)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 玻璃

private struct GlassModifier: ViewModifier {
    var cornerRadius: CGFloat
    var shadow: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(Midnight.surface))
            }
            .overlay {
                // 上緣的高光、下緣幾乎看不見：像光從上方打在玻璃上
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(colorScheme == .dark ? 0.16 : 0.70), Color.white.opacity(colorScheme == .dark ? 0.03 : 0.25)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(shadow ? (colorScheme == .dark ? 0.45 : 0.10) : 0), radius: 28, y: 14)
    }
}

extension View {
    /// 毛玻璃面板：半透明石墨、上緣高光、柔和陰影。
    func glass(cornerRadius: CGFloat = Midnight.radiusL, shadow: Bool = true) -> some View {
        modifier(GlassModifier(cornerRadius: cornerRadius, shadow: shadow))
    }

    /// 內距＋玻璃卡片。
    func glassCard(padding: CGFloat = 18, cornerRadius: CGFloat = Midnight.radiusL) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(cornerRadius: cornerRadius, shadow: false)
    }

    /// 紫青漸層的文字或圖示。
    func gradientForeground() -> some View {
        foregroundStyle(Midnight.textGradient)
    }

    /// 柔和的光暈（強調的按鈕、選取的節點）。
    func glow(_ color: Color = Midnight.violet, radius: CGFloat = 18, opacity: Double = 0.55) -> some View {
        shadow(color: color.opacity(opacity), radius: radius)
    }

    /// 清單與表單：隱藏系統底色，改用 Midnight 背景。
    func midnightList() -> some View {
        scrollContentBackground(.hidden)
            .background(MidnightBackground(animated: false))
    }
}

// MARK: - 按鈕

/// 主要按鈕：漸層膠囊加光暈；次要：玻璃膠囊；幽靈：只有文字。
struct MidnightButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case ghost
    }

    var kind: Kind = .primary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        configuration.label
            .font(.system(compact ? .subheadline : .body, design: .rounded).weight(.semibold))
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.vertical, compact ? 8 : 12)
            .foregroundStyle(kind == .primary ? Color.white : Midnight.text)
            .background {
                switch kind {
                case .primary:
                    shape.fill(Midnight.gradient)
                        .overlay(shape.strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                        .glow(radius: configuration.isPressed ? 8 : 16, opacity: 0.5)
                case .secondary:
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.fill(Midnight.raised))
                        .overlay(shape.strokeBorder(Midnight.hairline, lineWidth: 1))
                case .ghost:
                    Color.clear
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
            .contentShape(shape)
    }
}

/// 圓形圖示按鈕（工具列、側邊欄切換）。
struct GlassIconButtonStyle: ButtonStyle {
    var size: CGFloat = 36
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(isActive ? AnyShapeStyle(Midnight.textGradient) : AnyShapeStyle(Midnight.textSecondary))
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .fill(isActive || configuration.isPressed ? Midnight.raised : Color.clear)
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

// MARK: - 元件

/// 漸層方塊中的圖示（帶光暈）。
struct GlowIcon: View {
    let systemImage: String
    var size: CGFloat = 40
    var tint: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                if let tint {
                    shape.fill(LinearGradient(colors: [tint, tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    shape.fill(Midnight.gradient)
                }
            }
            .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .glow(tint ?? Midnight.violet, radius: size * 0.35, opacity: 0.45)
    }
}

/// 小標題：字距加寬的灰色字。
struct SectionLabel: View {
    let text: String
    var trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(text)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(Midnight.textTertiary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundStyle(Midnight.textTertiary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// 膠囊標籤（#標籤、狀態）。
struct GlassChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = Midnight.accent

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.system(.caption, design: .rounded).weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
    }
}

/// 漸層大數字＋說明（首頁統計）。
struct GlowStat: View {
    let value: Int
    let title: String
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption.weight(.semibold))
                }
                Text(title).font(.system(.caption, design: .rounded).weight(.medium))
            }
            .foregroundStyle(Midnight.textSecondary)
            Text("\(value)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .gradientForeground()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16, cornerRadius: Midnight.radiusM + 4)
        .accessibilityElement(children: .combine)
    }
}

/// 空狀態：漸層圖示、標題、說明。
struct MidnightEmptyState: View {
    let title: String
    let systemImage: String
    var message: String?

    var body: some View {
        VStack(spacing: 14) {
            GlowIcon(systemImage: systemImage, size: 56)
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(Midnight.text)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Midnight.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// 自動換行的橫向排列（標籤、膠囊）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 既有畫面使用的元件（改為 Midnight 風格）

/// 舊名稱保留：掃描、紀錄等工具畫面透過它們套用新的風格。
enum Theme {
    static let cornerRadius: CGFloat = Midnight.radiusL
    static let cardPadding: CGFloat = 18
    static let screenBackground = Midnight.canvas
    static let cardBackground = Midnight.raised
}

extension View {
    func card(padding: CGFloat = Theme.cardPadding) -> some View {
        glassCard(padding: padding)
    }

    func screenBackground() -> some View {
        background(MidnightBackground(animated: false))
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
                .font(.subheadline.weight(.semibold))
                .gradientForeground()
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Midnight.text)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Midnight.textTertiary)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(Midnight.textSecondary)
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
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .gradientForeground()
            if let unit {
                Text(unit)
                    .font(.title3)
                    .foregroundStyle(Midnight.textSecondary)
            }
        }
    }
}

/// 大標題列，右側為灰色數量。
struct ShelfHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(Midnight.text)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Midnight.textSecondary)
            }
        }
    }
}

/// 清單列：標題，右側灰色數量與箭頭。
struct ShelfRow: View {
    let title: String
    var detail: String?
    var systemImage: String?

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .gradientForeground()
                    .frame(width: 24)
            }
            Text(title)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(Midnight.text)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Midnight.textSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Midnight.textTertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// 頂部提示列：漸層圖示、標題與副標題。
struct BannerRow: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            GlowIcon(systemImage: systemImage, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Midnight.text)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Midnight.textSecondary)
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
                .stroke(Midnight.hairline, style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [6, 5]))
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: 0.1, to: 0.1 + 0.8 * clamped)
                .stroke(Midnight.gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [6, 5]))
                .rotationEffect(.degrees(90))
                .glow(radius: 8, opacity: 0.4)
            VStack(spacing: 0) {
                Text("\(Int((clamped * 100).rounded()))")
                    .font(.system(.headline, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Midnight.text)
                Text("%")
                    .font(.caption2)
                    .foregroundStyle(Midnight.textSecondary)
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
                .foregroundStyle(Midnight.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: Midnight.radiusM, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Midnight.radiusM, style: .continuous).strokeBorder(Midnight.hairline, lineWidth: 1))
    }
}
