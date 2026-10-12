import Foundation

// Guards the string tables (app/*.lproj/Localizable.strings) and the Swift
// sources that read them. Offline, no engine, no app code: run from the repo
// root via tests/check-l10n.sh (and from tests/run-cleanup.sh).
//
// Errors (exit 1):
//   - a table that does not parse, or repeats a key, or has an empty value;
//   - a table whose key set differs from en (missing and extra keys listed);
//   - a translation whose format specifiers differ from its key's: the same
//     argument positions with the same conversions (%@, %lld, %d, %lf ...),
//     where "%2$@ %1$@" reorders and a plain "%@ %@" counts as 1 then 2;
//   - a required language directory that is gone;
//   - a literal passed to String(localized:) or to a SwiftUI view or modifier
//     that localizes its title (Text, Button, Label, .help ...) that en does
//     not have: it would show in English in every language.
// Warnings (never fail): a non-English value identical to the English one
// (legitimate for brand names and shared words, so only reported), and table
// keys no source literal reaches (they may be reached dynamically).

struct StringsEntry {
    let key: String
    let value: String
    let line: Int
}

enum StringsParser {
    /// Old-style `"key" = "value";` with /* */ and // comments, the subset the
    /// app's tables use. Anything else is an error (fail closed), so a table
    /// the real loader would read differently cannot pass here.
    static func parse(_ text: String) -> (entries: [StringsEntry], error: String?) {
        let s = Array(text.unicodeScalars)
        var i = 0
        var line = 1
        var entries: [StringsEntry] = []

        func skipSpace() -> String? {
            while i < s.count {
                let c = s[i]
                if c == "\n" { line += 1; i += 1 }
                else if c == " " || c == "\t" || c == "\r" || c == "\u{FEFF}" { i += 1 }
                else if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                    while i < s.count, s[i] != "\n" { i += 1 }
                } else if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                    i += 2
                    while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") {
                        if s[i] == "\n" { line += 1 }
                        i += 1
                    }
                    if i + 1 >= s.count { return "line \(line): unterminated comment" }
                    i += 2
                } else { break }
            }
            return nil
        }

        func quoted() -> String? {
            guard i < s.count, s[i] == "\"" else { return nil }
            i += 1
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]
                if c == "\"" { i += 1; return String(out) }
                if c == "\n" { line += 1 }
                if c == "\\" {
                    i += 1
                    guard i < s.count else { return nil }
                    switch s[i] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "'": out.append("'")
                    case "U", "u":
                        guard i + 4 < s.count,
                              let v = UInt32(String(String.UnicodeScalarView(s[(i + 1)...(i + 4)])), radix: 16),
                              let scalar = Unicode.Scalar(v) else { return nil }
                        out.append(scalar)
                        i += 4
                    default: return nil
                    }
                    i += 1
                } else {
                    out.append(c)
                    i += 1
                }
            }
            return nil
        }

        while true {
            if let e = skipSpace() { return (entries, e) }
            if i >= s.count { break }
            let startLine = line
            guard let key = quoted() else { return (entries, "line \(startLine): expected a quoted key") }
            if let e = skipSpace() { return (entries, e) }
            guard i < s.count, s[i] == "=" else { return (entries, "line \(line): expected '=' after \"\(key)\"") }
            i += 1
            if let e = skipSpace() { return (entries, e) }
            guard let value = quoted() else { return (entries, "line \(line): expected a quoted value for \"\(key)\"") }
            if let e = skipSpace() { return (entries, e) }
            guard i < s.count, s[i] == ";" else { return (entries, "line \(line): expected ';' after the value of \"\(key)\"") }
            i += 1
            entries.append(StringsEntry(key: key, value: value, line: startLine))
        }
        return (entries, nil)
    }
}

enum FormatSpecifiers {
    /// Argument position -> conversion with length modifier ("@", "lld", "d").
    /// `problem` is set when the string mixes positional and plain specifiers
    /// or uses one position for two types.
    static func parse(_ text: String) -> (byPosition: [Int: String], problem: String?) {
        let s = Array(text.unicodeScalars)
        var result: [Int: String] = [:]
        var next = 1
        var sawPositional = false
        var sawPlain = false
        var problem: String?
        var i = 0
        let conversions = Set("@dDiuUxXoOfFeEgGaAcCsSpP".unicodeScalars)
        let lengths = ["hh", "ll", "h", "l", "q", "L", "z", "t", "j"]
        while i < s.count {
            guard s[i] == "%" else { i += 1; continue }
            var j = i + 1
            if j < s.count, s[j] == "%" { i = j + 1; continue }
            var position: Int?
            var k = j
            var digits = ""
            while k < s.count, s[k].properties.numericType != nil, s[k].isASCII { digits.unicodeScalars.append(s[k]); k += 1 }
            if !digits.isEmpty, k < s.count, s[k] == "$" { position = Int(digits); j = k + 1 }
            while j < s.count, "-+#0'".unicodeScalars.contains(s[j]) { j += 1 }
            while j < s.count, s[j].isASCII, s[j].properties.numericType != nil { j += 1 }
            if j < s.count, s[j] == "." {
                j += 1
                while j < s.count, s[j].isASCII, s[j].properties.numericType != nil { j += 1 }
            }
            var length = ""
            let rest = String(String.UnicodeScalarView(s[j...].prefix(2)))
            if let m = lengths.first(where: { rest.hasPrefix($0) }) { length = m; j += m.count }
            guard j < s.count, conversions.contains(s[j]) else { i += 1; continue }
            let type = length + String(Character(s[j]))
            let slot: Int
            if let p = position { slot = p; sawPositional = true } else { slot = next; next += 1; sawPlain = true }
            if let existing = result[slot], existing != type {
                problem = "argument \(slot) is used as both %\(existing) and %\(type)"
            }
            result[slot] = type
            i = j + 1
        }
        if sawPositional && sawPlain { problem = "mixes positional (%1$@) and plain (%@) specifiers" }
        return (result, problem)
    }

    static func describe(_ specs: [Int: String]) -> String {
        specs.isEmpty ? "none" : specs.keys.sorted().map { "\($0):%\(specs[$0]!)" }.joined(separator: " ")
    }
}

/// A literal passed to the localization helper, split at `\( )` interpolations.
struct SourceKey {
    enum Part { case text(String), hole }
    let file: String
    let line: Int
    let call: String
    let parts: [Part]

    var plain: String? {
        var out = ""
        for part in parts {
            guard case .text(let t) = part else { return nil }
            out += t
        }
        return out
    }
    /// The literal as written, interpolations shown as `\(…)`.
    var shown: String {
        parts.map { part -> String in
            if case .text(let t) = part { return t.replacingOccurrences(of: "\n", with: "\\n") }
            return "\\(…)"
        }.joined()
    }
    var hasLetters: Bool {
        parts.contains { part in
            if case .text(let t) = part { return t.unicodeScalars.contains { $0.properties.isAlphabetic } }
            return false
        }
    }
}

/// Reads the localizable literals out of one Swift file that the compiler
/// cannot be run on (Main.swift imports Sparkle, which the check does not
/// have). Everything else comes from the compiler's own list of keys, which
/// knows each interpolation's real type; this scanner knows none, so a
/// literal with an interpolation is an error here, as is any localizable call
/// whose literal it cannot read (multi-line, raw) and `NSLocalizedString`,
/// which the compiler does not list. It never skips such a call quietly.
final class SourceScanner {
    static let views: Set<String> = [
        "Text", "Button", "Label", "Toggle", "Picker", "Section", "TextField", "SecureField", "Menu", "Link",
        "GroupBox", "ProgressView", "Stepper", "DisclosureGroup", "LabeledContent", "Gauge", "Slider",
        "LocalizedStringKey",
    ]
    static let modifiers: Set<String> = [
        "help", "navigationTitle", "accessibilityLabel", "accessibilityHint", "accessibilityValue", "badge",
        "alert", "confirmationDialog",
    ]

    let bytes: [UInt8]
    let file: String
    private(set) var found: [SourceKey] = []
    /// `String(localized:)` calls whose argument is not a literal: not checkable here.
    private(set) var dynamic = 0
    /// Localizable calls this scanner cannot read: (line, what).
    private(set) var unreadable: [(line: Int, what: String)] = []

    init(file: String, text: String) {
        self.file = file
        bytes = Array(text.utf8)
    }

    private func line(_ offset: Int) -> Int { bytes[0..<offset].reduce(1) { $1 == 10 ? $0 + 1 : $0 } }
    private func isIdent(_ b: UInt8) -> Bool {
        (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 95
    }
    private func skipSpace(_ i: Int) -> Int {
        var i = i
        while i < bytes.count, bytes[i] == 32 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13 { i += 1 }
        return i
    }
    private func has(_ i: Int, _ word: String) -> Bool {
        let w = Array(word.utf8)
        return i + w.count <= bytes.count && Array(bytes[i..<(i + w.count)]) == w
    }

    /// Reads a single-line literal opening at `q` without recording anything.
    /// Returns its parts, the byte ranges of its interpolations and the index
    /// after the closing quote (nil if it never closes on that line).
    private func literal(at q: Int) -> (parts: [SourceKey.Part], inner: [Range<Int>], end: Int)? {
        var i = q + 1
        var parts: [SourceKey.Part] = []
        var inner: [Range<Int>] = []
        var cur: [UInt8] = []
        func flush() {
            if !cur.isEmpty { parts.append(.text(String(decoding: cur, as: UTF8.self))); cur = [] }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == 10 { return nil }
            if b == 34 { flush(); return (parts, inner, i + 1) }
            guard b == 92 else { cur.append(b); i += 1; continue }
            i += 1
            guard i < bytes.count else { return nil }
            switch bytes[i] {
            case 110: cur.append(10)
            case 116: cur.append(9)
            case 114: cur.append(13)
            case 48: cur.append(0)
            case 92, 34, 39: cur.append(bytes[i])
            case 117:
                guard i + 1 < bytes.count, bytes[i + 1] == 123, let close = bytes[i...].firstIndex(of: 125),
                      let v = UInt32(String(decoding: bytes[(i + 2)..<close], as: UTF8.self), radix: 16),
                      let scalar = Unicode.Scalar(v) else { return nil }
                cur.append(contentsOf: Array(String(Character(scalar)).utf8))
                i = close
            case 40:
                flush()
                var depth = 1
                var j = i + 1
                while j < bytes.count, depth > 0 {
                    if bytes[j] == 34 {
                        guard let nested = literal(at: j) else { return nil }
                        j = nested.end
                        continue
                    }
                    if bytes[j] == 40 { depth += 1 }
                    if bytes[j] == 41 { depth -= 1 }
                    j += 1
                }
                guard depth == 0 else { return nil }
                parts.append(.hole)
                inner.append((i + 1)..<(j - 1))
                i = j - 1
            default: return nil
            }
            i += 1
        }
        return nil
    }

    func scan() { scan(0..<bytes.count) }

    private func scan(_ range: Range<Int>) {
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            let b = bytes[i]
            if b == 47, i + 1 < end, bytes[i + 1] == 47 {
                while i < end, bytes[i] != 10 { i += 1 }
                continue
            }
            if b == 47, i + 1 < end, bytes[i + 1] == 42 {
                var depth = 1
                i += 2
                while i + 1 < end, depth > 0 {
                    if bytes[i] == 47, bytes[i + 1] == 42 { depth += 1; i += 2 }
                    else if bytes[i] == 42, bytes[i + 1] == 47 { depth -= 1; i += 2 }
                    else { i += 1 }
                }
                continue
            }
            if b == 35 || b == 34 {
                // Raw (#"..."#) and multi-line ("""...""") literals hold no localizable calls here: skip them.
                var hashes = 0
                var j = i
                while j < end, bytes[j] == 35 { hashes += 1; j += 1 }
                if j < end, bytes[j] == 34 {
                    let multiline = has(j, "\"\"\"")
                    if multiline || hashes > 0 {
                        let closer = String(repeating: "\"", count: multiline ? 3 : 1) + String(repeating: "#", count: hashes)
                        var k = j + (multiline ? 3 : 1)
                        while k < end, !has(k, closer) { k += (bytes[k] == 92 && hashes == 0 ? 2 : 1) }
                        i = min(end, k + closer.utf8.count)
                        continue
                    }
                    if let lit = literal(at: j) {
                        for r in lit.inner { scan(r) }
                        i = lit.end
                        continue
                    }
                    i = j + 1
                    continue
                }
                i += 1
                continue
            }
            guard isIdent(b), !(b >= 48 && b <= 57), i == 0 || !isIdent(bytes[i - 1]) else { i += 1; continue }
            var j = i
            while j < end, isIdent(bytes[j]) { j += 1 }
            let name = String(decoding: bytes[i..<j], as: UTF8.self)
            let prev = i > 0 ? bytes[i - 1] : 0
            let afterName = skipSpace(j)
            guard afterName < end, bytes[afterName] == 40 else { i = j; continue }
            if name == "NSLocalizedString" {
                unreadable.append((line(i), "NSLocalizedString (the compiler does not list its keys; use String(localized:))"))
                i = j
                continue
            }
            let arg = skipSpace(afterName + 1)
            var call: String?
            var quote = arg
            if name == "String", has(arg, "localized") {
                let colon = skipSpace(arg + "localized".utf8.count)
                if colon < end, bytes[colon] == 58 {
                    quote = skipSpace(colon + 1)
                    call = "String(localized:)"
                    if quote >= end || bytes[quote] != 34 { dynamic += 1; i = j; continue }
                }
            } else if prev == 46, Self.modifiers.contains(name) {
                call = ".\(name)"
            } else if prev != 46, Self.views.contains(name) {
                call = name
            }
            guard let call, quote < end else { i = j; continue }
            if bytes[quote] == 35 || has(quote, "\"\"\"") {
                unreadable.append((line(quote), "\(call) with a multi-line or raw literal"))
                i = j
                continue
            }
            // Not a literal (a variable, `verbatim:`): not localized from here.
            guard bytes[quote] == 34 else { i = j; continue }
            guard let lit = literal(at: quote) else {
                unreadable.append((line(quote), "\(call) with a literal that does not end on its line"))
                i = j
                continue
            }
            found.append(SourceKey(file: file, line: line(quote), call: call, parts: lit.parts))
            for r in lit.inner { scan(r) }
            i = lit.end
        }
    }
}

struct L10nReport {
    var errors: [String] = []
    var warnings: [String] = []
    var languages: [String] = []
    var keyCount = 0
    /// Keys the compiler listed, and literals the scanner read from the files it could not compile.
    var compilerKeys = 0
    var scannedLiterals = 0
    var compiledFiles = 0
    var scannedFiles: [String] = []
}

/// A key with every format specifier replaced by `%`: two keys with the same
/// shape differ only in the types of their arguments.
func specifierShape(_ key: String) -> String {
    key.replacingOccurrences(
        of: #"%(\d+\$)?[-+#0']*\d*(\.\d+)?(hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGaAcCsSpP]"#, with: "%", options: .regularExpression)
}

enum L10nAudit {
    static let requiredLanguages = ["en", "de", "es", "fr", "ja", "tr", "zh-Hans"]
    static let listCap = 10
    static let exceptionsPath = "tests/l10n-exceptions.txt"

    enum ExceptionKind { case never, gap }

    /// `never | text` (deliberately untranslated) and `gap | text` (missing
    /// from the tables when the check was added) lines, `#` comments. The text
    /// is the key exactly as the compiler writes it (`%lld`, `%@` for interpolations).
    /// A malformed line is an error, so a typo cannot silently exempt nothing.
    static func loadExceptions(root: String, report: inout L10nReport) -> [String: ExceptionKind] {
        guard let data = FileManager.default.contents(atPath: root + "/" + exceptionsPath) else { return [:] }
        guard let text = String(data: data, encoding: .utf8) else {
            report.errors.append("\(exceptionsPath): not UTF-8")
            return [:]
        }
        var out: [String: ExceptionKind] = [:]
        for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let kind: ExceptionKind
            if line.hasPrefix("never | ") { kind = .never } else if line.hasPrefix("gap | ") { kind = .gap } else {
                report.errors.append("\(exceptionsPath):\(n + 1): expected 'never | text' or 'gap | text'")
                continue
            }
            let text = String(line.drop { $0 != "|" }.dropFirst(2))
            if out[text] != nil { report.errors.append("\(exceptionsPath):\(n + 1): \"\(text)\" is listed twice") }
            out[text] = kind
        }
        return out
    }

    static func run(root: String, emitted: String) -> L10nReport {
        var report = L10nReport()
        let fm = FileManager.default
        let appDir = root + "/app"
        let dirs = ((try? fm.contentsOfDirectory(atPath: appDir)) ?? []).filter { $0.hasSuffix(".lproj") }.sorted()
        let languages = dirs.map { String($0.dropLast(".lproj".count)) }
        report.languages = languages
        for needed in requiredLanguages where !languages.contains(needed) {
            report.errors.append("app/\(needed).lproj is missing")
        }

        var tables: [String: [StringsEntry]] = [:]
        for lang in languages {
            let rel = "app/\(lang).lproj/Localizable.strings"
            guard let data = fm.contents(atPath: root + "/" + rel), let text = String(data: data, encoding: .utf8) else {
                report.errors.append("\(rel): missing or not UTF-8")
                continue
            }
            let parsed = StringsParser.parse(text)
            if let e = parsed.error {
                report.errors.append("\(rel): \(e)")
                continue
            }
            do {
                // Apple's own reader must agree with ours on what the table holds.
                let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                if let dict = plist as? [String: String], dict.count != Set(parsed.entries.map(\.key)).count {
                    report.errors.append("\(rel): the system parser reads \(dict.count) keys, this check reads \(Set(parsed.entries.map(\.key)).count)")
                }
            } catch {
                report.errors.append("\(rel): the system parser rejects it: \(error.localizedDescription)")
                continue
            }
            var seen: [String: Int] = [:]
            for entry in parsed.entries {
                if let first = seen[entry.key] {
                    report.errors.append("\(rel):\(entry.line): duplicate key \"\(entry.key)\" (first at line \(first))")
                }
                seen[entry.key] = seen[entry.key] ?? entry.line
                if entry.value.isEmpty { report.errors.append("\(rel):\(entry.line): empty value for \"\(entry.key)\"") }
            }
            tables[lang] = parsed.entries
        }
        guard let en = tables["en"] else { return report }
        let enValues = Dictionary(en.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        report.keyCount = enValues.count

        // The key's own specifiers must also match the English value's.
        for entry in en {
            let key = FormatSpecifiers.parse(entry.key)
            let value = FormatSpecifiers.parse(entry.value)
            if key.byPosition != value.byPosition {
                report.errors.append("en:\(entry.line): value's format specifiers [\(FormatSpecifiers.describe(value.byPosition))] differ from the key's [\(FormatSpecifiers.describe(key.byPosition))]: \"\(entry.key)\"")
            }
        }

        for lang in languages where lang != "en" {
            guard let entries = tables[lang] else { continue }
            let values = Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            let missing = Set(enValues.keys).subtracting(values.keys).sorted()
            let extra = Set(values.keys).subtracting(enValues.keys).sorted()
            func list(_ keys: [String]) -> String {
                keys.prefix(listCap).map { "\n      \"\($0)\"" }.joined() + (keys.count > listCap ? "\n      … and \(keys.count - listCap) more" : "")
            }
            if !missing.isEmpty { report.errors.append("\(lang): \(missing.count) key(s) missing from the table (they would show in English):" + list(missing)) }
            if !extra.isEmpty { report.errors.append("\(lang): \(extra.count) key(s) not in en (stale or misspelled):" + list(extra)) }
            var identical: [String] = []
            for entry in entries {
                let key = FormatSpecifiers.parse(entry.key)
                let value = FormatSpecifiers.parse(entry.value)
                if let p = value.problem {
                    report.errors.append("\(lang):\(entry.line): \(p): \"\(entry.key)\"")
                } else if key.byPosition != value.byPosition {
                    report.errors.append("\(lang):\(entry.line): format specifiers [\(FormatSpecifiers.describe(value.byPosition))] differ from the key's [\(FormatSpecifiers.describe(key.byPosition))]: \"\(entry.key)\"")
                }
                if entry.value == enValues[entry.key], entry.value.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) {
                    identical.append(entry.key)
                }
            }
            if !identical.isEmpty {
                report.warnings.append("\(lang): \(identical.count) value(s) identical to English (fine for names and shared words):" + list(identical))
            }
        }

        // Every key the app's code asks the tables for. The compiler's list is
        // the truth for the files it compiled; the scanner reads the rest.
        var used = Set<String>()
        var exceptionsUsed = Set<String>()
        var knownGaps = Set<String>()
        let exceptions = loadExceptions(root: root, report: &report)
        let enByShape = Dictionary(grouping: enValues.keys, by: specifierShape)

        func require(_ key: String, file: String, line: Int, call: String) {
            guard key.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) else { return }
            if enValues[key] != nil {
                used.insert(key)
                return
            }
            if let kind = exceptions[key] {
                exceptionsUsed.insert(key)
                if kind == .gap { knownGaps.insert(key) }
                return
            }
            var message = "\(file):\(line): \(call) key \"\(key)\" is not in en.lproj, so no language can translate it"
            // A key that differs from a table key only in a format specifier is
            // the live trap: the table entry is dead and the string stays English.
            if let near = enByShape[specifierShape(key)]?.sorted(), !near.isEmpty {
                message += "; the table has \(near.map { "\"\($0)\"" }.joined(separator: ", ")), which differs only in format specifiers"
                    + " (the compiler writes the key with the argument's real type)"
            }
            report.errors.append(message)
        }

        let emittedFiles = ((try? fm.contentsOfDirectory(atPath: emitted)) ?? []).filter { $0.hasSuffix(".stringsdata") }.sorted()
        if emittedFiles.isEmpty {
            report.errors.append("the compiler listed no localized strings at all (\(emitted)): nothing was checked")
        }
        var compiled = Set<String>()
        for file in emittedFiles {
            guard let data = fm.contents(atPath: emitted + "/" + file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let source = json["source"] as? String,
                  let byTable = json["tables"] as? [String: Any] else {
                report.errors.append("\(file): not a localized-strings listing from the compiler")
                continue
            }
            let name = (source as NSString).lastPathComponent
            compiled.insert(name)
            report.compiledFiles += 1
            for (table, entries) in byTable.sorted(by: { $0.key < $1.key }) {
                guard let entries = entries as? [[String: Any]] else { continue }
                if table != "Localizable", !entries.isEmpty {
                    report.errors.append("app/\(name): \(entries.count) key(s) go to the table \"\(table)\", which this check does not read")
                    continue
                }
                for entry in entries {
                    guard let key = entry["key"] as? String else { continue }
                    let line = ((entry["location"] as? [String: Any])?["startingLine"] as? Int) ?? 0
                    report.compilerKeys += 1
                    require(key, file: "app/" + name, line: line, call: "localized")
                }
            }
        }

        // Files the compiler was not given are read by the scanner; every
        // file is also searched for calls the compiler's list cannot contain.
        let sources = ((try? fm.contentsOfDirectory(atPath: appDir)) ?? []).filter { $0.hasSuffix(".swift") }.sorted()
        for name in sources {
            guard let data = fm.contents(atPath: appDir + "/" + name), let text = String(data: data, encoding: .utf8) else {
                report.errors.append("app/\(name): unreadable, so its localized strings were not checked")
                continue
            }
            let scanner = SourceScanner(file: "app/" + name, text: text)
            scanner.scan()
            let scanned = !compiled.contains(name)
            if scanned { report.scannedFiles.append(name) }
            for item in scanner.unreadable where scanned || item.what.hasPrefix("NSLocalizedString") {
                report.errors.append("app/\(name):\(item.line): \(item.what) cannot be checked")
            }
            guard scanned else { continue }
            for key in scanner.found {
                guard let plain = key.plain else {
                    report.errors.append("\(key.file):\(key.line): \(key.call) \"\(key.shown)\" has an interpolation; its format specifier is only known to the compiler, which was not run on this file")
                    continue
                }
                report.scannedLiterals += 1
                require(plain, file: key.file, line: key.line, call: key.call)
            }
        }
        if !knownGaps.isEmpty {
            report.warnings.append("\(knownGaps.count) source string(s) have no key in any table yet (listed as gap in \(exceptionsPath)); translate them and delete their lines")
        }
        for text in exceptions.keys.sorted() where !exceptionsUsed.contains(text) {
            report.warnings.append("\(exceptionsPath) lists \"\(text)\", which app/ no longer needs an exception for; delete the line")
        }
        let unused = Set(enValues.keys).subtracting(used).sorted()
        if !unused.isEmpty {
            report.warnings.append("en: \(unused.count) key(s) no String(localized:)/SwiftUI literal in app/ reaches (dead, or looked up dynamically):"
                + unused.prefix(listCap).map { "\n      \"\($0)\"" }.joined()
                + (unused.count > listCap ? "\n      … and \(unused.count - listCap) more" : ""))
        }
        return report
    }
}


// MARK: - Self-tests: the check must fail on the faults it exists to catch.

enum L10nFixtures {
    static func tree(_ files: [String: String]) -> String {
        let root = NSTemporaryDirectory() + "l10n-check-" + UUID().uuidString
        for (path, text) in files {
            let full = root + "/" + path
            try! FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try! text.write(toFile: full, atomically: true, encoding: .utf8)
        }
        return root
    }

    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func table(_ pairs: [(String, String)]) -> String {
        "/* fixture */\n" + pairs.map { "\"\(escaped($0.0))\" = \"\(escaped($0.1))\";" }.joined(separator: "\n") + "\n"
    }

    /// A valid tree in all required languages; `overrides` replaces a language's table.
    static func valid(source: String = "", overrides: [String: String] = [:]) -> [String: String] {
        let en = table([("Scan", "Scan"), ("Move %lld items to Trash?", "Move %lld items to Trash?"), ("%@ of %@", "%@ of %@")])
        var files = ["app/Main.swift": source]
        for lang in L10nAudit.requiredLanguages {
            let tr = table([("Scan", "Scan-\(lang)"), ("Move %lld items to Trash?", "Move %lld (\(lang))?"), ("%@ of %@", "%2$@ / %1$@ \(lang)")])
            files["app/\(lang).lproj/Localizable.strings"] = overrides[lang] ?? (lang == "en" ? en : tr)
        }
        return files
    }

    /// What the compiler writes for one file: its keys, in the Localizable table.
    static func stringsdata(source: String, keys: [String]) -> String {
        let entries = keys.enumerated().map { i, key in
            ["key": key, "comment": "", "location": ["startingLine": i + 1, "startingColumn": 1]] as [String: Any]
        }
        let json: [String: Any] = ["source": source, "tables": entries.isEmpty ? [:] : ["Localizable": entries]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }

    /// Audits a tree whose compiled files list the given keys (file name -> keys).
    static func audit(_ files: [String: String], compiled: [String: [String]] = ["Compiled.swift": []]) -> L10nReport {
        var files = files
        let emitted = NSTemporaryDirectory() + "l10n-emitted-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: emitted, withIntermediateDirectories: true)
        for (name, keys) in compiled {
            files["app/\(name)"] = files["app/\(name)"] ?? ""
            try! stringsdata(source: "app/\(name)", keys: keys).write(toFile: emitted + "/\(name).stringsdata", atomically: true, encoding: .utf8)
        }
        let root = tree(files)
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: emitted)
        }
        return L10nAudit.run(root: root, emitted: emitted)
    }

    /// Runs the compiler over one Swift file the way check-l10n.sh does and returns the directory it wrote.
    static func compile(_ source: String) -> String {
        let dir = NSTemporaryDirectory() + "l10n-compile-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: dir + "/out", withIntermediateDirectories: true)
        try! source.write(toFile: dir + "/Forms.swift", atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        process.arguments = [
            dir + "/Forms.swift", "-parse-as-library", "-swift-version", "6", "-target", "arm64-apple-macos14.0", "-c", "-wmo",
            "-module-name", "Forms", "-o", dir + "/x.o", "-emit-localized-strings", "-emit-localized-strings-path", dir + "/out",
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try! process.run()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "swiftc could not compile the fixture: \(text)")
        return dir + "/out"
    }
}

@main
struct L10nChecks {
    static func expect(_ report: L10nReport, errorContaining needles: [String], _ what: String) {
        for needle in needles {
            precondition(report.errors.contains { $0.contains(needle) },
                         "\(what): no error mentions '\(needle)'; errors: \(report.errors)")
        }
        precondition(!report.errors.isEmpty, "\(what): expected a failure")
    }

    /// Every localizable form the scanner used to skip, compiled for real: the
    /// compiler's list must contain it, so the tables are held to it.
    static let formsSource = ##"""
    import SwiftUI

    struct FormsView: View {
        @State var shown = false
        var code = 404
        var message = "x"
        var body: some View {
            Text(LocalizedStringKey("Form key"))
                .alert("Form alert", isPresented: $shown) { Button("Form alert OK") {} }
                .confirmationDialog("Form dialog", isPresented: $shown) { Button("Form dialog go") {} }
        }
        func plain() -> [String] {
            [String(localized: """
                Form multi
                line
                """),
             String(localized: #"Form raw "quoted" literal"#),
             String(localized: "HTTP \(code): \(message)"),
             String(localized: "Counted \(code) things")]
        }
    }
    """##

    static let formsKeys = [
        "Form key", "Form alert", "Form alert OK", "Form dialog", "Form dialog go", "Form multi\nline",
        "Form raw \"quoted\" literal", "HTTP %lld: %@", "Counted %lld things",
    ]

    static func compilerBackedTests() {
        let emitted = L10nFixtures.compile(formsSource)
        defer { try? FileManager.default.removeItem(atPath: (emitted as NSString).deletingLastPathComponent) }

        // The tables as they stood: none of the forms is in them, and the HTTP key carries the wrong specifier.
        func tree(source: String, extra: [(String, String)], http: String) -> [String: String] {
            var files: [String: String] = ["app/Forms.swift": source]
            for lang in L10nAudit.requiredLanguages {
                let pairs = (extra + [(http, "")]).map { ($0.0, lang == "en" ? $0.0 : $0.0 + " [\(lang)]") }
                files["app/\(lang).lproj/Localizable.strings"] = L10nFixtures.table(pairs)
            }
            return files
        }
        var files = tree(source: formsSource + "\nlet legacy = NSLocalizedString(\"Form NSLocalized\", comment: \"\")\n", extra: [], http: "HTTP %@: %@")
        let root = L10nFixtures.tree(files)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let broken = L10nAudit.run(root: root, emitted: emitted)
        expect(broken, errorContaining: [
            "key \"Form key\"", "key \"Form alert\"", "key \"Form alert OK\"", "key \"Form dialog\"", "key \"Form dialog go\"",
            "key \"Form multi\nline\"", "key \"Form raw \"quoted\" literal\"", "key \"Counted %lld things\"",
            "key \"HTTP %lld: %@\" is not in en.lproj",
            "the table has \"HTTP %@: %@\", which differs only in format specifiers",
            "NSLocalizedString",
        ], "forms the old scanner skipped")
        precondition(broken.compilerKeys == formsKeys.count, "the compiler listed every form: \(broken.compilerKeys)")

        // With the keys in every table (and the real HTTP specifier) and no NSLocalizedString it passes.
        files = tree(source: formsSource, extra: formsKeys.filter { $0 != "HTTP %lld: %@" }.map { ($0, "") }, http: "HTTP %lld: %@")
        let fixedRoot = L10nFixtures.tree(files)
        defer { try? FileManager.default.removeItem(atPath: fixedRoot) }
        let fixed = L10nAudit.run(root: fixedRoot, emitted: emitted)
        precondition(fixed.errors.isEmpty, "with every key present the forms pass: \(fixed.errors)")
        precondition(fixed.compilerKeys == formsKeys.count, "\(fixed.compilerKeys) keys from the compiler")
        print("PASS: l10n checker holds LocalizedStringKey, .alert, .confirmationDialog, multi-line and raw literals, and typed interpolations to the tables")
    }

    static func selfTests() {
        compilerBackedTests()

        // A coherent tree passes: compiled keys from the list, Main.swift from the scanner.
        let keys = ["Scan", "Move %lld items to Trash?", "%@ of %@"]
        let source = """
        import SwiftUI
        // String(localized: "Ghost in a comment")
        let s = "String(localized: \\"Ghost in a string\\")"
        struct V: View {
            var body: some View {
                Text("Scan").help("Scan")
                Text(verbatim: "Never localized")
                Text(variable)
                Button("Scan") {}
                let c = String(localized: someKey)
                let d = String(format: String(localized: "%@ of %@"), x, y)
            }
        }
        """
        let clean = L10nFixtures.audit(L10nFixtures.valid(source: source), compiled: ["Compiled.swift": keys])
        precondition(clean.errors.isEmpty, "clean tree must pass, got \(clean.errors)")
        precondition(clean.scannedFiles == ["Main.swift"] && clean.compiledFiles == 1 && clean.compilerKeys == 3, "\(clean)")

        // Nothing emitted by the compiler is an error, never a pass.
        let silent = L10nFixtures.audit(L10nFixtures.valid(), compiled: [:])
        expect(silent, errorContaining: ["the compiler listed no localized strings"], "no compiler output")

        // Missing and extra keys are listed per language.
        var files = L10nFixtures.valid()
        files["app/de.lproj/Localizable.strings"] = L10nFixtures.table([("Scan", "Scannen"), ("Stale", "Veraltet"), ("%@ of %@", "%@ von %@")])
        expect(L10nFixtures.audit(files), errorContaining: [
            "de: 1 key(s) missing", "Move %lld items to Trash?", "de: 1 key(s) not in en", "\"Stale\"",
        ], "key set drift")

        // Format specifiers: wrong type, dropped argument and mixing fail; reordering passes.
        for (bad, why) in [
            ("Move %d items to Trash?", "%lld became %d"),
            ("Move items to Trash?", "an argument was dropped"),
            ("Move %lld %lld items?", "an argument was added"),
        ] {
            files = L10nFixtures.valid(overrides: ["fr": L10nFixtures.table([("Scan", "Scan"), ("Move %lld items to Trash?", bad), ("%@ of %@", "%1$@ %2$@")])])
            expect(L10nFixtures.audit(files), errorContaining: ["fr:3: format specifiers"], why)
        }
        files = L10nFixtures.valid(overrides: ["es": L10nFixtures.table([("Scan", "Escanear"), ("Move %lld items to Trash?", "Mover %lld"), ("%@ of %@", "%@ de %1$@")])])
        expect(L10nFixtures.audit(files), errorContaining: ["es:4: mixes positional"], "mixed positional and plain")
        precondition(FormatSpecifiers.parse("100%% of %2$@ and %1$-5.2lf").byPosition == [2: "@", 1: "lf"], "%% is literal, flags and precision are skipped")
        precondition(FormatSpecifiers.parse("%@ — %@ of %@").byPosition == [1: "@", 2: "@", 3: "@"], "plain specifiers count in order")
        precondition(specifierShape("HTTP %lld: %@") == specifierShape("HTTP %@: %@") && specifierShape("a %@") != specifierShape("b %@"), "shape ignores only the specifiers")

        // Syntax errors, duplicate keys and empty values fail.
        files = L10nFixtures.valid(overrides: ["ja": "\"Scan\" = \"x\"\n"])
        expect(L10nFixtures.audit(files), errorContaining: ["ja", "expected ';'"], "missing semicolon")
        files = L10nFixtures.valid(overrides: ["tr": L10nFixtures.table([("Scan", "a"), ("Scan", "b"), ("Move %lld items to Trash?", "%lld"), ("%@ of %@", "%@ %@")])])
        expect(L10nFixtures.audit(files), errorContaining: ["duplicate key \"Scan\""], "duplicate key")
        files = L10nFixtures.valid(overrides: ["zh-Hans": L10nFixtures.table([("Scan", ""), ("Move %lld items to Trash?", "%lld"), ("%@ of %@", "%@ %@")])])
        expect(L10nFixtures.audit(files), errorContaining: ["zh-Hans.lproj/Localizable.strings:2: empty value"], "empty value")
        files = L10nFixtures.valid()
        files["app/de.lproj/Localizable.strings"] = nil
        expect(L10nFixtures.audit(files), errorContaining: ["app/de.lproj is missing"], "language directory gone")

        // Compiler keys no table holds fail with file and line; a table that differs only in a specifier is named.
        let report = L10nFixtures.audit(L10nFixtures.valid(), compiled: ["Compiled.swift": ["Not in the table", "Move %d things", "Scan"]])
        expect(report, errorContaining: ["app/Compiled.swift:1: localized key \"Not in the table\" is not in en.lproj",
                                         "app/Compiled.swift:2: localized key \"Move %d things\""], "compiler keys missing from the tables")
        let typed = L10nFixtures.audit(L10nFixtures.valid(), compiled: ["Compiled.swift": ["Move %d items to Trash?"]])
        expect(typed, errorContaining: ["the table has \"Move %lld items to Trash?\", which differs only in format specifiers"], "typed specifier mismatch")
        let otherTable = L10nFixtures.stringsdata(source: "app/Compiled.swift", keys: ["Scan"]).replacingOccurrences(of: "Localizable", with: "Errors")
        let emitted = NSTemporaryDirectory() + "l10n-emitted-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: emitted, withIntermediateDirectories: true)
        try! otherTable.write(toFile: emitted + "/Compiled.stringsdata", atomically: true, encoding: .utf8)
        let root = L10nFixtures.tree(L10nFixtures.valid())
        expect(L10nAudit.run(root: root, emitted: emitted), errorContaining: ["go to the table \"Errors\""], "another table")
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: emitted)

        // The scanner (Main.swift only) never skips what it cannot read.
        let leaky = "import Foundation\nlet a = String(localized: \"Not in the table\")\nstruct V { var body: some View { Text(\"Also missing\").help(\"Help missing\") } }\n"
        expect(L10nFixtures.audit(L10nFixtures.valid(source: leaky)), errorContaining: [
            "app/Main.swift:2: String(localized:) key \"Not in the table\" is not in en.lproj",
            "app/Main.swift:3: Text key \"Also missing\"",
            "app/Main.swift:3: .help key \"Help missing\"",
        ], "untranslatable source literals")
        let hard = "let a = String(localized: \"Move \\(n) things\")\nlet b = Text(LocalizedStringKey(\"Scan\"))\nlet c = String(localized: \"\"\"\nScan\n\"\"\")\nlet d = Text(#\"Scan\"#)\nlet e = NSLocalizedString(\"Scan\", comment: \"\")\nlet f = x.alert(\"Missing alert\", isPresented: y) {}\n"
        expect(L10nFixtures.audit(L10nFixtures.valid(source: hard)), errorContaining: [
            "app/Main.swift:1: String(localized:) \"Move \\(…) things\" has an interpolation",
            "app/Main.swift:3: String(localized:) with a multi-line or raw literal cannot be checked",
            "app/Main.swift:6: Text with a multi-line or raw literal cannot be checked",
            "app/Main.swift:7: NSLocalizedString",
            "app/Main.swift:8: .alert key \"Missing alert\"",
        ], "forms the scanner cannot read")
        precondition(L10nFixtures.audit(L10nFixtures.valid(source: "let b = Text(LocalizedStringKey(\"Scan\"))\n")).errors.isEmpty, "LocalizedStringKey with a known key passes")
        // NSLocalizedString is refused in compiled files too: the compiler does not list its keys.
        var nsFiles = L10nFixtures.valid()
        nsFiles["app/Compiled.swift"] = "let x = NSLocalizedString(\"Scan\", comment: \"\")\n"
        expect(L10nFixtures.audit(nsFiles, compiled: ["Compiled.swift": ["Scan"]]), errorContaining: ["app/Compiled.swift:1: NSLocalizedString"], "NSLocalizedString in a compiled file")

        // Listed exceptions pass (a gap with a warning); a stale line warns; a malformed one fails.
        let missing = ["Not in the table", "Move %d things", "Help missing"]
        files = L10nFixtures.valid()
        files[L10nAudit.exceptionsPath] = "# note\nnever | Not in the table\ngap | Move %d things\ngap | Help missing\ngap | Nothing uses this\n"
        let excepted = L10nFixtures.audit(files, compiled: ["Compiled.swift": missing])
        precondition(excepted.errors.isEmpty, "listed exceptions must pass: \(excepted.errors)")
        precondition(excepted.warnings.contains { $0.hasPrefix("2 source string(s) have no key") }, "gaps counted: \(excepted.warnings)")
        precondition(excepted.warnings.contains { $0.contains("\"Nothing uses this\"") }, "stale line reported: \(excepted.warnings)")
        files[L10nAudit.exceptionsPath] = "maybe | Not in the table\n"
        expect(L10nFixtures.audit(files, compiled: ["Compiled.swift": missing]), errorContaining: ["l10n-exceptions.txt:1: expected"], "malformed exception line")
        files[L10nAudit.exceptionsPath] = "gap | Move %d things\n"
        expect(L10nFixtures.audit(files, compiled: ["Compiled.swift": missing]), errorContaining: ["key \"Not in the table\" is not in en.lproj", "key \"Help missing\""], "partial exception list")

        // Identical-to-English is only a warning.
        files = L10nFixtures.valid(overrides: ["de": L10nFixtures.table([("Scan", "Scan"), ("Move %lld items to Trash?", "Move %lld items to Trash?"), ("%@ of %@", "%@ of %@")])])
        let same = L10nFixtures.audit(files)
        precondition(same.errors.isEmpty, "identical values must not fail: \(same.errors)")
        precondition(same.warnings.contains { $0.hasPrefix("de: 3 value(s) identical to English") }, "warned: \(same.warnings)")
        print("PASS: l10n checker self-tests")
    }

    static func main() {
        selfTests()
        guard CommandLine.arguments.count == 3 else {
            print("usage: L10nChecks ROOT EMITTED_DIR  (EMITTED_DIR: swiftc -emit-localized-strings-path output for app/*.swift)")
            exit(2)
        }
        let report = L10nAudit.run(root: CommandLine.arguments[1], emitted: CommandLine.arguments[2])
        print("l10n: \(report.languages.joined(separator: ", ")); \(report.keyCount) keys in en; "
            + "\(report.compilerKeys) keys from the compiler (\(report.compiledFiles) files), "
            + "\(report.scannedLiterals) literals read by the scanner in \(report.scannedFiles.joined(separator: ", "))")
        for w in report.warnings { print("WARNING: " + w) }
        for e in report.errors { print("ERROR: " + e) }
        guard report.errors.isEmpty else {
            print("FAIL: l10n: \(report.errors.count) error(s)")
            exit(1)
        }
        print("PASS: l10n tables agree on keys and format specifiers; every key app/ asks for is in them")
    }
}
