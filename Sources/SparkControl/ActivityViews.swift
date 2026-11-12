import SwiftUI
import Charts

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
        .navigationTitle("Ollama")
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
                Group {
                    // Same split as Kilo: In = uncached prompt, Out = output without reasoning.
                    TableColumn("In", value: \RequestEntry.inText).width(56)
                    TableColumn("Cached", value: \RequestEntry.cachedText).width(56)
                    TableColumn("Out", value: \RequestEntry.outText).width(48)
                    TableColumn("Reason", value: \RequestEntry.reasonText).width(52)
                    TableColumn("TTFT", value: \RequestEntry.ttftText).width(54)
                    TableColumn("Decode", value: \RequestEntry.decodeText).width(80)
                    TableColumn("Cost", value: \RequestEntry.costText).width(70)
                    TableColumn("Duration", value: \RequestEntry.durationText).width(64)
                }
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
    @State private var period = Period.day
    @State private var confirmReset = false

    enum Period: String, CaseIterable, Identifiable {
        case fourHours = "4h", day = "24h", week = "Week", month = "Month", year = "Year", all = "All Time"
        var id: Self { self }
        var since: Date {
            let hours: Double = switch self {
            case .fourHours: 4
            case .day: 24
            case .week: 24 * 7
            case .month: 24 * 30
            case .year: 24 * 365
            case .all: .infinity
            }
            return hours.isInfinite ? .distantPast : .now.addingTimeInterval(-hours * 3600)
        }
    }

    /// Totals for a set of requests. Token split matches Kilo: In excludes cached, Out excludes reasoning.
    struct Stats: Identifiable {
        var id: String { model }
        var model = ""
        var requests = 0, prompt = 0, cached = 0, completion = 0, reasoning = 0
        var cost = 0.0
        // Speed sums cover streamed requests only.
        var prefillTokens = 0, decodeTokens = 0
        var ttftSum = 0.0, decodeSum = 0.0, durationSum = 0.0
        var ttfts: [Double] = []

        init(model: String = "", _ recs: [UsageRecord] = []) {
            self.model = model
            for r in recs { add(r) }
        }

        mutating func add(_ r: UsageRecord) {
            requests += 1; prompt += r.prompt; cached += r.cached ?? 0
            completion += r.completion; reasoning += r.reasoning ?? 0; cost += r.cost
            if let t = r.ttft, t > 0 {
                ttfts.append(t); ttftSum += t
                prefillTokens += max(r.prompt - (r.cached ?? 0), 0)
            }
            if let d = r.decodeTime, d > 0, r.completion > 1 {
                decodeSum += d; decodeTokens += r.completion - 1
            }
        }

        var input: Int { prompt - cached }
        var output: Int { completion - reasoning }
        var hitRate: Double? { prompt > 0 ? Double(cached) / Double(prompt) : nil }
        /// Token-weighted, so long requests count for what they are.
        var decodeTPS: Double? { decodeSum > 0 ? Double(decodeTokens) / decodeSum : nil }
        var prefillTPS: Double? { ttftSum > 0 && prefillTokens > 0 ? Double(prefillTokens) / ttftSum : nil }
        var avgTTFT: Double? { ttfts.isEmpty ? nil : ttftSum / Double(ttfts.count) }
        func ttftPercentile(_ p: Double) -> Double? {
            guard !ttfts.isEmpty else { return nil }
            let sorted = ttfts.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        var avgPrompt: Int? { requests > 0 ? prompt / requests : nil }
        var avgOutput: Int? { requests > 0 ? completion / requests : nil }
    }

    var body: some View {
        let records = state.usage.filter { $0.date >= period.since }
        let rows = Dictionary(grouping: records, by: \.model)
            .map { Stats(model: $0.key, $0.value) }
            .sorted { ($0.cost, $0.requests) > ($1.cost, $1.requests) }
        let total = Stats(records)
        let speedPoints = records.compactMap { r in
            Speed.decode(completion: r.completion, decodeTime: r.decodeTime).map { (date: r.date, model: r.model, tps: $0) }
        }

        Form {
            Section {
                VStack(spacing: 14) {
                    HStack(alignment: .top) {
                        stat("Cost", total.cost.usd)
                        stat("Requests", total.requests.formatted())
                        stat("Cache Hit Rate", total.hitRate.map(Self.percent) ?? "—")
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

            Section {
                VStack(spacing: 14) {
                    HStack(alignment: .top) {
                        stat("Decode", total.decodeTPS.map(Self.tps) ?? "—")
                        stat("Prefill", total.prefillTPS.map(Self.tps) ?? "—")
                        stat("Time to First Token", total.avgTTFT.map(Self.secs) ?? "—")
                    }
                    Divider()
                    HStack(alignment: .top) {
                        stat("TTFT Median", total.ttftPercentile(0.5).map(Self.secs) ?? "—", small: true)
                        stat("TTFT P95", total.ttftPercentile(0.95).map(Self.secs) ?? "—", small: true)
                        stat("Avg Prompt", total.avgPrompt.map { $0.compact } ?? "—", small: true)
                        stat("Avg Output", total.avgOutput.map { $0.compact } ?? "—", small: true)
                    }
                    if speedPoints.count > 1 {
                        Chart(speedPoints, id: \.date) { p in
                            PointMark(x: .value("Time", p.date), y: .value("Decode tok/s", p.tps))
                                .foregroundStyle(by: .value("Model", p.model))
                                .symbolSize(24)
                        }
                        .chartYAxisLabel("Decode tok/s")
                        .chartLegend(rows.count > 1 ? .visible : .hidden)
                        .frame(height: 140)
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Performance")
            } footer: {
                Text("From streamed requests. Decode counts generated tokens after the first; prefill counts uncached prompt tokens over time to first token, so heavily cached requests show low prefill. Averages are token-weighted.")
            }

            Section("By Model") {
                if rows.isEmpty {
                    Text("No usage in this period.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Text("Model"); Text("Requests"); Text("In"); Text("Cached"); Text("Out"); Text("Reasoning")
                            Text("Hit Rate"); Text("Decode"); Text("Prefill"); Text("TTFT"); Text("Cost")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(rows) { r in
                            GridRow {
                                // Wrap long names instead of truncating; the numeric columns can't shrink.
                                Text(r.model)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(minWidth: 160, alignment: .leading)
                                    .textSelection(.enabled)
                                    .help(r.model)
                                Text(r.requests.formatted())
                                Text(r.input.compact)
                                Text(r.cached.compact)
                                Text(r.output.compact)
                                Text(r.reasoning.compact)
                                Text(r.hitRate.map(Self.percent) ?? "—")
                                Text(r.decodeTPS.map(Self.tps) ?? "—")
                                Text(r.prefillTPS.map(Self.tps) ?? "—")
                                Text(r.avgTTFT.map(Self.secs) ?? "—")
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

    static func tps(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(v < 100 ? 1 : 0))) + " tok/s" }
    static func secs(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(v < 10 ? 2 : 1))) + "s" }
    static func percent(_ v: Double) -> String { v.formatted(.percent.precision(.fractionLength(1))) }

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

private extension RequestEntry {
    var inText: String { prompt > 0 ? (prompt - cached).compact : "—" }
    var cachedText: String { prompt > 0 ? cached.compact : "—" }
    var outText: String { prompt > 0 ? (completion - reasoning).compact : "—" }
    var reasonText: String { prompt > 0 ? reasoning.compact : "—" }
    var ttftText: String { ttft.map(UsageView.secs) ?? "—" }
    var decodeText: String { Speed.decode(completion: completion, decodeTime: decodeTime).map(UsageView.tps) ?? "—" }
    var costText: String { cost.usd }
    var durationText: String { duration > 0 ? UsageView.secs(duration) : "" }
}
