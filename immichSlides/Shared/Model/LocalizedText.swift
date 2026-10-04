import Foundation

// Look up the template by a fixed key and then format it, so interpolation does not grow stale keys in the
// Catalog.

enum LocalizedText {
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, comment: "")
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
