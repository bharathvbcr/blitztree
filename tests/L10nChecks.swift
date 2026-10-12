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
    /// The key Swift writes for the literal: `\(n)` becomes `%lld`, a String `%@`.
    var pattern: NSRegularExpression {
        var p = "^"
        for part in parts {
            switch part {
            case .text(let t): p += NSRegularExpression.escapedPattern(for: t)
            case .hole: p += "%(?:\\d+\\$)?(?:@|ll[dux]|l[dux]|[dux]|lf|f|c|s)"
            }
        }
        return try! NSRegularExpression(pattern: p + "$")
    }
}

final class SourceScanner {
    static let views: Set<String> = [
        "Text", "Button", "Label", "Toggle", "Picker", "Section", "TextField", "SecureField", "Menu", "Link",
        "GroupBox", "ProgressView", "Stepper", "DisclosureGroup", "LabeledContent", "Gauge", "Slider",
    ]
    static let modifiers: Set<String> = [
        "help", "navigationTitle", "accessibilityLabel", "accessibilityHint", "accessibilityValue", "badge",
    ]

    let bytes: [UInt8]
    let file: String
    private(set) var found: [SourceKey] = []
    /// `String(localized:)` calls whose argument is not a literal: not checkable here.
    private(set) var dynamic = 0

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
            guard let call, quote < end, bytes[quote] == 34, !has(quote, "\"\"\""), let lit = literal(at: quote) else {
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
    var checkedLiterals = 0
    var literalsByCall: [String: Int] = [:]
    var dynamicCalls = 0
}

enum L10nAudit {
    static let requiredLanguages = ["en", "de", "es", "fr", "ja", "tr", "zh-Hans"]
    static let listCap = 10
    static let exceptionsPath = "tests/l10n-exceptions.txt"

    enum ExceptionKind { case never, gap }

    /// `never | text` (deliberately untranslated) and `gap | text` (missing
    /// from the tables when the check was added) lines, `#` comments. The text
    /// is the literal as the error prints it, interpolations shown as `\(…)`.
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

    static func run(root: String) -> L10nReport {
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

        // Source literals handed to the localization helper.
        var used = Set<String>()
        var exceptionsUsed = Set<String>()
        var knownGaps = Set<String>()
        let exceptions = loadExceptions(root: root, report: &report)
        let sources = ((try? fm.contentsOfDirectory(atPath: appDir)) ?? []).filter { $0.hasSuffix(".swift") }.sorted()
        for name in sources {
            guard let data = fm.contents(atPath: appDir + "/" + name), let text = String(data: data, encoding: .utf8) else {
                report.errors.append("app/\(name): unreadable, so its localized strings were not checked")
                continue
            }
            let scanner = SourceScanner(file: "app/" + name, text: text)
            scanner.scan()
            report.dynamicCalls += scanner.dynamic
            for key in scanner.found where key.hasLetters {
                report.checkedLiterals += 1
                report.literalsByCall[key.call, default: 0] += 1
                let matches: [String]
                if let plain = key.plain {
                    matches = enValues[plain] != nil ? [plain] : []
                } else {
                    let regex = key.pattern
                    matches = enValues.keys.filter {
                        regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
                    }
                }
                if matches.isEmpty {
                    let shown = key.shown
                    if let kind = exceptions[shown] {
                        exceptionsUsed.insert(shown)
                        if kind == .gap { knownGaps.insert(shown) }
                    } else {
                        report.errors.append("\(key.file):\(key.line): \(key.call) \"\(shown)\" has no key in en.lproj, so no language can translate it")
                    }
                }
                used.formUnion(matches)
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

    static func table(_ pairs: [(String, String)]) -> String {
        "/* fixture */\n" + pairs.map { "\"\($0.0)\" = \"\($0.1)\";" }.joined(separator: "\n") + "\n"
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

    static func audit(_ files: [String: String]) -> L10nReport {
        let root = tree(files)
        defer { try? FileManager.default.removeItem(atPath: root) }
        return L10nAudit.run(root: root)
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

    static func selfTests() {
        // A coherent tree passes, with source literals of every shape the app uses.
        let source = """
        import SwiftUI
        // String(localized: "Ghost in a comment")
        let s = "String(localized: \\"Ghost in a string\\")"
        struct V: View {
            var n = 3
            var body: some View {
                Text("Scan").help("Scan")
                Text(verbatim: "Never localized")
                Text(variable)
                Button("Scan") {}
                Label("\\(n) of \\(name)", systemImage: "x")
                let a = String(localized: "Move \\(n) items to Trash?")
                let b = String(localized: "\\(String(localized: "Scan")) of \\(n.description)")
                let c = String(localized: someKey)
                let d = String(format: String(localized: "%@ of %@"), x, y)
            }
        }
        """
        let clean = L10nFixtures.audit(L10nFixtures.valid(source: source))
        precondition(clean.errors.isEmpty, "clean tree must pass, got \(clean.errors)")
        precondition(clean.dynamicCalls == 1, "the non-literal String(localized:) is counted as unchecked, got \(clean.dynamicCalls)")

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

        // Source literals that no table holds fail, with file and line.
        let leaky = "import Foundation\nlet a = String(localized: \"Not in the table\")\nlet b = String(localized: \"Move \\(n) things\")\nstruct V { var body: some View { Text(\"Also missing\").help(\"Help missing\") } }\n"
        let sourceReport = L10nFixtures.audit(L10nFixtures.valid(source: leaky))
        expect(sourceReport, errorContaining: [
            "app/Main.swift:2: String(localized:) \"Not in the table\"",
            "app/Main.swift:3: String(localized:) \"Move \\(…) things\"",
            "app/Main.swift:4: Text \"Also missing\"",
            "app/Main.swift:4: .help \"Help missing\"",
        ], "untranslatable source literals")

        // Listed exceptions pass (a gap with a warning); a stale line warns; a malformed one fails.
        files = L10nFixtures.valid(source: leaky)
        files[L10nAudit.exceptionsPath] = "# note\nnever | Also missing\ngap | Not in the table\ngap | Move \\(…) things\ngap | Help missing\ngap | Nothing uses this\n"
        let excepted = L10nFixtures.audit(files)
        precondition(excepted.errors.isEmpty, "listed exceptions must pass: \(excepted.errors)")
        precondition(excepted.warnings.contains { $0.hasPrefix("3 source string(s) have no key") }, "gaps counted: \(excepted.warnings)")
        precondition(excepted.warnings.contains { $0.contains("\"Nothing uses this\"") }, "stale line reported: \(excepted.warnings)")
        files[L10nAudit.exceptionsPath] = "maybe | Not in the table\n"
        expect(L10nFixtures.audit(files), errorContaining: ["l10n-exceptions.txt:1: expected"], "malformed exception line")
        files[L10nAudit.exceptionsPath] = "gap | Move \\(…) things\n"
        expect(L10nFixtures.audit(files), errorContaining: ["\"Not in the table\" has no key", "\"Also missing\" has no key"], "partial exception list")

        // Identical-to-English is only a warning.
        files = L10nFixtures.valid(overrides: ["de": L10nFixtures.table([("Scan", "Scan"), ("Move %lld items to Trash?", "Move %lld items to Trash?"), ("%@ of %@", "%@ of %@")])])
        let same = L10nFixtures.audit(files)
        precondition(same.errors.isEmpty, "identical values must not fail: \(same.errors)")
        precondition(same.warnings.contains { $0.hasPrefix("de: 3 value(s) identical to English") }, "warned: \(same.warnings)")
        print("PASS: l10n checker self-tests")
    }

    static func main() {
        selfTests()
        let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
        let report = L10nAudit.run(root: root)
        print("l10n: \(report.languages.joined(separator: ", ")); \(report.keyCount) keys in en; "
            + "\(report.checkedLiterals) source literals checked, \(report.dynamicCalls) non-literal String(localized:) calls not checkable")
        print("l10n: literals by call: " + report.literalsByCall.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        for w in report.warnings { print("WARNING: " + w) }
        for e in report.errors { print("ERROR: " + e) }
        guard report.errors.isEmpty else {
            print("FAIL: l10n: \(report.errors.count) error(s)")
            exit(1)
        }
        print("PASS: l10n tables agree on keys and format specifiers; every app/ literal has a key")
    }
}
