import CoreML
import Foundation
import UIKit
import Vision

enum OCRError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "無法讀取這張圖片。"
        }
    }
}

/// 使用 Apple Vision 框架（VNRecognizeTextRequest）在裝置上辨識文字，完全不需要網路。
struct OCRService {
    var options: OCROptions

    init(options: OCROptions = OCRSettings.currentOptions()) {
        self.options = options
    }

    /// 辨識單張圖片。以高解析度圖片辨識，回傳較小的顯示用圖片；座標為正規化座標，兩者通用。
    func recognize(_ image: UIImage) async throws -> OCRPage {
        let prepared = ImagePreprocessor.normalized(image)
        guard let cgImage = prepared.cgImage else { throw OCRError.invalidImage }
        let lines = try await recognizeText(in: cgImage)
        return OCRPage(image: ImagePreprocessor.displayImage(prepared), lines: lines)
    }

    func recognizeText(in cgImage: CGImage) async throws -> [RecognizedLine] {
        let options = self.options
        // Vision 是同步 API，放到背景佇列避免卡住主執行緒
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let lines = try Self.performRecognition(on: cgImage, options: options)
                    continuation.resume(returning: lines)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func performRecognition(on cgImage: CGImage, options: OCROptions) throws -> [RecognizedLine] {
        let request = makeRequest(options: options)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedLine(
                text: text,
                confidence: candidate.confidence,
                boundingBox: TextLayout.topLeftNormalizedRect(fromVision: observation.boundingBox)
            )
        }
    }

    static func makeRequest(options: OCROptions) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.recognitionLevel.visionLevel
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.automaticallyDetectsLanguage = options.automaticallyDetectsLanguage

        // 快速模式只支援拉丁字母語言，先過濾掉目前模式不支援的語言，避免請求失敗
        let supported = Set(supportedLanguages(for: options.recognitionLevel))
        let languages = options.languages.filter { supported.contains($0) }
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }

        #if targetEnvironment(simulator)
        // 模擬器沒有 Neural Engine，指定 CPU 以免出現推論環境建立失敗
        let cpu = MLComputeDevice.allComputeDevices.first { device in
            if case .cpu = device { return true }
            return false
        }
        if let cpu {
            request.setComputeDevice(cpu, for: .main)
        }
        #endif

        return request
    }

    static func supportedLanguages(for level: RecognitionLevel) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level.visionLevel
        return (try? request.supportedRecognitionLanguages()) ?? []
    }
}

extension RecognitionLevel {
    var visionLevel: VNRequestTextRecognitionLevel {
        switch self {
        case .accurate: return .accurate
        case .fast: return .fast
        }
    }
}
