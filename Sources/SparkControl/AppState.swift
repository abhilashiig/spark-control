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
    var isFailure: Bool { if case .failed = self { true } else { false } }
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
    /// Each model that isn't stopped, by recipe id. Several can run at once when memory and ports allow.
    var phases: [UUID: Phase] = [:]
    /// Set when the Spark can't be reached at all.
    var offline = false
    /// The most recently started or used model: the default for chat and for requests that name none.
    var activeID: UUID?
    /// When each running model last started or served a request: the least recently used stops first.
    var lastUsed: [UUID: Date] = [:]
    var comfyLastUsed: Date?
    /// A model stopped to make room for another, shown until dismissed.
    var notice: String?
    /// Bumped after writing a tool's config, so the Connect page re-reads its status.
    var toolsChanged = Date()
    @ObservationIgnored private var toolSync: Task<Void, Never>?
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
    var comfyBusy = false
    /// Spark readings, oldest first: every 2 s while the Spark page is open, every 15 s otherwise.
    var spark: [SparkMonitor.Sample] = []
    var sparkStorage: (folders: [(String, Int64)], docker: String?)?
    /// The SSH tunnel that brings ComfyUI's port to this Mac, and the Spark address it goes to.
    @ObservationIgnored var comfyTunnel: (process: Process, target: String)?
    /// The SSH tunnel to NVIDIA's DGX Dashboard (port 11000 on the Spark).
    @ObservationIgnored var dashboardTunnel: (process: Process, target: String)?
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
        loaded.recipes = loaded.recipes.map { $0.migrated(defaultPort: loaded.device?.backendPort ?? 18300) }
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
                if Date().timeIntervalSince(lastPull) > 60 { await pullModels() }
                await refresh()
                if Date().timeIntervalSince(spark.last?.date ?? .distantPast) > 10 { await sampleSpark() }
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
    var isBusy: Bool { transition != nil || bench?.running == true }

    func phase(for r: Recipe) -> Phase { phases[r.id] ?? .stopped }
    var runningRecipes: [Recipe] { config.recipes.filter { phases[$0.id] == .ready } }

    /// One phase for the whole Spark, for the menu bar: trouble first, then work in progress, then running.
    var phase: Phase {
        if offline { return .offline }
        let all = Array(phases.values)
        if let f = all.first(where: \.isFailure) { return f }
        if let b = all.first(where: \.busy) { return b }
        return all.contains(.ready) || external != nil ? .ready : .stopped
    }

    var statusLine: String {
        if offline { return Phase.offline.label }
        if let (id, p) = phases.first(where: { $0.value.busy }), let r = config.recipes.first(where: { $0.id == id }) {
            return (p == .starting ? "Starting " : "Stopping ") + r.name + "…"
        }
        let names = runningRecipes.map(\.name) + (tf.comfyRunning ? ["ComfyUI"] : []) + (external.map { ["Unknown model: \($0)"] } ?? [])
        if !names.isEmpty { return names.joined(separator: " + ") + (names.count == 1 ? " is running" : " are running") }
        if let (id, p) = phases.first(where: { $0.value.isFailure }) {
            return (config.recipes.first { $0.id == id }?.name ?? "Model") + ": " + p.label
        }
        return "No model running"
    }


    // MARK: Connection

    private func configChanged(from old: Config) {
        guard config != old else { return }
        Store.save(config)
        if (config.recipes.filter({ !$0.isBlank }) != old.recipes.filter({ !$0.isBlank }) || config.profiles != old.profiles)
            && !applyingShared {
            modelsUpdated = Date()
            pushModels()
        }
        if config.gateway.port != old.gateway.port || config.gateway.allowLAN != old.gateway.allowLAN {
            gateway?.start(port: config.gateway.port, lan: config.gateway.allowLAN)
        }
        if config.device != old.device { networkChanged() }
        if config.recipes != old.recipes || config.gateway.port != old.gateway.port || config.gateway.apiKey != old.gateway.apiKey {
            syncTools()
        }
    }

    var toolModels: [Recipe] { config.recipes.filter { $0.enabled && !$0.isBlank } }
    var toolGateway: ClientTool.Gateway {
        // Most clients refuse an empty key, so give them a harmless one when none is set.
        .init(baseURL: apiBaseURL, apiKey: config.gateway.apiKey.isEmpty ? "sk-local" : config.gateway.apiKey)
    }

    /// Adds or updates the Spark Control provider in a coding tool's config.
    func writeTool(_ tool: ClientTool) {
        do {
            try tool.write(models: toolModels, gateway: toolGateway)
            event("Updated \(tool.name)'s config with \(toolModels.count) models")
        } catch {
            event("⚠︎ Couldn't update \(tool.name): \(error.localizedDescription)")
        }
        toolsChanged = Date()
    }

    /// Keeps tools that already list Spark Control on the current models, a moment after the last edit.
    private func syncTools() {
        guard config.gateway.syncTools else { return }
        toolSync?.cancel()
        toolSync = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            for t in ClientTool.allCases where t.status(models: toolModels, gateway: toolGateway) == .outdated { writeTool(t) }
        }
    }

    private func networkChanged() {
        if let d = config.device { Route.allCases.forEach { SSH.disconnect(d.sshTarget($0)) } }
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
            if new != nil { await pullModels() }
        }
    }

    // MARK: Shared model list

    @ObservationIgnored private var applyingShared = false
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var lastPull = Date.distantPast

    /// When this Mac last changed its model list or took the Spark's. Nil until its first sync.
    private var modelsUpdated: Date? {
        get { UserDefaults.standard.object(forKey: "modelsUpdated") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "modelsUpdated") }
    }

    /// Takes the Spark's model list when it's newer than this Mac's, or saves this Mac's there when it's older or missing.
    /// ponytail: last change wins by clock; two Macs editing within the same minute can overwrite each other.
    func pullModels() async {
        guard let target = sshTarget else { return }
        lastPull = Date()
        let res = await SSH.run(target, "cat \"\(SharedModels.path)\" 2>/dev/null || true", timeout: 20)
        guard res.code == 0 else { return }
        guard let start = res.output.firstIndex(of: "{") else {
            if modelsUpdated == nil { modelsUpdated = Date() }
            pushModels()
            return
        }
        guard let shared = try? JSONDecoder().decode(SharedModels.self, from: Data(res.output[start...].utf8)) else {
            event("The model list on the Spark (~/.config/spark-control/models.json) couldn't be read; keeping this Mac's")
            return
        }
        guard let merged = shared.merged(into: config.recipes, local: modelsUpdated) else {
            // A file without profiles gets this Mac's, stamped now so the other Macs take them.
            if shared.profiles == nil { modelsUpdated = Date() }
            if let m = modelsUpdated, m > shared.updated || shared.recipes.contains(where: \.isBlank) { pushModels() }
            return
        }
        let profiles = shared.mergedProfiles(into: config.profiles, local: modelsUpdated)
        let port = config.device?.backendPort ?? 18300
        applyingShared = true
        config.recipes = merged.map { $0.migrated(defaultPort: port) }
        if let profiles { config.profiles = profiles }
        applyingShared = false
        modelsUpdated = shared.updated
        event("Loaded \(shared.recipes.count) models" + (profiles.map { " and \($0.count) chat profiles" } ?? "") + " from the Spark")
        // Push back what the Spark lacks: this Mac's own models or profiles on a first sync, or profiles at all.
        if merged.count != shared.recipes.count || profiles?.count != shared.profiles?.count || shared.profiles == nil {
            modelsUpdated = Date()
            pushModels()
        }
    }

    /// Saves the model list on the Spark, a moment after the last change.
    private func pushModels() {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let target = sshTarget, let stamp = modelsUpdated else { return }
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? e.encode(SharedModels(updated: stamp, recipes: config.recipes.filter { !$0.isBlank }, profiles: config.profiles)) else { return }
            let file = SharedModels.path
            let cmd = "mkdir -p \"$(dirname \"\(file)\")\" && cat > \"\(file).tmp\" && mv \"\(file).tmp\" \"\(file)\""
            // Detached: writing the list to ssh's stdin may block until ssh connects.
            let res = await Task.detached { await SSH.run(target, cmd, timeout: 30, input: String(decoding: data, as: UTF8.self)) }.value
            if res.code != 0 { event("Couldn't save the model list on the Spark: \(res.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
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

    /// Reconciles state with what's actually serving on the Spark, port by port.
    func refresh() async {
        guard transition == nil else { return }
        guard let route, let device = config.device else {
            offline = config.device != nil
            return
        }
        offline = false
        var foundExternal: String?
        for p in Array(Set([device.backendPort] + config.recipes.map(port(of:)))).sorted() {
            let onPort = config.recipes.filter { port(of: $0) == p }
            let key = (onPort.first { phases[$0.id] == .ready && $0.backendKey != nil } ?? onPort.first { $0.backendKey != nil })?.backendKey
            let info = await Probe.backend(device.backendBase(route, port: p), key: key)
            guard transition == nil else { return }
            guard let info else {
                for r in onPort where phases[r.id] == .ready { phases[r.id] = .failed("Not responding") }
                continue
            }
            let match = onPort.first { phases[$0.id] == .ready && info.serves($0.upstreamModel) }
                ?? onPort.first { $0.id == config.lastActive && info.serves($0.upstreamModel) }
                ?? onPort.first { !$0.upstreamModel.isEmpty && info.serves($0.upstreamModel) }
            for r in onPort where r.id != match?.id && phases[r.id] == .ready { phases[r.id] = nil }
            if let match {
                learnModelID(match, info)
                if phases[match.id] != .ready {
                    event("Detected \(match.name) running on the Spark")
                    phases[match.id] = .ready
                    lastUsed[match.id] = lastUsed[match.id] ?? Date()
                    if activeID == nil { activeID = match.id }
                }
            } else if p == device.backendPort, info.loaded?.isEmpty != true {
                foundExternal = info.loaded?.first ?? info.listed.first ?? "unknown"
            }
        }
        external = foundExternal
        if let a = activeID, phases[a] != .ready { activeID = runningRecipes.max { (lastUsed[$0.id] ?? .distantPast) < (lastUsed[$1.id] ?? .distantPast) }?.id }
    }

    // MARK: Lifecycle

    func start(_ r: Recipe) { Task { try? await switchTo(r) } }

    func stop(_ r: Recipe) { Task { await stopAndWait(r) } }

    /// Stops one model, or with nil every model this app knows is running (and an unknown one on the default port).
    func stopAndWait(_ r: Recipe? = nil) async {
        try? await runTransition { [self] in
            if let r {
                if phases[r.id] != nil { try await doStop(r) }
                return
            }
            for x in config.recipes where phases[x.id] != nil { try? await doStop(x) }
            if external != nil { try await doStopExternal() }
        }
    }

    /// Starts a model, first stopping whatever it can't run beside (same port, or not enough memory).
    func switchTo(_ r: Recipe) async throws {
        try await runTransition { [self] in
            if phases[r.id] == .ready { touch(r); return }
            let before = try await makeRoom(for: r)
            try await doStart(r)
            await measureMemory(r, availableBefore: before)
        }
    }

    /// Called by the gateway before forwarding a request.
    func ensureRunning(_ r: Recipe) async throws {
        while let t = transition { _ = try? await t.value }
        if let b = bench, b.running, b.recipe != r.id, phases[r.id] != .ready {
            throw AppError("A benchmark is running on \(config.recipes.first { $0.id == b.recipe }?.name ?? "another model"). Try again when it finishes.")
        }
        if phases[r.id] != nil, phases[r.id] != .ready { await refresh() }
        if phases[r.id] == .ready { touch(r); return }
        guard config.gateway.autoSwap else {
            throw AppError("'\(r.apiID)' isn't running. Start it in Spark Control, or turn on automatic switching.")
        }
        try await switchTo(r)
        if phases[r.id] != .ready { throw AppError("'\(r.apiID)' failed to start: \(phase(for: r).label)") }
    }

    private func touch(_ r: Recipe) {
        lastUsed[r.id] = Date()
        activeID = r.id
    }

    // MARK: Memory

    /// Kept free for DGX OS, Docker and the page cache when models share the Spark.
    static let systemReserve: Int64 = 12_000_000_000

    /// What a model needs to start: set on its page, measured on an earlier start, or vLLM's own memory setting.
    func memoryNeed(_ r: Recipe) -> Int64? {
        if let gb = r.memoryGB { return Int64(gb * 1e9) }
        if r.vllm != nil, let f = VLLM.memoryFraction(of: r.startCommand) { return Int64(f * Double(sparkMemoryTotal)) }
        return nil
    }

    /// From the catalog status or, fresher, the GPU processes the last Spark reading saw.
    var comfyRunningNow: Bool { tf.comfyRunning || spark.last?.processes.contains { $0.name == "ComfyUI" } == true }

    var sparkMemoryTotal: Int64 { spark.last?.memTotal ?? Int64(VLLM.gb10Memory) }

    /// The first port from `base` no model uses, so catalog models can run side by side.
    func freePort(from base: Int) -> Int {
        let used = Set(config.recipes.map(port(of:)))
        return (base...).first { !used.contains($0) } ?? base
    }

    /// Stops what can't run beside `r`: anything on its port, then least recently used models until its memory need
    /// fits, or everything when the need isn't known yet. Returns the free memory just before it starts.
    private func makeRoom(for r: Recipe) async throws -> Int64? {
        var stopped: [String] = []
        for o in runningRecipes where o.id != r.id && port(of: o) == port(of: r) {
            try await doStop(o)
            stopped.append("\(o.name) (same port \(port(of: r)))")
        }
        if external != nil, port(of: r) == config.device?.backendPort {
            throw AppError("An unknown model (\(external ?? "?")) is using port \(port(of: r)). Stop it on the Spark first.")
        }

        guard let need = memoryNeed(r) else {
            for o in runningRecipes where o.id != r.id { try await doStop(o); stopped.append(o.name) }
            if comfyRunningNow { await stopComfyForRoom(); stopped.append("ComfyUI") }
            warnStopped(stopped, for: r.name, why: "its memory need isn't known until it has run once")
            await sampleSpark()
            return spark.last?.memAvailable
        }
        try await freeMemory(need, for: r.name, keep: r.id, stopped: &stopped)
        warnStopped(stopped, for: r.name, why: "it needs the memory")
        return spark.last?.memAvailable
    }

    /// Makes room for ComfyUI under the same one-at-a-time lock as model starts. Returns what it stopped.
    func makeRoomForComfy(_ need: Int64) async throws -> [String] {
        let out = Box<[String]>([])
        try await runTransition { [self] in
            var stopped: [String] = []
            try await freeMemory(need, for: "ComfyUI", keepComfy: true, stopped: &stopped)
            out.value = stopped
        }
        return out.value
    }

    /// Stops least recently used models (ComfyUI included, unless it's the one starting) until `need` plus the
    /// system reserve is free. `keep` is the model being started.
    func freeMemory(_ need: Int64, for name: String, keep: UUID? = nil, keepComfy: Bool = false, stopped: inout [String]) async throws {
        while true {
            await sampleSpark()
            let free = spark.last?.memAvailable ?? sparkMemoryTotal
            if free >= need + Self.systemReserve { return }
            var candidates: [(name: String, used: Date, stop: () async throws -> Void)] =
                runningRecipes.filter { $0.id != keep }.map { o in (o.name, lastUsed[o.id] ?? .distantPast, { try await self.doStop(o) }) }
            if comfyRunningNow && !keepComfy { candidates.append(("ComfyUI", comfyLastUsed ?? .distantPast, { await self.stopComfyForRoom() })) }
            guard let victim = candidates.min(by: { $0.used < $1.used }) else {
                warnStopped(stopped, for: name, why: "it needs more memory")
                throw AppError(String(format: "%@ needs %.0f GB but only %.0f GB is free (keeping %.0f GB for the system). Lower its memory on its page, or stop something on the Spark.",
                                      name, Double(need) / 1e9, Double(free) / 1e9, Double(Self.systemReserve) / 1e9))
            }
            try await victim.stop()
            stopped.append(victim.name)
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func stopComfyForRoom() async {
        guard let target = sshTarget else { return }
        _ = await SSH.run(target, "bash -c \(SSH.quote(ComfyUI.stopCommand))", timeout: 30)
        comfyCloseTunnel()
        tf.comfyRunning = false
    }

    private func warnStopped(_ names: [String], for name: String, why: String) {
        guard !names.isEmpty else { return }
        notice = "Stopped \(names.joined(separator: ", ")) to start \(name): \(why)."
        event("⚠︎ " + notice!)
    }

    /// Learns a model's memory need from the drop in free memory over its start, unless it was set on its page.
    private func measureMemory(_ r: Recipe, availableBefore before: Int64?) async {
        guard let before, r.vllm == nil, phases[r.id] == .ready, let i = config.recipes.firstIndex(where: { $0.id == r.id }),
              config.recipes[i].memoryGB == nil || config.recipes[i].memoryMeasured else { return }
        try? await Task.sleep(for: .seconds(3))
        await sampleSpark()
        guard let after = spark.last?.memAvailable, before - after > 1_000_000_000 else { return }
        // ponytail: one reading after start; models that load lazily (Ollama) or grow later read low.
        let gb = (Double(before - after) / 1e9 + 2).rounded(.up)
        config.recipes[i].memoryGB = gb
        config.recipes[i].memoryMeasured = true
        event(String(format: "Measured %@ at about %.0f GB of memory", r.name, gb))
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
            offline = true
            throw AppError("The Spark is unreachable.")
        }
        phases[r.id] = .starting
        touch(r)
        config.lastActive = r.id
        event("Starting \(r.name)  $ \(r.startCommand)")

        // Detach the start command so a backgrounded server can't hold the SSH session open,
        // then follow its output until it exits. One log per model, since several can start over time.
        // `;` (not `&&`) so only nohup is backgrounded and the SSH session returns at once.
        let log = "/tmp/spark-control/start-\(r.id.uuidString.prefix(8)).log"
        let launch = "mkdir -p /tmp/spark-control; nohup \(SSH.interactive(r.startCommand + "; echo __SPARK_EXIT__$?")) > \(log) 2>&1 < /dev/null & echo $!"
        let res = await SSH.run(target, launch, timeout: 20)
        guard res.code == 0, let pid = res.output.split(separator: "\n").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
            let why = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
            phases[r.id] = .failed("SSH failed" + (why.isEmpty ? "" : ": \(why)"))
            throw AppError(phase(for: r).label)
        }
        let exit = Box<Int32?>(nil)
        Task.detached { [weak self] in
            await SSH.run(target, "tail -n +1 -f --pid=\(pid) \(log)", timeout: r.timeout + 60) { line in
                if line.hasPrefix("__SPARK_EXIT__") { exit.value = Int32(line.dropFirst(14)) ?? -1 }
                else { self?.logFromBackground(line) }
            }
        }

        let deadline = Date().addingTimeInterval(r.timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(2))
            if let info = await Probe.backend(base, key: r.backendKey), info.serves(r.upstreamModel) {
                learnModelID(r, info)
                phases[r.id] = .ready
                event("\(r.name) is ready")
                return
            }
            if let code = exit.value, code != 0 {
                phases[r.id] = .failed("Start command exited with code \(code)")
                event(phase(for: r).label)
                throw AppError(phase(for: r).label)
            }
        }
        phases[r.id] = .failed("Didn't become ready within \(Int(r.timeout))s")
        event(phase(for: r).label)
        throw AppError(phase(for: r).label)
    }

    /// Fills in a recipe's backend model ID the first time we see it serving.
    private func learnModelID(_ r: Recipe, _ info: Probe.Backend) {
        guard r.upstreamModel.isEmpty, let id = info.loaded?.first ?? info.listed.first,
              let i = config.recipes.firstIndex(where: { $0.id == r.id }) else { return }
        config.recipes[i].upstreamModel = id
        event("Detected backend model ID: \(id)")
    }

    private func doStop(_ r: Recipe) async throws {
        guard let target = sshTarget, let base = backendBase(for: r) else {
            offline = true
            throw AppError("The Spark is unreachable.")
        }
        phases[r.id] = .stopping
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
        phases[r.id] = nil
        lastUsed[r.id] = nil
        if activeID == r.id { activeID = runningRecipes.max { (lastUsed[$0.id] ?? .distantPast) < (lastUsed[$1.id] ?? .distantPast) }?.id }
        event("\(r.name) stopped")
    }

    private func doStopExternal() async throws {
        throw AppError("An unknown model (\(external ?? "?")) is using port \(config.device?.backendPort ?? 0). Stop it on the Spark first.")
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
        phases = [:]
        activeID = nil
        external = nil
        offline = true
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
                        active: activeRecipe, running: Set(runningRecipes.map(\.id)))
    }

    func beginRequest(method: String, path: String, model: String, client: String, userAgent: String, body: Data) -> UUID {
        let e = RequestEntry(method: method, path: path, model: model, client: client, userAgent: userAgent,
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
            let rec = UsageRecord(date: Date(), model: recipe.apiID, client: requests.first { $0.id == id }?.client, prompt: u.prompt, completion: u.completion, cached: u.cached, reasoning: u.reasoning, cost: cost,
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
