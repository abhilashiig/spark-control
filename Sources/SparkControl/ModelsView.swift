import SwiftUI

/// Every model added to Spark Control: what's loaded, the rest of the library, and the picked one's details.
/// Downloading new ones happens on each engine's page, linked below the list.
struct ModelsView: View {
    @Environment(AppState.self) private var state
    @Environment(ChatStore.self) private var chats
    @Binding var selection: Pane?
    @State private var search = ""
    @State private var picked: Recipe.ID?
    @AppStorage("modelsFilter") private var filter = "All"
    @State private var confirmDelete = false

    var body: some View {
        let shown = shown
        let loaded = shown.filter { state.phase(for: $0) != .stopped }
        let library = shown.filter { state.phase(for: $0) == .stopped }
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let n = state.notice { NoticeBanner(text: n).padding(.horizontal, 12).padding(.bottom, 20) }
                    memory.padding(.horizontal, 12).padding(.bottom, 24)
                    if !loaded.isEmpty { section("Loaded", loaded, top: 8) }
                    if !library.isEmpty { section("Library", library, top: loaded.isEmpty ? 8 : 20) }
                    if shown.isEmpty {
                        Text(state.config.recipes.isEmpty ? "No models yet. Download one from an engine below." : "No models match.")
                            .font(.system(size: 13)).foregroundStyle(Color.text2)
                            .padding(.horizontal, 12).padding(.top, 8)
                    }
                    moreModels.padding(.horizontal, 12).padding(.top, 28)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 420, maxWidth: .infinity)
            Hairline(vertical: true)
            Group {
                if let r = current { inspector(r) } else {
                    Text("No model selected").font(.system(size: 13)).foregroundStyle(Color.text2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 300)
        }
        .pageHeader("Models") {
            Segments(selection: $filter, options: filters.map { ($0, $0) })
            HeaderSearch(text: $search)
            Button { selection = .model(state.addRecipe()) } label: { Label("Add Model", systemImage: "plus") }
                .help("Add a custom model: any OpenAI-compatible server on the Spark")
        }
        .confirmationDialog("Delete “\(current?.name ?? "")”?", isPresented: $confirmDelete, presenting: current) { r in
            Button("Delete", role: .destructive) { picked = nil; state.deleteRecipe(r.id) }
        } message: { _ in
            Text("This removes the recipe from Spark Control. Nothing on the Spark is changed.")
        }
    }

    private var filters: [String] {
        let engines = Set(state.config.recipes.map(state.engineName))
        return ["All", "Running"] + ["TensorFold", "vLLM", "Ollama", "Custom"].filter(engines.contains)
    }

    private var shown: [Recipe] {
        state.config.recipes.filter { r in
            guard search.isEmpty || r.name.localizedCaseInsensitiveContains(search) else { return false }
            return switch filter {
            case "Running": state.phase(for: r) != .stopped
            case "All": true
            default: !filters.contains(filter) || state.engineName(r) == filter
            }
        }
    }

    /// The picked model, else the most recently used running one, else the first.
    private var current: Recipe? {
        state.config.recipes.first { $0.id == picked } ?? state.activeRecipe ?? state.runningRecipes.first ?? state.config.recipes.first
    }

    // MARK: Memory

    private var memory: some View {
        let total = state.sparkMemoryTotal
        let running = state.runningRecipes
        // The Spark's own reading; until the first one, what the running models are known to need.
        let used = state.spark.last?.memUsed ?? running.compactMap(state.memoryNeed).reduce(0, +)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Memory").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.text)
                Spacer()
                (Text(Self.gb(used)).foregroundStyle(Color.text).fontWeight(.medium)
                    + Text(" of \(Self.gb(total)) in use").foregroundStyle(Color.text2))
                    .font(.system(size: 12.5)).monospacedDigit()
            }
            MemoryBar(fraction: Double(used) / Double(max(1, total)), fill: Color.ink).padding(.top, 10)
            if !running.isEmpty {
                HStack(spacing: 16) {
                    ForEach(running) { r in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.ink).frame(width: 8, height: 8)
                            Text(r.name)
                        }
                    }
                }
                .font(.system(size: 12)).foregroundStyle(Color.text2).padding(.top, 8)
            }
            if let r = current, state.phase(for: r) == .stopped, r.enabled {
                let stops = state.stopsToStart(r)
                VStack(alignment: .leading, spacing: 0) {
                    if let need = state.memoryNeed(r) {
                        let after = used - stops.compactMap(state.memoryNeed).reduce(0, +) + need
                        MemoryBar(fraction: Double(after) / Double(max(1, total)), fill: .brand)
                        Text("\(r.name) needs \(Self.gb(need)). Loading it \(stops.isEmpty ? "" : "unloads \(Self.names(stops)) first, ")leaving \(Self.gb(max(0, total - after))) free.")
                            .padding(.top, 8)
                    } else {
                        Text("\(r.name)'s memory need is measured on its first start\(stops.isEmpty ? "." : ", so loading it unloads \(Self.names(stops)) first.")")
                    }
                }
                .font(.system(size: 12)).foregroundStyle(Color.text2).lineSpacing(4)
                .padding(.top, 16)
                .overlay(alignment: .top) { Hairline() }
                .padding(.top, 16)
            }
        }
    }

    // MARK: List

    private func section(_ title: String, _ recipes: [Recipe], top: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.text2)
                .padding(.horizontal, 12).padding(.top, top).padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(recipes) { row($0) }
        }
    }

    private func row(_ r: Recipe) -> some View {
        let p = state.phase(for: r)
        let on = current?.id == r.id
        return HStack(spacing: 14) {
            ModelAvatar(name: r.name, phase: p, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name.isEmpty ? "Untitled" : r.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                    .foregroundStyle(r.enabled ? Color.text : Color.text2)
                Text(meta(r)).font(.system(size: 12)).foregroundStyle(p.isFailure ? Color.danger : Color.text2).lineLimit(1)
            }
            Spacer(minLength: 8)
            if p.busy { ProgressView().controlSize(.small) }
            Text(state.memoryNeed(r).map(Self.gb) ?? "—").font(.system(size: 12.5)).foregroundStyle(Color.text2).monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(on ? Color.black.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .hoverFill(radius: 10, active: on)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { selection = .model(r.id) }
        .onTapGesture { picked = r.id }
        .contextMenu {
            if p == .ready { Button("Stop") { state.stop(r) } } else { Button("Load") { state.start(r) }.disabled(!canStart(r)) }
            Button("Settings and Benchmarks") { selection = .model(r.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Open Settings") { selection = .model(r.id) }
    }

    private func meta(_ r: Recipe) -> String {
        let p = state.phase(for: r)
        var parts = [state.engineName(r)]
        if p != .stopped && p != .ready { parts.append(p.label) }
        else if !r.enabled { parts.append("Off") }
        let ctx = context(r), dr = drafts(r)
        if ctx != "—" && ctx != "Default" { parts.append("\(ctx) context") }
        if dr != "—" && dr != "Off" { parts.append("\(dr) drafts") }
        return parts.joined(separator: "  ·  ")
    }

    private var moreModels: some View {
        let link = { (title: String) in Text(.init("[\(title)](spark-pane://\(title.lowercased()))")) }
        return (Text("Get more models from ") + link("TensorFold") + Text(", ") + link("vLLM") + Text(", ")
            + link("Ollama") + Text(" or ") + link("ComfyUI") + Text(", or ")
            + Text(.init("[connect a custom server](spark-pane://custom)")) + Text("."))
            .font(.system(size: 12)).foregroundStyle(Color.text2).lineSpacing(5)
            .tint(.brand)
            .environment(\.openURL, OpenURLAction { url in
                let panes: [String: Pane] = ["tensorfold": .tensorfold, "vllm": .vllm, "ollama": .discovered, "comfyui": .comfy]
                selection = panes[url.host()?.lowercased() ?? ""] ?? .model(state.addRecipe())
                return .handled
            })
    }

    // MARK: Details

    private func inspector(_ r: Recipe) -> some View {
        let p = state.phase(for: r)
        return GeometryReader { g in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 14) {
                        ModelAvatar(name: r.name, size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.name.isEmpty ? "Untitled" : r.name)
                                .font(.system(size: 19, weight: .semibold)).tracking(-0.3).foregroundStyle(Color.text)
                                .textSelection(.enabled)
                            Text(r.apiID).font(.system(size: 13)).foregroundStyle(Color.text2).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                                .help("The name clients ask for")
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Group {
                                if p == .stopped {
                                    Circle().strokeBorder(Color(light: 0xAEAEB2, dark: 0x636366), lineWidth: 1.5)
                                } else {
                                    Circle().fill(p == .ready ? Color.running : p.color)
                                }
                            }
                            .frame(width: 7, height: 7)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                            Text(p == .ready ? "Running" : p == .stopped ? (r.enabled ? "Not loaded" : "Off") : p.label)
                                .foregroundStyle(p.isFailure ? Color.danger : p == .stopped ? Color.text2 : Color.text3)
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                        .font(.system(size: 12.5))
                        actions(r, p)
                    }
                    VStack(spacing: 0) {
                        Hairline()
                        detail("Engine", state.engineName(r))
                        detail("Context", context(r))
                        detail("Draft model", ["—", "Off"].contains(drafts(r)) ? "None" : drafts(r))
                        detail("Memory", state.memoryNeed(r).map { "\(Self.gb($0)) of \(Self.gb(state.sparkMemoryTotal))" } ?? "—")
                        detail("On disk", disk(r).map { $0.formatted(.byteCount(style: .file)) } ?? "—")
                        detail("Port", String(state.port(of: r)))
                    }
                    if let route = state.route, let d = state.config.device {
                        let endpoint = Demo.on ? "spark.local:\(state.port(of: r))" : "\(d.host(route)):\(state.port(of: r))"
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Endpoint").font(.system(size: 12)).foregroundStyle(Color.text2)
                            HStack(spacing: 6) {
                                Text(endpoint).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text)
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                Spacer(minLength: 0)
                                CopyButton(text: endpoint).buttonStyle(GhostIconStyle(size: 26)).help("Copy endpoint")
                            }
                            .padding(.leading, 10).padding(.trailing, 4)
                            .frame(height: 32)
                            .background(Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 16) {
                        Button("Settings") { selection = .model(r.id) }.foregroundStyle(Color.brand)
                        Button("View logs") { selection = .logs }.foregroundStyle(Color.brand)
                        Spacer()
                        Button("Remove…") { confirmDelete = true }.foregroundStyle(Color.danger)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .frame(minHeight: g.size.height, alignment: .top)
            }
        }
    }

    @ViewBuilder private func actions(_ r: Recipe, _ p: Phase) -> some View {
        if p.busy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(p.label).foregroundStyle(Color.text2) }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, minHeight: 32)
        } else if p == .ready {
            HStack(spacing: 8) {
                Button("Open in Chat") {
                    chats.selection = chats.newChat(model: r.apiID, profiles: state.config.profiles)
                    selection = .chat
                }
                .buttonStyle(DesignButtonStyle())
                .disabled(!r.enabled)
                Button("Stop") { state.stop(r) }.buttonStyle(DesignButtonStyle(prominent: false))
            }
        } else {
            VStack(spacing: 8) {
                Button(p.isFailure ? "Try again" : "Load model") { state.start(r) }
                    .buttonStyle(DesignButtonStyle())
                    .disabled(!canStart(r))
                let stops = state.stopsToStart(r)
                if canStart(r), !stops.isEmpty {
                    Text("Unloads \(Self.names(stops)) first")
                } else if !r.enabled {
                    Text("Turned off in its settings")
                } else if state.route == nil {
                    Text("The Spark isn't reachable")
                }
            }
            .font(.system(size: 12)).foregroundStyle(Color.text2).multilineTextAlignment(.center)
        }
    }

    private func canStart(_ r: Recipe) -> Bool {
        r.enabled && !r.startCommand.isEmpty && state.route != nil && !state.isBusy
    }

    private func detail(_ k: String, _ v: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(k).foregroundStyle(Color.text2)
                Spacer()
                Text(v).foregroundStyle(Color.text).multilineTextAlignment(.trailing).monospacedDigit()
            }
            .font(.system(size: 13))
            .padding(.vertical, 10)
            Hairline()
        }
    }

    private func disk(_ r: Recipe) -> Int64? {
        (r.tensorfold ?? VLLM.model(r.vllm)?.key).flatMap { state.tf.models[$0]?.bytes }.flatMap { $0 > 0 ? $0 : nil }
    }

    private static func names(_ rs: [Recipe]) -> String {
        rs.map(\.name).formatted(.list(type: .and))
    }

    private func context(_ r: Recipe) -> String {
        if TensorFold.model(r.tensorfold) != nil {
            return switch TensorFold.context(of: r.startCommand) {
            case .engineDefault: "Default"
            case .window(let n): Self.tokens(n)
            case .yarn(let f): "YaRN ×\(f)"
            }
        }
        if let m = VLLM.model(r.vllm) { return Self.tokens(VLLM.context(of: r.startCommand) ?? m.window) }
        return "—"
    }

    private func drafts(_ r: Recipe) -> String {
        if let m = TensorFold.model(r.tensorfold), let source = m.drafts {
            return TensorFold.draftsOn(r.startCommand) ? (source == "MTP" ? "MTP" : "DFlash") : "Off"
        }
        if VLLM.model(r.vllm) != nil {
            let n = VLLM.drafts(of: r.startCommand)
            return n == 0 ? "Off" : "MTP ×\(n)"
        }
        return "—"
    }

    private static func gb(_ bytes: Int64) -> String { String(format: "%.0f GB", Double(bytes) / 1e9) }

    /// 262144 → "262K", 1048576 → "1M".
    static func tokens(_ n: Int) -> String {
        n >= 1_048_576 && n % 1_048_576 == 0 ? "\(n / 1_048_576)M" : "\(Int((Double(n) / 1000).rounded()))K"
    }
}

private struct MemoryBar: View {
    let fraction: Double
    let fill: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.well)
                RoundedRectangle(cornerRadius: 5).fill(fill).frame(width: g.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 10)
        .animation(.smooth, value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Memory")
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

extension AppState {
    /// Downloaded by the app, or already complete in the Spark's cache from another setup.
    func isOnSpark(_ i: CatalogItem) -> Bool {
        let st = tf.models[i.key] ?? .init()
        if st.download == .done { return true }
        // ponytail: 99% because a pull may skip a repo's non-weight files, as in the catalog rows.
        return st.download == .none && (tfSizes[i.key].map { st.bytes > 0 && st.bytes >= $0 * 99 / 100 } ?? false)
    }

    /// Which engine serves a model, for its badge.
    func engineName(_ r: Recipe) -> String {
        if r.tensorfold != nil { return "TensorFold" }
        if r.vllm != nil { return "vLLM" }
        let c = r.startCommand.lowercased()
        if c.contains("ollama") || discovered?.contains(where: { $0 == r.upstreamModel }) == true { return "Ollama" }
        if c.contains("vllm") || c.contains("flash serve") { return "vLLM" }
        if c.contains("tensorfold") { return "TensorFold" }
        return "Custom"
    }

    /// What starting `r` would stop, as `makeRoom` decides it: models on its port, then least recently used ones until
    /// its memory need fits, or everything when the need isn't known. ponytail: a preview from the last Spark reading,
    /// ignoring ComfyUI; `makeRoom` re-reads memory as it goes, so the real start may stop one more or one fewer.
    func stopsToStart(_ r: Recipe) -> [Recipe] {
        let others = runningRecipes.filter { $0.id != r.id }
        guard let need = memoryNeed(r) else { return others }
        var out = others.filter { port(of: $0) == port(of: r) }
        var free = (spark.last?.memAvailable ?? sparkMemoryTotal) + out.compactMap(memoryNeed).reduce(0, +)
        for o in others.sorted(by: { (lastUsed[$0.id] ?? .distantPast) < (lastUsed[$1.id] ?? .distantPast) })
        where free < need + Self.systemReserve && !out.contains(where: { $0.id == o.id }) {
            out.append(o)
            free += memoryNeed(o) ?? 0
        }
        return out
    }
}

/// Scales down a touch while pressed, for card-sized buttons.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
