import XCTest
@testable import LocalOCR

final class OCRSettingsTests: XCTestCase {
    private let suiteName = "LocalOCRTests.OCRSettings"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testLanguagesRoundTrip() {
        let languages = ["zh-Hant", "ja-JP", "en-US"]
        XCTAssertEqual(OCRSettings.decode(OCRSettings.encode(languages)), languages)
    }

    func testDecodeIgnoresEmptyEntries() {
        XCTAssertEqual(OCRSettings.decode(""), [])
        XCTAssertEqual(OCRSettings.decode("en-US,,zh-Hant,"), ["en-US", "zh-Hant"])
    }

    func testCurrentOptionsUsesRegisteredDefaults() {
        OCRSettings.registerDefaults(in: defaults)
        let options = OCRSettings.currentOptions(from: defaults)
        XCTAssertEqual(options, OCROptions())
    }

    func testCurrentOptionsReflectsStoredValues() {
        OCRSettings.registerDefaults(in: defaults)
        defaults.set(RecognitionLevel.fast.rawValue, forKey: OCRSettings.Key.recognitionLevel)
        defaults.set("en-US", forKey: OCRSettings.Key.languages)
        defaults.set(false, forKey: OCRSettings.Key.usesLanguageCorrection)
        defaults.set(true, forKey: OCRSettings.Key.automaticallyDetectsLanguage)

        let options = OCRSettings.currentOptions(from: defaults)
        XCTAssertEqual(options.recognitionLevel, .fast)
        XCTAssertEqual(options.languages, ["en-US"])
        XCTAssertFalse(options.usesLanguageCorrection)
        XCTAssertTrue(options.automaticallyDetectsLanguage)
    }
}
