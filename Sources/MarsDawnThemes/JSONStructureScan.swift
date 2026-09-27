import Foundation

/// A pre-pass over a `theme.json`'s bytes, before any decoder sees them (kit #125, security
/// review L2).
///
/// `JSONDecoder` and `JSONSerialization` both accept an object that repeats a key and silently
/// keep one of the values, so `{"accent": "#000000", "accent": "#FFFFFF"}` would show a reviewer
/// one colour and the app another. This scanner walks the JSON grammar itself, compares each
/// object's keys after unescaping (`"accent"` is `"accent"`), and refuses a repeat; it also
/// refuses nesting deeper than any theme needs, so a pathological file is turned away in linear
/// time without recursion.
package enum JSONStructureScan {
    /// A `theme.json` nests at most 5 deep (`style.hr.style.colors`); 16 leaves room and still
    /// stops a hostile file long before any recursion in a decoder could matter.
    package static let maxDepth = 16

    package enum Failure: Error, Equatable, Sendable {
        /// `path` is the JSON path of the object holding the repeated key; `key` is the repeated
        /// key itself (unescaped, still attacker text -- quote it before printing).
        case duplicateKey(path: [String], key: String)
        case tooDeep
        case malformed
    }

    private enum Container {
        case object(keys: Set<String>, path: [String], pendingKey: String?)
        case array(path: [String], index: Int)
    }

    package static func scan(_ data: Data) throws(Failure) {
        let bytes = [UInt8](data)
        var index = 0
        var stack: [Container] = []

        func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        /// The path the next value sits at.
        func currentPath() -> [String] {
            switch stack.last {
            case .object(_, let path, let key): path + [key ?? ""]
            case .array(let path, let index): path + [String(index)]
            case nil: []
            }
        }

        func readString() throws(Failure) -> String {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw .malformed }
            index += 1
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []
            func flushRaw() throws(Failure) {
                guard !raw.isEmpty else { return }
                guard let text = String(validating: raw, as: UTF8.self) else { throw .malformed }
                scalars.append(contentsOf: text.unicodeScalars)
                raw.removeAll()
            }
            func hex4() throws(Failure) -> UInt32 {
                guard index + 4 <= bytes.count else { throw .malformed }
                var value: UInt32 = 0
                for byte in bytes[index..<index + 4] {
                    let digit: UInt32
                    switch byte {
                    case 0x30...0x39: digit = UInt32(byte - 0x30)
                    case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
                    case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
                    default: throw .malformed
                    }
                    value = value << 4 | digit
                }
                index += 4
                return value
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    try flushRaw()
                    return String(scalars)
                }
                if byte < 0x20 { throw .malformed }
                if byte == UInt8(ascii: "\\") {
                    try flushRaw()
                    index += 1
                    guard index < bytes.count else { throw .malformed }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        var value = try hex4()
                        if (0xD800...0xDBFF).contains(value) {
                            guard index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { throw .malformed }
                            index += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw .malformed }
                            value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(value) else { throw .malformed }
                        scalars.append(scalar)
                    default: throw .malformed
                    }
                    continue
                }
                raw.append(byte)
                index += 1
            }
            throw .malformed
        }

        func skipScalarLiteral() throws(Failure) {
            let start = index
            while index < bytes.count {
                let byte = bytes[index]
                let isLiteralByte = (0x30...0x39).contains(byte) || (0x61...0x7A).contains(byte)
                    || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
                    || byte == UInt8(ascii: "E")
                guard isLiteralByte else { break }
                index += 1
            }
            if index == start { throw .malformed }
        }

        /// After a value closes (scalar or container), move the parent past it.
        func valueEnded() {
            guard let top = stack.popLast() else { return }
            switch top {
            case .object(let keys, let path, _): stack.append(.object(keys: keys, path: path, pendingKey: nil))
            case .array(let path, let index): stack.append(.array(path: path, index: index + 1))
            }
        }

        func beginValue() throws(Failure) {
            skipWhitespace()
            guard index < bytes.count else { throw .malformed }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                guard stack.count < maxDepth else { throw .tooDeep }
                stack.append(.object(keys: [], path: currentPath(), pendingKey: nil))
                index += 1
            case UInt8(ascii: "["):
                guard stack.count < maxDepth else { throw .tooDeep }
                stack.append(.array(path: currentPath(), index: 0))
                index += 1
            case UInt8(ascii: "\""):
                _ = try readString()
                valueEnded()
            default:
                try skipScalarLiteral()
                valueEnded()
            }
        }

        try beginValue()
        while !stack.isEmpty {
            skipWhitespace()
            guard index < bytes.count else { throw .malformed }
            let byte = bytes[index]
            switch stack.last! {
            case .object(var keys, let path, let pending):
                if pending == nil {
                    if byte == UInt8(ascii: "}") {
                        index += 1
                        stack.removeLast()
                        valueEnded()
                        continue
                    }
                    if byte == UInt8(ascii: ","), !keys.isEmpty {
                        index += 1
                        skipWhitespace()
                    } else if !keys.isEmpty {
                        throw .malformed
                    }
                    let key = try readString()
                    guard keys.insert(key).inserted else { throw .duplicateKey(path: path, key: key) }
                    skipWhitespace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw .malformed }
                    index += 1
                    stack[stack.count - 1] = .object(keys: keys, path: path, pendingKey: key)
                    try beginValue()
                } else {
                    throw .malformed
                }
            case .array(_, let count):
                if byte == UInt8(ascii: "]") {
                    index += 1
                    stack.removeLast()
                    valueEnded()
                    continue
                }
                if count > 0 {
                    guard byte == UInt8(ascii: ",") else { throw .malformed }
                    index += 1
                }
                try beginValue()
            }
        }
        skipWhitespace()
        if index != bytes.count { throw .malformed }
    }
}
