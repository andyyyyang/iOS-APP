import Observation
import SwiftUI

/// 正在收集中的文件：可從不同來源一頁一頁加入，確認後才一起分析。
/// 「掃描」與「相機」分頁共用同一份，一份文件的頁數不受單次拍照限制。
@MainActor
@Observable
final class ScanDraft {
    struct Page: Identifiable {
        let id = UUID()
        /// 以 JPEG 保存，分析時才逐頁解碼，避免多頁佔用大量記憶體。
        let imageData: Data
        let thumbnail: UIImage
        let source: ScanSource
    }

    private(set) var pages: [Page] = []
    /// 正在處理新加入的頁面（壓縮與縮圖在背景執行）。
    private(set) var pendingCount = 0

    var isEmpty: Bool { pages.isEmpty && pendingCount == 0 }

    /// 紀錄使用的來源：以第一頁的來源為主。
    var primarySource: ScanSource { pages.first?.source ?? .photoLibrary }

    /// 加入頁面；轉正、壓縮與縮圖在背景進行，大量頁面也不會卡住畫面。
    func add(_ images: [UIImage], source: ScanSource) async {
        pendingCount += images.count
        defer { pendingCount -= images.count }
        let prepared = await Task.detached(priority: .userInitiated) {
            images.compactMap { image -> Page? in
                let normalized = ImagePreprocessor.normalized(image, maxPixelLength: 4096)
                guard let data = normalized.jpegData(compressionQuality: 0.85) else { return nil }
                let thumbnail = ImagePreprocessor.normalized(normalized, maxPixelLength: 240)
                return Page(imageData: data, thumbnail: thumbnail, source: source)
            }
        }.value
        pages.append(contentsOf: prepared)
    }

    func remove(_ id: Page.ID) {
        pages.removeAll { $0.id == id }
    }

    func move(_ id: Page.ID, by offset: Int) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard pages.indices.contains(target) else { return }
        pages.swapAt(index, target)
    }

    func clear() {
        pages.removeAll()
    }
}

/// 收集中文件的頁面列：縮圖、頁碼、刪除與排序，以及「開始分析」。
struct DraftTray: View {
    let draft: ScanDraft
    var isProcessing: Bool
    var onAnalyze: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(
                title: "這份文件",
                systemImage: "doc.on.doc",
                trailing: draft.pendingCount > 0 ? "處理中…" : "\(draft.pages.count) 頁"
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(draft.pages.enumerated()), id: \.element.id) { index, page in
                        DraftPageThumbnail(draft: draft, page: page, number: index + 1)
                    }
                }
                .padding(.vertical, 2)
            }

            Text("可以繼續拍照或從其他來源加入頁面；全部頁面（例如發票＋報單）加入後再開始分析。長按縮圖可調整順序。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    draft.clear()
                } label: {
                    Label("清除", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Button(action: onAnalyze) {
                    Label("開始分析（\(draft.pages.count) 頁）", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(isProcessing || draft.pendingCount > 0 || draft.pages.isEmpty)
        }
        .card()
    }
}

/// 收集中文件的一頁縮圖：頁碼、刪除，長按可調整順序。
struct DraftPageThumbnail: View {
    let draft: ScanDraft
    let page: ScanDraft.Page
    let number: Int
    var width: CGFloat = 64

    var body: some View {
        Image(uiImage: page.thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: width, height: width * 4 / 3)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Text("\(number)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    draft.remove(page.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .font(.body)
                }
                .padding(2)
                .accessibilityLabel("刪除第 \(number) 頁")
            }
            .contextMenu {
                Button("往前移", systemImage: "arrow.left") { draft.move(page.id, by: -1) }
                Button("往後移", systemImage: "arrow.right") { draft.move(page.id, by: 1) }
                Button("刪除", systemImage: "trash", role: .destructive) { draft.remove(page.id) }
            }
    }
}
