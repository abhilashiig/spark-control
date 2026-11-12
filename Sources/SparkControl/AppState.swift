import SwiftUI
import Network
import ServiceManagement

enum Phase: Equatable {
    case stopped, starting, ready, stopping, offline
    case failed(String)

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .ready: "Running"
        case .stopping: "Stopping…"
        case .offline: "Spark unreachable"
        case .failed(let m): m
        }
    }
    var busy: Bool { self == .starting || self == .stopping }
}

struct LogLine: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
    let event: Bool
}

struct RouteCheck: Equatable {
    var host: String
    var ip: String?
    var ssh: Bool?
    var backend: Bool?
    var auth: Bool?
    var checking = true
}

struct AppError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor @Observable
final class AppState {
    var config: Config { didSet { configChanged(from: oldValue) } }
    var route: Route?
    var checks: [Route: RouteCheck] = [:]
    var phase = Phase.stopped
    var activeID: UUID?
    /// A model is serving on the Spark that no recipe matches.
    var external: String?
    var logs: [LogLine] = []
    var requests: [RequestEntry] = []
    var usage: [UsageRecord]
    var discovered: [String]?
    var discovering = false
    var tf = TensorFold.Status()
    /// Set while the TensorFold engine is being installed or removed; its output goes here too.
    var tfBusy = false
    var tfLog: [String] = []
    var tfSizes: [String: Int64] = [:]
    /// The benchmark in progress: which model, its output so far, and its pid on the Spark.
    var bench: (recipe: UUID, lines: [String], pid: Int?, running: Bool)?
    var benchResults = Store.loadBenchmarks()
    var gatewayError: String?
    var showSetup: Bool
    var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                event("Open at Login: \(error.localizedDescription)")
            }
        }
    }

    @ObservationIgnored private var transition: Task<Void, Error>?
    @ObservationIgnored private var gateway: Gateway?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var debounce: Task<Void, Never>?

    init() {
        var loaded = Store.loadConfig()
        for i in loaded.recipes.indices {
            loaded.recipes[i].startCommand = TensorFold.addingDrafter(to: loaded.recipes[i].startCommand, model: loaded.recipes[i].tensorfold)
        }
        config = loaded
        usage = Store.loadUsage()
        showSetup = loaded.device == nil
        let g = Gateway(state: self)
        gateway = g
        g.start(port: loaded.gateway.port, lan: loaded.gateway.allowLAN)
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        monitor.start(queue: .main)
        Task {
            while true {
                try? await Task.sleep(for: .seconds(15))
                if route == nil { await selectRoute() }
                await refresh()
            }
        }
    }

    // MARK: Derived

    var activeRecipe: Recipe? { config.recipes.first { $0.id == activeID } }
    var sshTarget: String? { route.flatMap { r in config.device?.sshTarget(r) } }
    /// Where a model is served: its own port, or the Spark's default.
    func backendBase(for r: Recipe?) -> String? { route.flatMap { config.device?.backendBase($0, port: r?.port) } }
    func port(of r: Recipe) -> Int { r.port ?? config.device?.backendPort ?? 18300 }
    var apiBaseURL: String { "http://localhost:\(config.gateway.port)/v1" }
    var isBusy: Bool { transition != nil || phase.busy || bench?.running == true }

    func phase(for r: Recipe) -> Phase { r.id == activeID ? phase : .stopped }

    var statusLine: String {
        switch phase {
        case .ready: activeRecipe.map { "\($0.name) is running" } ?? external.map { "Unknown model: \($0)" } ?? "Running"
        case .starting: "Starting \(activeRecipe?.name ?? "model")…"
        case .stopping: "Stopping \(activeRecipe?.name ?? "model")…"
        case .stopped: "No model running"
        default: phase.label
        }
    }

    var menuSymbol: String {
        switch phase {
        case .ready: "cpu.fill"
        case .failed, .offline: "exclamationmark.triangle"
        default: "cpu"
        }
    }

    // MARK: Connection

    private func configChanged(from old: Config) {
        guard config != old else { return }
        Store.save(config)
        if config.gateway.port != old.gateway.port || config.gateway.allowLAN != old.gateway.allowLAN {
            gateway?.start(port: config.gateway.port, lan: config.gateway.allowLAN)
        }
        if config.device != old.device { networkChanged() }
    }

    private func networkChanged() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await selectRoute()
            await refresh()
        }
    }

    func networkTrouble() { networkChanged() }

    func selectRoute() async {
        guard let d = config.device else { route = nil; return }
        let new: Route?
        switch d.mode {
        case .local: new = .local
        case .tailscale: new = .tailscale
        case .auto:
            if await Probe.tcp(d.host(.local), 22, timeout: 1.5) != nil { new = .local }
            else if await Probe.tcp(d.host(.tailscale), 22, timeout: 2.5) != nil { new = .tailscale }
            else { new = nil }
        }
        if new != route {
            route = new
            event(new.map { "Connected via \($0.label) (\(d.host($0)))" } ?? "Spark is unreachable on both routes")
        }
    }

    func runChecks(for d: Device) async {
        for r in Route.allCases { checks[r] = RouteCheck(host: d.host(r)) }
        await withTaskGroup(of: (Route, RouteCheck).self) { group in
            for r in Route.allCases {
                group.addTask {
                    let host = d.host(r)
                    async let ssh = Probe.tcp(host, 22)
                    async let backend = Probe.tcp(host, d.backendPort)
                    let ip = await ssh
                    var c = RouteCheck(host: host, ip: ip, ssh: ip != nil, backend: await backend != nil, checking: false)
                    if ip != nil { c.auth = await SSH.run(d.sshTarget(r), "true", timeout: 10).code == 0 }
                    return (r, c)
                }
            }
            // Drop results from an older check if the hostname was edited meanwhile.
            for await (r, c) in group where checks[r]?.host == c.host { checks[r] = c }
        }
    }

    /// Reconciles state with what's actually serving on the Spark.
    func refresh() async {
        guard transition == nil else { return }
        guard let route, let device = config.device else {
            if config.device != nil { phase = .offline }
            return
        }
        // The active model's port, or every port a model could be on when we don't know what's running.
        let ports = activeRecipe.map { [port(of: $0)] }
            ?? Array(Set([device.backendPort] + config.recipes.map(port(of:)))).sorted()
        var found: (port: Int, info: Probe.Backend)?
        for p in ports {
            let key = (activeRecipe.map { [$0] } ?? config.recipes).first { port(of: $0) == p && $0.backendKey != nil }?.backendKey
            if let info = await Probe.backend(device.backendBase(route, port: p), key: key) { found = (p, info); break }
        }
        guard transition == nil else { return }
        guard let (foundPort, info) = found else {
            if activeID != nil, phase == .ready { phase = .failed("Not responding") }
            else if activeID == nil { phase = .stopped; external = nil }
            return
        }
        if let r = activeRecipe, info.serves(r.upstreamModel) {
            learnModelID(r, info)
            phase = .ready
            external = nil
            return
        }
        let onPort = config.recipes.filter { port(of: $0) == foundPort }
        let match = onPort.first { $0.id == config.lastActive && info.serves($0.upstreamModel) }
            ?? onPort.first { !$0.upstreamModel.isEmpty && info.serves($0.upstreamModel) }
        if let match {
            if activeID != match.id { event("Detected \(match.name) running on the Spark") }
            activeID = match.id
            external = nil
        } else {
            activeID = nil
            external = info.loaded?.first ?? info.listed.first ?? "unknown"
        }
        phase = .ready
    }

    // MARK: Lifecycle

    func start(_ r: Recipe) { Task { try? await switchTo(r) } }

    func stop() { Task { await stopAndWait() } }

    func stopAndWait() async {
        try? await runTransition { [self] in
            guard activeID != nil || external != nil else { return }
            try await doStop()
        }
    }

    func switchTo(_ r: Recipe) async throws {
        try await runTransition { [self] in
            if activeID == r.id, phase == .ready { return }
            if activeID != nil || external != nil { try await doStop() }
            try await doStart(r)
        }
    }

    /// Called by the gateway before forwarding a request.
    func ensureRunning(_ r: Recipe) async throws {
        while let t = transition { _ = try? await t.value }
        if let b = bench, b.running, b.recipe != r.id {
            throw AppError("A benchmark is running on \(config.recipes.first { $0.id == b.recipe }?.name ?? "another model"). Try again when it finishes.")
        }
        if activeID == r.id {
            if phase != .ready { await refresh() }
            if phase == .ready { return }
        }
        guard config.gateway.autoSwap else {
            throw AppError("'\(r.apiID)' isn't running. Start it in Spark Control, or turn on automatic switching.")
        }
        try await switchTo(r)
        if phase != .ready { throw AppError("'\(r.apiID)' failed to start: \(phase.label)") }
    }

    /// One start/stop at a time; everyone else waits for it.
    private func runTransition(_ work: @escaping @MainActor () async throws -> Void) async throws {
        while let t = transition { _ = try? await t.value }
        let t = Task { @MainActor in
            defer { transition = nil }
            try await work()
        }
        transition = t
        try await t.value
    }

    private func doStart(_ r: Recipe) async throws {
        guard let target = sshTarget, let base = backendBase(for: r) else {
            phase = .offline
            throw AppError("The Spark is unreachable.")
        }
        activeID = r.id
        external = nil
        phase = .starting
        config.lastActive = r.id
        event("Starting \(r.name)  $ \(r.startCommand)")

        // Detach the start command so a backgrounded server can't hold the SSH session open,
        // then follow its output until it exits.
        // `;` (not `&&`) so only nohup is backgrounded and the SSH session returns at once.
        let launch = "mkdir -p /tmp/spark-control; nohup \(SSH.interactive(r.startCommand + "; echo __SPARK_EXIT__$?")) > /tmp/spark-control/start.log 2>&1 < /dev/null & echo $!"
        let res = await SSH.run(target, launch, timeout: 20)
        guard res.code == 0, let pid = res.output.split(separator: "\n").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
            let why = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .failed("SSH failed" + (why.isEmpty ? "" : ": \(why)"))
            throw AppError(phase.label)
        }
        let exit = Box<Int32?>(nil)
        Task.detached { [weak self] in
            await SSH.run(target, "tail -n +1 -f --pid=\(pid) /tmp/spark-control/start.log", timeout: r.timeout + 60) { line in
                if line.hasPrefix("__SPARK_EXIT__") { exit.value = Int32(line.dropFirst(14)) ?? -1 }
                else { self?.logFromBackground(line) }
            }
        }

        let deadline = Date().addingTimeInterval(r.timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(2))
            if let info = await Probe.backend(base, key: r.backendKey), info.serves(r.upstreamModel) {
                learnModelID(r, info)
                phase = .ready
                event("\(r.name) is ready")
                return
            }
            if let code = exit.value, code != 0 {
                phase = .failed("Start command exited with code \(code)")
                event(phase.label)
                throw AppError(phase.label)
            }
        }
        phase = .failed("Didn't become ready within \(Int(r.timeout))s")
        event(phase.label)
        throw AppError(phase.label)
    }

    /// Fills in a recipe's backend model ID the first time we see it serving.
    private func learnModelID(_ r: Recipe, _ info: Probe.Backend) {
        guard r.upstreamModel.isEmpty, let id = info.loaded?.first ?? info.listed.first,
              let i = config.recipes.firstIndex(where: { $0.id == r.id }) else { return }
        config.recipes[i].upstreamModel = id
        event("Detected backend model ID: \(id)")
    }

    private func doStop() async throws {
        guard let target = sshTarget else {
            phase = .offline
            throw AppError("The Spark is unreachable.")
        }
        guard let r = activeRecipe, let base = backendBase(for: r) else {
            phase = .failed("An unknown model (\(external ?? "?")) is using port \(config.device?.backendPort ?? 0). Stop it on the Spark first.")
            throw AppError(phase.label)
        }
        phase = .stopping
        event("Stopping \(r.name)  $ \(r.stopCommand)")
        let res = await SSH.run(target, SSH.interactive(r.stopCommand), timeout: 180) { [weak self] line in
            self?.logFromBackground(line)
        }
        if res.code != 0 { event("Stop command exited with code \(res.code)") }
        // Wait for the port to free up so the next model can bind it.
        for _ in 0..<30 {
            if await Probe.backend(base, key: r.backendKey) == nil { break }
            try? await Task.sleep(for: .seconds(2))
        }
        activeID = nil
        external = nil
        phase = .stopped
        event("\(r.name) stopped")
    }

    /// Stops the running model cleanly, then powers off the Spark. Returns an error message on failure.
    /// Without a password it tries passwordless sudo and polkit; with one, it goes to `sudo -S` over stdin
    /// and is never stored or put on a command line.
    func shutdownSpark(password: String? = nil) async -> String? {
        guard let target = sshTarget else { return "The Spark is unreachable." }
        await stopAndWait()
        event("Shutting down the Spark")
        // --no-block queues the poweroff and returns, so ssh exits cleanly before the link drops.
        let cmd = password == nil
            ? "sudo -n systemctl poweroff --no-block 2>/dev/null || systemctl poweroff --no-block --no-ask-password"
            : "sudo -S -p '' systemctl poweroff --no-block"
        let res = await SSH.run(target, cmd, timeout: 20, input: password)
        guard res.code == 0 else {
            let out = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
            event("Shutdown failed: \(out)")
            return password == nil ? "The Spark needs your password to shut down." : "Shutdown failed. Check the password.\n\n\(out)"
        }
        activeID = nil
        external = nil
        phase = .offline
        return nil
    }

    // MARK: Ollama

    func discover() async {
        guard let target = sshTarget else { return }
        discovering = true
        defer { discovering = false }
        let script = #"for d in "${OLLAMA_MODELS:-$HOME/.ollama/models}" /usr/share/ollama/.ollama/models; do find "$d/manifests" -mindepth 4 -maxdepth 4 -type f 2>/dev/null; done"#
        let res = await SSH.run(target, SSH.interactive(script), timeout: 30)
        guard res.code == 0 else {
            event("Ollama scan failed: \(res.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }
        discovered = Set(res.output.split(separator: "\n").compactMap { Transform.ollamaName(manifestPath: String($0)) }).sorted()
    }

    func recipeID(forOllama name: String) -> UUID? {
        config.recipes.first { !$0.upstreamModel.isEmpty && Transform.norm($0.upstreamModel) == Transform.norm(name) }?.id
    }

    // MARK: Recipes

    func addRecipe() -> UUID {
        let r = Recipe(name: "New Model", startCommand: "", stopCommand: "", enabled: false)
        config.recipes.append(r)
        return r.id
    }

    func addRecipe(fromOllama name: String) -> UUID {
        let short = name.split(separator: "/").last.map { String($0.split(separator: ":")[0]) } ?? name
        let r = Recipe(name: short, startCommand: "ollama-start \(name)", stopCommand: "ollama-stop",
                       upstreamModel: name, enabled: false)
        config.recipes.append(r)
        return r.id
    }

    func deleteRecipe(_ id: UUID) {
        config.recipes.removeAll { $0.id == id }
    }

    // MARK: Gateway bookkeeping

    func gatewaySnapshot() -> GatewaySnapshot {
        GatewaySnapshot(settings: config.gateway, recipes: config.recipes.filter(\.enabled),
                        active: activeRecipe, runningID: phase == .ready ? activeID : nil)
    }

    func beginRequest(method: String, path: String, model: String, body: Data) -> UUID {
        let e = RequestEntry(method: method, path: path, model: model,
                             forwarded: String(decoding: body.prefix(64 << 10), as: UTF8.self))
        requests.insert(e, at: 0)
        if requests.count > 200 { requests.removeLast() }
        return e.id
    }

    func finishRequest(_ id: UUID, status: Int, usage u: Transform.Usage?, recipe: Recipe, duration: Double,
                       ttft: Double? = nil, decodeTime: Double? = nil, error: String?) {
        let cost = u.map { Transform.cost($0, recipe) } ?? 0
        if let i = requests.firstIndex(where: { $0.id == id }) {
            requests[i].status = status
            requests[i].duration = duration
            requests[i].prompt = u?.prompt ?? 0
            requests[i].completion = u?.completion ?? 0
            requests[i].cached = u?.cached ?? 0
            requests[i].reasoning = u?.reasoning ?? 0
            requests[i].ttft = ttft
            requests[i].decodeTime = decodeTime
            requests[i].cost = cost
            requests[i].error = error
        }
        if let u {
            let rec = UsageRecord(date: Date(), model: recipe.apiID, prompt: u.prompt, completion: u.completion, cached: u.cached, reasoning: u.reasoning, cost: cost,
                                  ttft: ttft, decodeTime: decodeTime)
            usage.append(rec)
            Store.append(rec)
        }
    }

    func resetUsage() {
        usage = []
        Store.resetUsage()
    }

    // MARK: Logs

    func log(_ text: String) { append(LogLine(text: text, event: false)) }
    func event(_ text: String) { append(LogLine(text: text, event: true)) }

    nonisolated func logFromBackground(_ text: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.log(text) } }
    }

    private func append(_ line: LogLine) {
        logs.append(line)
        if logs.count > 3000 { logs.removeFirst(logs.count - 3000) }
    }
}
