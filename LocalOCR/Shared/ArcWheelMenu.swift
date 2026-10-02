import SwiftUI

struct ArcWheelItem: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let color: Color
    var isEnabled = true
}

/// 沿著右側弧線排列的滾輪選單：中間的項目為選取狀態，越往上下越淡、越傾斜。
/// 滑動選擇，點一下置中的項目即可開啟；點其他項目會先捲到中間。
struct ArcWheelMenu: View {
    let items: [ArcWheelItem]
    @Binding var selection: String?
    var radius: CGFloat = 560
    var rowHeight: CGFloat = 104
    var onActivate: (ArcWheelItem) -> Void

    /// 弧線與把手需要的右側空間。
    private let trailingSpace: CGFloat = 96

    var body: some View {
        GeometryReader { proxy in
            let radius = self.radius
            ZStack {
                arc(in: proxy.size)

                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            row(for: item)
                                .frame(height: rowHeight)
                                .id(item.id)
                                .visualEffect { content, geometry in
                                    let frame = geometry.frame(in: .scrollView)
                                    let viewport = geometry.bounds(of: .scrollView)?.height ?? frame.height
                                    let dy = frame.midY - viewport / 2
                                    let limit = radius * 0.95
                                    let clamped = min(max(dy, -limit), limit)
                                    let shift = radius - (radius * radius - clamped * clamped).squareRoot()
                                    let distance = min(abs(dy) / max(viewport / 2, 1), 1)
                                    return content
                                        .offset(x: shift)
                                        .rotationEffect(.radians(-asin(clamped / radius)), anchor: .trailing)
                                        .scaleEffect(1 - distance * 0.12, anchor: .trailing)
                                        .opacity(1 - distance * 0.8)
                                        .blur(radius: max(0, distance - 0.65) * 8)
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $selection, anchor: .center)
                .safeAreaPadding(.vertical, max(0, (proxy.size.height - rowHeight) / 2))

                Capsule()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: 46, height: 16)
                    .position(x: proxy.size.width - trailingSpace + 52, y: proxy.size.height / 2)
                    .allowsHitTesting(false)
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func arc(in size: CGSize) -> some View {
        let arcRadius = radius * 0.92
        return Circle()
            .stroke(Color.secondary.opacity(0.25), lineWidth: 1.5)
            .frame(width: arcRadius * 2, height: arcRadius * 2)
            .position(x: size.width - trailingSpace + 26 + arcRadius, y: size.height / 2)
            .allowsHitTesting(false)
    }

    private func row(for item: ArcWheelItem) -> some View {
        let isSelected = item.id == selection
        return HStack(spacing: 18) {
            Spacer(minLength: 0)
            Text(item.title)
                .font(.title3.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, isSelected ? 14 : 0)
                .padding(.vertical, isSelected ? 8 : 0)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Theme.cardBackground)
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                    }
                }
            Image(systemName: item.systemImage)
                .font(.title2.weight(.medium))
                .foregroundStyle(item.color)
                .frame(width: 78, height: 64)
                .background {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(isSelected ? item.color.opacity(0.1) : Color(.tertiarySystemFill))
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .stroke(item.color, lineWidth: 2)
                    }
                }
        }
        .padding(.trailing, trailingSpace)
        .opacity(item.isEnabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                onActivate(item)
            } else {
                withAnimation(.snappy) { selection = item.id }
            }
        }
        .animation(.snappy, value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    struct Demo: View {
        @State private var selection: String? = "camera"
        let items = [
            ArcWheelItem(id: "photos", title: "相簿", systemImage: "photo.on.rectangle", color: .green),
            ArcWheelItem(id: "camera", title: "拍照", systemImage: "camera", color: .blue),
            ArcWheelItem(id: "document", title: "掃描文件", systemImage: "doc.viewfinder", color: .orange),
            ArcWheelItem(id: "paste", title: "貼上圖片", systemImage: "doc.on.clipboard", color: .red),
            ArcWheelItem(id: "live", title: "即時掃描", systemImage: "camera.viewfinder", color: .pink),
        ]

        var body: some View {
            ArcWheelMenu(items: items, selection: $selection) { _ in }
                .screenBackground()
        }
    }
    return Demo()
}
