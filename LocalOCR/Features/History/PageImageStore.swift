import SwiftUI
import UIKit

/// 紀錄的頁面照片：存成檔案（Application Support/ScanPages/<id>/000.jpg…），不放進資料庫，紀錄列表才不會變慢。
enum PageImageStore {
    private static var root: URL {
        URL.applicationSupportDirectory.appending(path: "ScanPages", directoryHint: .isDirectory)
    }

    static func folder(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// 依序存入頁面，檔名從 `startIndex` 開始編號；回傳實際存入的頁數。
    @discardableResult
    static func save(_ images: [UIImage], for id: UUID, startingAt startIndex: Int) -> Int {
        let folder = folder(for: id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved = 0
        for (offset, image) in images.enumerated() {
            guard let data = image.jpegData(compressionQuality: 0.8) else { continue }
            let url = folder.appending(path: String(format: "%03d.jpg", startIndex + offset))
            if (try? data.write(to: url, options: .atomic)) != nil {
                saved += 1
            }
        }
        return saved
    }

    /// 依頁碼排序的照片檔。
    static func pageURLs(for id: UUID?) -> [URL] {
        guard let id else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder(for: id), includingPropertiesForKeys: nil)) ?? []
        return urls
            .compactMap { url in pageNumber(of: url).map { (number: $0, url: url) } }
            .sorted { $0.number < $1.number }
            .map(\.url)
    }

    private static func pageNumber(of url: URL) -> Int? {
        guard url.pathExtension == "jpg" else { return nil }
        return Int(url.deletingPathExtension().lastPathComponent)
    }

    /// 已分配給新頁面（可能還在背景寫入）的下一個頁碼。
    @MainActor private static var nextNumber: [UUID: Int] = [:]

    /// 為新頁面保留連續的頁碼：接在已存檔與寫入中的頁面之後，不會覆寫或插到前面。
    @MainActor
    static func reserve(_ count: Int, for id: UUID) -> Int {
        let onDisk = pageURLs(for: id).compactMap(pageNumber).max().map { $0 + 1 } ?? 0
        let start = max(onDisk, nextNumber[id] ?? 0)
        nextNumber[id] = start + count
        return start
    }

    static func remove(for id: UUID?) {
        guard let id else { return }
        try? FileManager.default.removeItem(at: folder(for: id))
    }
}

extension ScanRecord {
    /// 存入新頁面的照片（接在已存的頁面之後），在背景寫檔；需要等寫完時 await 回傳的工作。
    @MainActor
    @discardableResult
    func storePageImages(_ images: [UIImage]) -> Task<Void, Never> {
        guard !images.isEmpty else { return Task {} }
        let id = pagesID ?? UUID()
        pagesID = id
        let start = PageImageStore.reserve(images.count, for: id)
        return Task.detached(priority: .utility) {
            _ = PageImageStore.save(images, for: id, startingAt: start)
        }
    }

    var pageImageURLs: [URL] { PageImageStore.pageURLs(for: pagesID) }
}

/// 從檔案載入的縮圖。
struct PageThumbnailView: View {
    let url: URL
    var size = CGSize(width: 72, height: 96)

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: url) {
            let target = CGSize(width: size.width * 3, height: size.height * 3)
            image = await UIImage(contentsOfFile: url.path(percentEncoded: false))?.byPreparingThumbnail(ofSize: target)
        }
    }
}

/// 全螢幕看照片：左右滑動換頁，雙指或點兩下放大，可分享目前這一頁。
struct PageImageViewer: View {
    let urls: [URL]
    @State var selection: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    PageImagePage(url: url)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .always : .never))
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(urls.count > 1 ? "第 \(selection + 1)／\(urls.count) 頁" : "照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if urls.indices.contains(selection) {
                        ShareLink(item: urls[selection])
                    }
                }
            }
        }
    }
}

private struct PageImagePage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableImageView(image: image)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            image = await Task.detached(priority: .userInitiated) { [url] in
                UIImage(contentsOfFile: url.path(percentEncoded: false))
            }.value
        }
    }
}

/// 可縮放的圖片（UIScrollView）：雙指縮放、點兩下放大／還原。
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
                let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
                scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
            }
        }
    }
}
