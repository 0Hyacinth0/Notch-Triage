import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simplifiedChinese:
            return "简体中文"
        case .english:
            return "English"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    func localized(_ source: String) -> String {
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return source
        }

        return bundle.localizedString(forKey: source, value: source, table: nil)
    }

    func localizedFormat(_ source: String, _ arguments: CVarArg...) -> String {
        String(
            format: localized(source),
            locale: locale,
            arguments: arguments
        )
    }
}
