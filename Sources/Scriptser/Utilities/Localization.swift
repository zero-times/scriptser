import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }

    static let defaultsKey = "appLanguage"

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

    var localization: String {
        guard self == .system else { return rawValue }
        return Self.systemLocalization(preferredLanguages: Locale.preferredLanguages)
    }

    static func systemLocalization(preferredLanguages: [String]) -> String {
        for language in preferredLanguages {
            if language.hasPrefix("zh") { return "zh-Hans" }
            if language.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    var locale: Locale { Locale(identifier: localization) }

    var label: String {
        switch self {
        case .system: return L10n.text("Follow System")
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }
}

enum L10n {
    static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    static func text(_ key: String, language: AppLanguage = .current) -> String {
        guard let path = resourceBundle.path(forResource: language.localization, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg..., language: AppLanguage = .current) -> String {
        String(format: text(key, language: language), locale: language.locale, arguments: arguments)
    }

    static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.current.locale
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
