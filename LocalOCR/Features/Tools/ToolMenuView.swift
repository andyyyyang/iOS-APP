import SwiftUI

enum AppTab: Hashable {
    case scan
    case live
    case history
    case settings
}

/// 小工具選單：以弧形滾輪列出所有功能。
struct ToolMenuView: View {
    enum Tool: String, CaseIterable {
        case photos
        case camera
        case document
        case paste
        case live
        case history
        case templates
        case server
        case settings

        var title: String {
            switch self {
            case .photos: return "相簿"
            case .camera: return "拍照"
            case .document: return "掃描文件"
            case .paste: return "貼上圖片"
            case .live: return "即時掃描"
            case .history: return "紀錄"
            case .templates: return "情境樣板"
            case .server: return "伺服器同步"
            case .settings: return "設定"
            }
        }

        var systemImage: String {
            switch self {
            case .photos: return "photo.on.rectangle"
            case .camera: return "camera"
            case .document: return "doc.viewfinder"
            case .paste: return "doc.on.clipboard"
            case .live: return "camera.viewfinder"
            case .history: return "clock.arrow.circlepath"
            case .templates: return "square.stack.3d.up"
            case .server: return "icloud.and.arrow.up"
            case .settings: return "gearshape"
            }
        }

        var color: Color {
            switch self {
            case .photos: return .green
            case .camera: return .blue
            case .document: return .orange
            case .paste: return .red
            case .live: return .pink
            case .history: return .cyan
            case .templates: return .yellow
            case .server: return .indigo
            case .settings: return .teal
            }
        }

        var isAvailable: Bool {
            switch self {
            case .camera: return CameraPicker.isAvailable
            case .document: return DocumentScannerView.isSupported
            default: return true
            }
        }
    }

    var onSelect: (Tool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: String? = Tool.photos.rawValue
    @State private var deniedTrigger = 0

    private var items: [ArcWheelItem] {
        Tool.allCases.map { tool in
            ArcWheelItem(id: tool.rawValue, title: tool.title, systemImage: tool.systemImage, color: tool.color, isEnabled: tool.isAvailable)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ArcWheelMenu(items: items, selection: $selection) { item in
                guard let tool = Tool(rawValue: item.id) else { return }
                if tool.isAvailable {
                    onSelect(tool)
                } else {
                    deniedTrigger += 1
                }
            }
            .ignoresSafeArea(edges: .vertical)

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(Theme.cardBackground, in: Circle())
                }
                .accessibilityLabel("關閉")
                .padding(.bottom, 12)
                Text("工具")
                    .font(.largeTitle.bold())
                Text("上下滑動選擇，點一下開啟")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .screenBackground()
        .sensoryFeedback(.error, trigger: deniedTrigger)
    }
}

#Preview {
    ToolMenuView { _ in }
}
