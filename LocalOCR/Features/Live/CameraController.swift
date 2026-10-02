import AVFoundation
import SwiftUI
import UIKit

/// 連續拍照用的相機（AVFoundation）：預覽＋高解析度拍照，可以一直拍。
/// session 操作與拍照回呼都在同一個序列佇列上，每次拍照保證只回傳一次，逾時也會回傳錯誤，畫面不會卡住。
final class CameraController: NSObject, @unchecked Sendable {
    enum CameraError: LocalizedError {
        case unavailable
        case timedOut
        case noImage
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "相機尚未就緒，請稍候再試。"
            case .timedOut: return "拍照逾時，請再按一次快門。"
            case .noImage: return "沒有取得照片，請再試一次。"
            case .failed(let message): return message
            }
        }
    }

    static var isAvailable: Bool { backCamera != nil }

    private static var backCamera: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "LocalOCR.camera")
    private let device = CameraController.backCamera
    // 以下只在 queue 上存取
    private var isConfigured = false
    private var pending: [Int64: CheckedContinuation<Data, Error>] = [:]
    // 以下只在主執行緒存取
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    func start() {
        queue.async { [self] in
            if !isConfigured { configure() }
            if isConfigured, !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// 預覽畫面建立後呼叫：預覽與照片方向跟著手機方向。
    @MainActor
    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = session
        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotation = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.applyPreviewRotation() }
        }
        applyPreviewRotation()
    }

    @MainActor
    func applyPreviewRotation() {
        guard let rotation, let connection = previewLayer?.connection else { return }
        let angle = rotation.videoRotationAngleForHorizonLevelPreview
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    /// 拍一張照片。
    @MainActor
    func capturePhoto() async throws -> UIImage {
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard session.isRunning, let connection = output.connection(with: .video) else {
                    continuation.resume(throwing: CameraError.unavailable)
                    return
                }
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                let settings = output.availablePhotoCodecTypes.contains(.jpeg)
                    ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                    : AVCapturePhotoSettings()
                settings.maxPhotoDimensions = output.maxPhotoDimensions
                settings.photoQualityPrioritization = .balanced
                let id = settings.uniqueID
                pending[id] = continuation
                output.capturePhoto(with: settings, delegate: self)
                // 保險：相機沒有回呼時也要讓畫面恢復
                queue.asyncAfter(deadline: .now() + 10) { [self] in
                    pending.removeValue(forKey: id)?.resume(throwing: CameraError.timedOut)
                }
            }
        }
        guard let image = UIImage(data: data) else { throw CameraError.noImage }
        return image
    }

    private func configure() {
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .balanced
        // 文件用 1200 萬像素就很清楚；48MP 太大、拍得慢又佔記憶體
        let area: (CMVideoDimensions) -> Int = { Int($0.width) * Int($0.height) }
        let sizes = device.activeFormat.supportedMaxPhotoDimensions
        if let size = sizes.filter({ area($0) <= 12_600_000 }).max(by: { area($0) < area($1) }) ?? sizes.min(by: { area($0) < area($1) }) {
            output.maxPhotoDimensions = size
        }
        session.commitConfiguration()

        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            device.unlockForConfiguration()
        }
        isConfigured = true
        Task { @MainActor in self.applyPreviewRotation() }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let failure = error.map { CameraError.failed($0.localizedDescription) } ?? .noImage
        queue.async { [self] in
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let data {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: failure)
            }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        // 正常情況下照片已在上面回傳；這裡處理沒有產生照片的失敗
        let id = resolvedSettings.uniqueID
        let failure = error.map { CameraError.failed($0.localizedDescription) } ?? .noImage
        queue.async { [self] in
            pending.removeValue(forKey: id)?.resume(throwing: failure)
        }
    }
}

/// 相機預覽。
struct CameraPreview: UIViewRepresentable {
    let camera: CameraController

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attach(view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}

/// 快門按鈕。
struct ShutterButton: View {
    var isBusy: Bool
    var ringColor: Color = .white
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(ringColor.opacity(0.9), lineWidth: 4)
                    .frame(width: 74, height: 74)
                Circle()
                    .fill(Color.white)
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.15), radius: 2)
                if isBusy {
                    ProgressView()
                        .tint(.black)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("拍照")
    }
}

/// 處理相機權限：已允許時顯示內容，否則請求權限或引導到「設定」。
struct CameraAccessView<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            if !CameraController.isAvailable {
                ContentUnavailableView(
                    "此裝置沒有可用的相機",
                    systemImage: "camera",
                    description: Text("模擬器無法使用相機。你仍可在「掃描」分頁從相簿加入頁面。")
                )
            } else {
                switch status {
                case .authorized:
                    content()
                case .notDetermined:
                    ProgressView("正在請求相機權限…")
                        .task {
                            _ = await AVCaptureDevice.requestAccess(for: .video)
                            status = AVCaptureDevice.authorizationStatus(for: .video)
                        }
                default:
                    ContentUnavailableView {
                        Label("需要相機權限", systemImage: "camera")
                    } description: {
                        Text("請到「設定」允許本 App 使用相機。照片與辨識全程在裝置上處理。")
                    } actions: {
                        Button("前往設定") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .onAppear { status = AVCaptureDevice.authorizationStatus(for: .video) }
    }
}
