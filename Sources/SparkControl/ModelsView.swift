import SwiftUI

/// Every model in one place: what's running, what's on the Spark ready to start, and what the engines' catalogs
/// can download. Rows start, stop, download and open; the name goes to the model's own page.
struct ModelsView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?
    @State private var kind = Kind.all
    @State private var search = ""
    @State private var deleting: CatalogItem?

    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", text = "Text", image = "Image"
        var id: Self { self }
    }

    var body: some View {
        let recipes = state.config.recipes.filter { matches($0.name, image: false) }
        let running = recipes.filter { state.phase(for: $0) != .stopped }
        // Catalog models already added show as the user's model instead.
        let catalog = allCatalog.filter { state.catRecipeID($0) == nil && matches($0.name, image: $0.isImage) }
        let onSpark = catalog.filter(state.isOnSpark)
        let available = catalog.filter { !state.isOnSpark($0) }

        Form {
            if let n = state.notice { Section { NoticeBanner(text: n) } }
            Section("Running") {
                if running.isEmpty && !(state.tf.comfyRunning && kind != .text) {
                    Text("Nothing is running.").foregroundStyle(.secondary)
                }
                ForEach(running) { RecipeRow(recipe: $0, selection: $selection) }
                if state.tf.comfyRunning && kind != .text { ComfyRunningRow(selection: $selection) }
            }
            Section {
                ForEach(recipes.filter { state.phase(for: $0) == .stopped }) { RecipeRow(recipe: $0, selection: $selection) }
                ForEach(onSpark) { ModelRow(item: $0, selection: $selection, deleting: $deleting, unified: true) }
            } header: {
                Text("On Spark")
            } footer: {
                Text("Your models and downloaded catalog models, ready to start. A model starts beside the running ones when its port is free and it fits in memory; otherwise the least recently used stops first, with a warning.")
            }
            if !available.isEmpty {
                Section {
                    ForEach(available) { ModelRow(item: $0, selection: $selection, deleting: $deleting, unified: true) }
                } header: {
                    Text("Available to Download")
                } footer: {
                    Text("From the TensorFold, vLLM and ComfyUI catalogs. Install an engine on its page under Engines to download its models.")
                }
            }
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

    private var allCatalog: [CatalogItem] {
        TensorFold.catalog.map(CatalogItem.tf) + VLLM.catalog.map(CatalogItem.vllm) + ComfyUI.catalog.map(CatalogItem.comfy)
    }

    private func matches(_ name: String, image: Bool) -> Bool {
        (kind == .all || (kind == .image) == image) && (search.isEmpty || name.localizedCaseInsensitiveContains(search))
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

struct EngineBadge: View {
    let name: String
    var body: some View {
        Text(name).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
    }
}

/// One of your models: status, engine and port, with Start or Stop.
private struct RecipeRow: View {
    @Environment(AppState.self) private var state
    let recipe: Recipe
    @Binding var selection: Pane?

    var body: some View {
        let phase = state.phase(for: recipe)
        HStack(spacing: 12) {
            StatusDot(phase: phase)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Button(recipe.name.isEmpty ? "Untitled" : recipe.name) { selection = .model(recipe.id) }
                        .buttonStyle(.plain).font(.body.weight(.medium))
                    EngineBadge(name: state.engineName(recipe))
                    if !recipe.enabled { Text("Off").font(.caption).foregroundStyle(.tertiary) }
                }
                Text(phase == .stopped || phase == .ready ? detail : phase.label)
                    .font(.caption).foregroundStyle(phase.isFailure ? Color.red : Color.secondary).lineLimit(1)
            }
            Spacer()
            if phase.busy {
                ProgressView().controlSize(.small)
            } else if phase == .ready {
                Button("Stop") { state.stop(recipe) }
            } else {
                Button(phase.isFailure ? "Try Again" : "Start") { state.start(recipe) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!recipe.enabled || recipe.startCommand.isEmpty || state.route == nil || state.isBusy)
            }
            Button { selection = .model(recipe.id) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).help("Settings, benchmarks and details")
        }
        .padding(.vertical, 3)
    }
}

extension RecipeRow {
    var detail: String {
        let mem = state.memoryNeed(recipe).map { String(format: " · %.0f GB", Double($0) / 1e9) } ?? " · memory unknown"
        return (state.phase(for: recipe) == .ready ? "Running · " : "") + "Port \(state.port(of: recipe))" + mem
    }
}

private struct ComfyRunningRow: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(phase: .ready)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Button("ComfyUI") { selection = .comfy }.buttonStyle(.plain).font(.body.weight(.medium))
                    EngineBadge(name: "Image")
                }
                Text("Image generation · open an image model to use it").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state.comfyBusy { ProgressView().controlSize(.small) }
            Button("Stop") { Task { await state.comfyStop() } }.disabled(state.comfyBusy)
            Button("Open") { Task { await state.comfyOpen() } }.buttonStyle(.borderedProminent).disabled(state.comfyBusy)
            Button { selection = .comfy } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }
}
