import SwiftUI

struct ModelView: View {
    @Environment(AppState.self) private var state
    let id: UUID
    @Binding var selection: Pane?
    @State private var confirmDelete = false

    /// Looked up by id so deleting the model can't leave a stale index behind.
    private var recipe: Binding<Recipe> {
        Binding {
            state.config.recipes.first { $0.id == id } ?? Recipe(name: "", startCommand: "", stopCommand: "")
        } set: { new in
            if let i = state.config.recipes.firstIndex(where: { $0.id == id }) { state.config.recipes[i] = new }
        }
    }

    var body: some View {
        let r = recipe
        Form {
            if let n = state.notice { Section { NoticeBanner(text: n) } }
            Section { ModelHeader(recipe: r.wrappedValue) }

            Section {
                MemoryField(recipe: r)
            } footer: {
                Text(memoryFooter(r.wrappedValue))
            }

            if let m = TensorFold.model(r.wrappedValue.tensorfold) {
                TensorFoldSection(recipe: r, model: m)
            }
            if let m = VLLM.model(r.wrappedValue.vllm) {
                VLLMSection(recipe: r, model: m)
            }

            BenchmarkSection(recipe: r.wrappedValue)

            Section {
                TextField("Name", text: r.name)
                CodeField(title: "Start command", text: r.startCommand, prompt: "qwen-start")
                CodeField(title: "Stop command", text: r.stopCommand, prompt: "qwen-stop")
                TextField("Spark port", value: r.port, format: .number.grouping(.never),
                          prompt: Text("\((state.config.device?.backendPort ?? 18300).formatted(.number.grouping(.never))) (default)"))
                TextField("Startup timeout (seconds)", value: r.timeout, format: .number.grouping(.never))
                Toggle("Enabled", isOn: r.enabled)
            } header: {
                Text("Recipe")
            }

            Section {
                LabeledContent("API model name") {
                    HStack(spacing: 6) {
                        Text(r.wrappedValue.apiID).monospaced().textSelection(.enabled)
                        CopyButton(text: r.wrappedValue.apiID)
                    }
                }
                if r.wrappedValue.servedName != nil {
                    LabeledContent("Backend model ID") { Text(r.wrappedValue.upstreamModel).monospaced().textSelection(.enabled) }
                } else {
                    CodeField(title: "Backend model ID", text: r.upstreamModel, prompt: "Detected on first start")
                }
                Toggle("Reasoning", isOn: Binding { r.wrappedValue.hasReasoning } set: { r.wrappedValue.reasoning = $0 })
                Toggle("Image input", isOn: Binding { r.wrappedValue.takesImages } set: {
                    r.wrappedValue.images = $0
                    if r.wrappedValue.tensorfold != nil { r.wrappedValue.startCommand = TensorFold.withVision(r.wrappedValue.startCommand, $0) }
                })
            } header: {
                Text("API")
            } footer: {
                Text("The API name stays fixed, so renaming the model doesn't break clients.")
            }

            Section {
                TextField("Input", value: r.priceIn, format: .number.precision(.fractionLength(0...4)))
                TextField("Output", value: r.priceOut, format: .number.precision(.fractionLength(0...4)))
                TextField("Cache read", value: r.priceCache, format: .number.precision(.fractionLength(0...4)),
                          prompt: Text("Same as input"))
            } header: {
                Text("Pricing")
            } footer: {
                Text("USD per 1M tokens.")
            }

            Section {
                RulesEditor(rules: r.rules)
            } header: {
                Text("Parameter Rules")
            } footer: {
                Text("Default fills in a missing value, Override always replaces it, Remove strips it. Values are JSON or plain text.")
            }

            Section {
                Button("Delete Model…", role: .destructive) { confirmDelete = true }
            }
        }
        .page()
        .pageHeader(r.wrappedValue.name.isEmpty ? "Untitled" : r.wrappedValue.name) {
            Button { selection = .models } label: { Label("Back to Models", systemImage: "xmark") }.help("Back to Models")
        }
        .confirmationDialog("Delete “\(r.wrappedValue.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                selection = .models
                state.deleteRecipe(id)
            }
        } message: {
            Text("This removes the recipe from Spark Control. Nothing on the Spark is changed.")
        }
    }
}

private struct ModelHeader: View {
    @Environment(AppState.self) private var state
    let recipe: Recipe
    @State private var keyTarget: String?

    var body: some View {
        let phase = state.phase(for: recipe)
        HStack(spacing: 14) {
            ModelAvatar(name: recipe.name, phase: phase, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(recipe.name.isEmpty ? "Untitled" : recipe.name).font(.title2.weight(.bold))
                    EngineBadge(name: state.engineName(recipe))
                }
                HStack(spacing: 6) {
                    Text(phase.label)
                        .foregroundStyle(phase.isFailure ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
                .font(.callout)
            }
            Spacer()
            if case .failed(let m) = phase, m.contains("Permission denied"), let target = state.sshTarget {
                Button("Set Up Key Login…") { keyTarget = target }.buttonStyle(DesignButtonStyle(prominent: false)).fixedSize()
            }
            if phase.busy {
                ProgressView().controlSize(.small)
            } else if phase == .ready {
                Button("Stop") { state.stop(recipe) }
                    .buttonStyle(DesignButtonStyle(prominent: false)).frame(width: 110)
            } else {
                Button(phase.isFailure ? "Try again" : "Load model") { state.start(recipe) }
                .buttonStyle(DesignButtonStyle()).frame(width: 130)
                .disabled(!recipe.enabled || recipe.startCommand.isEmpty || state.route == nil || state.isBusy)
            }
        }
        .padding(.vertical, 6)
        .sheet(item: $keyTarget) { target in
            KeyLoginSheet(target: target) { state.start(recipe) }
        }
    }
}

extension ModelView {
    func memoryFooter(_ r: Recipe) -> String {
        var s = "Models run side by side when this fits in the Spark's free memory, keeping \(AppState.systemReserve / 1_000_000_000) GB for the system; otherwise the least recently used model stops first, with a warning."
        if r.vllm != nil { s += " vLLM claims all of this at start, for weights and context." }
        else if r.memoryGB == nil { s += " Empty means unknown: it's measured on the next start, and until then starting it stops everything else." }
        else if r.memoryMeasured { s += " Measured on its last start." }
        if r.tensorfold != nil { s += " TensorFold sizes its context pool to the memory that's free when it starts, so it measures large; --parallel 1 in the start command keeps it smaller." }
        return s
    }
}

/// Memory a model needs while running. For vLLM it's also the share of memory the container may take.
private struct MemoryField: View {
    @Environment(AppState.self) private var state
    @Binding var recipe: Recipe

    var body: some View {
        let shown: Double? = recipe.memoryGB ?? (recipe.vllm != nil ? VLLM.memoryFraction(of: recipe.startCommand).map { ($0 * Double(state.sparkMemoryTotal) / 1e9).rounded() } : nil)
        LabeledContent {
            HStack(spacing: 4) {
                TextField("Memory", value: Binding<Double?>(get: { shown }, set: { v in
                    recipe.memoryGB = v
                    recipe.memoryMeasured = false
                    if let v, recipe.vllm != nil {
                        recipe.startCommand = VLLM.withMemory(recipe.startCommand, v, total: Double(state.sparkMemoryTotal),
                                                             footprint: VLLM.model(recipe.vllm)?.footprintGB)
                    }
                }), format: .number, prompt: Text("Unknown"))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 90)
                Text("GB").foregroundStyle(.secondary)
            }
        } label: {
            Text("Memory needed")
            if recipe.memoryMeasured { Text("Measured").font(.caption) }
        }
    }
}

/// Regular label, monospaced value.
private struct CodeField: View {
    let title: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .font(.body.monospaced())
                .multilineTextAlignment(.trailing)
        }
    }
}


private struct RulesEditor: View {
    @Binding var rules: [ParamRule]

    var body: some View {
        ForEach($rules) { $rule in
            HStack(spacing: 8) {
                TextField("", text: $rule.key, prompt: Text("parameter"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .frame(width: 170)
                Picker("", selection: $rule.kind) {
                    ForEach(ParamRule.Kind.allCases, id: \.self) { Text($0.label) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("", text: $rule.value, prompt: Text(rule.kind == .remove ? "" : "value"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .disabled(rule.kind == .remove)
                Button {
                    rules.removeAll { $0.id == rule.id }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove Rule")
            }
        }
        Button("Add Rule") { rules.append(ParamRule()) }
    }
}

/// Context window and drafts for TensorFold catalog models, kept in the start command's flags.
private struct TensorFoldSection: View {
    @Binding var recipe: Recipe
    let model: TensorFold.Model

    var body: some View {
        let current = TensorFold.context(of: recipe.startCommand)
        let options = TensorFold.contextOptions(model)
        Section {
            Picker("Context", selection: Binding { current } set: {
                recipe.startCommand = TensorFold.withContext(recipe.startCommand, $0, model: model)
            }) {
                ForEach(options.contains(current) ? options : options + [current], id: \.self) {
                    Text($0.label(model)).tag($0)
                }
            }
            if let source = model.drafts {
                Toggle(isOn: Binding { TensorFold.draftsOn(recipe.startCommand) } set: {
                    recipe.startCommand = TensorFold.withDrafts(recipe.startCommand, $0)
                }) {
                    Text("Speculative drafts (\(source))")
                    Text("Faster decoding, same replies.")
                }
            }
        } header: {
            Text("TensorFold")
        } footer: {
            Text(footer(current))
        }
    }

    private func footer(_ c: TensorFold.Context) -> String {
        var s = "Changes apply at the next start."
        if case .yarn = c {
            s += " YaRN changes replies at every length: leave it off unless prompts go past \(model.window.formatted()) tokens."
        }
        return s
    }
}

/// Context window and MTP drafts for vLLM catalog models, kept in the start command's flags.
private struct VLLMSection: View {
    @Binding var recipe: Recipe
    let model: VLLM.Model

    var body: some View {
        let ctx = VLLM.context(of: recipe.startCommand) ?? model.window
        let options = VLLM.contextOptions(model)
        let drafts = VLLM.drafts(of: recipe.startCommand)
        Section {
            Picker("Context", selection: Binding { ctx } set: {
                recipe.startCommand = VLLM.fitted(VLLM.withContext(recipe.startCommand, $0), model)
            }) {
                ForEach(options.contains(ctx) ? options : (options + [ctx]).sorted(), id: \.self) {
                    Text($0 == model.window ? "Full window (\($0.formatted()))" : "\($0.formatted()) tokens").tag($0)
                }
            }
            Picker(selection: Binding { drafts } set: {
                recipe.startCommand = VLLM.withDrafts(recipe.startCommand, $0, model: model)
            }) {
                Text("Off").tag(0)
                ForEach(Array(Set(model.fixedDrafts ? [model.suggested] : [1, 2, 3, drafts, model.suggested])).filter { $0 > 0 }.sorted(), id: \.self) { n in
                    Text(n == model.suggested ? "\(n) tokens (suggested)" : "\(n) token\(n == 1 ? "" : "s")").tag(n)
                }
            } label: {
                Text("MTP drafts")
            }
        } header: {
            Text("vLLM")
        } footer: {
            Text("Changes apply at the next start. More drafts aren't always faster; run a benchmark to compare.")
        }
    }
}
