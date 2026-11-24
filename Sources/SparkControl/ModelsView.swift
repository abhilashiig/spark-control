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
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let n = state.notice { NoticeBanner(text: n) }
                    memory.card(padding: 18)
                    table(shown)
                    moreModels
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 380, maxWidth: .infinity)
            Hairline(vertical: true)
            Group {
                if let r = current { inspector(r) } else {
                    Text("No model selected").font(.system(size: 13)).foregroundStyle(Color.text2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 300)
            .background(Color.sidebar)
        }
        .pageHeader("Models") {
            Segments(selection: $filter, options: filters.map { ($0, $0) })
            HeaderSearch(text: $search, prompt: "Search models", width: 180)
            Button { selection = .model(state.addRecipe()) } label: { Label("Add Model", systemImage: "plus") }
                .labelStyle(.titleAndIcon)
                .buttonStyle(DesignButtonStyle(height: 34))
                .fixedSize()
                .help("Add custom model")
        }
        .confirmationDialog("Delete “\(current?.name ?? "")”?", isPresented: $confirmDelete, presenting: current) { r in
            Button("Delete", role: .destructive) { picked = nil; state.deleteRecipe(r.id) }
        } message: { _ in
            Text("Nothing on the Spark is changed.")
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
        let reserve = AppState.systemReserve
        let models = running.compactMap(state.memoryNeed).reduce(0, +)
        let committed = models + reserve
        let segments: [(String, Color, Int64)] = running.compactMap { r in state.memoryNeed(r).map { (r.name, EngineBadge.color(state.engineName(r)), $0) } }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Unified memory").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.text)
                Text("Models run side by side when they fit").font(.system(size: 13)).foregroundStyle(Color.text3)
                    .lineLimit(1)
                Spacer(minLength: 8)
                (Text(Self.num(committed)).foregroundStyle(Color.text).fontWeight(.medium)
                    + Text(" / \(Self.gb(total)) committed").foregroundStyle(Color.text3))
                    .font(.system(size: 13, design: .monospaced))
                    .fixedSize()
            }
            GeometryReader { g in
                let w = { (b: Int64) in max(2, g.size.width * Double(b) / Double(max(1, total))) }
                HStack(spacing: 2) {
                    ForEach(segments, id: \.0) { _, color, bytes in Rectangle().fill(color).frame(width: w(bytes)) }
                    Rectangle().fill(Hatch()).frame(width: w(reserve))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.well)
                .clipShape(RoundedRectangle(cornerRadius: .corner(999)))
            }
            .frame(height: 10)
            .animation(.smooth, value: committed)
            .accessibilityElement()
            .accessibilityLabel("Memory committed")
            .accessibilityValue("\(Self.gb(committed)) of \(Self.gb(total))")
            FlowLayout {
                ForEach(segments, id: \.0) { name, color, bytes in legend(name, Self.gb(bytes)) { RoundedRectangle(cornerRadius: .corner(2)).fill(color) } }
                legend("System reserve", Self.gb(reserve)) { RoundedRectangle(cornerRadius: .corner(2)).fill(Color(light: 0xD4D4D8, dark: 0x3A3A42)) }
                legend("Free for models", Self.gb(max(0, total - committed))) {
                    RoundedRectangle(cornerRadius: .corner(2)).fill(Color.well).overlay(RoundedRectangle(cornerRadius: .corner(2)).strokeBorder(Color(light: 0xD4D4D8, dark: 0x3A3A42)))
                }
            }
            if let r = current, state.phase(for: r) == .stopped, r.enabled {
                let stops = state.stopsToStart(r)
                Group {
                    if let need = state.memoryNeed(r) {
                        let after = committed - stops.compactMap(state.memoryNeed).reduce(0, +) + need
                        Text("\(r.name) needs \(Self.gb(need)). Loading it \(stops.isEmpty ? "" : "unloads \(Self.names(stops)) first, ")leaving \(Self.gb(max(0, total - after))) free.")
                    } else {
                        Text("\(r.name)'s memory need is measured on its first start\(stops.isEmpty ? "." : ", so loading it unloads \(Self.names(stops)) first.")")
                    }
                }
                .font(.system(size: 12)).foregroundStyle(Color.text3).lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Hairline() }
            }
        }
    }

    private func legend(_ name: String, _ value: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 8) {
            swatch().frame(width: 8, height: 8)
            Text(name).foregroundStyle(Color.text3)
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text)
        }
        .font(.system(size: 12.5))
        .lineLimit(1)
    }

    // MARK: List

    /// Running models first. Narrow windows drop Context and Speculative, then Engine and Fit.
    private func table(_ recipes: [Recipe]) -> some View {
        let rows = recipes.filter { state.phase(for: $0) != .stopped } + recipes.filter { state.phase(for: $0) == .stopped }
        return VStack(spacing: 0) {
            if rows.isEmpty {
                Text(state.config.recipes.isEmpty ? "No models yet. Download one from an engine below." : "No models match.")
                    .font(.system(size: 13)).foregroundStyle(Color.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            } else {
                ViewThatFits(in: .horizontal) {
                    columns(rows, level: 2)
                    columns(rows, level: 1)
                    columns(rows, level: 0)
                }
            }
        }
        .background(Color(light: 0xFFFFFF, dark: 0x0F0F11), in: RoundedRectangle(cornerRadius: .corner(14), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .corner(14), style: .continuous).strokeBorder(Color.cardBorder))
    }

    private func columns(_ rows: [Recipe], level: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Model").frame(minWidth: 180, idealWidth: 180, maxWidth: .infinity, alignment: .leading)
                if level >= 1 { Text("Engine").frame(width: 96, alignment: .leading) }
                if level >= 2 {
                    Text("Context").frame(width: 76, alignment: .leading)
                    Text("Speculative").frame(width: 84, alignment: .leading)
                }
                Text("Memory").frame(width: 60, alignment: .trailing)
                if level >= 1 { Text("Fit").frame(width: 120, alignment: .leading) }
                Color.clear.frame(width: 70, height: 1)
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.text2)
            .padding(.horizontal, 18).padding(.vertical, 10)
            Hairline()
            ForEach(rows) { r in
                row(r, level: level)
                if r.id != rows.last?.id { Rectangle().fill(Color(light: 0xF4F4F5, dark: 0x1A1A1E)).frame(height: 1) }
            }
        }
    }

    private func row(_ r: Recipe, level: Int) -> some View {
        let p = state.phase(for: r)
        let on = current?.id == r.id
        return HStack(spacing: 12) {
            HStack(spacing: 12) {
                ModelAvatar(name: r.name, phase: p, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name.isEmpty ? "Untitled" : r.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .foregroundStyle(r.enabled ? Color.text : Color.text2)
                    Text(source(r)).font(.system(size: 12)).foregroundStyle(p.isFailure ? Color.danger : Color.text2).lineLimit(1)
                }
            }
            .frame(minWidth: 180, idealWidth: 180, maxWidth: .infinity, alignment: .leading)
            if level >= 1 { EngineBadge(name: state.engineName(r)).frame(width: 96, alignment: .leading) }
            if level >= 2 {
                Text(context(r)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(light: 0x3F3F46, dark: 0xD4D4D8))
                    .frame(width: 76, alignment: .leading)
                Text(["—", "Off"].contains(drafts(r)) ? "—" : drafts(r)).font(.system(size: 12)).foregroundStyle(Color(light: 0x3F3F46, dark: 0xD4D4D8))
                    .frame(width: 84, alignment: .leading)
            }
            Text(state.memoryNeed(r).map(Self.gb) ?? "—").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text)
                .frame(width: 60, alignment: .trailing)
            if level >= 1 {
                let (fit, color) = fit(r, p)
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(fit).lineLimit(1)
                }
                .font(.system(size: 12)).foregroundStyle(color == Color.text2 ? Color.text3 : color)
                .frame(width: 120, alignment: .leading)
            }
            rowAction(r, p).frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(on ? Color.overlay(0.05) : p == .ready ? Color(light: 0xFAFAFA, dark: 0x15151A) : .clear)
        .hoverFill(Color.overlay(0.025), radius: 0, active: on)
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

    @ViewBuilder private func rowAction(_ r: Recipe, _ p: Phase) -> some View {
        if p.busy {
            ProgressView().controlSize(.small)
        } else if p == .ready {
            Button("Chat") { openChat(r) }.buttonStyle(PillButtonStyle(filled: true)).disabled(!r.enabled)
        } else {
            Button("Start") { picked = r.id; state.start(r) }.buttonStyle(PillButtonStyle()).disabled(!canStart(r))
        }
    }

    private func openChat(_ r: Recipe) {
        chats.selection = chats.newChat(model: r.apiID, profiles: state.config.profiles)
        selection = .chat
    }

    private func fit(_ r: Recipe, _ p: Phase) -> (String, Color) {
        if p == .ready { return ("Loaded", Color.running) }
        if p.isFailure { return ("Failed", Color.danger) }
        if p.busy { return (p.label, VizColor.warning) }
        if !r.enabled { return ("Off", Color.text2) }
        let stops = state.stopsToStart(r)
        if stops.isEmpty { return ("Fits now", Color.text2) }
        return ("Stops \(stops.count) model\(stops.count == 1 ? "" : "s")", VizColor.warning)
    }

    private func source(_ r: Recipe) -> String {
        let p = state.phase(for: r)
        if p.isFailure { return p.label }
        if !r.upstreamModel.isEmpty && r.upstreamModel != r.name { return r.upstreamModel }
        return r.apiID
    }

    private var moreModels: some View {
        let link = { (title: String) in Text(.init("[\(title)](spark-pane://\(title.lowercased()))")) }
        return (Text("Get more models from ") + link("TensorFold") + Text(", ") + link("vLLM") + Text(", ")
            + link("Ollama") + Text(" or ") + link("ComfyUI") + Text(", or ")
            + Text(.init("[connect a custom server](spark-pane://custom)")) + Text("."))
            .font(.system(size: 13)).foregroundStyle(Color.text3).lineSpacing(5)
            .tint(.link)
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
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Text(ModelAvatar.tag(r.name))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(EngineBadge.text(state.engineName(r)))
                            .minimumScaleFactor(0.6).lineLimit(1).padding(.horizontal, 3)
                            .frame(width: 44, height: 44)
                            .background(EngineBadge.color(state.engineName(r)).opacity(0.12), in: RoundedRectangle(cornerRadius: .corner(11), style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: .corner(11), style: .continuous).strokeBorder(EngineBadge.color(state.engineName(r)).opacity(0.3)))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.name.isEmpty ? "Untitled" : r.name)
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.text)
                                .textSelection(.enabled)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle().fill(p == .stopped ? Color.text2 : p == .ready ? Color.running : p.color)
                                    .frame(width: 6, height: 6)
                                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                                Text((p == .ready ? "Running" : p == .stopped ? (r.enabled ? "Not loaded" : "Off") : p.label) + " · " + state.engineName(r))
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(p.isFailure ? Color.danger : p == .ready ? Color.running : Color.text3)
                        }
                    }
                    actions(r, p)
                    VStack(spacing: 12) {
                        detail("Engine", state.engineName(r))
                        detail("API name", r.apiID, mono: true)
                        detail("Context", context(r), mono: true)
                        detail("Draft model", ["—", "Off"].contains(drafts(r)) ? "None" : drafts(r))
                        detail("Memory", state.memoryNeed(r).map { "\(Self.gb($0)) of \(Self.gb(state.sparkMemoryTotal))" } ?? "—", mono: true)
                        detail("On disk", disk(r).map { $0.formatted(.byteCount(style: .file)) } ?? "—", mono: true)
                        detail("Port", String(state.port(of: r)), mono: true)
                    }
                    .padding(.vertical, 16)
                    .overlay(alignment: .top) { Hairline() }
                    .overlay(alignment: .bottom) { Hairline() }
                    if let route = state.route, let d = state.config.device {
                        let endpoint = Demo.on ? "spark.local:\(state.port(of: r))" : "\(d.host(route)):\(state.port(of: r))"
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Endpoint").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.text2)
                            HStack(spacing: 6) {
                                Text(endpoint).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text)
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                Spacer(minLength: 0)
                                CopyButton(text: endpoint).buttonStyle(GhostIconStyle(size: 26)).help("Copy endpoint")
                            }
                            .padding(.leading, 12).padding(.trailing, 6)
                            .frame(height: 40)
                            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(9), style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: .corner(9), style: .continuous).strokeBorder(Color(light: 0xE4E4E7, dark: 0x26262B)))
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 16) {
                        Button("Settings") { selection = .model(r.id) }.foregroundStyle(Color.link)
                        Button("View logs") { selection = .logs }.foregroundStyle(Color.link)
                        Spacer()
                        Button("Remove…") { confirmDelete = true }.foregroundStyle(Color.danger)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                }
                .padding(24)
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
                Button("Open in Chat") { openChat(r) }
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

    private func detail(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(k).foregroundStyle(Color.text2)
            Spacer()
            Text(v).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .foregroundStyle(Color.text).multilineTextAlignment(.trailing).lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(size: 13))
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

    private static func gb(_ bytes: Int64) -> String { num(bytes) + " GB" }
    private static func num(_ bytes: Int64) -> String { String(format: "%.0f", Double(bytes) / 1e9) }

    /// 262144 → "262K", 1048576 → "1M".
    static func tokens(_ n: Int) -> String {
        n >= 1_048_576 && n % 1_048_576 == 0 ? "\(n / 1_048_576)M" : "\(Int((Double(n) / 1000).rounded()))K"
    }
}

/// The system reserve's diagonal stripes.
private struct Hatch: ShapeStyle {
    func resolve(in env: EnvironmentValues) -> some ShapeStyle {
        let dark = env.colorScheme == .dark
        return ImagePaint(image: Image(nsImage: Self.tile(dark ? (0x3A3A42, 0x2A2A30) : (0xD4D4D8, 0xE4E4E7))))
    }

    private static func tile(_ c: (UInt32, UInt32)) -> NSImage {
        func ns(_ v: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1) }
        return NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
            ns(c.1).setFill(); r.fill()
            ns(c.0).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 2.8
            for o in stride(from: -8.0, through: 8.0, by: 8.0) { path.move(to: NSPoint(x: o, y: 0)); path.line(to: NSPoint(x: o + 8, y: 8)) }
            path.stroke()
            return true
        }
    }
}

/// Lays out legend items left to right, wrapping to new lines.
struct FlowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (v, p) in zip(subviews, place(bounds.width, subviews).points) {
            v.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func place(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0, pts: [CGPoint] = []
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + 8; line = 0 }
            pts.append(CGPoint(x: x, y: y))
            x += s.width + 20; line = max(line, s.height); maxX = max(maxX, x - 20)
        }
        return (pts, CGSize(width: maxX, height: y + line))
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
