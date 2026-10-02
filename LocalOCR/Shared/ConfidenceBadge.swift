import SwiftUI

struct ConfidenceBadge: View {
    let confidence: Float

    var body: some View {
        Text("\(Int((confidence * 100).rounded()))%")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Self.color(for: confidence))
            .background(Self.color(for: confidence).opacity(0.15), in: Capsule())
    }

    static func color(for confidence: Float) -> Color {
        switch confidence {
        case 0.8...: return .green
        case 0.5..<0.8: return .orange
        default: return .red
        }
    }
}
