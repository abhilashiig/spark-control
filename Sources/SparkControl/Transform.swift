import Foundation

/// Pure request/response rewriting. Everything passes through untouched unless a rule applies.
enum Transform {
    /// prompt includes cached tokens; completion includes reasoning tokens (OpenAI convention).
    typealias Usage = (prompt: Int, completion: Int, cached: Int, reasoning: Int)

    static func norm(_ s: String) -> String {
        let l = s.lowercased()
        return l.hasSuffix(":latest") ? String(l.dropLast(7)) : l
    }

    /// A rule value is JSON when it parses (0.6, true, {...}), otherwise plain text.
    static func value(_ s: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed)) ?? s
    }

    static let samplingKeys = ["temperature", "top_p", "top_k", "min_p", "presence_penalty", "frequency_penalty", "repetition_penalty"]

    /// Applies the recipe's rules and model rewrite. Returns the top-level keys it changed.
    @discardableResult
    static func apply(_ body: inout [String: Any], recipe: Recipe, path: String, streamUsage: Bool) -> Set<String> {
        var changed = Set<String>()
        // Before the rules, so a rule can still set one of these on purpose.
        if recipe.modelSampling {
            for k in samplingKeys where body.removeValue(forKey: k) != nil { changed.insert(k) }
        }
        if path.hasSuffix("chat/completions") { changed.formUnion(thinking(&body, recipe: recipe)) }
        for rule in recipe.rules where !rule.key.isEmpty {
            switch rule.kind {
            case .remove:
                if body.removeValue(forKey: rule.key) != nil { changed.insert(rule.key) }
            case .default:
                if body[rule.key] == nil { body[rule.key] = value(rule.value); changed.insert(rule.key) }
            case .override:
                body[rule.key] = value(rule.value); changed.insert(rule.key)
            }
        }
        if !recipe.upstreamModel.isEmpty, body["model"] as? String != recipe.upstreamModel {
            body["model"] = recipe.upstreamModel
            changed.insert("model")
        }
        if streamUsage, body["stream"] as? Bool == true, path.hasSuffix("completions") {
            var options = body["stream_options"] as? [String: Any] ?? [:]
            if options["include_usage"] == nil {
                options["include_usage"] = true
                body["stream_options"] = options
                changed.insert("stream_options")
            }
        }
        return changed
    }

    /// Standard effort names, lowest first.
    static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    static func effortLabel(_ e: String) -> String {
        switch e { case "none": "Off"; case "xhigh": "X-High"; default: e.capitalized }
    }

    /// The thinking level a client asked for, from `reasoning_effort` (Pi) or `reasoning.effort`/`enabled`
    /// (OpenRouter's SDK, Kilo), else the model's default effort, turned into something its template accepts:
    /// a name from `effortLevels` (the nearest one at or above the ask), or `enable_thinking` for on/off models
    /// and for off where the levels have no "none". Templates raise on names they don't know, so nothing else
    /// is sent. A numeric or unknown effort is the client's own business and passes untouched.
    static func thinking(_ body: inout [String: Any], recipe: Recipe) -> Set<String> {
        guard recipe.hasReasoning else { return [] }
        let r = body["reasoning"] as? [String: Any]
        if body["reasoning_effort"] != nil, !(body["reasoning_effort"] is String) { return [] }
        let asked = body["reasoning_effort"] as? String ?? r?["effort"] as? String
            ?? (r?["enabled"] as? Bool == false ? "none" : nil)
        guard let e = (asked ?? recipe.effort)?.lowercased(),
              let rank = efforts.firstIndex(of: e == "off" ? "none" : e)
        else { return [] }

        var level: String? // nil = thinking off (or on, for on/off models) through enable_thinking
        var thinks = rank > 1 // on/off models: minimal is as good as off
        if let levels = recipe.effortLevels {
            let rankOf = { efforts.firstIndex(of: $0) ?? 0 }
            let canTurnOff = !recipe.ids.contains("gpt-oss")
            if levels.contains(efforts[rank]) { level = efforts[rank] }
            else if rank == 0 && canTurnOff { level = nil }
            else { level = levels.first { rankOf($0) >= rank } ?? levels.last }
            thinks = level != nil
        }

        var changed = Set<String>()
        if let level {
            if body["reasoning_effort"] as? String != level { body["reasoning_effort"] = level; changed.insert("reasoning_effort") }
            return changed
        }
        if body.removeValue(forKey: "reasoning_effort") != nil { changed.insert("reasoning_effort") }
        var kwargs = body["chat_template_kwargs"] as? [String: Any] ?? [:]
        if kwargs["enable_thinking"] == nil { // the client's own switch wins
            kwargs["enable_thinking"] = thinks
            body["chat_template_kwargs"] = kwargs
            changed.insert("chat_template_kwargs")
        }
        return changed
    }

    /// What a forwarded body asks of thinking: Off/On, an effort level, or nil when it leaves the model's default.
    static func thinkingLabel(_ body: [String: Any]?) -> String? {
        let on = (body?["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool
        if on == false { return "Off" }
        switch body?["reasoning_effort"] {
        case let e as String: return effortLabel(e)
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): return n.stringValue
        default: return on == true ? "On" : nil
        }
    }

    /// JSONSerialization prints 0.7 as 0.69999999999999996. Swap floats for decimals of their
    /// shortest form so rewritten bodies keep the client's exact numbers.
    static func serialize(_ obj: Any) -> Data? {
        func clean(_ v: Any) -> Any {
            switch v {
            case let d as [String: Any]: return d.mapValues(clean)
            case let a as [Any]: return a.map(clean)
            case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID() && CFNumberIsFloatType(n):
                return NSDecimalNumber(string: "\(n.doubleValue)")
            default: return v
            }
        }
        return try? JSONSerialization.data(withJSONObject: clean(obj), options: [.withoutEscapingSlashes, .fragmentsAllowed])
    }

    /// Rebuilds a request body keeping the client's original bytes for every top-level field
    /// that wasn't changed. Re-serializing the whole body reorders keys inside `tools` and
    /// `messages`, which changes the rendered prompt and kills the backend's prefix cache.
    static func rebuild(_ original: Data, _ new: [String: Any], changed: Set<String>) -> Data? {
        let bytes = [UInt8](original)
        guard let members = topLevelMembers(bytes) else { return nil }
        func field(_ key: String, _ value: Data) -> Data? { serialize(key).map { $0 + Data(":".utf8) + value } }
        var parts: [Data] = []
        for m in members {
            if !changed.contains(m.key) {
                guard let f = field(m.key, Data(bytes[m.value])) else { return nil }
                parts.append(f)
            } else if let v = new[m.key] { // nil = removed by a rule
                guard let d = serialize(v), let f = field(m.key, d) else { return nil }
                parts.append(f)
            }
        }
        for key in changed.subtracting(members.map(\.key)).sorted() {
            if let v = new[key], let d = serialize(v), let f = field(key, d) { parts.append(f) }
        }
        return Data("{".utf8) + Data(parts.joined(separator: Data(",".utf8))) + Data("}".utf8)
    }

    /// Byte ranges of a JSON object's top-level values, in order. nil if it isn't a well-formed object.
    static func topLevelMembers(_ b: [UInt8]) -> [(key: String, value: Range<Int>)]? {
        var i = 0
        func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        func skipSpace() { while i < b.count, isSpace(b[i]) { i += 1 } }
        func skipString() -> Bool { // i is at the opening quote
            i += 1
            while i < b.count {
                if b[i] == 92 { i += 2; continue } // backslash escape
                if b[i] == 34 { i += 1; return true }
                i += 1
            }
            return false
        }
        skipSpace()
        guard i < b.count, b[i] == 123 else { return nil }
        i += 1
        var out: [(key: String, value: Range<Int>)] = []
        while true {
            skipSpace()
            guard i < b.count else { return nil }
            if b[i] == 125 { return out }
            if !out.isEmpty {
                guard b[i] == 44 else { return nil }
                i += 1
                skipSpace()
            }
            guard i < b.count, b[i] == 34 else { return nil }
            let keyStart = i
            guard skipString(),
                  let key = (try? JSONSerialization.jsonObject(with: Data(b[keyStart..<i]), options: .fragmentsAllowed)) as? String
            else { return nil }
            skipSpace()
            guard i < b.count, b[i] == 58 else { return nil }
            i += 1
            skipSpace()
            let start = i
            var depth = 0
            while i < b.count {
                let c = b[i]
                if c == 34 { guard skipString() else { return nil }; continue }
                if c == 123 || c == 91 { depth += 1 }
                else if c == 125 || c == 93 { if depth == 0 { break }; depth -= 1 }
                else if c == 44, depth == 0 { break }
                i += 1
            }
            var end = i
            while end > start, isSpace(b[end - 1]) { end -= 1 }
            guard end > start else { return nil }
            out.append((key, start..<end))
        }
    }

    /// The conversation in a request body, in order: OpenAI chat, Anthropic messages and Responses `input`.
    static func messages(_ body: [String: Any]) -> [(role: String, text: String)] {
        var out: [(role: String, text: String)] = []
        for key in ["system", "instructions"] {
            if let s = body[key] { let t = text(s); if !t.isEmpty { out.append(("system", t)) } }
        }
        if let s = body["input"] as? String { out.append(("user", s)) }
        for m in (body["messages"] ?? body["input"]) as? [[String: Any]] ?? [] {
            let calls = (m["tool_calls"] as? [Any] ?? []).map { text(($0 as? [String: Any])?["function"] ?? $0) }
            let t = ([text(m["content"] ?? m["output"] ?? (m["name"] != nil ? m : ""))] + calls).filter { !$0.isEmpty }
            let type = m["type"] as? String ?? ""
            out.append((m["role"] as? String ?? (type.hasSuffix("output") ? "tool" : "assistant"), t.joined(separator: "\n\n")))
        }
        return out
    }

    /// Readable text of a content value: plain text, parts, tool calls as `→ name(args)`, other parts as `[type]`.
    static func text(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let a as [Any]: return a.map(text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        case let d as [String: Any]:
            if let t = d["text"] as? String { return t }
            if let name = d["name"] as? String {
                let args = d["arguments"] ?? d["input"] ?? ""
                let s = args as? String ?? serialize(args).map { String(decoding: $0, as: UTF8.self) } ?? ""
                return "→ \(name)(\(s))"
            }
            if let c = d["content"] ?? d["output"] { return text(c) }
            return "[\(d["type"] as? String ?? "part")]"
        default: return ""
        }
    }

    /// A model's chat-title reply, minus any thinking, quotes, markdown and "Title:" prefix.
    static func chatTitle(_ raw: String) -> String? {
        var t = raw
        if let end = t.range(of: "</think>") { t = String(t[end.upperBound...]) }
        let junk = CharacterSet(charactersIn: "\"'`*#.").union(.whitespaces)
        t = (t.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? "").trimmingCharacters(in: junk)
        if t.lowercased().hasPrefix("title:") { t = String(t.dropFirst(6)).trimmingCharacters(in: junk) }
        return t.isEmpty ? nil : String(t.prefix(60))
    }

    static func usage(_ obj: [String: Any]) -> Usage? {
        guard let u = obj["usage"] as? [String: Any] else { return nil }
        let p = u["prompt_tokens"] as? Int ?? u["input_tokens"] as? Int
        let c = u["completion_tokens"] as? Int ?? u["output_tokens"] as? Int
        guard p != nil || c != nil else { return nil }
        let details = u["prompt_tokens_details"] as? [String: Any] ?? u["input_tokens_details"] as? [String: Any]
        let outDetails = u["completion_tokens_details"] as? [String: Any] ?? u["output_tokens_details"] as? [String: Any]
        return (p ?? 0, c ?? 0, details?["cached_tokens"] as? Int ?? 0, outDetails?["reasoning_tokens"] as? Int ?? 0)
    }

    /// Cached prompt tokens at the cache price, the rest of the prompt at the input price.
    static func cost(_ u: Usage, _ r: Recipe) -> Double {
        let cached = min(max(u.cached, 0), u.prompt)
        let raw = (Double(u.prompt - cached) * r.priceIn + Double(cached) * (r.priceCache ?? r.priceIn)
            + Double(u.completion) * r.priceOut) / 1_000_000
        return (raw * 1e10).rounded() / 1e10 // drop float noise like 2.8820000000000002e-05
    }

    /// Reads usage from a JSON response and, if asked, adds `usage.cost`. Data is nil when unchanged.
    static func process(_ json: Data, recipe: Recipe, inject: Bool) -> (data: Data?, usage: Usage?) {
        guard var obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let u = usage(obj) else { return (nil, nil) }
        guard inject, var dict = obj["usage"] as? [String: Any] else { return (nil, u) }
        dict["cost"] = cost(u, recipe)
        obj["usage"] = dict
        return (serialize(obj), u)
    }

    private static let dataPrefix = Data("data:".utf8)
    private static let usageKey = Data("\"usage\"".utf8)

    /// One SSE line (including its newline). Only lines carrying a usage object are touched.
    static func sseLine(_ line: Data, recipe: Recipe, inject: Bool) -> (line: Data, usage: Usage?) {
        guard line.starts(with: dataPrefix), line.range(of: usageKey) != nil else { return (line, nil) }
        let payload = String(decoding: line.dropFirst(dataPrefix.count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let (data, u) = process(Data(payload.utf8), recipe: recipe, inject: inject)
        guard let data else { return (line, u) }
        return (Data("data: ".utf8) + data + Data("\n".utf8), u)
    }

    /// True for the first SSE chunk that carries generated output (text, reasoning or a tool call).
    static func isTokenChunk(_ line: Data) -> Bool {
        guard line.starts(with: dataPrefix),
              let obj = (try? JSONSerialization.jsonObject(with: line.dropFirst(dataPrefix.count))) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first else { return false }
        if let t = choice["text"] as? String, !t.isEmpty { return true }
        guard let d = choice["delta"] as? [String: Any] else { return false }
        for k in ["content", "reasoning_content", "reasoning"] { if let s = d[k] as? String, !s.isEmpty { return true } }
        return (d["tool_calls"] as? [Any])?.isEmpty == false
    }

    /// `…/manifests/<registry>/<namespace>/<repo>/<tag>` → the name `ollama run` uses.
    static func ollamaName(manifestPath: String) -> String? {
        guard let r = manifestPath.range(of: "/manifests/") else { return nil }
        let p = manifestPath[r.upperBound...].split(separator: "/").map(String.init)
        guard p.count == 4 else { return nil }
        if p[0] == "registry.ollama.ai" {
            return p[1] == "library" ? "\(p[2]):\(p[3])" : "\(p[1])/\(p[2]):\(p[3])"
        }
        return "\(p[0])/\(p[1])/\(p[2]):\(p[3])"
    }

    /// Which app sent a request: the header Spark Control writes into the coding tools it sets up, else the name the
    /// app gives itself in X-Title, else the product in its User-Agent without the version ("OpenAI/Python 1.40" →
    /// "OpenAI/Python", "curl/8.7.1" → "curl").
    static func client(spark: String?, title: String?, userAgent: String?) -> String {
        for v in [spark, title] {
            if let v = v?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return String(v.prefix(60)) }
        }
        guard let first = userAgent?.split(separator: " ").first else { return "Unknown" }
        var parts = first.split(separator: "/")
        if parts.count > 1, let last = parts.last, last.drop(while: { $0 == "v" }).first?.isNumber == true { parts.removeLast() }
        return String(parts.joined(separator: "/").prefix(60))
    }
}
