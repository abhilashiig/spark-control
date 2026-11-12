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
                Toggle(isOn: r.enabled) {
                    Text("Enabled")
                    Text("Only enabled models can be started or requested through the API.")
                }
            } header: {
                Text("Recipe")
            } footer: {
                Text("Commands run on the Spark through your shell, exactly as typed, so aliases and functions work.")
            }

            Section {
                LabeledContent("API model name") {
                    HStack(spacing: 6) {
                        Text(r.wrappedValue.apiID).monospaced().textSelection(.enabled)
                        CopyButton(text: r.wrappedValue.apiID)
                    }
                }
                CodeField(title: "Backend model ID", text: r.upstreamModel, prompt: "Detected on first start")
            } header: {
                Text("API")
            } footer: {
                Text("Clients ask for “\(r.wrappedValue.apiID)” at \(state.apiBaseURL). It's renamed to the backend model ID before reaching the Spark.")
            }

            Section {
                TextField("Input", value: r.priceIn, format: .number.precision(.fractionLength(0...4)))
                TextField("Output", value: r.priceOut, format: .number.precision(.fractionLength(0...4)))
                TextField("Cache read", value: r.priceCache, format: .number.precision(.fractionLength(0...4)),
                          prompt: Text("Same as input"))
            } header: {
                Text("Pricing")
            } footer: {
                Text("USD per 1M tokens. Cached prompt tokens use the cache read price. Used for usage totals and usage.cost. Nothing is billed.")
            }

            Section {
                RulesEditor(rules: r.rules)
            } header: {
                Text("Parameter Rules")
            } footer: {
                Text("Requests pass through unchanged unless a rule applies. Default fills in a missing value, Override always replaces it, and Remove strips it. Values are JSON (0.6, true, {\"enable_thinking\": false}) or plain text.")
            }

            Section {
                Button("Delete Model…", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(r.wrappedValue.name.isEmpty ? "Untitled" : r.wrappedValue.name)
        .confirmationDialog("Delete “\(r.wrappedValue.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                selection = nil
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
            Image(systemName: "cpu")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 46, height: 46)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(recipe.name.isEmpty ? "Untitled" : recipe.name).font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    StatusDot(phase: phase)
                    Text(phase.label)
                        .foregroundStyle(phase.isFailure ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
                .font(.callout)
            }
            Spacer()
            if case .failed(let m) = phase, m.contains("Permission denied"), let target = state.sshTarget {
                Button("Set Up Key Login…") { keyTarget = target }.controlSize(.large)
            }
            if phase.busy {
                ProgressView().controlSize(.small)
            } else if phase == .ready {
                Button("Stop") { state.stop(recipe) }.controlSize(.large)
            } else {
                Button(phase.isFailure ? "Try Again" : "Start") {
                    state.start(recipe)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!recipe.enabled || recipe.startCommand.isEmpty || state.route == nil || state.isBusy)
            }
        }
        .padding(.vertical, 4)
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
                        recipe.startCommand = VLLM.withMemory(recipe.startCommand, v, total: Double(state.sparkMemoryTotal))
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

struct NoticeBanner: View {
    @Environment(AppState.self) private var state
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(VizColor.warning)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { state.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
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
                    Text("Faster decoding with the same replies. Off decodes one token at a time, also without copy drafts.")
                }
            }
        } header: {
            Text("TensorFold")
        } footer: {
            Text(footer(current))
        }
    }

    private func footer(_ c: TensorFold.Context) -> String {
        var s = "Changes apply at the next start; the startup line in Logs shows the context and drafts in use."
        s += " TensorFold runs as many requests at once as fit in memory at this window; if not even one fits, it refuses to start and Logs name the window that does."
        if case .engineDefault = c { s += " TensorFold's default is 16k to 32k tokens, depending on the model." }
        if case .yarn = c {
            s += " YaRN changes replies at every length, not only long prompts: leave it off unless prompts go past \(model.window.formatted()) tokens. At 1M tokens a GB10 runs two requests at once, and a 1M-token prompt takes about 26 minutes to prefill."
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
                recipe.startCommand = VLLM.withContext(recipe.startCommand, $0)
            }) {
                ForEach(options.contains(ctx) ? options : (options + [ctx]).sorted(), id: \.self) {
                    Text($0 == model.window ? "Full window (\($0.formatted()))" : "\($0.formatted()) tokens").tag($0)
                }
            }
            Picker(selection: Binding { drafts } set: {
                recipe.startCommand = VLLM.withDrafts(recipe.startCommand, $0, model: model)
            }) {
                Text("Off").tag(0)
                ForEach(Array(Set([1, 2, 3, drafts, model.suggested])).filter { $0 > 0 }.sorted(), id: \.self) { n in
                    Text(n == model.suggested ? "\(n) tokens (suggested)" : "\(n) token\(n == 1 ? "" : "s")").tag(n)
                }
            } label: {
                Text("MTP drafts")
                Text("Tokens the MTP head drafts per step. Same replies, faster decoding; more isn't always faster because later drafts are accepted less often.")
            }
        } header: {
            Text("vLLM")
        } footer: {
            Text("Changes apply at the next start. MTP also takes some memory from the KV cache (about 20% fewer cached tokens measured on a GB10). Run a benchmark after changing drafts to see which is fastest for your prompts.")
        }
    }
}
