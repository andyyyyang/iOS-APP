import SwiftUI

/// 顯示圖片並以框線標示每個辨識到的文字區塊，點選框線可複製該段文字。
struct AnnotatedImageView: View {
    let page: OCRPage
    var showsBoxes = true
    var onTapLine: (RecognizedLine) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            let frame = TextLayout.aspectFitRect(imageSize: page.image.size, in: proxy.size)

            ZStack(alignment: .topLeading) {
                Image(uiImage: page.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)

                if showsBoxes {
                    ForEach(page.lines) { line in
                        let rect = TextLayout.denormalize(line.boundingBox, into: frame)
                        let color = ConfidenceBadge.color(for: line.confidence)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(color.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1.5))
                            .frame(width: max(rect.width, 4), height: max(rect.height, 4))
                            .contentShape(Rectangle())
                            .onTapGesture { onTapLine(line) }
                            .position(x: rect.midX, y: rect.midY)
                            .accessibilityLabel(line.text)
                    }
                }
            }
        }
    }
}
