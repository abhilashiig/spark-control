import Foundation

/// Coding tools that can talk to the gateway. Each gets a "spark-control" provider listing the enabled models with
/// their prices and whether they reason and take images; the rest of the tool's config is left alone.
enum ClientTool: String, CaseIterable, Identifiable {
    case kilo, pi, hermes
    var id: Self { self }
    static let provider = "spark-control"

    var name: String {
        switch self {
        case .kilo: "Kilo Code"
        case .pi: "Pi"
        case .hermes: "Hermes"
        }
    }

    /// The tool's own folder; missing = not installed.
    var folder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .kilo: return home.appending(path: ".config/kilo")
        case .pi: return home.appending(path: ".pi/agent")
        case .hermes: return home.appending(path: ".hermes")
        }
    }

    var file: URL {
        switch self {
        case .kilo:
            // Kilo reads any of these; use the one that's there.
            let names = ["kilo.jsonc", "kilo.json", "config.json"]
            return names.map { folder.appending(path: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
                ?? folder.appending(path: names[0])
        case .pi: return folder.appending(path: "models.json")
        case .hermes: return folder.appending(path: "config.yaml")
        }
    }

    struct Gateway {
        var baseURL: String
        var apiKey: String
    }

    /// `existing` with the Spark Control provider replaced by one listing `models`.
    func apply(to existing: String, models: [Recipe], gateway: Gateway) throws -> String {
        switch self {
        case .kilo:
            return try Self.mergeJSON(existing) { root in
                var providers = root["provider"] as? [String: Any] ?? [:]
                providers[Self.provider] = Self.kilo(models, gateway)
                root["provider"] = providers
            }
        case .pi:
            return try Self.mergeJSON(existing) { root in
                var providers = root["providers"] as? [String: Any] ?? [:]
                providers[Self.provider] = Self.pi(models, gateway)
                root["providers"] = providers
            }
        case .hermes:
            return try Self.replaceYAMLProvider(in: existing, block: Self.hermes(models, gateway))
        }
    }

    /// Whether `text` already has a Spark Control provider.
    func isAdded(_ text: String) -> Bool {
        switch self {
        case .kilo, .pi: text.contains("\"\(Self.provider)\"")
        case .hermes: Self.yamlProvider(in: text.components(separatedBy: "\n")) != nil
        }
    }

    // MARK: Per-tool provider entries

    /// Kilo (an OpenCode fork) only shows a request's cost with OpenRouter's SDK, which reads `usage.cost` from the
    /// response; the plain OpenAI-compatible one ignores it. `cost` also lets it price from the token counts.
    /// The OpenRouter SDK refuses to start without an API key.
    private static func kilo(_ models: [Recipe], _ g: Gateway) -> [String: Any] {
        [
            "name": "Spark Control",
            "npm": "@openrouter/ai-sdk-provider",
            "options": ["baseURL": g.baseURL, "apiKey": g.apiKey],
            "models": Dictionary(models.map { r in
                (r.apiID, [
                    "name": r.name,
                    "reasoning": r.hasReasoning,
                    "attachment": r.takesImages,
                    "tool_call": true,
                    "modalities": ["input": r.takesImages ? ["text", "image"] : ["text"], "output": ["text"]],
                    "cost": ["input": r.priceIn, "output": r.priceOut, "cache_read": r.priceCache ?? r.priceIn],
                ] as [String: Any])
            }, uniquingKeysWith: { a, _ in a }),
        ]
    }

    private static func pi(_ models: [Recipe], _ g: Gateway) -> [String: Any] {
        [
            "name": "Spark Control",
            "baseUrl": g.baseURL,
            "api": "openai-completions",
            "apiKey": g.apiKey,
            // The Spark's servers reject the developer role and reasoning_effort.
            "compat": ["supportsDeveloperRole": false, "supportsReasoningEffort": false],
            "models": models.map { r in
                [
                    "id": r.apiID, "name": r.name, "reasoning": r.hasReasoning,
                    "input": r.takesImages ? ["text", "image"] : ["text"],
                    "cost": ["input": r.priceIn, "output": r.priceOut, "cacheRead": r.priceCache ?? r.priceIn, "cacheWrite": 0],
                ] as [String: Any]
            },
        ]
    }

    /// Hermes prices requests from the gateway's /v1/models and has no per-model reasoning flag.
    private static func hermes(_ models: [Recipe], _ g: Gateway) -> [String] {
        var lines = [
            "\(provider):",
            "  name: Spark Control",
            "  base_url: \(quote(g.baseURL))",
            "  api_key: \(quote(g.apiKey))",
            "  api_mode: chat_completions",
        ]
        if let first = models.first { lines.append("  model: \(quote(first.apiID))") }
        lines.append(models.isEmpty ? "  models: {}" : "  models:")
        for r in models {
            lines += ["    \(quote(r.apiID)):", "      supports_vision: \(r.takesImages)"]
        }
        return lines
    }

    // MARK: Editing

    /// JSON (and Kilo's JSONC) round-trips through JSONSerialization: keys come out sorted and comments are dropped,
    /// which is why `write` keeps a backup.
    private static func mergeJSON(_ text: String, _ edit: (inout [String: Any]) -> Void) throws -> String {
        var root: [String: Any] = [:]
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .json5Allowed) as? [String: Any]
            else { throw ToolError.unreadable }
            root = parsed
        }
        edit(&root)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// The YAML is edited as text so every comment and setting outside our block stays exactly as it was.
    /// Assumes block-style YAML for `providers:`, which is what Hermes writes.
    static func replaceYAMLProvider(in text: String, block: [String]) throws -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        guard let p = lines.firstIndex(where: { $0.hasPrefix("providers:") }) else {
            if lines.last == "" { lines.removeLast() }
            return (lines + ["providers:"] + block.map { "  " + $0 }).joined(separator: "\n") + "\n"
        }
        let inline = lines[p].dropFirst("providers:".count).trimmingCharacters(in: .whitespaces)
        guard inline.isEmpty || inline.hasPrefix("#") || inline == "{}" else { throw ToolError.unreadable }
        if inline == "{}" { lines[p] = "providers:" }
        let indent = childIndent(lines, after: p)
        let new = block.map { indent + $0 }
        if let (start, end) = yamlProvider(in: lines) {
            lines.replaceSubrange(start..<end, with: new)
        } else {
            lines.insert(contentsOf: new, at: p + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// Line range of the spark-control entry under `providers:`, without trailing blank lines.
    private static func yamlProvider(in lines: [String]) -> (Int, Int)? {
        guard let p = lines.firstIndex(where: { $0.hasPrefix("providers:") }) else { return nil }
        let indent = childIndent(lines, after: p)
        var i = p + 1
        while i < lines.count, lines[i].isEmpty || lines[i].hasPrefix(" ") {
            if lines[i] == indent + provider + ":" {
                var end = i + 1
                while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces).isEmpty
                        || leading(lines[end]) > indent.count { end += 1 }
                while end > i + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
                return (i, end)
            }
            i += 1
        }
        return nil
    }

    private static func childIndent(_ lines: [String], after p: Int) -> String {
        let child = lines[(p + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let child, child.hasPrefix(" ") else { return "  " }
        return String(repeating: " ", count: leading(child))
    }

    private static func leading(_ s: String) -> Int { s.prefix { $0 == " " }.count }

    /// A JSON string is a valid double-quoted YAML string.
    private static func quote(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }

    enum ToolError: LocalizedError {
        case unreadable
        var errorDescription: String? { "The config file couldn't be read, so it was left unchanged." }
    }

    // MARK: Files

    enum Status: Equatable {
        case notInstalled, notAdded, upToDate, outdated, unreadable
    }

    func status(models: [Recipe], gateway: Gateway) -> Status {
        guard FileManager.default.fileExists(atPath: folder.path) else { return .notInstalled }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard isAdded(text) else { return .notAdded }
        guard let new = try? apply(to: text, models: models, gateway: gateway) else { return .unreadable }
        return new == text ? .upToDate : .outdated
    }

    /// Writes the provider in, keeping the previous file as `<name>.spark-control.bak`.
    func write(models: [Recipe], gateway: Gateway) throws {
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let new = try apply(to: old, models: models, gateway: gateway)
        guard new != old else { return }
        if !old.isEmpty {
            try old.write(to: file.appendingPathExtension("spark-control.bak"), atomically: true, encoding: .utf8)
        }
        try new.write(to: file, atomically: true, encoding: .utf8)
    }
}
