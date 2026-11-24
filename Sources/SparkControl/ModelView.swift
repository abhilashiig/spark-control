import SwiftUI

struct ModelView: View {
    @Environment(AppState.self) private var state
    @Environment(ChatStore.self) private var chats
    let id: UUID
    @Binding var selection: Pane?
    @State private var confirmDelete = false
    @State private var tab = Tab.configuration
    @State private var keyTarget: String?
    @State private var width: CGFloat = 1000

    enum Tab: String, CaseIterable { case configuration = "Configuration", api = "API", pricing = "Pricing", benchmark = "Benchmark" }

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
        VStack(spacing: 0) {
            topBar(r.wrappedValue)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let n = state.notice { NoticeBanner(text: n) }
                    hero(r.wrappedValue)
                    stats(r.wrappedValue)
                    tabBar
                    if width > 860 {
                        HStack(alignment: .top, spacing: 24) {
                            main(r).frame(maxWidth: .infinity, alignment: .leading)
                            side(r.wrappedValue).frame(width: 300)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 24) { main(r); side(r.wrappedValue) }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 56)
                .frame(maxWidth: 1080)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            }
        }
        .textFieldStyle(.plain)
        .toggleStyle(.switch)
        .confirmationDialog("Delete “\(r.wrappedValue.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                selection = .models
                state.deleteRecipe(id)
            }
        } message: {
            Text("Nothing on the Spark is changed.")
        }
        .sheet(item: $keyTarget) { target in
            KeyLoginSheet(target: target) { state.start(r.wrappedValue) }
        }
    }

    // MARK: Header

    private func topBar(_ r: Recipe) -> some View {
        let phase = state.phase(for: r)
        return HStack(spacing: 8) {
            Button("Models") { selection = .models }.buttonStyle(.plain).foregroundStyle(Color.text3)
            Text("/").foregroundStyle(Color(light: 0xA1A1AA, dark: 0x4A4A52))
            Text(r.name.isEmpty ? "Untitled" : r.name).fontWeight(.medium).foregroundStyle(Color.text).lineLimit(1)
            Spacer(minLength: 12)
            Group {
                if case .failed(let m) = phase, m.contains("Permission denied"), let target = state.sshTarget {
                    Button("Set Up Key Login…") { keyTarget = target }.buttonStyle(DesignButtonStyle(prominent: false, height: 34))
                }
                if phase.busy {
                    ProgressView().controlSize(.small).padding(.horizontal, 8)
                } else if phase == .ready {
                    Button("Stop") { state.stop(r) }.buttonStyle(DesignButtonStyle(prominent: false, height: 34))
                    if !r.isEmbedding {
                        Button("Open in Chat") {
                            chats.selection = chats.newChat(model: r.apiID, profiles: state.config.profiles)
                            selection = .chat
                        }
                        .buttonStyle(DesignButtonStyle(height: 34))
                        .disabled(!r.enabled)
                    }
                } else {
                    Button(phase.isFailure ? "Try again" : "Load model") { state.start(r) }
                        .buttonStyle(DesignButtonStyle(height: 34))
                        .disabled(!canStart(r))
                }
            }
            .fixedSize()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 28)
        .frame(minHeight: 60)
        .background { Color.pageBackground.gesture(WindowDragGesture()) }
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func hero(_ r: Recipe) -> some View {
        let phase = state.phase(for: r)
        let engine = state.engineName(r)
        let color = statusColor(phase)
        return HStack(spacing: 16) {
            Text(ModelAvatar.tag(r.name))
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(EngineBadge.text(engine))
                .minimumScaleFactor(0.6).lineLimit(1).padding(.horizontal, 4)
                .frame(width: 56, height: 56)
                .background(EngineBadge.color(engine).opacity(0.12), in: RoundedRectangle(cornerRadius: .corner(14), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: .corner(14), style: .continuous).strokeBorder(EngineBadge.color(engine).opacity(0.3)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(r.name.isEmpty ? "Untitled" : r.name).font(.system(size: 24, weight: .semibold)).tracking(-0.4)
                        .textSelection(.enabled)
                    EngineBadge(name: engine)
                    ForEach(tags(r), id: \.self) { t in
                        Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(Color(light: 0x52525B, dark: 0xC4C4CC))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color(light: 0xF4F4F5, dark: 0x1C1C21), in: RoundedRectangle(cornerRadius: .corner(6), style: .continuous))
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                        .background(Circle().fill(color.opacity(0.15)).padding(-3))
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(statusText(r, phase)).lineLimit(3).textSelection(.enabled)
                }
                .font(.system(size: 13))
                .foregroundStyle(phase == .stopped ? Color.text3 : color)
            }
        }
    }

    private func tags(_ r: Recipe) -> [String] {
        r.isEmbedding ? ["Embedding"] : [r.takesImages ? "Vision" : nil, r.hasReasoning ? "Reasoning" : nil].compactMap { $0 }
    }

    private func statusText(_ r: Recipe, _ p: Phase) -> String {
        switch p {
        case .ready: "Running on port \(state.port(of: r))"
        case .stopped: r.enabled ? "Not loaded" : "Off"
        default: p.label
        }
    }

    private func statusColor(_ p: Phase) -> Color {
        switch p {
        case .ready: Color.running
        case .stopped: Color.text2
        case .failed, .offline: Color.danger
        default: VizColor.warning
        }
    }

    // MARK: Stats

    private func stats(_ r: Recipe) -> some View {
        let day = state.usage.filter { $0.model == r.apiID && $0.date >= Date.now.addingTimeInterval(-86_400) }
        let topClient = Dictionary(grouping: day, by: { $0.client ?? "Unknown" }).max { $0.value.count < $1.value.count }?.key
        let need = state.memoryNeed(r)
        let runs = state.benchResults[r.id] ?? []
        let benching = state.bench.map { $0.recipe == r.id && $0.running } ?? false
        let fraction = Double(need ?? 0) / Double(max(1, state.sparkMemoryTotal))
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            statCard(r.memoryMeasured ? "Memory · measured" : "Memory") {
                bigNumber(need.map { String(format: "%.0f", Double($0) / 1e9) } ?? "—", unit: need == nil ? nil : "GB")
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: .corner(999)).fill(Color(light: 0xE4E4E7, dark: 0x222227))
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: .corner(999)).fill(EngineBadge.color(state.engineName(r))).frame(width: g.size.width * min(1, fraction))
                        }
                }
                .frame(height: 4)
            }
            statCard("Requests · 24h") {
                bigNumber(day.count.formatted())
                caption(topClient.map { "from \($0)" } ?? "None yet")
            }
            statCard("Input tokens · 24h") {
                bigNumber(day.reduce(0) { $0 + $1.prompt }.compact)
                caption("\(day.reduce(0) { $0 + $1.cost }.usd) at current pricing")
            }
            statCard("Benchmark") {
                if benching {
                    Text("Running…").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.text3).padding(.vertical, 4)
                } else if let d = runs.last?.decode {
                    bigNumber(String(format: "%.1f", d), unit: "tok/s")
                } else {
                    Text("Not run yet").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.text3).padding(.vertical, 4)
                }
                let fresh = runs.isEmpty && !benching
                Button(fresh ? "Run benchmark →" : "View results →") {
                    tab = .benchmark
                    if fresh { Task { await state.runBenchmark(r) } }
                }
                .buttonStyle(.plain).foregroundStyle(Color.link).font(.system(size: 13, weight: .medium))
                .disabled(fresh && !canStart(r))
            }
        }
    }

    private func statCard(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Color.text3)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(12), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .corner(12), style: .continuous).strokeBorder(Color.cardBorder))
    }

    private func bigNumber(_ v: String, unit: String? = nil) -> some View {
        (Text(v).font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.text)
            + Text(unit.map { " " + $0 } ?? "").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.text3))
            .tracking(-0.3)
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(Color.text2).lineLimit(1)
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { t in
                let on = tab == t
                Button { tab = t } label: {
                    Text(t.rawValue)
                        .font(.system(size: 13, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Color.text : Color.text3)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Rectangle().fill(on ? Color.text : .clear).frame(height: 2) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Hairline() }
    }

    @ViewBuilder private func main(_ r: Binding<Recipe>) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            switch tab {
            case .configuration: configuration(r)
            case .api: api(r)
            case .pricing: pricing(r)
            case .benchmark:
                card {
                    VStack(alignment: .leading, spacing: 12) { BenchmarkSection(recipe: r.wrappedValue) }
                        .textFieldStyle(.roundedBorder)
                        .padding(16)
                }
            }
        }
    }

    @ViewBuilder private func configuration(_ r: Binding<Recipe>) -> some View {
        group("Recipe", "How Spark Control starts, checks and stops this model.") {
            row("Name") { TextField("Name", text: r.name, prompt: Text("Untitled")).multilineTextAlignment(.trailing) }
            Hairline()
            CommandBox(title: "Start command", text: r.startCommand, prompt: "qwen-start")
            Hairline()
            CommandBox(title: "Stop command", text: r.stopCommand, prompt: "qwen-stop")
            Hairline()
            HStack(spacing: 0) {
                field("Spark port") {
                    TextField("Spark port", value: r.port, format: .number.grouping(.never),
                              prompt: Text("\((state.config.device?.backendPort ?? 18300).formatted(.number.grouping(.never))) (default)"))
                }
                Hairline(vertical: true)
                field("Startup timeout (seconds)") {
                    TextField("Startup timeout", value: r.timeout, format: .number.grouping(.never))
                }
                Hairline(vertical: true)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enabled").fontWeight(.medium)
                        Text("Shown in Chat and API").font(.system(size: 12)).foregroundStyle(Color.text2)
                    }
                    Spacer(minLength: 0)
                    Toggle("Enabled", isOn: r.enabled).labelsHidden()
                }
                .font(.system(size: 13))
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        group("Memory", memoryFooter(r.wrappedValue)) {
            MemoryField(recipe: r).padding(.horizontal, 16).padding(.vertical, 12)
        }
        if let m = TensorFold.model(r.wrappedValue.tensorfold) {
            group("TensorFold", TensorFoldSection.footer(TensorFold.context(of: r.wrappedValue.startCommand), model: m)) {
                TensorFoldSection(recipe: r, model: m).padding(16)
            }
        }
        if let m = VLLM.model(r.wrappedValue.vllm) {
            group("vLLM", "Changes apply at the next start. More drafts aren't always faster; run a benchmark to compare.") {
                VLLMSection(recipe: r, model: m).padding(16)
            }
        }
    }

    @ViewBuilder private func api(_ r: Binding<Recipe>) -> some View {
        group("API", "The API name stays fixed, so renaming the model never breaks clients.") {
            row("API model name") {
                HStack(spacing: 8) {
                    Text(r.wrappedValue.apiID).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.pageBackground, in: RoundedRectangle(cornerRadius: .corner(6), style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: .corner(6), style: .continuous).strokeBorder(Color(light: 0xE4E4E7, dark: 0x26262B)))
                    CopyButton(text: r.wrappedValue.apiID).foregroundStyle(Color.text3)
                }
            }
            Hairline()
            row("Backend model ID") {
                if r.wrappedValue.servedName != nil {
                    Text(r.wrappedValue.upstreamModel).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text3).textSelection(.enabled)
                } else {
                    TextField("Backend model ID", text: r.upstreamModel, prompt: Text("Detected on first start"))
                        .font(.system(size: 12, design: .monospaced)).multilineTextAlignment(.trailing)
                }
            }
            Hairline()
            row("Reasoning", note: r.wrappedValue.isEmbedding && r.wrappedValue.hasReasoning ? "Embedding models don't produce reasoning; turn this off" : nil) {
                Toggle("Reasoning", isOn: Binding { r.wrappedValue.hasReasoning } set: { r.wrappedValue.reasoning = $0 }).labelsHidden()
            }
            Hairline()
            row("Image input") {
                Toggle("Image input", isOn: Binding { r.wrappedValue.takesImages } set: {
                    r.wrappedValue.images = $0
                    if r.wrappedValue.tensorfold != nil { r.wrappedValue.startCommand = TensorFold.withVision(r.wrappedValue.startCommand, $0) }
                }).labelsHidden()
            }
            Hairline()
            row("Model's Own Sampling", sub: "Ignores the temperature, top_p and other sampling values clients send, so the model maker's defaults apply.") {
                Toggle("Model's Own Sampling", isOn: r.modelSampling).labelsHidden()
            }
        }
        group("Parameter Rules", "Default fills in a missing value, Override always replaces it, Remove strips it. Values are JSON or plain text.") {
            VStack(alignment: .leading, spacing: 8) { RulesEditor(rules: r.rules) }
                .textFieldStyle(.roundedBorder)
                .padding(16)
        }
    }

    private func pricing(_ r: Binding<Recipe>) -> some View {
        group("Pricing", "USD per million tokens. Used for cost tracking in Usage.") {
            HStack(spacing: 0) {
                field("Input") { TextField("Input", value: r.priceIn, format: .number.precision(.fractionLength(0...4)), prompt: Text("0")) }
                Hairline(vertical: true)
                field("Output") { TextField("Output", value: r.priceOut, format: .number.precision(.fractionLength(0...4)), prompt: Text("0")) }
                Hairline(vertical: true)
                field("Cache read") {
                    TextField("Cache read", value: r.priceCache, format: .number.precision(.fractionLength(0...4)), prompt: Text("Same as input"))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Side column

    private func side(_ r: Recipe) -> some View {
        let snippet = quickStart(r)
        return VStack(alignment: .leading, spacing: 16) {
            sideCard {
                Text("Quick start").font(.system(size: 13, weight: .semibold))
                ScrollView(.horizontal) {
                    Text(snippet).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(light: 0x3F3F46, dark: 0xD4D4D8))
                        .lineSpacing(4).textSelection(.enabled).fixedSize().padding(12)
                }
                .scrollIndicators(.never)
                .background(Color.pageBackground, in: RoundedRectangle(cornerRadius: .corner(8), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: .corner(8), style: .continuous).strokeBorder(Color.hairline))
                Button("Copy snippet") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                }
                .buttonStyle(DesignButtonStyle(prominent: false, height: 34))
            }
            sideCard {
                Text("How memory is shared").font(.system(size: 13, weight: .semibold))
                Text("Models share memory, keeping \(AppState.systemReserve / 1_000_000_000) GB for the system. When one doesn't fit, the least recently used stops.")
                    .font(.system(size: 13)).foregroundStyle(Color.text3).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            sideCard(border: Color.danger.opacity(0.35)) {
                Text("Remove model").font(.system(size: 13, weight: .semibold))
                Text("Nothing on the Spark is changed.")
                    .font(.system(size: 13)).foregroundStyle(Color.text3).fixedSize(horizontal: false, vertical: true)
                Button("Remove…") { confirmDelete = true }.buttonStyle(.plain).foregroundStyle(Color.danger).font(.system(size: 13, weight: .medium))
            }
        }
    }

    private func quickStart(_ r: Recipe) -> String {
        let auth = state.config.gateway.apiKey.isEmpty ? "" : "\n  -H \"Authorization: Bearer \(state.toolGateway.apiKey)\" \\"
        let body = r.isEmbedding
            ? "'{\"model\": \"\(r.apiID)\",\n       \"input\": \"Hello\"}'"
            : "'{\"model\": \"\(r.apiID)\",\n       \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"
        return "curl \(state.apiBaseURL)/\(r.isEmbedding ? "embeddings" : "chat/completions") \\\(auth)\n  -H \"Content-Type: application/json\" \\\n  -d \(body)"
    }

    // MARK: Building blocks

    private func canStart(_ r: Recipe) -> Bool {
        r.enabled && !r.startCommand.isEmpty && state.route != nil && !state.isBusy
    }

    private func group(_ title: String, _ subtitle: String?, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.text3).fixedSize(horizontal: false, vertical: true) }
            }
            card(content)
        }
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(12), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: .corner(12), style: .continuous).strokeBorder(Color.cardBorder))
            .clipShape(RoundedRectangle(cornerRadius: .corner(12), style: .continuous))
    }

    private func sideCard(border: Color = Color.cardBorder, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(12), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: .corner(12), style: .continuous).strokeBorder(border))
    }

    private func row(_ label: String, sub: String? = nil, note: String? = nil, @ViewBuilder _ trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                if let sub { Text(sub).font(.system(size: 12)).foregroundStyle(Color.text2).fixedSize(horizontal: false, vertical: true) }
                if let note {
                    Label(note, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(VizColor.warning)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func field(_ label: String, @ViewBuilder _ input: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.text3)
            input()
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.pageBackground, in: RoundedRectangle(cornerRadius: .corner(8), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: .corner(8), style: .continuous).strokeBorder(Color(light: 0xE4E4E7, dark: 0x26262B)))
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A start or stop command: title, Copy, and the editable command on the page's dark well.
private struct CommandBox: View {
    let title: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                CopyButton(text: text).foregroundStyle(Color.text3).disabled(text.isEmpty)
            }
            HStack(alignment: .top, spacing: 8) {
                Text("$").foregroundStyle(Color.text2)
                TextField(title, text: $text, prompt: Text(prompt), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...12)
                    .foregroundStyle(Color(light: 0x3F3F46, dark: 0xD4D4D8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(4)
            .padding(12)
            .background(Color.pageBackground, in: RoundedRectangle(cornerRadius: .corner(8), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: .corner(8), style: .continuous).strokeBorder(Color.hairline))
        }
        .font(.system(size: 13))
        .padding(16)
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
        VStack(alignment: .leading, spacing: 14) {
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speculative drafts (\(source))")
                        Text("Faster decoding, same replies.").font(.system(size: 12)).foregroundStyle(Color.text2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    static func footer(_ c: TensorFold.Context, model: TensorFold.Model) -> String {
        var s = "Changes apply at the next start."
        if case .yarn = c {
            s += " Use YaRN only past \(model.window.formatted()) tokens; it changes every reply."
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
        VStack(alignment: .leading, spacing: 14) {
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
        }
    }
}
