import UIKit
import XCTest
@testable import LocalOCR

/// 實際呼叫 Vision 辨識程式繪製的文字，確認裝置端 OCR 與座標換算正確。
final class OCRServiceTests: XCTestCase {
    func testRecognizesEnglishText() async throws {
        let page = try await recognize("Hello OCR 2026", languages: ["en-US"])
        XCTAssertTrue(page.text.contains("Hello"), "辨識結果：\(page.text)")
        XCTAssertTrue(page.text.contains("2026"), "辨識結果：\(page.text)")
    }

    func testRecognizesTraditionalChinese() async throws {
        let page = try await recognize("繁體中文辨識", languages: ["zh-Hant", "en-US"])
        XCTAssertTrue(page.text.contains("中文"), "辨識結果：\(page.text)")
    }

    func testBoundingBoxUsesTopLeftOrigin() async throws {
        // 文字畫在高圖片的上方，正確換算後 midY 應小於 0.5
        let image = render("TOP TEXT", canvas: CGSize(width: 1000, height: 1600), origin: CGPoint(x: 60, y: 80))
        let page = try await OCRService(options: options(languages: ["en-US"])).recognize(image)
        let box = try XCTUnwrap(page.lines.first?.boundingBox, "辨識結果：\(page.text)")
        XCTAssertLessThan(box.midY, 0.5)
        XCTAssertGreaterThanOrEqual(box.minX, -0.01)
        XCTAssertLessThanOrEqual(box.maxX, 1.01)
    }

    func testBlankImageProducesNoLines() async throws {
        let image = render("", canvas: CGSize(width: 400, height: 400), origin: .zero)
        let page = try await OCRService(options: options(languages: ["en-US"])).recognize(image)
        XCTAssertTrue(page.lines.isEmpty)
    }

    func testAccurateModeSupportsTraditionalChinese() {
        XCTAssertTrue(OCRService.supportedLanguages(for: .accurate).contains("zh-Hant"))
    }

    func testRequestOnlyUsesLanguagesSupportedByLevel() {
        let request = OCRService.makeRequest(options: OCROptions(recognitionLevel: .fast, languages: ["zh-Hant", "en-US"]))
        let supported = Set(OCRService.supportedLanguages(for: .fast))
        XCTAssertTrue(Set(request.recognitionLanguages).isSubset(of: supported))
    }

    // MARK: - Helpers

    private func options(languages: [String]) -> OCROptions {
        OCROptions(recognitionLevel: .accurate, languages: languages, usesLanguageCorrection: true, automaticallyDetectsLanguage: false)
    }

    private func recognize(_ text: String, languages: [String]) async throws -> OCRPage {
        let image = render(text, canvas: CGSize(width: 1400, height: 400), origin: CGPoint(x: 60, y: 120))
        return try await OCRService(options: options(languages: languages)).recognize(image)
    }

    private func render(_ text: String, canvas: CGSize, origin: CGPoint) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: canvas))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 110, weight: .semibold),
                .foregroundColor: UIColor.black,
            ]
            (text as NSString).draw(at: origin, withAttributes: attributes)
        }
    }
}
