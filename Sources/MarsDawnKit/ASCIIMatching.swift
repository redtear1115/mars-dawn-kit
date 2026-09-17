/// ASCII matching on bytes and scalars, for checks on characters that HTML and URL parsers treat
/// specially. `Character` and `String` comparisons work on grapheme clusters and can miss an
/// ASCII character that a combining mark or Prepend scalar has joined to its neighbour.

func asciiLowercased(_ byte: UInt8) -> UInt8 {
    (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte | 0x20 : byte
}

/// Whether `bytes` starts with the ASCII string `prefix`, ignoring ASCII case only.
func asciiCaseInsensitiveHasPrefix(_ bytes: String.UTF8View, _ prefix: String) -> Bool {
    guard bytes.count >= prefix.utf8.count else { return false }
    return zip(bytes, prefix.utf8).allSatisfy { asciiLowercased($0) == asciiLowercased($1) }
}

/// The lowercased scheme if `scalars` is an ASCII URL scheme (`[A-Za-z][A-Za-z0-9+.-]*`), else nil.
func asciiURLScheme(_ scalars: Substring.UnicodeScalarView) -> String? {
    guard let first = scalars.first, ("a"..."z").contains(first) || ("A"..."Z").contains(first) else {
        return nil
    }
    var scheme: [UInt8] = []
    for scalar in scalars {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "+", ".", "-":
            scheme.append(asciiLowercased(UInt8(scalar.value)))
        default:
            return nil
        }
    }
    return String(decoding: scheme, as: UTF8.self)
}
