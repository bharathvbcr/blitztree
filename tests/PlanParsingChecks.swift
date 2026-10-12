import Foundation

/// The plan parsers, with no server and no network: PartialPlanParser turns a
/// plan that is still being written into cards one by one, whatever size the
/// chunks arrive in; PlanJSON.decode reads a finished reply. The streams below
/// are the shapes models and endpoints really send (compact, pretty-printed,
/// strings full of braces and escapes, a reply cut off mid-item).
@main
struct PlanParsingChecks {
    /// One item as JSON, built here so the end offset of each item is known.
    static func json(_ title: String, detail: String = "d", group: String = "safe", bytes: Int64 = 1000,
                     paths: [String] = ["/a"], action: String = "trash", command: String = "") -> String {
        func s(_ v: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: [v], options: [.withoutEscapingSlashes])
            let array = String(decoding: data, as: UTF8.self)
            return String(array.dropFirst().dropLast())
        }
        return "{\"title\":\(s(title)),\"detail\":\(s(detail)),\"group\":\(s(group)),\"bytes\":\(bytes),"
            + "\"paths\":[\(paths.map(s).joined(separator: ","))],\"action\":\(s(action)),\"command\":\(s(command))}"
    }

    static func item(_ title: String, detail: String = "d", group: String = "safe", bytes: Int64 = 1000,
                     paths: [String] = ["/a"], action: String = "trash", command: String = "") -> PlanItemSpec {
        PlanItemSpec(title: title, detail: detail, group: group, bytes: bytes, paths: paths, action: action, command: command)
    }

    /// Items awkward for a hand-written scanner: every bracket inside a string,
    /// escaped quotes, a string ending in an escaped backslash, non-ASCII.
    static let tricky: [(json: String, spec: PlanItemSpec)] = {
        let specs = [
            item("Xcode DerivedData", detail: "Rebuilt on the next build", bytes: 2_147_483_648, paths: ["/Users/x/Library/Developer/Xcode/DerivedData"]),
            item("Remove \"legacy\" {cache} [old]", detail: "braces } ] and quotes \" inside", group: "ask", bytes: 5, paths: ["/p/}", "/p/]", "/p/{", "/p/["]),
            item("Ends in a backslash\\", detail: "C:\\Users\\x\\", paths: ["/a\\"]),
            item("日本語のフォルダ é 🌲", detail: "naïve — “quoted”", bytes: 123_456_789, paths: ["/Users/x/日本語", "/Users/x/é"]),
            item("Docker images", group: "ask", bytes: 9_000_000_000, paths: [], action: "command", command: "docker image prune -a"),
        ]
        return specs.map { (json(
            $0.title, detail: $0.detail, group: $0.group, bytes: $0.bytes, paths: $0.paths, action: $0.action, command: $0.command), $0) }
    }()

    /// `{"summary":..,"items":[..]}` and where each item's closing brace ends.
    static func plan(_ items: [String], summary: String = "3.2 GB can go", pretty: Bool = false) -> (text: String, ends: [Int]) {
        var text = "{\"summary\":\"\(summary)\",\(pretty ? "\n  " : "")\"items\":\(pretty ? " " : "")["
        var ends: [Int] = []
        for (i, one) in items.enumerated() {
            if i > 0 { text += pretty ? ",\n    " : "," } else if pretty { text += "\n    " }
            text += one
            ends.append(text.unicodeScalars.count)
        }
        text += (pretty ? "\n  ]\n}" : "]}")
        return (text, ends)
    }

    static func feed(_ chunks: [String]) -> [PlanItemSpec] {
        var parser = PartialPlanParser()
        return chunks.flatMap { parser.append($0) }
    }

    static func split(_ scalars: [Unicode.Scalar], at cuts: [Int]) -> [String] {
        var out: [String] = []
        var from = 0
        for cut in cuts + [scalars.count] {
            out.append(String(String.UnicodeScalarView(scalars[from..<cut])))
            from = cut
        }
        return out
    }

    static func main() {
        let expected = tricky.map(\.spec)
        let (compact, ends) = plan(tricky.map(\.json))
        let scalars = Array(compact.unicodeScalars)

        // 1. Whole, and cut into two at every position (inside keys, escapes, items).
        precondition(feed([compact]) == expected, "one chunk: \(feed([compact]).map(\.title))")
        for cut in 0...scalars.count {
            let got = feed(split(scalars, at: [cut]))
            precondition(got == expected, "split at \(cut) of \(scalars.count): got \(got.map(\.title))")
        }
        print("PASS: \(scalars.count + 1) two-chunk splits give the whole plan")

        // 2. One scalar at a time: each card appears when its closing brace arrives, not before.
        var parser = PartialPlanParser()
        var seen: [PlanItemSpec] = []
        for (i, s) in scalars.enumerated() {
            let fresh = parser.append(String(s))
            seen += fresh
            let complete = ends.filter { $0 <= i + 1 }.count
            precondition(seen.count == complete, "after \(i + 1) scalars: \(seen.count) cards, \(complete) items complete")
            precondition(fresh.count <= 1)
        }
        precondition(seen == expected)
        print("PASS: streamed one scalar at a time, each card arrives with its closing brace")

        // 3. Random chunk sizes, compact and pretty-printed.
        var state: UInt64 = 0xC0FFEE
        func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % n
        }
        for pretty in [false, true] {
            let text = plan(tricky.map(\.json), pretty: pretty).text
            let all = Array(text.unicodeScalars)
            for _ in 0..<300 {
                var cuts: [Int] = []
                var at = 0
                while true {
                    at += 1 + next(40)
                    if at >= all.count { break }
                    cuts.append(at)
                }
                let got = feed(split(all, at: cuts))
                precondition(got == expected, "pretty \(pretty), cuts \(cuts): got \(got.map(\.title))")
            }
        }
        print("PASS: 600 random chunkings, compact and pretty-printed")

        // 4. Bad items do not stop the stream.
        let missing = "{\"title\":\"no command\",\"detail\":\"d\",\"group\":\"safe\",\"bytes\":1,\"paths\":[],\"action\":\"trash\"}"
        let wrongType = "{\"title\":\"bytes as text\",\"detail\":\"d\",\"group\":\"safe\",\"bytes\":\"many\",\"paths\":[],\"action\":\"trash\",\"command\":\"\"}"
        let extra = json("has an extra field").dropLast() + ",\"confidence\":0.9}"
        let mixed = plan([tricky[0].json, missing, wrongType, String(extra), tricky[1].json]).text
        let kept = feed([mixed]).map(\.title)
        precondition(kept == [tricky[0].spec.title, "has an extra field", tricky[1].spec.title], "invalid items are skipped, unknown fields ignored: \(kept)")
        for cut in stride(from: 1, to: mixed.unicodeScalars.count, by: 7) {
            precondition(feed(split(Array(mixed.unicodeScalars), at: [cut])).map(\.title) == kept, "mixed stream split at \(cut)")
        }

        // 5. A reply cut off mid-item yields only the finished cards.
        let cutText = String(compact.unicodeScalars.prefix(ends[1] + 20))
        precondition(feed([cutText]) == Array(expected.prefix(2)), "a truncated third item is not emitted")
        precondition(feed([String(compact.unicodeScalars.prefix(ends[1] - 1))]) == Array(expected.prefix(1)), "an item without its closing brace is not emitted")

        // 6. Nothing after the closing bracket counts, and a finished parser stays finished.
        var done = PartialPlanParser()
        precondition(done.append(compact + "\n```\nAlso: {\"title\":\"x\"}") == expected)
        precondition(done.append(tricky[0].json).isEmpty && done.append("\"items\":[" + tricky[1].json + "]").isEmpty, "append after the end returns nothing")
        let trailing = compact.dropLast() + ",\"items\":[" + tricky[0].json + "]}"
        precondition(feed([String(trailing)]) == expected, "a second items array after the first closed is ignored")

        // 7. Where the plan sits in the reply.
        precondition(feed(["Here is the plan:\n```json\n", compact, "\n```"]) == expected, "a fence and prose before the object")
        precondition(feed(["{\"items\":[", tricky[0].json, "],\"summary\":\"later\"}"]) == [expected[0]], "summary after the items")
        precondition(feed(["{\"summary\":\"Remove \\\"items\\\" [soon]\",\"items\":[", tricky[2].json, "]}"]) == [expected[2]],
                     "the word items quoted inside the summary is not the key")
        var empty = PartialPlanParser()
        precondition(!empty.hasInput && empty.append("").isEmpty && !empty.hasInput, "an empty chunk is not input")
        precondition(empty.append("{").isEmpty && empty.hasInput, "any text counts as input")
        precondition(feed(["{\"summary\":\"nothing\",\"items\":[]}"]).isEmpty, "an empty plan has no cards")
        print("PASS: PartialPlanParser (bad items skipped, truncated replies, text around the plan, finished state)")

        // 8. The finished reply decodes to the same plan the stream produced.
        let whole = PlanJSON.decode(text: compact)
        precondition(whole?.0 == "3.2 GB can go" && whole?.1 == expected, "plain reply")
        precondition(PlanJSON.decode(text: "```json\n\(compact)\n```")?.1 == expected, "fenced reply")
        precondition(PlanJSON.decode(text: "Sure! Here is my plan:\n\(compact)\nLet me know.")?.1 == expected, "reply with prose around it")
        precondition(PlanJSON.decode(text: plan(tricky.map(\.json), pretty: true).text)?.1 == expected, "pretty-printed reply")
        precondition(PlanJSON.decode(text: "{\"items\":[]}")?.0 == "", "a missing summary reads as empty")
        precondition(PlanJSON.decode(text: "{\"summary\":\"s\"}")?.1.isEmpty == true, "a plan without items has none")
        precondition(PlanJSON.decode(text: mixed) == nil, "one invalid item fails the finished plan (the stream already showed the valid cards)")
        precondition(PlanJSON.decode(text: "{\"summary\":\"s\",\"items\":{\"title\":\"x\"}}") == nil, "items that are not an array")
        precondition(PlanJSON.decode(text: "{\"summary\":\"s\",\"items\":[1,2]}") == nil, "items that are not objects")
        precondition(PlanJSON.decode(text: "[1,2,3]") == nil && PlanJSON.decode(text: "no json at all") == nil, "not a plan")
        precondition(PlanJSON.decode(text: String(compact.unicodeScalars.dropLast(3))) == nil, "a cut-off reply does not decode")
        precondition(PlanJSON.decode(["summary": 5, "items": []])?.0 == "", "a non-string summary reads as empty")
        // Braces in the wrong order once trapped on a reversed range.
        for junk in ["}{", "}", "{", "", "}items{", "} {\"summary\":\"s\",\"items\":[]"] {
            precondition(PlanJSON.decode(text: junk) == nil, "junk decoded: \(junk)")
        }
        print("PASS: PlanJSON.decode (plain, fenced, prose-wrapped, pretty, and the refusals)")
        print("PASS: PlanParsingChecks")
    }
}
