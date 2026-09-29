import Foundation

/// A coding key that accepts any string, used only to enumerate the keys a JSON object actually
/// has (so they can be compared against a type's real `CodingKeys`).
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

/// Thrown as itself, not wrapped in a `DecodingError`, so the validator can tell an unknown key
/// from any other failure and quote the key (attacker text) before it repeats it (kit #125, M4).
/// `description` quotes it too, for any caller that just prints the error.
enum StrictDecodingError: Error, CustomStringConvertible {
    case unknownKey(String, path: [CodingKey])
    case missingEnglish(path: [CodingKey])

    var description: String {
        switch self {
        case .unknownKey(let key, let path):
            let location = ThemeValidator.render(path)
            let quoted = ThemeMessageText.quote(key)
            return location.isEmpty ? "unknown key '\(quoted)'" : "unknown key '\(quoted)' at '\(location)'"
        case .missingEnglish(let path):
            return "missing required 'en' entry at '\(ThemeValidator.render(path))'"
        }
    }
}

/// Design §4.2: "Unknown keys are rejected, at every level." `Decodable.init(from:)` alone never
/// sees a key it didn't declare, so every strict type in this module calls this first, comparing
/// the JSON object's real keys against its own `CodingKeys`, before decoding any field.
func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(_ decoder: Decoder, keyedBy type: Keys.Type) throws {
    let any = try decoder.container(keyedBy: AnyCodingKey.self)
    let known = Set(Keys.allCases.map(\.stringValue))
    for key in any.allKeys where !known.contains(key.stringValue) {
        throw StrictDecodingError.unknownKey(key.stringValue, path: decoder.codingPath)
    }
}

/// Same check for a type whose associated-value cases are told apart by a `"type"` discriminator
/// (the style-option enums below): `allowed` is the discriminator's own closed vocabulary plus
/// whatever parameter keys that case takes.
func rejectUnknownKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let any = try decoder.container(keyedBy: AnyCodingKey.self)
    for key in any.allKeys where !allowed.contains(key.stringValue) {
        throw StrictDecodingError.unknownKey(key.stringValue, path: decoder.codingPath)
    }
}
