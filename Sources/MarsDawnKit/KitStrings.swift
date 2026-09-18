import Foundation

/// The kit's localized strings, for the other modules in this package.
package enum KitStrings {
    /// The bundle holding the kit's resources and localizations.
    package static var bundle: Bundle { .module }

    /// Label of a web image that wasn't loaded (the app preview uses the same wording).
    package static var webImage: String { String(localized: "Web image", bundle: .module) }
}
