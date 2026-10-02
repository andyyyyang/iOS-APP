import SwiftUI

/// 「拍照」來源的全螢幕相機：可以連續拍多頁，按「完成」一次加入。
struct MultiShotCameraView: View {
    var onFinish: ([UIImage]) -> Void

    private struct Shot: Identifiable {
        let id = UUID()
        let image: UIImage
        let thumbnail: UIImage?
    }

    @State private var camera = CameraController()
    @State private var shots: [Shot] = []
    @State private var isCapturing = false
    @State private var shutterTrigger = 0
    @State private var showsFlash = false
    @State private var message: String?

    var body: some View {
        CameraAccessView {
            ZStack {
                CameraPreview(camera: camera)
                    .ignoresSafeArea()
                if showsFlash {
                    Color.white
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                VStack(spacing: 12) {
                    topBar
                    Spacer()
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                    }
                    thumbnails
                    ShutterButton(isBusy: isCapturing) {
                        Task { await capture() }
                    }
                    .padding(.bottom, 8)
                }
                .padding()
            }
            .onAppear { camera.start() }
            .onDisappear { camera.stop() }
        }
        .background(Color.black.ignoresSafeArea())
        .sensoryFeedback(.impact, trigger: shutterTrigger)
    }

    private var topBar: some View {
        HStack {
            Button("取消") { onFinish([]) }
                .buttonStyle(.bordered)
            Spacer()
            Button {
                onFinish(shots.map(\.image))
            } label: {
                Text(shots.isEmpty ? "完成" : "完成（\(shots.count) 頁）")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(shots.isEmpty || isCapturing)
        }
        .tint(.white)
        .foregroundStyle(.black)
    }

    @ViewBuilder
    private var thumbnails: some View {
        if !shots.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                            thumbnail(shot, number: index + 1)
                                .id(shot.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: shots.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .trailing) }
                }
            }
        }
    }

    private func thumbnail(_ shot: Shot, number: Int) -> some View {
        Group {
            if let image = shot.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray
            }
        }
        .frame(width: 48, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(3)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                shots.removeAll { $0.id == shot.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .padding(2)
            .accessibilityLabel("刪除第 \(number) 頁")
        }
    }

    @MainActor
    private func capture() async {
        isCapturing = true
        defer { isCapturing = false }
        do {
            let image = try await camera.capturePhoto()
            shutterTrigger += 1
            flash()
            let thumbnail = await image.byPreparingThumbnail(ofSize: CGSize(width: 96, height: 128))
            shots.append(Shot(image: image, thumbnail: thumbnail))
            message = "已拍 \(shots.count) 頁，可以繼續拍下一頁"
        } catch {
            message = error.localizedDescription
        }
    }

    private func flash() {
        showsFlash = true
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeOut(duration: 0.25)) { showsFlash = false }
        }
    }
}
