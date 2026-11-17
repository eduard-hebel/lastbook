import Foundation

/// LFM3's prompt format and tool-call notation, ported from desktop llm_local.py (_render_lfm3, _lfm3_arg,
/// _parse_lfm3_calls), which follows the chat template inside the GGUF: the same <|im_start|> and <|im_end|>
/// turns as LFM2, but the tools sit in a <tools> block at the end of the system prompt, a tool call is written
/// as XML (<tool_call><function=name><parameter=k>v</parameter></function></tool_call>), and a tool result is
/// wrapped in <tool_response>. The template can also open a reasoning block before the answer; the prompt
/// fills that block in empty, the template's own no-thinking path — left open, the model spent a whole
/// 1,800-token round reasoning on the hardest questions in testing and never reached an answer.
enum LFM3Prompt {
    /// render_value from the model's chat template: a string as it is, everything else as JSON.
    static func arg(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "null" }
        if let s = v as? String { return s }
        return LFMPrompt.json(v)
    }

    /// OpenAI-shaped messages to LFM3 segments, as the model's chat template lays them out. The system
    /// messages before the model's first reply go together at the top, as in the other formats, with the
    /// tools in their <tools> block last.
    static func render(_ msgs: [Rec], tools: [Rec]?) -> [Segment] {
        let lastUser = msgs.indices.last(where: { msgs[$0].s("role") == "user" }) ?? -1
        let firstReply = msgs.indices.first(where: { $0 > lastUser && ["assistant", "tool"].contains(msgs[$0].s("role")) }) ?? msgs.count
        let top = msgs.enumerated().filter { $0.element.s("role") == "system" && $0.offset < firstReply }.map { $0.element }
        let rest = msgs.enumerated().filter { !($0.element.s("role") == "system" && $0.offset < firstReply) }.map { $0.element }
        var system = top.map { pyStrip(GemmaPrompt.text($0)) }.joined(separator: "\n\n")
        if let tools, !tools.isEmpty {
            system += (system.isEmpty ? "" : "\n") + "<tools>\n" + tools.map { LFMPrompt.json($0["function"] as? Rec ?? $0) }.joined(separator: "\n") + "\n</tools>"
        }
        var seg: [Segment] = []
        if !system.isEmpty {
            seg += [("<|im_start|>", true), ("system\n", false), (system, false), ("<|im_end|>", true), ("\n", false)]
        }
        for m in rest {
            seg.append(("<|im_start|>", true))
            seg.append((m.s("role") + "\n", false))
            if m.s("role") == "assistant" {
                let content = m["content"] != nil ? LFMPrompt.stripThinking(GemmaPrompt.text(m)) : ""
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
                        parts.append("<tool_call>\n<function=" + f.s("name") + ">\n" + args.keys.sorted(by: pyLT).map {
                            "<parameter=\($0)>\n\(arg(args[$0]))\n</parameter>\n"
                        }.joined() + "</function>\n</tool_call>")
                    }
                    seg.append((parts.joined(separator: "\n\n"), false))
                }
            } else if m.s("role") == "tool" {
                seg.append(("<tool_response>\n" + pyStrip(GemmaPrompt.text(m)) + "\n</tool_response>", false))
            } else {
                seg.append((pyStrip(GemmaPrompt.text(m)), false))
            }
            seg += [("<|im_end|>", true), ("\n", false)]
        }
        seg += [("<|im_start|>", true), ("assistant\n", false), (LFMPrompt.thinkOpen + LFMPrompt.thinkClose, true)]
        return seg
    }

    /// A rough count of tokens, on the high side, as GemmaPrompt.sizeOf counts them (desktop size_of).
    static func sizeOf(_ segs: [Segment]) -> Double {
        Double(segs.reduce(0) { $0 + $1.text.unicodeScalars.count }) / 3.2 + 8 * Double(segs.count)
    }

    // ------------------------------------------------------------------------------------------- LFM3's tool calls --
    static let CALL = #"(?s)<tool_call>\s*<function=([\w.-]+)>(.*?)</function>\s*</tool_call>"#
    static let PARAM = #"(?s)<parameter=([\w-]+)>(.*?)</parameter>"#

    /// (text before the first call, [(name, arguments)]) from what the model wrote (desktop _parse_lfm3_calls).
    /// A parameter's value is the text between the newlines the template puts around it, read as JSON when it
    /// parses (a number, true, a list) and kept as the string it is otherwise.
    static func parseCalls(_ text: String) -> (String, [(String, Rec)]) {
        let text = LFMPrompt.stripThinking(text)
        var calls: [(String, Rec)] = []
        let rx = Rx.re(CALL), px = Rx.re(PARAM)
        for m in rx.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let nb = Range(m.range(at: 1), in: text), let bb = Range(m.range(at: 2), in: text) else { continue }
            let body = String(text[bb])
            var args: Rec = [:]
            for p in px.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let kb = Range(p.range(at: 1), in: body), let vb = Range(p.range(at: 2), in: body) else { continue }
                var v = String(body[vb])
                if v.hasPrefix("\n") { v.removeFirst() }
                if v.hasSuffix("\n") { v.removeLast() }
                if let data = v.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) {
                    args[String(body[kb])] = j
                } else {
                    args[String(body[kb])] = v
                }
            }
            calls.append((String(text[nb]), args))
        }
        if let cut = text.range(of: "<tool_call>") { return (String(text[..<cut.lowerBound]), calls) }
        return (text, calls)
    }
}
