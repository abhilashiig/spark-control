import SwiftUI

/// Every model added to Spark Control in one table, with its settings. Downloading new ones happens on each
/// engine's page, linked below the table.
struct ModelsView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?
    @State private var search = ""
    @State private var picked: Recipe.ID?
    /// The column the table is sorted by, remembered across launches. Empty = running first, then the rest.
    @AppStorage("modelsSort") private var sortKey = ""
    @AppStorage("modelsSortDescending") private var sortDescending = false

    /// One table row, with the values its columns sort by.
    struct Row: Identifiable {
        let recipe: Recipe
        var id: Recipe.ID { recipe.id }
        let name, engine, status, drafts: String
        let context, port: Int
        let memory, disk: Int64
    }

    /// Sortable columns by the key they're remembered under.
    private static let sortKeys: [(String, (SortOrder) -> KeyPathComparator<Row>)] = [
        ("name", { KeyPathComparator(\Row.name, comparator: .localizedStandard, order: $0) }),
        ("engine", { KeyPathComparator(\Row.engine, order: $0) }),
        ("status", { KeyPathComparator(\Row.status, order: $0) }),
        ("context", { KeyPathComparator(\Row.context, order: $0) }),
        ("drafts", { KeyPathComparator(\Row.drafts, order: $0) }),
        ("memory", { KeyPathComparator(\Row.memory, order: $0) }),
        ("disk", { KeyPathComparator(\Row.disk, order: $0) }),
        ("port", { KeyPathComparator(\Row.port, order: $0) }),
    ]

    private var sortOrder: Binding<[KeyPathComparator<Row>]> {
        Binding {
            Self.sortKeys.first { $0.0 == sortKey }.map { [$0.1(sortDescending ? .reverse : .forward)] } ?? []
        } set: { new in
            guard let c = new.first else { sortKey = ""; return }
            sortKey = Self.sortKeys.first { $0.1(.forward).keyPath == c.keyPath }?.0 ?? ""
            sortDescending = c.order == .reverse
        }
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            if let n = state.notice { NoticeBanner(text: n).padding(12).transition(.move(edge: .top).combined(with: .opacity)) }
            Table(rows, selection: $picked, sortOrder: sortOrder) {
                TableColumn("") { r in actions(r.recipe) }.width(30)
                TableColumn("Model", value: \.name) { r in name(r.recipe) }.width(min: 160, ideal: 220)
                TableColumn("Engine", value: \.engine) { r in EngineBadge(name: r.engine) }.width(min: 70, ideal: 80)
                TableColumn("Status", value: \.status) { r in status(r.recipe) }.width(min: 80, ideal: 110)
                TableColumn("Context", value: \.context) { r in Text(context(r.recipe)) }.width(min: 60, ideal: 90)
                TableColumn("Drafts", value: \.drafts) { r in Text(r.drafts) }.width(min: 50, ideal: 70)
                TableColumn("Memory", value: \.memory) { r in Text(Self.gb(r.memory)).monospacedDigit() }.width(min: 50, ideal: 70)
                TableColumn("On Disk", value: \.disk) { r in Text(r.disk > 0 ? r.disk.formatted(.byteCount(style: .file)) : "—").monospacedDigit() }.width(min: 55, ideal: 75)
                TableColumn("Port", value: \.port) { r in Text(r.port > 0 ? String(r.port) : "—").monospacedDigit() }.width(min: 45, ideal: 55)
            }
            .contextMenu(forSelectionType: Recipe.ID.self) { ids in
                if let id = ids.first { Button("Settings and Benchmarks") { selection = .model(id) } }
            } primaryAction: { ids in
                if let id = ids.first { selection = .model(id) }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No Models Yet" : "No Matches", systemImage: "cpu",
                                           description: Text(search.isEmpty ? "Download one from an engine below." : ""))
                }
            }
            // Fixed height: sized to its text, it pushed the window's content past its edges.
            AddModelsHelp(selection: $selection)
                .frame(height: 150)
                .background(Color.pageBackground)
                .overlay(alignment: .top) { Divider() }
        }
        .animation(.snappy, value: state.notice)
        .searchable(text: $search, placement: .toolbar, prompt: "Search models")
        .navigationTitle("Models")
    }

    /// Running first, then the rest.
    private var rows: [Row] {
        let recipes = state.config.recipes.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        let ordered = recipes.filter { state.phase(for: $0) != .stopped } + recipes.filter { state.phase(for: $0) == .stopped }
        return ordered.map { r in
            Row(recipe: r, name: r.name.isEmpty ? "Untitled" : r.name, engine: state.engineName(r), status: statusText(r),
                drafts: drafts(r), context: contextTokens(r), port: state.port(of: r), memory: state.memoryNeed(r) ?? 0,
                disk: (r.tensorfold ?? VLLM.model(r.vllm)?.key).flatMap { state.tf.models[$0]?.bytes } ?? 0)
        }
        .sorted(using: sortOrder.wrappedValue)
    }

    // MARK: Cells

    private func name(_ r: Recipe) -> some View {
        HStack(spacing: 8) {
            ModelAvatar(name: r.name, phase: state.phase(for: r), size: 24)
            Text(r.name.isEmpty ? "Untitled" : r.name).fontWeight(.semibold)
                .foregroundStyle(r.enabled ? .primary : .secondary)
            Button { selection = .model(r.id) } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .help("Settings, benchmarks and details (or double-click the row)")
        }
    }

    private func status(_ r: Recipe) -> some View {
        let p = state.phase(for: r)
        return HStack(spacing: 6) {
            StatusDot(phase: p)
            Text(statusText(r))
                .foregroundStyle(p.isFailure ? Color.red : Color.primary)
        }
        .help(p.label)
    }

    private func statusText(_ r: Recipe) -> String {
        let p = state.phase(for: r)
        return p == .stopped ? (r.enabled ? "Stopped" : "Off") : p.label
    }

    /// The window in tokens, for sorting: TensorFold's default sorts first, YaRN by the window it stretches to.
    private func contextTokens(_ r: Recipe) -> Int {
        if let m = TensorFold.model(r.tensorfold) {
            return switch TensorFold.context(of: r.startCommand) {
            case .engineDefault: 0
            case .window(let n): n
            case .yarn(let f): m.window * f
            }
        }
        if let m = VLLM.model(r.vllm) { return VLLM.context(of: r.startCommand) ?? m.window }
        return -1
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

    private static func gb(_ bytes: Int64) -> String { bytes > 0 ? String(format: "%.0f GB", Double(bytes) / 1e9) : "—" }

    @ViewBuilder private func actions(_ r: Recipe) -> some View {
        let p = state.phase(for: r)
        if p.busy {
            ProgressView().controlSize(.small)
        } else if p == .ready {
            IconButton(title: "Stop", symbol: "stop.fill", color: .red) { state.stop(r) }
        } else {
            IconButton(title: p.isFailure ? "Try Again" : "Start", symbol: p.isFailure ? "arrow.clockwise" : "play.fill", color: p.isFailure ? .orange : .green) { state.start(r) }
                .disabled(!r.enabled || r.startCommand.isEmpty || state.route == nil || state.isBusy)
        }
    }

    /// 262144 → "262k", 1048576 → "1M".
    static func tokens(_ n: Int) -> String {
        n >= 1_048_576 && n % 1_048_576 == 0 ? "\(n / 1_048_576)M" : "\(Int((Double(n) / 1000).rounded()))k"
    }
}

/// Where new models come from, and what this app does with them.
private struct AddModelsHelp: View {
    @Binding var selection: Pane?
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Get More Models").font(.headline)
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                    .help("Spark Control starts and stops models on your DGX Spark over SSH and serves the running ones to this Mac through one OpenAI-compatible API. This list and each model's settings are kept on the Spark, so every Mac using it sees the same models. Download new models from an engine, or add your own.")
            }
            // No Grid or fixedSize here: either one beside the Table left the whole window blank on first launch.
            HStack(spacing: 10) {
                tile("TensorFold", "square.stack.3d.up.fill", .indigo, .tensorfold, "Tested GB10 builds, drafts, long contexts",
                     "Builds TensorFold has tested on one GB10, with speculative drafts and long contexts. A good default for one person chatting or coding.")
                tile("vLLM", "shippingbox.fill", .teal, .vllm, "NVFP4 with MTP, many requests at once",
                     "NVIDIA NVFP4 models in the official vLLM container, with MTP drafts. Pick it when several clients or agents send requests at once. The first start takes 10–15 minutes.")
                tile("Ollama", "magnifyingglass", .brown, .discovered, "Models already pulled on the Spark",
                     "Models you've already pulled with Ollama on the Spark. The widest choice of GGUF sizes, usually slower.")
                tile("ComfyUI", "photo.on.rectangle.angled", .pink, .comfy, "Image generation and editing",
                     "Image generation and editing, opened in your browser.")
                tile("Custom", "plus", .gray, nil, "Any OpenAI-compatible server",
                     "Anything else that serves an OpenAI-compatible API on the Spark (llama.cpp, SGLang, your own scripts), when a model or setting isn't in the catalogs. Give it a start and a stop command; they run in your Spark shell, so aliases work.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// `pane` nil = a custom model: adds one and opens its page.
    private func tile(_ title: String, _ symbol: String, _ tint: Color, _ pane: Pane?, _ short: String, _ long: String) -> some View {
        Button { selection = pane ?? .model(state.addRecipe()) } label: {
            VStack(alignment: .leading, spacing: 8) {
                IconTile(symbol: symbol, tint: tint, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(short).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .card(padding: 12, radius: 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(long)
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
}

/// A table action: a filled round icon (green to start, red to stop), its name as tooltip and for VoiceOver.
private struct IconButton: View {
    let title: String
    let symbol: String
    var color = Color.green
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(enabled ? color.opacity(hover ? 1 : 0.85) : Color.secondary.opacity(0.3)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(title)
        .help(title)
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
