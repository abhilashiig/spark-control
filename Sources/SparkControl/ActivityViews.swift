import SwiftUI

struct DiscoveredView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?

    var body: some View {
        Group {
            if let names = state.discovered, !names.isEmpty {
                List(names, id: \.self) { name in
                    HStack(spacing: 10) {
                        Image(systemName: "shippingbox").foregroundStyle(.secondary)
                        Text(name).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let id = state.recipeID(forOllama: name) {
                            Button("Configured") { selection = .model(id) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Set Up…") { selection = .model(state.addRecipe(fromOllama: name)) }
                        }
                    }
                    .padding(.vertical, 3)
                }
            } else if state.discovering {
                ProgressView("Looking for Ollama models…")
            } else {
                ContentUnavailableView {
                    Label(state.discovered == nil ? "Ollama Models" : "No Ollama Models", systemImage: "shippingbox")
                } description: {
                    Text("Lists the models installed in Ollama on the Spark. Nothing runs until you set one up and enable it.")
                } actions: {
                    Button("Scan Spark") { Task { await state.discover() } }.disabled(state.route == nil)
                }
            }
        }
        .navigationTitle("Discovered")
        .toolbar {
            Button { Task { await state.discover() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(state.discovering || state.route == nil)
        }
        .task { if state.discovered == nil, state.route != nil { await state.discover() } }
    }
}

struct RequestsView: View {
    @Environment(AppState.self) private var state
    @State private var selected: RequestEntry.ID?

    var body: some View {
        VSplitView {
            Table(state.requests, selection: $selected) {
                TableColumn("Time") { e in Text(e.date, format: .dateTime.hour().minute().second()) }.width(76)
                TableColumn("Model", value: \.model)
                TableColumn("Endpoint", value: \.path)
                TableColumn("Status") { e in
                    Text(e.status == 0 ? "…" : "\(e.status)")
                        .foregroundStyle(e.status >= 400 ? Color.red : Color.primary)
                }
                .width(50)
                // Same split as Kilo: In = uncached prompt, Out = output without reasoning.
                TableColumn("In") { e in Text(e.prompt > 0 ? (e.prompt - e.cached).compact : "—").monospacedDigit() }.width(56)
                TableColumn("Cached") { e in Text(e.prompt > 0 ? e.cached.compact : "—").monospacedDigit() }.width(56)
                TableColumn("Out") { e in Text(e.prompt > 0 ? (e.completion - e.reasoning).compact : "—").monospacedDigit() }.width(48)
                TableColumn("Reason") { e in Text(e.prompt > 0 ? e.reasoning.compact : "—").monospacedDigit() }.width(52)
                TableColumn("Cost") { e in Text(e.cost.usd).monospacedDigit() }.width(70)
                TableColumn("Duration") { e in
                    Text(e.duration > 0 ? e.duration.formatted(.number.precision(.fractionLength(1))) + "s" : "").monospacedDigit()
                }
                .width(64)
            }
            .frame(minHeight: 180)

            ScrollView {
                Text(detail)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(minHeight: 120)
        }
        .overlay {
            if state.requests.isEmpty {
                ContentUnavailableView("No Requests Yet", systemImage: "arrow.left.arrow.right",
                                       description: Text("Point your clients at \(state.apiBaseURL)"))
            }
        }
        .navigationTitle("Requests")
    }

    private var detail: String {
        guard let e = state.requests.first(where: { $0.id == selected }) else {
            return "Select a request to see exactly what was sent to the Spark."
        }
        var text = "\(e.method) \(e.path) → \(e.model)\n"
        if let err = e.error { text += "Error: \(err)\n" }
        text += "\nForwarded body:\n"
        if let obj = try? JSONSerialization.jsonObject(with: Data(e.forwarded.utf8)),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            text += String(decoding: pretty, as: UTF8.self)
        } else {
            text += e.forwarded.isEmpty ? "(empty)" : e.forwarded
        }
        return text
    }
}

struct UsageView: View {
    @Environment(AppState.self) private var state
    @State private var period = Period.month
    @State private var confirmReset = false

    enum Period: String, CaseIterable, Identifiable {
        case today = "Today", month = "30 Days", all = "All Time"
        var id: Self { self }
        var since: Date {
            switch self {
            case .today: Calendar.current.startOfDay(for: .now)
            case .month: .now.addingTimeInterval(-30 * 86_400)
            case .all: .distantPast
            }
        }
    }

    private struct Row: Identifiable {
        var id: String { model }
        var model: String
        var requests = 0, prompt = 0, cached = 0, completion = 0, reasoning = 0
        var cost = 0.0
        // Kilo's split: In excludes cached tokens, Out excludes reasoning.
        var input: Int { prompt - cached }
        var output: Int { completion - reasoning }
        var hitRate: String { prompt > 0 ? (Double(cached) / Double(prompt)).formatted(.percent.precision(.fractionLength(1))) : "—" }
    }

    var body: some View {
        let since = period.since
        let rows = Dictionary(grouping: state.usage.filter { $0.date >= since }, by: \.model)
            .map { model, recs in
                Row(model: model, requests: recs.count, prompt: recs.reduce(0) { $0 + $1.prompt },
                    cached: recs.reduce(0) { $0 + ($1.cached ?? 0) },
                    completion: recs.reduce(0) { $0 + $1.completion },
                    reasoning: recs.reduce(0) { $0 + ($1.reasoning ?? 0) }, cost: recs.reduce(0) { $0 + $1.cost })
            }
            .sorted { ($0.cost, $0.requests) > ($1.cost, $1.requests) }

        let total = rows.reduce(into: Row(model: "")) {
            $0.requests += $1.requests; $0.prompt += $1.prompt; $0.cached += $1.cached
            $0.completion += $1.completion; $0.reasoning += $1.reasoning; $0.cost += $1.cost
        }

        Form {
            Section {
                VStack(spacing: 14) {
                    HStack(alignment: .top) {
                        stat("Cost", total.cost.usd)
                        stat("Requests", total.requests.formatted())
                        stat("Cache Hit Rate", total.hitRate)
                    }
                    Divider()
                    HStack(alignment: .top) {
                        stat("In", total.input.formatted(), small: true)
                        stat("Cache Read", total.cached.formatted(), small: true)
                        stat("Out", total.output.formatted(), small: true)
                        stat("Reasoning", total.reasoning.formatted(), small: true)
                    }
                }
                .padding(.vertical, 6)
            } footer: {
                Text("Counted like Kilo: In excludes cached tokens, Out excludes reasoning.")
            }
            Section("By Model") {
                if rows.isEmpty {
                    Text("No usage in this period.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow {
                            Text("Model"); Text("Requests"); Text("In"); Text("Cached"); Text("Out"); Text("Reasoning"); Text("Hit Rate"); Text("Cost")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(rows) { r in
                            GridRow {
                                Text(r.model).lineLimit(1)
                                Text(r.requests.formatted())
                                Text(r.input.compact)
                                Text(r.cached.compact)
                                Text(r.output.compact)
                                Text(r.reasoning.compact)
                                Text(r.hitRate)
                                Text(r.cost.usd)
                            }
                            .monospacedDigit()
                        }
                    }
                }
            }
            Section {
                Button("Reset Usage…", role: .destructive) { confirmReset = true }
                    .disabled(state.usage.isEmpty)
            } footer: {
                Text("Costs are computed from each model's prices. Nothing is billed.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Usage")
        .toolbar {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .confirmationDialog("Reset all usage history?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { state.resetUsage() }
        } message: {
            Text("This permanently deletes the usage history stored on this Mac.")
        }
    }

    private func stat(_ title: String, _ value: String, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(small ? .title3.weight(.medium) : .title2.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LogsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(state.logs) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(l.date, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.tertiary)
                            Text(l.text)
                                .foregroundStyle(l.event ? .primary : .secondary)
                                .fontWeight(l.event ? .medium : .regular)
                        }
                        .id(l.id)
                    }
                }
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .onChange(of: state.logs.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .overlay {
            if state.logs.isEmpty { ContentUnavailableView("No Logs", systemImage: "text.alignleft") }
        }
        .navigationTitle("Logs")
        .toolbar {
            Button { state.logs.removeAll() } label: { Label("Clear", systemImage: "trash") }
        }
    }
}
