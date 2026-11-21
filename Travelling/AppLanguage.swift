import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case ukrainian = "uk"

    static let preferenceKey = "appLanguage"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: "English"
        case .ukrainian: "Українська"
        }
    }

    static var defaultCode: String {
        let savedCode = UserDefaults.standard.string(forKey: preferenceKey)
        if let savedCode, AppLanguage(rawValue: savedCode) != nil {
            return savedCode
        }
        let preferredLanguage = Bundle.main.preferredLocalizations.first ?? Locale.current.identifier
        return preferredLanguage.hasPrefix("uk") ? ukrainian.rawValue : english.rawValue
    }

    static var currentCode: String {
        let savedCode = UserDefaults.standard.string(forKey: preferenceKey)
        return savedCode.flatMap(AppLanguage.init(rawValue:))?.rawValue ?? defaultCode
    }

    static func localized(_ key: String) -> String {
        guard let localizationPath = Bundle.main.path(forResource: currentCode, ofType: "lproj"),
              let localizationBundle = Bundle(path: localizationPath)
        else {
            return NSLocalizedString(key, comment: "")
        }
        return localizationBundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
