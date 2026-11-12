import SwiftUI

// MARK: Running

extension AppState {
    /// Starts the model if needed, runs the benchmark on the Spark and keeps the result.
    /// Other models can't be switched to while it runs.
    func runBenchmark(_ r: Recipe) async {
        guard bench?.running != true else { return }
        bench = (r.id, [], nil, true)
        defer { bench?.running = false }
        func say(_ s: String) { bench?.lines.append(s) }

        if phase(for: r) != .ready {
            say("Starting \(r.name)…")
            do { try await switchTo(r) } catch {
                say("Couldn't start \(r.name): \(error.localizedDescription)")
                return
            }
        }
        guard let target = sshTarget, let r = config.recipes.first(where: { $0.id == r.id }) else {
            say("The Spark is unreachable.")
            return
        }
        let key: String? = r.tensorfold != nil || r.vllm != nil ? "\"$(cat \"\(TensorFold.dataDir)/api-key\")\"" : r.backendKey.map(SSH.quote)
        let launch = Benchmark.launchScript(port: port(of: r), model: r.upstreamModel, keyExpr: key)
        let res = await SSH.run(target, "bash -c \(SSH.quote(launch))", timeout: 30)
        guard res.code == 0, let pid = res.output.split(separator: "\n").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
            say("Couldn't start the benchmark: \(res.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }
        bench?.pid = pid
        event("Benchmarking \(r.name)")

        // Follow the log. If SSH drops (the Mac slept), reattach while the run is still going.
        let found = Box<Benchmark.Result?>(nil)
        let log = "\"\(Benchmark.dir)/run.log\""
        var from = "+1"
        repeat {
            await SSH.run(target, "tail -n \(from) -f --pid=\(pid) \(log)", timeout: 4 * 3600) { [weak self] line in
                if let result = Benchmark.parse(line) { found.value = result; return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.bench?.lines.append(line) } }
            }
            from = "0"
            if found.value != nil || bench?.pid == nil { break }
            try? await Task.sleep(for: .seconds(5))
        } while await SSH.run(target, "kill -0 \(pid)", timeout: 15).code == 0

        if found.value == nil, bench?.pid != nil {
            // The result line may have been written while we were disconnected.
            let tail = await SSH.run(target, "grep -a '^\(Benchmark.marker)' \(log) | tail -1", timeout: 30)
            found.value = Benchmark.parse(tail.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let result = found.value else {
            let why = bench?.pid == nil ? "Benchmark cancelled" : "Benchmark ended without results"
            say(why)
            event("\(why): \(r.name)")
            return
        }
        benchResults[r.id, default: []].append(result)
        benchResults[r.id] = Array(benchResults[r.id]!.suffix(10))
        Store.save(benchResults)
        event("Benchmark of \(r.name) finished")
    }

    func deleteBenchmark(_ id: UUID, started: String) {
        benchResults[id]?.removeAll { $0.started == started }
        Store.save(benchResults)
    }

    func clearBenchmarks() {
        benchResults = [:]
        try? FileManager.default.removeItem(at: Store.benchURL)
    }

    func cancelBenchmark() {
        guard let pid = bench?.pid, let target = sshTarget else { return }
        bench?.pid = nil
        Task { await SSH.run(target, "kill \(pid)", timeout: 15) }
    }
}

// MARK: Model page section

struct BenchmarkSection: View {
    @Environment(AppState.self) private var state
    let recipe: Recipe
    @State private var shown: String?
    @State private var showLog = false

    var body: some View {
        let runs = state.benchResults[recipe.id] ?? []
        let mine = state.bench.flatMap { $0.recipe == recipe.id ? $0 : nil }
        let result = runs.last { $0.started == shown } ?? runs.last
        Section {
            HStack {
                if mine?.running == true {
                    ProgressView().controlSize(.small)
                    Text("Running… this can take several minutes.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { state.cancelBenchmark() }
                        .disabled(mine?.pid == nil)
                } else {
                    Text(result.map { "Run \(Self.date($0.started))" } ?? "Not run yet").foregroundStyle(.secondary)
                    Spacer()
                    Button("Run Benchmark") {
                        shown = nil
                        showLog = true
                        Task { await state.runBenchmark(recipe) }
                    }
                    .disabled(!recipe.enabled || recipe.startCommand.isEmpty || state.route == nil || state.isBusy)
                }
            }
            if let mine, !mine.lines.isEmpty {
                if mine.running {
                    LogBox(lines: mine.lines)
                } else {
                    DisclosureGroup("Output", isExpanded: $showLog) { LogBox(lines: mine.lines) }
                }
            }
            if runs.count > 1, mine?.running != true {
                RunComparison(recipe: recipe.id, runs: runs, selected: result?.started) { shown = $0 }
            }
            if let result, mine?.running != true {
                ResultTables(result: result)
            }
        } header: {
            Text("Benchmark")
        } footer: {
            Text("Runs on the Spark: one request each at 32k, 64k, 128k and 200k-token prompts (sizes past the model's context are replaced by the largest that fits), then 1, 2 and 4 concurrent 1k-token requests, 128 output tokens each. Starts the model if needed, and other models can't be switched to until it finishes. Each run is also saved on the Spark in ~/spark-bench-results.")
        }
    }

    static func date(_ iso: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: iso)?.formatted(date: .abbreviated, time: .shortened) ?? iso
    }
}

extension Benchmark.Result {
    private static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
    /// Averages over the single-request sizes, so they're comparable across runs with the same sizes.
    var decode: Double? { Self.mean(single.compactMap(\.tgTps)) }
    var prefill: Double? { Self.mean(single.compactMap(\.ppTps)) }
    /// At the smallest prompt.
    var ttft: Double? { single.first { $0.error == nil }?.ttftMs.map { $0 / 1000 } }
    var batchDecode: Double? { batch.compactMap(\.tgTps).max() }
    var peakMem: Double? { single.compactMap(\.peakMemGb).max() }
}

/// The saved runs of one model side by side, best first by the chosen metric.
private struct RunComparison: View {
    enum SortKey: String, CaseIterable, Identifiable {
        case decode = "Decode", prefill = "Prefill", ttft = "TTFT", batch = "Concurrent", newest = "Newest"
        var id: Self { self }
    }

    @Environment(AppState.self) private var state
    let recipe: UUID
    let runs: [Benchmark.Result]
    let selected: String?
    let select: (String) -> Void
    @AppStorage("benchSort") private var sort = SortKey.decode

    private var sorted: [Benchmark.Result] {
        // Higher is better except TTFT; runs missing the metric go last.
        func key(_ r: Benchmark.Result) -> Double? {
            switch sort {
            case .decode: r.decode
            case .prefill: r.prefill
            case .ttft: r.ttft.map { -$0 }
            case .batch: r.batchDecode
            case .newest: nil
            }
        }
        if sort == .newest { return runs.reversed() }
        return runs.sorted { (key($0) ?? -.infinity) > (key($1) ?? -.infinity) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Sort by", selection: $sort) {
                ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("Run").gridColumnAlignment(.leading)
                    Text("Decode"); Text("Prefill"); Text("TTFT"); Text("Concurrent"); Text("Peak mem")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(sorted.enumerated()), id: \.element.started) { i, r in
                    GridRow {
                        Label(BenchmarkSection.date(r.started), systemImage: r.started == selected ? "largecircle.fill.circle" : "circle")
                        Text(rate(r.decode)); Text(rate(r.prefill))
                        Text(r.ttft.map { String(format: "%.2f s", $0) } ?? "–")
                        Text(rate(r.batchDecode))
                        Text(r.peakMem.map { String(format: "%.1f GB", $0) } ?? "–")
                    }
                    .fontWeight(i == 0 && sort != .newest ? .semibold : .regular)
                    .contentShape(Rectangle())
                    .onTapGesture { select(r.started) }
                    .contextMenu {
                        Button("Delete Run", role: .destructive) { state.deleteBenchmark(recipe, started: r.started) }
                    }
                }
            }
            .monospacedDigit()
            .font(.callout)
            Text("Decode and prefill average the single-request sizes; TTFT is at the smallest prompt; Concurrent is the best total decode. Click a run to see its details, right-click to delete it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func rate(_ v: Double?) -> String { v.map { "\($0.formatted(.number.precision(.fractionLength($0 < 100 ? 1 : 0)))) t/s" } ?? "–" }
}

private struct ResultTables: View {
    let result: Benchmark.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !result.single.isEmpty {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Prompt").gridColumnAlignment(.leading)
                        Text("TTFT"); Text("Prefill"); Text("Decode"); Text("E2E"); Text("Peak mem")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(result.single, id: \.self) { s in
                        GridRow {
                            Text(tokens(s.pp))
                            if let error = s.error {
                                Text(error).foregroundStyle(.red).lineLimit(2).gridCellColumns(5).gridCellAnchor(.leading)
                            } else {
                                Text(seconds(s.ttftMs.map { $0 / 1000 }))
                                Text(rate(s.ppTps)); Text(rate(s.tgTps))
                                Text(seconds(s.e2eS))
                                Text(s.peakMemGb.map { String(format: "%.1f GB", $0) } ?? "–")
                            }
                        }
                    }
                }
            }
            if !result.batch.isEmpty {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Concurrent \(tokens(result.batchPp ?? 1024))").gridColumnAlignment(.leading)
                        Text("Decode"); Text("Speedup"); Text("Prefill"); Text("TTFT"); Text("E2E")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(result.batch, id: \.self) { b in
                        GridRow {
                            Text("\(b.batch)×")
                            if let error = b.error {
                                Text(error).foregroundStyle(.red).lineLimit(2).gridCellColumns(5).gridCellAnchor(.leading)
                            } else {
                                Text(rate(b.tgTps))
                                Text(b.speedup.map { String(format: "%.2f×", $0) } ?? "–")
                                Text(rate(b.ppTps))
                                Text(seconds(b.ttftMs.map { $0 / 1000 }))
                                Text(seconds(b.e2eS))
                            }
                        }
                    }
                }
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .font(.callout)
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }

    private var note: String? {
        var parts: [String] = []
        if let skipped = result.skipped, !skipped.isEmpty {
            parts.append("Skipped \(skipped.map(tokens).joined(separator: ", ")): past the \(result.context.map { $0.formatted() } ?? "")-token context.")
        }
        if !result.exactSizing { parts.append("Prompt sizes are approximate: the server has no /tokenize.") }
        parts.append("Decode is per request for single prompts and the total across requests when concurrent. Model: \(result.model).")
        return parts.joined(separator: " ")
    }

    private func tokens(_ n: Int) -> String { n >= 1024 && n % 1024 == 0 ? "\(n / 1024)k" : n.formatted() }
    private func rate(_ v: Double?) -> String { v.map { "\($0.formatted(.number.precision(.fractionLength($0 < 100 ? 1 : 0)))) t/s" } ?? "–" }
    private func seconds(_ v: Double?) -> String { v.map { $0 < 10 ? String(format: "%.2f s", $0) : String(format: "%.1f s", $0) } ?? "–" }
}
