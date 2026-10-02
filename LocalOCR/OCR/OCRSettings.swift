import Foundation

enum RecognitionLevel: String, CaseIterable, Identifiable {
    case accurate
    case fast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accurate: return "精確"
        case .fast: return "快速"
        }
    }
}

struct OCROptions: Equatable {
    var recognitionLevel: RecognitionLevel = .accurate
    var languages: [String] = OCRSettings.defaultLanguages
    var usesLanguageCorrection = true
    var automaticallyDetectsLanguage = false
}

/// 使用者設定，存在 UserDefaults（介面端透過 @AppStorage 讀寫同一組 key）。
enum OCRSettings {
    enum Key {
        static let recognitionLevel = "ocr.recognitionLevel"
        static let languages = "ocr.languages"
        static let usesLanguageCorrection = "ocr.usesLanguageCorrection"
        static let automaticallyDetectsLanguage = "ocr.automaticallyDetectsLanguage"
        static let autoSaveHistory = "history.autoSave"
    }

    static let defaultLanguages = ["zh-Hant", "zh-Hans", "en-US"]

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Key.recognitionLevel: RecognitionLevel.accurate.rawValue,
            Key.languages: encode(defaultLanguages),
            Key.usesLanguageCorrection: true,
            Key.automaticallyDetectsLanguage: false,
            Key.autoSaveHistory: true,
        ])
    }

    static func currentOptions(from defaults: UserDefaults = .standard) -> OCROptions {
        OCROptions(
            recognitionLevel: RecognitionLevel(rawValue: defaults.string(forKey: Key.recognitionLevel) ?? "") ?? .accurate,
            languages: decode(defaults.string(forKey: Key.languages) ?? ""),
            usesLanguageCorrection: defaults.bool(forKey: Key.usesLanguageCorrection),
            automaticallyDetectsLanguage: defaults.bool(forKey: Key.automaticallyDetectsLanguage)
        )
    }

    /// @AppStorage 不支援陣列，語言清單以逗號分隔字串儲存（順序即優先順序）。
    static func encode(_ languages: [String]) -> String {
        languages.joined(separator: ",")
    }

    static func decode(_ string: String) -> [String] {
        string.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    static func displayName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
