import SwiftUI
import AppKit
import Charts

// MARK: Sampling

extension AppState {
    /// One reading from the Spark, appended to the history (five minutes at the page's 2-second pace).
    func sampleSpark() async {
        guard let target = sshTarget else { return }
        let res = await SSH.run(target, "bash -c \(SSH.quote(SparkMonitor.script))", timeout: 10)
        guard res.code == 0 else { return }
        let s = SparkMonitor.parse(res.output)
        guard s.memTotal > 0 else { return }
        spark.append(s)
        if spark.count > 150 { spark.removeFirst(spark.count - 150) }
    }

    func measureStorage() async {
        guard let target = sshTarget else { return }
        let res = await SSH.run(target, "bash -c \(SSH.quote(SparkMonitor.storageScript))", timeout: 60)
        if res.code == 0 { sparkStorage = SparkMonitor.parseStorage(res.output) }
    }
}

// MARK: View

struct SparkView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let samples = state.spark
        ScrollView {
            if let now = samples.last {
                VStack(alignment: .leading, spacing: 18) {
                    tiles(now, samples)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        HistoryChart(title: "CPU", unit: "%", points: cpuSeries(samples), domain: 0...100)
                        HistoryChart(title: "GPU", unit: "%", points: samples.compactMap { s in s.gpuUtil.map { (s.date, $0) } }, domain: 0...100)
                        HistoryChart(title: "Memory used", unit: "GB", points: samples.map { ($0.date, gb($0.memUsed)) },
                                     domain: 0...max(1, gb(now.memTotal)))
                        HistoryChart(title: "GPU temperature", unit: "°C", points: samples.compactMap { s in s.gpuTemp.map { (s.date, $0) } },
                                     domain: 0...max(100, (samples.compactMap(\.gpuTemp).max() ?? 0) + 5))
                    }
                    MemoryBreakdown(sample: now)
                    HStack(alignment: .top, spacing: 14) {
                        CoresCard(samples: samples)
                        TemperaturesCard(sample: now)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    StorageCard(sample: now)
                }
                .padding(20)
                .animation(.smooth, value: samples.count)
            } else {
                ContentUnavailableView(state.route == nil ? "Spark unreachable" : "Reading the Spark…",
                                       systemImage: "gauge.with.dots.needle.33percent")
                    .padding(.top, 80)
            }
        }
        .background(Color.pageBackground)
        .navigationTitle("Spark")
        .toolbar {
            Button { Task { await state.openDashboard() } } label: { Label("DGX Dashboard", systemImage: "safari") }
                .help("Open NVIDIA's DGX Dashboard in your browser, through an SSH tunnel")
                .disabled(state.route == nil)
        }
        .task {
            await state.measureStorage()
            while !Task.isCancelled {
                await state.sampleSpark()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func tiles(_ now: SparkMonitor.Sample, _ samples: [SparkMonitor.Sample]) -> some View {
        let cpu = samples.count > 1 ? SparkMonitor.cpuPercent("cpu", from: samples[samples.count - 2], to: now) : nil
        return HStack(spacing: 14) {
            Tile(title: "Memory", symbol: "memorychip.fill", tint: .purple, value: String(format: "%.0f / %.0f GB", gb(now.memUsed), gb(now.memTotal)),
                 detail: String(format: "%.0f GB available", gb(now.memAvailable)),
                 fraction: Double(now.memUsed) / Double(max(1, now.memTotal)),
                 status: now.memAvailable < 12 << 30 ? .warning("Low") : nil)
            Tile(title: "CPU", symbol: "cpu.fill", tint: .blue, value: cpu.map { String(format: "%.0f%%", $0) } ?? "—",
                 detail: "\(now.coreCount) cores · load " + (now.load.first.map { String(format: "%.2f", $0) } ?? "—"),
                 fraction: cpu.map { $0 / 100 })
            Tile(title: "GPU", symbol: "square.stack.3d.up.fill", tint: .green, value: now.gpuUtil.map { String(format: "%.0f%%", $0) } ?? "—",
                 detail: now.clock.map { String(format: "%.0f MHz", $0) } ?? "",
                 fraction: now.gpuUtil.map { $0 / 100 })
            Tile(title: "GPU temperature", symbol: "thermometer.medium", tint: .orange, value: now.gpuTemp.map { String(format: "%.0f °C", $0) } ?? "—",
                 detail: now.power.map { String(format: "%.0f W", $0) } ?? "", status: now.gpuTemp.map(TempStatus.init))
        }
    }

    private func cpuSeries(_ samples: [SparkMonitor.Sample]) -> [(Date, Double)] {
        zip(samples, samples.dropFirst()).compactMap { a, b in SparkMonitor.cpuPercent("cpu", from: a, to: b).map { (b.date, $0) } }
    }
}

private func gb(_ bytes: Int64) -> Double { Double(bytes) / 1e9 }

// MARK: Pieces

/// Reserved status colours always come with a word and an icon.
enum TempStatus {
    case good(String), warning(String), critical(String)

    // ponytail: fixed GPU thresholds; the GB10's throttle point isn't published, so these are conservative guesses.
    init(_ celsius: Double) {
        self = celsius >= 95 ? .critical("Hot") : celsius >= 85 ? .warning("Warm") : .good("Normal")
    }

    var label: String { switch self { case .good(let s), .warning(let s), .critical(let s): s } }
    var color: Color { switch self { case .good: VizColor.good; case .warning: VizColor.warning; case .critical: VizColor.critical } }
    var icon: String { switch self { case .good: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .critical: "flame.fill" } }
}

private struct Tile: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    let detail: String
    var fraction: Double? = nil
    var status: TempStatus? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, tint: tint, size: 24)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if let status {
                    Label(status.label, systemImage: status.icon).font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon).foregroundStyle(status.color)
                }
            }
            Text(value).font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit()
                .minimumScaleFactor(0.6).lineLimit(1)
                .contentTransition(.numericText())
            if let fraction { Meter(fraction: fraction, tint: tint) }
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .card(padding: 14)
    }
}

/// A rounded gradient bar that eases between readings.
private struct Meter: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
        .animation(.smooth, value: fraction)
    }
}

/// One series over the last five minutes, with a hover readout.
private struct HistoryChart: View {
    let title: String
    let unit: String
    let points: [(Date, Double)]
    let domain: ClosedRange<Double>
    @State private var hover: Date?

    var body: some View {
        let shown = hover.flatMap { h in points.min { abs($0.0.timeIntervalSince(h)) < abs($1.0.timeIntervalSince(h)) } } ?? points.last
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(shown.map { format($0.1) } ?? "—").font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(VizColor.series[0])
                    .contentTransition(.numericText())
            }
            Chart {
                ForEach(points, id: \.0) { p in
                    AreaMark(x: .value("Time", p.0), y: .value(unit, p.1))
                        .foregroundStyle(LinearGradient(colors: [VizColor.series[0].opacity(0.3), VizColor.series[0].opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.0), y: .value(unit, p.1))
                        .foregroundStyle(VizColor.series[0])
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                if let hover, let shown {
                    RuleMark(x: .value("Time", hover)).foregroundStyle(.secondary.opacity(0.5))
                    PointMark(x: .value("Time", shown.0), y: .value(unit, shown.1))
                        .foregroundStyle(VizColor.series[0]).symbolSize(60)
                }
            }
            .chartYScale(domain: domain)
            .chartXScale(domain: (points.last?.0 ?? .now).addingTimeInterval(-300)...(points.last?.0 ?? .now))
            .chartPlotStyle { $0.clipped() }
            .chartXAxis { AxisMarks(values: .stride(by: .minute)) { AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
            .chartYAxis { AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel() } }
            .chartXSelection(value: $hover)
            .frame(height: 130)
        }
    }

    private func format(_ v: Double) -> String {
        unit == "%" ? String(format: "%.0f%%", v) : unit == "GB" ? String(format: "%.1f GB", v) : String(format: "%.0f %@", v, unit)
    }
}

/// What holds the memory: each process using the GPU, the rest of the system, and what's free.
private struct MemoryBreakdown: View {
    let sample: SparkMonitor.Sample

    var body: some View {
        let parts = self.parts
        Card(title: "Memory by Process") {
            GeometryReader { g in
                HStack(spacing: 2) {
                    let usable = g.size.width - CGFloat(parts.count - 1) * 2
                    ForEach(parts, id: \.name) { p in
                        RoundedRectangle(cornerRadius: 4).fill(p.color)
                            .frame(width: width(p.bytes, of: usable))
                            .help(p.name + ": " + String(format: "%.1f GB", gb(p.bytes)))
                    }
                }
            }
            .frame(height: 22)
            FlowLegend(items: parts.map { ($0.name, String(format: "%.1f GB", gb($0.bytes)), $0.color) })
            if sample.processes.isEmpty {
                Text("No process is using the GPU.").font(.caption).foregroundStyle(.secondary)
            }
            if sample.swapTotal - sample.swapFree > 1 << 30 {
                Label(String(format: "%.1f GB in swap: memory is overcommitted", gb(sample.swapTotal - sample.swapFree)),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(VizColor.warning)
            }
        }
    }
}

extension MemoryBreakdown {
    typealias Part = (name: String, bytes: Int64, color: Color)

    var parts: [Part] {
        let procs = Array(sample.processes.prefix(VizColor.series.count))
        let other = max(0, sample.memUsed - procs.reduce(0) { $0 + $1.bytes })
        var out: [Part] = procs.enumerated().map { i, p in (p.name, p.bytes, VizColor.series[i]) }
        out.append(("System and other", other, Color.secondary.opacity(0.55)))
        out.append(("Available", sample.memAvailable, Color.secondary.opacity(0.18)))
        return out
    }

    func width(_ bytes: Int64, of usable: CGFloat) -> CGFloat {
        max(0, usable * CGFloat(bytes) / CGFloat(max(1, sample.memTotal)))
    }
}

private struct FlowLegend: View {
    let items: [(String, String, Color)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.0) { name, value, color in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                    Text(name).font(.caption)
                    Text(value).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}

private struct CoresCard: View {
    let samples: [SparkMonitor.Sample]
    var body: some View {
        let cores: [(Int, Double)] = {
            guard samples.count > 1, let now = samples.last else { return [] }
            let prev = samples[samples.count - 2]
            return (0..<now.coreCount).compactMap { i in SparkMonitor.cpuPercent("cpu\(i)", from: prev, to: now).map { (i, $0) } }
        }()
        Card(title: "CPU Cores") {
            Chart(cores, id: \.0) { c in
                BarMark(x: .value("Core", "\(c.0)"), y: .value("%", c.1), width: .ratio(0.7))
                    .foregroundStyle(VizColor.series[0])
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
            }
            .chartYScale(domain: 0...100)
            .chartXAxis { AxisMarks { AxisValueLabel().font(.system(size: 8)) } }
            .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) { AxisGridLine(); AxisValueLabel() } }
            .frame(height: 120)
        }
    }
}

private struct TemperaturesCard: View {
    let sample: SparkMonitor.Sample
    var body: some View {
        Card(title: "Temperatures") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                if let t = sample.gpuTemp { row("GPU", t) }
                if let t = sample.zones.max() { row("System, hottest sensor", t) }
                if let t = sample.nvmeTemp { row("SSD", t) }
            }
            if !sample.zones.isEmpty {
                Text("System sensors: " + sample.zones.map { String(format: "%.0f", $0) }.joined(separator: " · ") + " °C")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)  // stretch to the CPU Cores card beside it
        }
    }

    private func row(_ name: String, _ t: Double) -> some View {
        GridRow {
            Text(name)
            Text(String(format: "%.0f °C", t)).monospacedDigit().gridColumnAlignment(.trailing)
            if name == "GPU" {
                let s = TempStatus(t)
                Label(s.label, systemImage: s.icon).font(.caption).foregroundStyle(s.color)
            }
        }
    }
}

private struct StorageCard: View {
    @Environment(AppState.self) private var state
    let sample: SparkMonitor.Sample

    var body: some View {
        Card(title: "Storage") {
            let used = Double(sample.diskUsed) / Double(max(1, sample.diskTotal))
            HStack {
                Text(String(format: "%.0f GB free of %.0f GB", gb(sample.diskFree), gb(sample.diskTotal))).monospacedDigit()
                Spacer()
                Button { Task { await state.measureStorage() } } label: { Label("Measure", systemImage: "arrow.clockwise") }
                    .controlSize(.small)
            }
            Meter(fraction: used, tint: used > 0.9 ? VizColor.critical : VizColor.series[0])
            if let st = state.sparkStorage {
                FlowLegend(items: st.folders.map { ($0.0, String(format: "%.1f GB", gb($0.1)), Color.clear) }
                           + (st.docker.map { [("Docker images", $0, Color.clear)] } ?? []))
            }
        }
    }
}

// MARK: SSH keys

/// The keys that can log in to the Spark as you, with each one's last login, so unknown ones can be removed.
struct SSHKeysView: View {
    @Environment(AppState.self) private var state
    @State private var keys: [SSHKeys.Key]?
    /// Loaded after the keys, as reading sshd's log takes a moment; nil until then.
    @State private var logins: [String: SSHKeys.Login]?
    @State private var failed = false
    @State private var busy = false
    @State private var removing: SSHKeys.Key?
    private let mine = SSHKeys.localFingerprints()

    var body: some View {
        Form {
            Section {
                Text("Each key below can log in to the Spark as you, without a password. Remove any key you don't recognise. A copy of the file from before each removal is kept as ~/.ssh/authorized_keys.spark-control.bak on the Spark.")
                    .foregroundStyle(.secondary)
            }
            if let keys {
                Section("\(keys.count) authorized key\(keys.count == 1 ? "" : "s")") {
                    if keys.isEmpty { Text("No keys.").foregroundStyle(.secondary) }
                    ForEach(keys) { row($0) }
                }
            } else if state.sshTarget == nil {
                ContentUnavailableView("Spark unreachable", systemImage: "key.slash")
            } else if failed {
                ContentUnavailableView("Couldn't read the keys", systemImage: "key.slash",
                                       description: Text("The Spark didn't answer in time. Try Refresh."))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .page()
        .navigationTitle("SSH Keys")
        .toolbar {
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(state.sshTarget == nil || busy)
        }
        .task(id: state.sshTarget) { await load() }
        .confirmationDialog("Remove “\(removing.map(name) ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Key", role: .destructive) { if let k = removing { Task { await remove(k) } } }
        } message: {
            Text("Whoever holds this key can no longer log in to the Spark as you. Sessions already open stay open until they end.")
        }
    }

    private func name(_ k: SSHKeys.Key) -> String { k.comment.isEmpty ? "Unnamed key" : k.comment }

    private func row(_ k: SSHKeys.Key) -> some View {
        let isMine = mine.contains(k.fingerprint)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.fill").foregroundStyle(isMine ? Color.brand : .secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name(k)).font(.headline)
                    if isMine {
                        Text("This Mac").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.brand.opacity(0.15), in: Capsule()).foregroundStyle(Color.brand)
                    }
                }
                Text("\(k.type)  \(k.fingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if !k.options.isEmpty {
                    Text("Restricted: \(k.options)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                // Spark Control logs in with a key, so an empty list means the log isn't readable, not that no key was used.
                if logins == nil {
                    Text("Checking last login…").font(.caption).foregroundStyle(.tertiary)
                } else if let logins, !logins.isEmpty {
                    if let l = logins[k.fingerprint] {
                        Text("Last login \(l.date.formatted(.relative(presentation: .named))) from \(l.from)").font(.caption)
                    } else {
                        Text("No logins in the last 90 days").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Button("Remove", role: .destructive) { removing = k }
                .disabled(isMine || busy)
                .help(isMine ? "This Mac's key: removing it would disconnect Spark Control from the Spark." : "Remove this key from the Spark")
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        guard let target = state.sshTarget else { return }
        let res = await SSH.run(target, SSHKeys.keysCommand, timeout: 15)
        failed = res.code != 0
        guard !failed else { return }
        keys = SSHKeys.keys(res.output)
        let log = await SSH.run(target, "bash -c \(SSH.quote(SSHKeys.loginsScript))", timeout: 60)
        logins = log.code == 0 ? SSHKeys.logins(log.output) : [:]
    }

    private func remove(_ k: SSHKeys.Key) async {
        guard let target = state.sshTarget, !mine.contains(k.fingerprint) else { return }
        busy = true
        defer { busy = false }
        let res = await SSH.run(target, "bash -c \(SSH.quote(SSHKeys.removeScript(k.blob)))", timeout: 20)
        state.event(res.code == 0 ? "Removed SSH key \(name(k)) (\(k.fingerprint)) from the Spark" : "Couldn't remove SSH key \(name(k)): \(res.output)")
        await load()
    }
}
