import SwiftUI
import UIKit

// MARK: - 設計語言

/// 黑色頂部列與功能列、白色內容、平面的粉彩色塊；沒有漸層與光暈。淺色為主，深色模式改用深灰。
enum DS {
    /// 頂部列與功能列。
    static let ink = Color.adaptive(dark: 0x0B0B0C, light: 0x111113)
    /// 黑色區塊上的按鈕（選取中）與搜尋框。
    static let inkRaised = Color(hex: 0x2A2A2E)
    static let inkField = Color(hex: 0x26262A)
    /// 黑色區塊上的文字。
    static let onInk = Color.white
    static let onInkDim = Color.white.opacity(0.6)

    /// 中間內容。
    static let pane = Color.adaptive(dark: 0x1C1C1E, light: 0xFFFFFF)
    /// 左右側欄與設定等畫面的底色。
    static let sidebar = Color.adaptive(dark: 0x151517, light: 0xF4F4F6)
    /// 卡片。
    static let card = Color.adaptive(dark: 0x242427, light: 0xFFFFFF)
    static let cardBorder = Color.adaptive(dark: 0x2F2F33, light: 0xECECF0)
    static let hairline = Color.adaptive(dark: 0x2A2A2E, light: 0xE8E8EC)
    /// 淺灰按鈕、分段控制的底。
    static let control = Color.adaptive(dark: 0x2C2C30, light: 0xF0F0F3)
    static let controlTrack = Color.adaptive(dark: 0x2A2A2E, light: 0xE8E8EC)

    static let text = Color.adaptive(dark: 0xF2F2F4, light: 0x16161A)
    static let textSecondary = Color.adaptive(dark: 0xA1A1AA, light: 0x6B6B76)
    static let textTertiary = Color.adaptive(dark: 0x6E6E78, light: 0xA2A2AC)
    /// 粉彩色塊上的次要文字。
    static let onPastelSecondary = Color.adaptive(dark: 0xC9C9D1, light: 0x4D4D57)

    /// 主要按鈕（黑底白字；深色模式反過來）。
    static let primary = Color.adaptive(dark: 0xF2F2F4, light: 0x111113)
    static let onPrimary = Color.adaptive(dark: 0x111113, light: 0xFFFFFF)

    /// 連結與標籤。
    static let link = Color.adaptive(dark: 0x9DAEFF, light: 0x3D5BD9)
    static let success = Color.adaptive(dark: 0x4ADE80, light: 0x2F9E62)
    static let warning = Color.adaptive(dark: 0xFBBF24, light: 0xB7791F)
    static let danger = Color.adaptive(dark: 0xF87171, light: 0xD83A3A)

    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 9

    /// 平面的粉彩色（淺色模式粉彩、深色模式低飽和的深色）。
    enum Pastel: CaseIterable {
        case sky
        case mint
        case lavender
        case butter
        case blush

        var color: Color {
            switch self {
            case .sky: return .adaptive(dark: 0x1E3440, light: 0xDDF1FB)
            case .mint: return .adaptive(dark: 0x1F3A26, light: 0xD7F3DA)
            case .lavender: return .adaptive(dark: 0x33284A, light: 0xECE2FC)
            case .butter: return .adaptive(dark: 0x3D3418, light: 0xFCF0C8)
            case .blush: return .adaptive(dark: 0x432532, light: 0xFBE0E9)
            }
        }

        /// 依字串穩定地挑一個顏色（同一則筆記、同一個資料夾每次顏色相同）。
        static func stable(for key: String) -> Pastel {
            let sum = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            return allCases[sum % allCases.count]
        }
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

    /// 深色／淺色模式各自的顏色。
    static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
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

/// 外觀設定：淺色（預設）、深色、跟隨系統。
enum AppAppearance: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    static let key = "app.appearance"

    var id: Self { self }

    var title: String {
        switch self {
        case .light: return "淺色"
        case .dark: return "深色"
        case .system: return "跟隨系統"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

// MARK: - 卡片與底色

extension View {
    /// 卡片：白底、細框、極淡的陰影。
    func card(padding: CGFloat = 16, cornerRadius: CGFloat = DS.radius, fill: Color = DS.card, bordered: Bool = true) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(DS.cardBorder, lineWidth: 1)
                }
            }
    }

    /// 粉彩色塊卡片（沒有框線）。
    func pastelCard(_ pastel: DS.Pastel, padding: CGFloat = 14, cornerRadius: CGFloat = DS.radius) -> some View {
        card(padding: padding, cornerRadius: cornerRadius, fill: pastel.color, bordered: false)
    }

    func screenBackground() -> some View {
        background(DS.sidebar.ignoresSafeArea())
    }

    /// 清單與表單：隱藏系統底色，改用側欄的淺灰。
    func canvasList() -> some View {
        scrollContentBackground(.hidden)
            .background(DS.sidebar.ignoresSafeArea())
    }
}

// MARK: - 按鈕

/// 膠囊按鈕：主要（黑底白字）、次要（淺灰底）。
struct PillButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    var kind: Kind = .primary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(compact ? .subheadline : .body).weight(.semibold))
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical, compact ? 8 : 11)
            .foregroundStyle(kind == .primary ? DS.onPrimary : DS.text)
            .background(kind == .primary ? DS.primary : DS.control, in: Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// 方形圖示按鈕（淺色區塊上）。
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(isActive ? DS.text : DS.textSecondary)
            .frame(width: size, height: size)
            .background(
                isActive || configuration.isPressed ? DS.control : Color.clear,
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}

/// 黑色頂部列與功能列上的圖示按鈕。`highlighted`：功能列中目前的面板（白底黑字）。
struct InkIconButtonStyle: ButtonStyle {
    var size: CGFloat = 36
    var isActive = false
    var highlighted = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.5, weight: .regular))
            .foregroundStyle(highlighted ? DS.ink : (isActive ? DS.onInk : DS.onInkDim))
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(highlighted ? Color.white : (isActive || configuration.isPressed ? DS.inkRaised : Color.clear))
            }
            .contentShape(Rectangle())
    }
}

// MARK: - 元件

/// 小標題列：標題＋右側的灰色說明。
struct SectionHeader: View {
    let title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
                .foregroundStyle(DS.text)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// 膠囊標籤：粉彩底，或只有框線。
struct Chip: View {
    let text: String
    var pastel: DS.Pastel?

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(pastel == nil ? DS.textSecondary : DS.text)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                if let pastel {
                    Capsule().fill(pastel.color)
                } else {
                    Capsule().strokeBorder(DS.cardBorder, lineWidth: 1)
                }
            }
    }
}

/// 圓形底的圖示（卡片右上角）。
struct CircleIcon: View {
    let systemImage: String
    var fill: Color = DS.card
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .regular))
            .foregroundStyle(DS.text)
            .frame(width: size, height: size)
            .background(fill, in: Circle())
    }
}

/// 空狀態：標題與說明，沒有插圖。
struct EmptyStateView: View {
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(DS.text)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(DS.textSecondary)
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

/// 底部的黑色浮動工具列：粉彩圓鈕（參考圖的工具列）。
struct FloatingPalette<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 6) {
            content()
        }
        .padding(6)
        .background(DS.ink, in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 15, y: 8)
    }
}

/// 浮動工具列中的一個圓鈕：粉彩底、黑色圖示或文字。
struct PaletteButton: View {
    let title: String
    var systemImage: String?
    var glyph: String?
    var pastel: DS.Pastel?
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let glyph {
                    Text(glyph).font(.system(size: size * 0.4, weight: .bold))
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: size * 0.42, weight: .medium))
                }
            }
            .foregroundStyle(pastel == nil ? Color.white : Color(hex: 0x16161A))
            .frame(width: size, height: size)
            .background(pastel?.color ?? DS.inkRaised, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}

// MARK: - 掃描等工具畫面使用的元件

enum Theme {
    static let cornerRadius: CGFloat = DS.radius
    static let cardPadding: CGFloat = 16
    static let screenBackground = DS.sidebar
    static let cardBackground = DS.card
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
                .font(.subheadline)
                .foregroundStyle(DS.textSecondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.text)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.textTertiary)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(DS.textSecondary)
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
                .font(.system(size: 30, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(DS.text)
            if let unit {
                Text(unit)
                    .font(.subheadline)
                    .foregroundStyle(DS.textSecondary)
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
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(DS.text)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
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
                    .foregroundStyle(DS.textSecondary)
                    .frame(width: 24)
            }
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(DS.text)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.textTertiary)
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
            CircleIcon(systemImage: systemImage, fill: DS.Pastel.sky.color, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(DS.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 弧形量表，用來顯示信心度（0~1）。
struct ConfidenceGauge: View {
    let value: Double
    var size: CGFloat = 64

    private var clamped: Double { min(max(value, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.1, to: 0.9)
                .stroke(DS.controlTrack, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: 0.1, to: 0.1 + 0.8 * clamped)
                .stroke(DS.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(90))
            VStack(spacing: 0) {
                Text("\(Int((clamped * 100).rounded()))")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(DS.text)
                Text("%")
                    .font(.caption2)
                    .foregroundStyle(DS.textSecondary)
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
                .foregroundStyle(DS.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.sidebar, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
    }
}

// MARK: - 頁面共用元件（知識庫、待辦、圖面、產能清單、搜尋共用，讓各頁一致）

/// 頁面標題：大標題、灰色的摘要，右側放這一頁的動作。
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.horizontalSizeClass) private var sizeClass

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: sizeClass == .compact ? 24 : 28, weight: .semibold))
                .foregroundStyle(DS.text)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .accessibilityElement(children: .contain)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// 搜尋欄：白底細框，聚焦時框線變深，有清除鈕。
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 36
    var autofocus = false

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(DS.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(DS.text)
                .focused($focused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous).strokeBorder(focused ? DS.textSecondary : DS.cardBorder, lineWidth: 1))
        .onAppear { if autofocus { focused = true } }
    }
}

/// 篩選膠囊：選單的標籤或開關，選中時黑底白字（同主要膠囊按鈕）。
struct FilterChip: View {
    let title: String
    var isActive = false
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(title)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(isActive ? DS.onPrimary : DS.text)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(isActive ? DS.primary : DS.control, in: Capsule(style: .continuous))
        .contentShape(Capsule())
    }
}

/// 開關膠囊。
struct ToggleChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            FilterChip(title: title, isActive: isOn, systemImage: isOn ? "checkmark" : nil)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// 分段切換：淺灰底，選中的那段黑底白字。
struct SegmentedPills<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(isSelected ? DS.onPrimary : DS.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isSelected ? DS.primary : Color.clear, in: Capsule(style: .continuous))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(DS.control, in: Capsule(style: .continuous))
    }
}

/// 粉彩數字卡：小標題、大數字、可選的說明。
struct MetricTile: View {
    let title: String
    let value: String
    var detail: String?
    var pastel: DS.Pastel = .sky
    var valueColor: Color = DS.text

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(DS.onPastelSecondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 19, weight: .bold).monospacedDigit())
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(DS.onPastelSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pastelCard(pastel, padding: 12)
    }
}

/// 一列「標籤 … 值」（規格、狀態等資訊卡片中）。
struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = DS.text
    var emphasized = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(DS.textSecondary)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "-" : value)
                .font(.subheadline.weight(emphasized ? .semibold : .regular))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// 圓形圖示按鈕（淺灰底），頁面標題列上的次要動作。
struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(DS.text)
            .frame(width: size, height: size)
            .background(DS.control, in: Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Circle())
    }
}

/// 頁面上方的工具列，最多兩列，避免壓縮內容的空間：
/// 第一列是標題、摘要與右側的圖示按鈕（含搜尋鈕）；第二列是一排可以橫向捲動的膠囊。
/// 搜尋平常收起來，按放大鏡才展開（暫時取代第二列），按「取消」清空並收起。
struct PageToolbar<Actions: View, Chips: View>: View {
    let title: String
    var subtitle: String?
    @Binding var query: String
    var searchPlaceholder = "搜尋"
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var chips: () -> Chips

    @State private var isSearching = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(
        _ title: String,
        subtitle: String? = nil,
        query: Binding<String>,
        searchPlaceholder: String = "搜尋",
        @ViewBuilder actions: @escaping () -> Actions,
        @ViewBuilder chips: @escaping () -> Chips
    ) {
        self.title = title
        self.subtitle = subtitle
        _query = query
        self.searchPlaceholder = searchPlaceholder
        self.actions = actions
        self.chips = chips
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title, subtitle: subtitle) {
                HStack(spacing: 8) {
                    actions()
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { isSearching.toggle() }
                        if !isSearching { query = "" }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .symbolVariant(query.isEmpty ? .none : .circle.fill)
                    }
                    .buttonStyle(CircleIconButtonStyle())
                    .accessibilityLabel(isSearching ? "收起搜尋" : "搜尋")
                }
            }
            if isSearching || !query.isEmpty {
                HStack(spacing: 10) {
                    SearchField(placeholder: searchPlaceholder, text: $query, height: 34, autofocus: true)
                    Button("取消") {
                        query = ""
                        withAnimation(.easeOut(duration: 0.2)) { isSearching = false }
                    }
                    .font(.subheadline)
                    .foregroundStyle(DS.text)
                }
                .transition(.opacity)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        chips()
                    }
                }
                .scrollIndicators(.hidden)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, sizeClass == .compact ? 16 : 24)
        .padding(.top, sizeClass == .compact ? 14 : 18)
        .padding(.bottom, 10)
    }
}
