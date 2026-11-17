import Foundation

/// LFM2.5's prompt format and tool-call notation, ported from desktop llm_local.py (_render_lfm, _lfm_arg,
/// _parse_lfm_calls), which follows the chat template inside the GGUF: turns between <|im_start|> and <|im_end|>,
/// the tools listed as JSON at the end of the system prompt, and tool calls written as
/// <|tool_call_start|>[name(arg='value')]<|tool_call_end|>. Segments work as in GemmaPrompt: template markup is
/// special (it counts as the tokens it names), message text never is, so library text cannot start a turn.
enum LFMPrompt {
    // The model's reasoning-block tags, named indirectly: this file is also handled by tools that use the word as markup.
    static let thinkOpen = "<" + "think" + ">"
    static let thinkClose = "</" + "think" + ">"

    /// The model's reasoning, kept out of its answers and out of the history it is shown again (desktop _strip_lfm_thinking).
    static func stripThinking(_ t: String) -> String {
        var out = t
        while let open = out.range(of: thinkOpen), let close = out.range(of: thinkClose, range: open.upperBound..<out.endIndex) {
            out.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return pyStrip(out)
    }

    /// format_arg_value from the model's chat template: strings single-quoted with backslash escapes, the rest as JSON.
    static func arg(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "null" }
        if let s = v as? String {
            return "'" + s.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "'", with: "\\'")
                          .replacingOccurrences(of: "\n", with: "\\n")
                          .replacingOccurrences(of: "\r", with: "\\r") + "'"
        }
        return json(v)
    }

    /// Compact JSON with sorted keys, spelled as Python's json.dumps spells it (", " and ": " between parts), so a
    /// tool list or a structured argument reads the same on both platforms.
    static func json(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        if let b = v as? Bool { return b ? "true" : "false" }
        if let s = v as? String { return jsonString(s) }
        if let n = v as? NSNumber { return GemmaPrompt.pyNum(n) }
        if let d = v as? [String: Any] {
            return "{" + d.keys.sorted(by: pyLT).map { jsonString($0) + ": " + json(d[$0]!) }.joined(separator: ", ") + "}"
        }
        if let a = v as? [Any] { return "[" + a.map { json($0) }.joined(separator: ", ") + "]" }
        return jsonString("\(v)")
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for sc in s.unicodeScalars {
            switch sc {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if sc.value < 0x20 { out += String(format: "\\u%04x", sc.value) } else { out.unicodeScalars.append(sc) }
            }
        }
        return out + "\""
    }

    /// OpenAI-shaped messages to LFM2.5 segments, as the model's chat template lays them out. As in the Gemma
    /// format, the system messages before the model's first reply go together at the top, the tools listed last.
    static func render(_ msgs: [Rec], tools: [Rec]?) -> [Segment] {
        let lastUser = msgs.indices.last(where: { msgs[$0].s("role") == "user" }) ?? -1
        let firstReply = msgs.indices.first(where: { $0 > lastUser && ["assistant", "tool"].contains(msgs[$0].s("role")) }) ?? msgs.count
        let top = msgs.enumerated().filter { $0.element.s("role") == "system" && $0.offset < firstReply }.map { $0.element }
        let rest = msgs.enumerated().filter { !($0.element.s("role") == "system" && $0.offset < firstReply) }.map { $0.element }
        var system = top.map { pyStrip(GemmaPrompt.text($0)) }.joined(separator: "\n\n")
        if let tools, !tools.isEmpty {
            system += (system.isEmpty ? "" : "\n") + "List of tools: [" + tools.map { json($0) }.joined(separator: ", ") + "]"
        }
        var seg: [Segment] = []
        if !system.isEmpty {
            seg += [("<|im_start|>", true), ("system\n", false), (system, false), ("<|im_end|>", true), ("\n", false)]
        }
        for m in rest {
            seg.append(("<|im_start|>", true))
            seg.append((m.s("role") + "\n", false))
            if m.s("role") == "assistant" {
                let content = m["content"] != nil ? stripThinking(GemmaPrompt.text(m)) : ""
                if !content.isEmpty { seg.append((content, false)) }
                let calls = m["tool_calls"] as? [Rec] ?? []
                if !calls.isEmpty {
                    var parts: [String] = []
                    for c in calls {
                        let f = c["function"] as? Rec ?? [:]
                        var args: Rec = [:]
                        if let s = f["arguments"] as? String {
                            args = (try? JSONSerialization.jsonObject(with: Data((s.isEmpty ? "{}" : s).utf8))) as? Rec ?? [:]
                        } else if let d = f["arguments"] as? Rec { args = d }
                        parts.append(f.s("name") + "(" + args.keys.sorted(by: pyLT).map { "\($0)=\(arg(args[$0]))" }.joined(separator: ", ") + ")")
                    }
                    seg += [("<|tool_call_start|>", true), ("[" + parts.joined(separator: ", ") + "]", false), ("<|tool_call_end|>", true)]
                }
            } else {
                seg.append((pyStrip(GemmaPrompt.text(m)), false))
            }
            seg += [("<|im_end|>", true), ("\n", false)]
        }
        seg += [("<|im_start|>", true), ("assistant\n", false)]
        return seg
    }

    /// A rough count of tokens, on the high side, as GemmaPrompt.sizeOf counts them (desktop size_of).
    static func sizeOf(_ segs: [Segment]) -> Double {
        Double(segs.reduce(0) { $0 + $1.text.unicodeScalars.count }) / 3.2 + 8 * Double(segs.count)
    }

    // ------------------------------------------------------------------------------------------- LFM2's tool calls --
    static let CALL = #"(?s)<\|tool_call_start\|>\s*\[(.*?)\]\s*<\|tool_call_end\|>"#

    /// (text before the first call, [(name, arguments)]) from what the model wrote (desktop _parse_lfm_calls).
    static func parseCalls(_ text: String) -> (String, [(String, Rec)]) {
        let text = stripThinking(text)
        var calls: [(String, Rec)] = []
        let rx = Rx.re(CALL)
        for m in rx.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let b = Range(m.range(at: 1), in: text) else { continue }
            var p = CallParser(String(text[b]))
            if let found = try? p.calls() { calls += found }
        }
        if !calls.isEmpty {
            if let cut = text.range(of: "<|tool_call_start|>") { return (String(text[..<cut.lowerBound]), calls) }
            return (text, calls)
        }
        // The model also writes a call as the whole reply with no markers around it — [name(arg='value')] right after
        // its reasoning — which is how it answered both test questions when given this format's own rendered prompt.
        // Only a reply that is nothing but the bracketed list counts, so citations like [S1] in an answer never parse.
        let trimmed = pyStrip(text)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            var p = CallParser(String(trimmed.dropFirst().dropLast()))
            if let found = try? p.calls(), !found.isEmpty { return ("", found) }
        }
        return (text, calls)
    }

    /// Reads LFM2's tool calls: name(arg='value', arg=2, arg=["a"]) — strings single-quoted with backslash escapes,
    /// everything else as JSON (the template writes dicts and lists with tojson). Desktop _LfmCalls.
    struct CallParser {
        struct Bad: Error {}
        let s: [Character]
        var i = 0
        init(_ str: String) { s = Array(str) }

        mutating func ws() { while i < s.count, " \n\t\r".contains(s[i]) { i += 1 } }

        mutating func ident(dots: Bool) throws -> String {
            guard i < s.count, s[i] == "_" || (s[i].isLetter && s[i].isASCII) else { throw Bad() }
            var j = i + 1
            while j < s.count, s[j].isASCII, s[j].isLetter || s[j].isNumber || s[j] == "_" || s[j] == "-" || (dots && s[j] == ".") { j += 1 }
            defer { i = j }
            return String(s[i..<j])
        }

        mutating func calls() throws -> [(String, Rec)] {
            var out: [(String, Rec)] = []
            while true {
                ws()
                if i >= s.count { return out }
                let name = try ident(dots: true)
                ws()
                guard i < s.count, s[i] == "(" else { throw Bad() }
                i += 1
                out.append((name, try args()))
                ws()
                if i < s.count, s[i] == "," { i += 1 }
            }
        }

        mutating func args() throws -> Rec {
            var out: Rec = [:]
            while true {
                ws()
                if i < s.count, s[i] == ")" { i += 1; return out }
                let key = try ident(dots: false)
                ws()
                guard i < s.count, s[i] == "=" else { throw Bad() }
                i += 1
                out[key] = try value()
                ws()
                if i < s.count, s[i] == "," { i += 1 }
            }
        }

        mutating func value() throws -> Any {
            ws()
            if i < s.count, s[i] == "'" {
                i += 1
                var out = ""
                while i < s.count {
                    let c = s[i]
                    if c == "\\", i + 1 < s.count {
                        let nxt = s[i + 1]
                        out.append(nxt == "n" ? "\n" : nxt == "r" ? "\r" : nxt == "t" ? "\t" : String(nxt))
                        i += 2
                    } else if c == "'" {
                        i += 1
                        return out
                    } else {
                        out.append(c)
                        i += 1
                    }
                }
                throw Bad()
            }
            // A JSON value (string, number, true/false/null, [..] or {..}): scan to its end by depth, then read it as JSON.
            let start = i
            var depth = 0, instr = false, esc = false
            while i < s.count {
                let c = s[i]
                if instr {
                    if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { instr = false }
                } else if c == "\"" { instr = true }
                else if c == "[" || c == "{" { depth += 1 }
                else if c == "]" || c == "}" {
                    if depth == 0 { break }
                    depth -= 1
                } else if c == ",", depth == 0 { break }
                else if c == ")", depth == 0 { break }
                i += 1
            }
            guard let data = String(s[start..<i]).data(using: .utf8),
                  let v = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) else { throw Bad() }
            return v
        }
    }
}
