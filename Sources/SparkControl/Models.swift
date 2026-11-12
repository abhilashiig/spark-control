import Foundation

enum RouteMode: String, Codable, CaseIterable, Identifiable {
    case auto, local, tailscale
    var id: Self { self }
    var label: String {
        switch self {
        case .auto: "Automatic"
        case .local: "Local Network"
        case .tailscale: "Tailscale"
        }
    }
}

enum Route: String, Codable, CaseIterable, Identifiable {
    case local, tailscale
    var id: Self { self }
    var label: String { self == .local ? "Local Network" : "Tailscale" }
    var shortLabel: String { self == .local ? "Local" : "Tailscale" }
    var symbol: String { self == .local ? "wifi" : "point.3.connected.trianglepath.dotted" }
}

struct Device: Codable, Equatable {
    var user = "abhi"
    var baseHost = "aitopatom-049b"
    var mode = RouteMode.auto
    var localOverride = ""
    var tailscaleOverride = ""
    var backendPort = 18300

    /// Hostname without a trailing ".local", so the Tailscale address never carries it.
    var base: String {
        let h = baseHost.trimmingCharacters(in: .whitespaces)
        return h.lowercased().hasSuffix(".local") ? String(h.dropLast(6)) : h
    }

    func host(_ route: Route) -> String {
        switch route {
        case .local: localOverride.isEmpty ? base + ".local" : localOverride
        case .tailscale: tailscaleOverride.isEmpty ? base : tailscaleOverride
        }
    }

    func sshTarget(_ route: Route) -> String { "\(user)@\(host(route))" }
    func backendBase(_ route: Route, port: Int? = nil) -> String { "http://\(host(route)):\(port ?? backendPort)" }
}

struct ParamRule: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case `default`, override, remove
        var label: String {
            switch self {
            case .default: "Default"
            case .override: "Override"
            case .remove: "Remove"
            }
        }
    }

    var id = UUID()
    var key = ""
    var kind = Kind.default
    var value = ""
}

struct Recipe: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var startCommand: String
    var stopCommand: String
    /// Model ID the backend on the Spark expects. Empty = detect on first start.
    var upstreamModel = ""
    /// USD per 1M tokens.
    var priceIn = 0.0
    var priceOut = 0.0
    /// Price for cached prompt tokens. nil = charged at the input price.
    var priceCache: Double?
    var enabled = true
    /// Port this model serves on, when it isn't the Spark's default.
    var port: Int?
    var timeout = 600.0
    var rules: [ParamRule] = []
    /// Set for models added from the TensorFold catalog: the catalog id.
    var tensorfold: String?
    /// Sent to the backend as a bearer token, replacing the client's.
    var backendKey: String?

    /// The name clients put in the `model` field.
    var apiID: String {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && !".-_".contains($0) })
            .joined(separator: "-")
    }

    func answers(to model: String) -> Bool {
        let m = model.lowercased()
        return m == apiID || m == name.lowercased()
            || (!upstreamModel.isEmpty && Transform.norm(m) == Transform.norm(upstreamModel))
    }
}

struct GatewaySettings: Codable, Equatable {
    var port = 18080
    var allowLAN = false
    var apiKey = ""
    var autoSwap = true
    var injectCost = true
    var streamUsage = true
}

struct Config: Codable, Equatable {
    var device: Device?
    var recipes: [Recipe]
    var gateway = GatewaySettings()
    var lastActive: UUID?

    static let seed = Config(device: nil, recipes: [
        Recipe(name: "Qwen3.8 Flash", startCommand: "qwen-start", stopCommand: "qwen-stop"),
        Recipe(name: "Laguna S 2.1", startCommand: "laguna-start", stopCommand: "laguna-stop",
               upstreamModel: "hf.co/mradermacher/Laguna-S-2.1-Uncensored-i1-GGUF:i1-Q4_K_M"),
        Recipe(name: "Qwen3.5 Abliterated", startCommand: "qwen35-start", stopCommand: "qwen35-stop",
               upstreamModel: "qwen35-abl"),
    ])
}

struct UsageRecord: Codable {
    var date: Date
    var model: String
    var prompt: Int
    var completion: Int
    var cached: Int?
    var reasoning: Int?
    var cost: Double
    /// Streamed requests only: seconds to the first token, and from first token to the end.
    var ttft: Double?
    var decodeTime: Double?
}

struct RequestEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let method: String
    let path: String
    let model: String
    let forwarded: String
    var status = 0
    var duration = 0.0
    var prompt = 0
    var completion = 0
    var cached = 0
    var reasoning = 0
    var cost = 0.0
    var ttft: Double?
    var decodeTime: Double?
    var error: String?
}

enum Store {
    static let dir: URL = {
        let d = URL.applicationSupportDirectory.appending(path: "Spark Control", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static let configURL = dir.appending(path: "config.json")
    static let usageURL = dir.appending(path: "usage.jsonl")

    static func loadConfig() -> Config {
        guard let data = try? Data(contentsOf: configURL) else { return .seed }
        if let c = try? JSONDecoder().decode(Config.self, from: data) { return c }
        // Never silently overwrite a config we couldn't read.
        try? FileManager.default.moveItem(at: configURL, to: dir.appending(path: "config.unreadable-\(Int(Date().timeIntervalSince1970)).json"))
        return .seed
    }

    static func save(_ c: Config) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(c).write(to: configURL, options: .atomic)
    }

    static func loadUsage() -> [UsageRecord] {
        guard let text = try? String(contentsOf: usageURL, encoding: .utf8) else { return [] }
        let d = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? d.decode(UsageRecord.self, from: Data($0.utf8)) }
    }

    static func append(_ r: UsageRecord) {
        guard var line = try? JSONEncoder().encode(r) else { return }
        line.append(10)
        if let h = try? FileHandle(forWritingTo: usageURL) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
            try? h.close()
        } else {
            try? line.write(to: usageURL)
        }
    }

    static func resetUsage() { try? FileManager.default.removeItem(at: usageURL) }

    static let benchURL = dir.appending(path: "benchmarks.json")

    /// Benchmark runs per model id, newest last.
    static func loadBenchmarks() -> [UUID: [Benchmark.Result]] {
        (try? Data(contentsOf: benchURL)).flatMap { try? JSONDecoder().decode([UUID: [Benchmark.Result]].self, from: $0) } ?? [:]
    }

    static func save(_ b: [UUID: [Benchmark.Result]]) {
        try? JSONEncoder().encode(b).write(to: benchURL, options: .atomic)
    }
}

/// Speeds are only known for streamed requests (time to first token is measurable there).
enum Speed {
    /// Prompt tokens actually computed (not from cache) per second of time-to-first-token.
    static func prefill(prompt: Int, cached: Int, ttft: Double?) -> Double? {
        guard let ttft, ttft > 0, prompt - cached > 0 else { return nil }
        return Double(prompt - cached) / ttft
    }
    /// Generated tokens (incl. reasoning) per second after the first token.
    static func decode(completion: Int, decodeTime: Double?) -> Double? {
        guard let decodeTime, decodeTime > 0, completion > 1 else { return nil }
        return Double(completion - 1) / decodeTime
    }
}
