import Foundation

/// A minimal TOML reader for Dealer's settings file (#10). It covers the subset settings use:
/// `[table]` / `[a.b]` headers, bare, quoted and dotted keys, basic and literal strings, integers,
/// floats, booleans, arrays (multi-line, trailing commas, nested), and comments. Multi-line
/// strings, inline tables, arrays of tables and dates are reported as unsupported.
///
/// It never throws: a bad line becomes a `TOML.Problem` and parsing resumes on the next line, so
/// one typo doesn't discard the rest of the file.
enum TOML {
    indirect enum Value: Equatable {
        case string(String)
        case integer(Int)
        case float(Double)
        case bool(Bool)
        case array([Value])

        var typeName: String {
            switch self {
            case .string: return "a string"
            case .integer: return "an integer"
            case .float: return "a float"
            case .bool: return "a boolean"
            case .array: return "an array"
            }
        }
    }

    struct Problem: Equatable, CustomStringConvertible {
        let line: Int
        let message: String
        var description: String { "line \(line): \(message)" }
    }

    struct Document {
        /// Values by dotted key, e.g. `"workspaces.switcher"`.
        var values: [String: Value] = [:]
        /// The line each key was defined on, for error messages.
        var lines: [String: Int] = [:]
        var problems: [Problem] = []
    }

    static func parse(_ text: String) -> Document {
        var p = Parser(Array(text.unicodeScalars))
        return p.run()
    }

    /// Formats a value the way it would be written in the file.
    static func literal(_ v: Value) -> String {
        switch v {
        case .string(let s):
            var out = "\""
            for c in s.unicodeScalars {
                switch c {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\t": out += "\\t"
                case "\r": out += "\\r"
                default:
                    if c.value < 0x20 { out += String(format: "\\u%04X", c.value) } else { out.unicodeScalars.append(c) }
                }
            }
            return out + "\""
        case .integer(let i): return String(i)
        case .float(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .array(let a): return "[" + a.map(literal).joined(separator: ", ") + "]"
        }
    }

    private struct ParseError: Error { let message: String }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        var line = 1
        var table: [String] = []
        var doc = Document()
        /// Headers already opened, to report duplicates.
        var tables: Set<String> = []

        init(_ s: [Unicode.Scalar]) { self.s = s }

        var atEnd: Bool { i >= s.count }
        var peek: Unicode.Scalar? { atEnd ? nil : s[i] }

        mutating func advance() {
            if s[i] == "\n" { line += 1 }
            i += 1
        }

        mutating func skipSpaces() {
            while let c = peek, c == " " || c == "\t" { advance() }
        }

        /// Spaces, newlines and comments (inside arrays).
        mutating func skipTrivia() {
            while let c = peek {
                if c == " " || c == "\t" || c == "\n" || c == "\r" { advance() }
                else if c == "#" { while let d = peek, d != "\n" { advance() } }
                else { break }
            }
        }

        mutating func skipLine() {
            while let c = peek, c != "\n" { advance() }
        }

        /// After a value or header: only spaces and a comment may follow on the line.
        mutating func expectEndOfLine() throws {
            skipSpaces()
            if peek == "#" { skipLine() }
            if peek == "\r" { advance() }
            guard atEnd || peek == "\n" else { throw ParseError(message: "unexpected text after the value") }
        }

        mutating func run() -> Document {
            while !atEnd {
                skipTrivia()
                guard !atEnd else { break }
                let start = line
                do {
                    if peek == "[" { try header() } else { try keyValue() }
                } catch let e as ParseError {
                    doc.problems.append(Problem(line: start, message: e.message))
                    // Resume on the line after the error (it may be later than `start` for arrays).
                    skipLine()
                } catch {}
            }
            return doc
        }

        mutating func header() throws {
            advance() // [
            if peek == "[" { throw ParseError(message: "arrays of tables ([[…]]) aren't supported") }
            skipSpaces()
            let path = try keyPath()
            skipSpaces()
            guard peek == "]" else { throw ParseError(message: "expected ] to close the table header") }
            advance()
            try expectEndOfLine()
            let name = path.joined(separator: ".")
            if tables.contains(name) { throw ParseError(message: "table [\(name)] is defined twice") }
            tables.insert(name)
            table = path
        }

        mutating func keyValue() throws {
            let path = try keyPath()
            skipSpaces()
            guard peek == "=" else { throw ParseError(message: "expected = after the key") }
            advance()
            skipSpaces()
            let startLine = line
            let v = try value()
            try expectEndOfLine()
            let key = (table + path).joined(separator: ".")
            if doc.values[key] != nil { throw ParseError(message: "\(key) is set twice") }
            doc.values[key] = v
            doc.lines[key] = startLine
        }

        mutating func keyPath() throws -> [String] {
            var parts = [try keyPart()]
            while true {
                skipSpaces()
                guard peek == "." else { return parts }
                advance()
                skipSpaces()
                parts.append(try keyPart())
            }
        }

        mutating func keyPart() throws -> String {
            if peek == "\"" { return try basicString() }
            if peek == "'" { return try literalString() }
            var k = ""
            while let c = peek, c.properties.isASCIIHexDigit || ("a"..."z").contains(c) || ("A"..."Z").contains(c)
                    || c == "_" || c == "-" || ("0"..."9").contains(c) {
                k.unicodeScalars.append(c)
                advance()
            }
            guard !k.isEmpty else { throw ParseError(message: "expected a key") }
            return k
        }

        mutating func value() throws -> Value {
            guard let c = peek else { throw ParseError(message: "expected a value") }
            switch c {
            case "\"": return .string(try basicString())
            case "'": return .string(try literalString())
            case "[": return try array()
            case "{": throw ParseError(message: "inline tables ({…}) aren't supported")
            default: return try scalar()
            }
        }

        mutating func basicString() throws -> String {
            advance() // "
            if peek == "\"", i + 1 < s.count, s[i + 1] == "\"" { throw ParseError(message: "multi-line strings aren't supported") }
            var out = ""
            while let c = peek {
                if c == "\n" { break }
                advance()
                if c == "\"" { return out }
                if c == "\\" {
                    guard let e = peek else { break }
                    advance()
                    switch e {
                    case "n": out += "\n"
                    case "t": out += "\t"
                    case "r": out += "\r"
                    case "\"": out += "\""
                    case "\\": out += "\\"
                    case "u", "U":
                        let n = e == "u" ? 4 : 8
                        var hex = ""
                        for _ in 0..<n { if let h = peek { hex.unicodeScalars.append(h); advance() } }
                        guard let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) else {
                            throw ParseError(message: "bad \\\(e) escape")
                        }
                        out.unicodeScalars.append(u)
                    default: throw ParseError(message: "unknown escape \\\(e)")
                    }
                } else {
                    out.unicodeScalars.append(c)
                }
            }
            throw ParseError(message: "unterminated string")
        }

        mutating func literalString() throws -> String {
            advance() // '
            var out = ""
            while let c = peek, c != "\n" {
                advance()
                if c == "'" { return out }
                out.unicodeScalars.append(c)
            }
            throw ParseError(message: "unterminated string")
        }

        mutating func array() throws -> Value {
            advance() // [
            var items: [Value] = []
            while true {
                skipTrivia()
                guard let c = peek else { throw ParseError(message: "unterminated array") }
                if c == "]" { advance(); return .array(items) }
                items.append(try value())
                skipTrivia()
                if peek == "," { advance(); continue }
                skipTrivia()
                guard peek == "]" else { throw ParseError(message: "expected , or ] in the array") }
            }
        }

        mutating func scalar() throws -> Value {
            var tok = ""
            while let c = peek, !(c == " " || c == "\t" || c == "\n" || c == "\r" || c == "#" || c == "," || c == "]") {
                tok.unicodeScalars.append(c)
                advance()
            }
            if tok == "true" { return .bool(true) }
            if tok == "false" { return .bool(false) }
            let digits = tok.replacingOccurrences(of: "_", with: "")
            if let n = Int(digits) { return .integer(n) }
            if digits.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let d = Double(digits) { return .float(d) }
            if tok == "inf" || tok == "+inf" { return .float(.infinity) }
            if tok == "-inf" { return .float(-.infinity) }
            if tok == "nan" { return .float(.nan) }
            throw ParseError(message: tok.isEmpty ? "expected a value" : "can't read value \(tok) (strings need quotes)")
        }
    }
}
