import SwiftUI

/// Every model on the Spark in one table: your models with their settings, and catalog models downloaded but
/// not added yet. Downloading new ones happens on each engine's page, linked below the table.
struct ModelsView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?
    @State private var kind = Kind.all
    @State private var search = ""
    @State private var deleting: CatalogItem?
    @State private var picked: Entry.ID?
    @State private var adding: Set<String> = []
    /// The column the table is sorted by, remembered across launches. Empty = running first, then the rest.
    @AppStorage("modelsSort") private var sortKey = ""
    @AppStorage("modelsSortDescending") private var sortDescending = false

    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", text = "Text", image = "Image"
        var id: Self { self }
    }

    enum Entry: Identifiable {
        case recipe(Recipe), catalog(CatalogItem)
        var id: String {
            switch self {
            case .recipe(let r): r.id.uuidString
            case .catalog(let i): i.key
            }
        }
    }

    /// One table row, with the values its columns sort by.
    struct Row: Identifiable {
        let entry: Entry
        var id: String { entry.id }
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
            if let n = state.notice { NoticeBanner(text: n).padding(12) }
            Table(rows, selection: $picked, sortOrder: sortOrder) {
                TableColumn("") { r in actions(r.entry) }.width(30)
                TableColumn("Model", value: \.name) { r in name(r.entry) }.width(min: 160, ideal: 220)
                TableColumn("Engine", value: \.engine) { r in EngineBadge(name: r.engine) }.width(min: 70, ideal: 80)
                TableColumn("Status", value: \.status) { r in status(r.entry) }.width(min: 80, ideal: 110)
                TableColumn("Context", value: \.context) { r in Text(context(r.entry)) }.width(min: 60, ideal: 90)
                TableColumn("Drafts", value: \.drafts) { r in Text(r.drafts) }.width(min: 50, ideal: 70)
                TableColumn("Memory", value: \.memory) { r in Text(Self.gb(r.memory)).monospacedDigit() }.width(min: 50, ideal: 70)
                TableColumn("On Disk", value: \.disk) { r in Text(r.disk > 0 ? r.disk.formatted(.byteCount(style: .file)) : "—").monospacedDigit() }.width(min: 55, ideal: 75)
                TableColumn("Port", value: \.port) { r in Text(r.port > 0 ? String(r.port) : "—").monospacedDigit() }.width(min: 45, ideal: 55)
            }
            .contextMenu(forSelectionType: Entry.ID.self) { ids in
                if let e = ids.first.flatMap(entry) { menu(e) }
            } primaryAction: { ids in
                if let e = ids.first.flatMap(entry) { open(e) }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No Models Yet" : "No Matches", systemImage: "cpu",
                                           description: Text(search.isEmpty ? "Download one from an engine below." : ""))
                }
            }
            Divider()
            // Scrolls inside a capped height: sized to its text, it pushed the window's content past its edges.
            ScrollView { AddModelsHelp(selection: $selection) }
                .frame(height: 240)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search models")
        .toolbar {
            Picker("Type", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .catalogPage("Models", deleting: $deleting)
    }

    /// Running first, then your other models, then catalog models on the Spark that aren't added yet.
    private var entries: [Entry] {
        let recipes = state.config.recipes.filter { matches($0.name, image: false) }
        let running = recipes.filter { state.phase(for: $0) != .stopped }
        let stopped = recipes.filter { state.phase(for: $0) == .stopped }
        let catalog = (TensorFold.catalog.map(CatalogItem.tf) + VLLM.catalog.map(CatalogItem.vllm) + ComfyUI.catalog.map(CatalogItem.comfy))
            .filter { state.catRecipeID($0) == nil && state.isOnSpark($0) && matches($0.name, image: $0.isImage) }
        return (running + stopped).map(Entry.recipe) + catalog.map(Entry.catalog)
    }

    private func entry(_ id: Entry.ID) -> Entry? { entries.first { $0.id == id } }

    private var rows: [Row] {
        let rows = entries.map { e in
            Row(entry: e, name: name(of: e), engine: engine(e), status: statusText(e), drafts: drafts(e),
                context: contextTokens(e), port: port(e), memory: memoryBytes(e) ?? 0, disk: diskBytes(e) ?? 0)
        }
        return rows.sorted(using: sortOrder.wrappedValue)
    }

    private func name(of e: Entry) -> String {
        switch e {
        case .recipe(let r): r.name.isEmpty ? "Untitled" : r.name
        case .catalog(let i): i.name
        }
    }

    private func matches(_ name: String, image: Bool) -> Bool {
        (kind == .all || (kind == .image) == image) && (search.isEmpty || name.localizedCaseInsensitiveContains(search))
    }

    // MARK: Cells

    @ViewBuilder private func name(_ e: Entry) -> some View {
        switch e {
        case .recipe(let r):
            HStack(spacing: 6) {
                Text(r.name.isEmpty ? "Untitled" : r.name).fontWeight(.medium)
                    .foregroundStyle(r.enabled ? .primary : .secondary)
                Button { selection = .model(r.id) } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .help("Settings, benchmarks and details (or double-click the row)")
            }
        case .catalog(let i):
            Text(i.name).help(i.note)
        }
    }

    private func engine(_ e: Entry) -> String {
        switch e {
        case .recipe(let r): state.engineName(r)
        case .catalog(let i): i.engine
        }
    }

    @ViewBuilder private func status(_ e: Entry) -> some View {
        switch e {
        case .recipe(let r):
            let p = state.phase(for: r)
            HStack(spacing: 6) {
                StatusDot(phase: p)
                Text(statusText(e))
                    .foregroundStyle(p.isFailure ? Color.red : Color.primary)
            }
            .help(p.label)
        case .catalog(let i):
            let running = i.isImage && state.tf.comfyRunning
            HStack(spacing: 6) {
                StatusDot(phase: running ? .ready : .stopped)
                Text(statusText(e)).foregroundStyle(.secondary)
            }
        }
    }

    private func statusText(_ e: Entry) -> String {
        switch e {
        case .recipe(let r):
            let p = state.phase(for: r)
            return p == .stopped ? (r.enabled ? "Stopped" : "Off") : p.label
        case .catalog(let i):
            return i.isImage && state.tf.comfyRunning ? "In ComfyUI" : i.isImage ? "Ready" : "Not added"
        }
    }

    /// The window in tokens, for sorting: TensorFold's default sorts first, YaRN by the window it stretches to.
    private func contextTokens(_ e: Entry) -> Int {
        guard case .recipe(let r) = e else { return -1 }
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

    private func context(_ e: Entry) -> String {
        guard case .recipe(let r) = e else { return "—" }
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

    private func drafts(_ e: Entry) -> String {
        guard case .recipe(let r) = e else { return "—" }
        if let m = TensorFold.model(r.tensorfold), let source = m.drafts {
            return TensorFold.draftsOn(r.startCommand) ? (source == "MTP" ? "MTP" : "DFlash") : "Off"
        }
        if VLLM.model(r.vllm) != nil {
            let n = VLLM.drafts(of: r.startCommand)
            return n == 0 ? "Off" : "MTP ×\(n)"
        }
        return "—"
    }

    private func memoryBytes(_ e: Entry) -> Int64? {
        switch e {
        case .recipe(let r): state.memoryNeed(r)
        case .catalog(.vllm(let m)): Int64(m.memoryGB * 1e9)
        case .catalog: nil
        }
    }

    private static func gb(_ bytes: Int64) -> String { bytes > 0 ? String(format: "%.0f GB", Double(bytes) / 1e9) : "—" }

    private func diskBytes(_ e: Entry) -> Int64? {
        let key: String? = switch e {
        case .recipe(let r): r.tensorfold ?? VLLM.model(r.vllm)?.key
        case .catalog(let i): i.key
        }
        return key.flatMap { state.tf.models[$0]?.bytes }
    }

    /// 0 for catalog models not added yet, which have no port.
    private func port(_ e: Entry) -> Int {
        guard case .recipe(let r) = e else { return 0 }
        return state.port(of: r)
    }

    @ViewBuilder private func actions(_ e: Entry) -> some View {
        switch e {
        case .recipe(let r):
            let p = state.phase(for: r)
            if p.busy {
                ProgressView().controlSize(.small)
            } else if p == .ready {
                IconButton(title: "Stop", symbol: "stop.fill", color: .red) { state.stop(r) }
            } else {
                IconButton(title: p.isFailure ? "Try Again" : "Start", symbol: p.isFailure ? "arrow.clockwise" : "play.fill", color: p.isFailure ? .orange : .green) { state.start(r) }
                    .disabled(!r.enabled || r.startCommand.isEmpty || state.route == nil || state.isBusy)
            }
        case .catalog(let i):
            if case .comfy(let m) = i {
                IconButton(title: "Open in ComfyUI", symbol: "arrow.up.forward", color: .accentColor) { Task { await state.comfyOpen(template: m.template) } }
                    .disabled(!state.engineReady(i) || state.comfyBusy || state.isBusy)
                    .help("Starts ComfyUI if needed and opens this model's workflow in the browser")
            } else if adding.contains(i.key) {
                ProgressView().controlSize(.small)
            } else {
                IconButton(title: "Add and start", symbol: "play.fill") {
                    adding.insert(i.key)
                    Task {
                        if let id = await state.catAdd(i), let r = state.config.recipes.first(where: { $0.id == id }) { state.start(r) }
                        adding.remove(i.key)
                    }
                }
                .disabled(!state.engineReady(i) || state.isBusy)
            }
        }
    }

    @ViewBuilder private func menu(_ e: Entry) -> some View {
        switch e {
        case .recipe(let r):
            Button("Settings and Benchmarks") { selection = .model(r.id) }
        case .catalog(let i):
            if i.isImage, state.tf.comfyRunning {
                Button("Stop ComfyUI") { Task { await state.comfyStop() } }
            }
            Button("Show on \(i.engine) Page") { open(e) }
            if state.downloadedByApp(i) {
                Divider()
                Button("Delete from the Spark…", role: .destructive) { deleting = i }
            }
        }
    }

    private func open(_ e: Entry) {
        switch e {
        case .recipe(let r): selection = .model(r.id)
        case .catalog(.tf): selection = .tensorfold
        case .catalog(.vllm): selection = .vllm
        case .catalog(.comfy): selection = .comfy
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Get More Models").font(.headline)
            Text("Spark Control starts and stops models on your DGX Spark over SSH and serves the running ones to this Mac through one OpenAI-compatible API. This list and each model's settings are kept on the Spark, so every Mac using it sees the same models. Download new models from an engine, or add your own:")
                .font(.callout).foregroundStyle(.secondary)
            // No Grid or fixedSize here: either one beside the Table left the whole window blank on first launch.
            VStack(alignment: .leading, spacing: 6) {
                row("TensorFold", "square.stack.3d.up", .tensorfold,
                    "Builds TensorFold has tested on one GB10, with speculative drafts and long contexts. A good default for one person chatting or coding.")
                row("vLLM", "shippingbox", .vllm,
                    "NVIDIA NVFP4 models in the official vLLM container, with MTP drafts. Pick it when several clients or agents send requests at once. The first start takes 10–15 minutes.")
                row("Ollama", "magnifyingglass", .discovered,
                    "Models you've already pulled with Ollama on the Spark. The widest choice of GGUF sizes, usually slower.")
                row("ComfyUI", "photo.on.rectangle.angled", .comfy,
                    "Image generation and editing, opened in your browser.")
            }
            row("Custom", "plus.circle", nil,
                "Anything else that serves an OpenAI-compatible API on the Spark (llama.cpp, SGLang, your own scripts), when a model or setting isn't in the catalogs. Give it a start and a stop command; they run in your Spark shell, so aliases work.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @Environment(AppState.self) private var state

    /// `pane` nil = a custom model: adds one and opens its page.
    private func row(_ title: String, _ symbol: String, _ pane: Pane?, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button { selection = pane ?? .model(state.addRecipe()) } label: { Label(title, systemImage: symbol).frame(minWidth: 100, alignment: .leading) }
                .buttonStyle(.link)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
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

struct EngineBadge: View {
    let name: String
    var body: some View {
        Text(name).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
    }
}
