import SwiftUI
import AppKit
import Charts

// MARK: Sampling

extension AppState {
    /// One reading from the Spark, appended to the history (an hour at the page's 2-second pace).
    func sampleSpark() async {
        guard let target = sshTarget else { return }
        let res = await SSH.run(target, "bash -c \(SSH.quote(SparkMonitor.script))", timeout: 10)
        guard res.code == 0 else { return }
        let s = SparkMonitor.parse(res.output)
        guard s.memTotal > 0 else { return }
        spark.append(s)
        if spark.count > 1800 { spark.removeFirst(spark.count - 1800) }
    }

    func measureStorage() async {
        guard let target = sshTarget else { return }
        let res = await SSH.run(target, "bash -c \(SSH.quote(SparkMonitor.storageScript))", timeout: 60)
        if res.code == 0 { sparkStorage = SparkMonitor.parseStorage(res.output) }
    }
}

// MARK: View

/// Chart and bar colours from the design: periwinkle for load, teal for memory, amber for heat.
private enum OverviewColor {
    static let load = Color(light: 0x5B6CF0, dark: 0x8B9DFF)
    static let memory = Color(light: 0x0D9488, dark: 0x5EEAD4)
    static let heat = Color(light: 0xD97706, dark: 0xFBBF24)
    static let pink = Color(light: 0xDB2777, dark: 0xF472B6)
    static let other = Color(light: 0xA1A1AA, dark: 0x6B6B74)
    static let track = Color(light: 0xF0F0F2, dark: 0x1C1C21)
    static let trackLine = Color(light: 0xD4D4D8, dark: 0x3A3A42)
    static let grid = Color(light: 0xEDEDF0, dark: 0x1F1F23)
}

struct SparkView: View {
    @Environment(AppState.self) private var state
    /// Seconds of history the charts show. ponytail: readings are only taken while this page is open and kept for an
    /// hour, so there's no 24 h range; a longer one needs sampling in the background.
    @AppStorage("overviewRange") private var range = 300

    var body: some View {
        let all = state.spark
        let samples = all.last.map { last in all.filter { last.date.timeIntervalSince($0.date) <= Double(range) } } ?? []
        VStack(spacing: 0) {
            header(all.last)
            ScrollView {
                if let now = samples.last {
                    VStack(alignment: .leading, spacing: 16) {
                        tiles(now, all)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12)], spacing: 12) {
                            HistoryChart(title: "CPU", unit: "%", color: OverviewColor.load, points: cpuSeries(samples), domain: 0...100, range: range)
                            HistoryChart(title: "GPU", unit: "%", color: OverviewColor.load,
                                         points: samples.compactMap { s in s.gpuUtil.map { (s.date, $0) } }, domain: 0...100, range: range)
                            HistoryChart(title: "Memory used", unit: "GB", color: OverviewColor.memory, points: samples.map { ($0.date, gb($0.memUsed)) },
                                         domain: 0...max(1, gb(now.memTotal)), range: range)
                            HistoryChart(title: "GPU temperature", unit: "°C", color: OverviewColor.heat,
                                         points: samples.compactMap { s in s.gpuTemp.map { (s.date, $0) } },
                                         domain: 0...max(100, (samples.compactMap(\.gpuTemp).max() ?? 0) + 5), range: range)
                        }
                        MemoryBreakdown(sample: now)
                        let pair = Group { CoresCard(samples: all); TemperaturesCard(sample: now) }
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 12) { pair.frame(minWidth: 380) }.fixedSize(horizontal: false, vertical: true)
                            VStack(spacing: 12) { pair }
                        }
                        StorageCard(sample: now)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 48)
                    .animation(.smooth, value: samples.count)
                } else {
                    ContentUnavailableView(state.route == nil ? "Spark unreachable" : "Reading the Spark…",
                                           systemImage: "gauge.with.dots.needle.33percent")
                        .padding(.top, 80)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.pageBackground)
        .task {
            await state.measureStorage()
            while !Task.isCancelled {
                await state.sampleSpark()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Title, a Live pill and what needs attention, then the time range and DGX Dashboard.
    private func header(_ now: SparkMonitor.Sample?) -> some View {
        let live = state.route != nil && now.map { Date().timeIntervalSince($0.date) < 30 } == true
        return HStack(spacing: 12) {
            Text("Overview").pageTitle()
            HStack(spacing: 6) {
                Circle().fill(live ? Color.running : Color.text2).frame(width: 6, height: 6)
                Text(live ? "Live" : state.route == nil ? "Offline" : "Waiting")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(live ? Color.running : Color.text2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((live ? Color.running : Color.text2).opacity(0.1), in: RoundedRectangle(cornerRadius: .corner(999)))
            if let now {
                Text(health(now)).font(.system(size: 13)).foregroundStyle(Color.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            Segments(selection: $range, options: [(300, "5 min"), (3600, "1 h")])
            Button { Task { await state.openDashboard() } } label: { Label("DGX Dashboard", systemImage: "safari") }
                .labelStyle(.iconOnly)
                .buttonStyle(GhostIconStyle())
                .help("Open NVIDIA's DGX Dashboard in your browser, through an SSH tunnel")
                .disabled(state.route == nil)
        }
        .padding(.leading, 28)
        .padding(.trailing, 20)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .background { Color.pageBackground.gesture(WindowDragGesture()) }
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func health(_ s: SparkMonitor.Sample) -> String {
        var issues: [String] = []
        if s.memAvailable < 12 << 30 { issues.append("Memory low") }
        if s.swapTotal - s.swapFree > 1 << 30 { issues.append("Swapping") }
        if let t = s.gpuTemp, case .good = TempStatus(t) {} else if let t = s.gpuTemp { issues.append("GPU \(TempStatus(t).label.lowercased())") }
        if s.diskTotal > 0, Double(s.diskUsed) / Double(s.diskTotal) > 0.9 { issues.append("Disk almost full") }
        return issues.isEmpty ? "All systems normal" : issues.joined(separator: " · ")
    }

    private func tiles(_ now: SparkMonitor.Sample, _ samples: [SparkMonitor.Sample]) -> some View {
        let cpu = samples.count > 1 ? SparkMonitor.cpuPercent("cpu", from: samples[samples.count - 2], to: now) : nil
        let mem = Double(now.memUsed) / Double(max(1, now.memTotal))
        let idle = { (v: Double?) in v.map { $0 < 5 ? "Idle" : "Busy" } }
        let tiles = Group {
            Tile(title: "Memory", value: String(format: "%.0f", gb(now.memUsed)), unit: String(format: "/ %.0f GB", gb(now.memTotal)),
                 detail: String(format: "%.0f GB available", gb(now.memAvailable)),
                 fraction: mem, tint: Color.text,
                 tag: now.memAvailable < 12 << 30 ? ("Low", VizColor.warning) : (String(format: "%.0f%%", mem * 100), Color.text3))
            Tile(title: "CPU", value: cpu.map { String(format: "%.0f", $0) } ?? "—", unit: "%",
                 detail: "\(now.coreCount) cores · load " + (now.load.first.map { String(format: "%.2f", $0) } ?? "—"),
                 fraction: cpu.map { $0 / 100 }, tint: OverviewColor.load, tag: idle(cpu).map { ($0, Color.text3) })
            Tile(title: "GPU", value: now.gpuUtil.map { String(format: "%.0f", $0) } ?? "—", unit: "%",
                 detail: now.clock.map { String(format: "%@ MHz", Int($0).formatted()) } ?? "",
                 fraction: now.gpuUtil.map { $0 / 100 }, tint: OverviewColor.load, tag: idle(now.gpuUtil).map { ($0, Color.text3) })
            Tile(title: "GPU temperature", value: now.gpuTemp.map { String(format: "%.0f", $0) } ?? "—", unit: "°C",
                 detail: now.power.map { String(format: "%.0f W draw", $0) } ?? "",
                 fraction: now.gpuTemp.map { $0 / 100 }, tint: now.gpuTemp.map { TempStatus($0).color } ?? Color.running,
                 tag: now.gpuTemp.map { (TempStatus($0).label, TempStatus($0).color) })
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { tiles.frame(minWidth: 200) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) { tiles }
        }
    }

    private func cpuSeries(_ samples: [SparkMonitor.Sample]) -> [(Date, Double)] {
        zip(samples, samples.dropFirst()).compactMap { a, b in SparkMonitor.cpuPercent("cpu", from: a, to: b).map { (b.date, $0) } }
    }
}

private func gb(_ bytes: Int64) -> Double { Double(bytes) / 1e9 }

// MARK: Pieces

/// Reserved status colours always come with a word.
enum TempStatus {
    case good(String), warning(String), critical(String)

    // ponytail: fixed GPU thresholds; the GB10's throttle point isn't published, so these are conservative guesses.
    init(_ celsius: Double) {
        self = celsius >= 95 ? .critical("Hot") : celsius >= 85 ? .warning("Warm") : .good("Normal")
    }

    var label: String { switch self { case .good(let s), .warning(let s), .critical(let s): s } }
    var color: Color { switch self { case .good: Color.running; case .warning: VizColor.warning; case .critical: Color.danger } }
    var icon: String { switch self { case .good: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .critical: "flame.fill" } }
}

/// A card with the design's 13pt semibold title and an optional mono note on the right.
private struct Panel<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.text)
                Spacer(minLength: 0)
                trailing
            }
            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: 18)
    }
}

private func note(_ s: String, mono: Bool = true) -> some View {
    Text(s).font(.system(size: 12, design: mono ? .monospaced : .default)).foregroundStyle(Color.text3).lineLimit(1)
}

private struct Tile: View {
    let title: String
    let value: String
    let unit: String
    let detail: String
    var fraction: Double?
    let tint: Color
    var tag: (String, Color)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(Color.text3).lineLimit(1)
                Spacer(minLength: 0)
                if let tag { Text(tag.0).font(.system(size: 12)).foregroundStyle(tag.1) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 28, weight: .semibold)).tracking(-0.8).monospacedDigit()
                    .contentTransition(.numericText())
                Text(unit).font(.system(size: 14)).foregroundStyle(Color.text3)
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            Meter(fraction: fraction ?? 0, tint: tint)
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.text2).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 2)
        .card(padding: 16)
        .accessibilityElement(children: .combine)
    }
}

/// A 4pt bar that eases between readings.
private struct Meter: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        GeometryReader { g in
            RoundedRectangle(cornerRadius: .corner(999)).fill(Color(light: 0xE4E4E7, dark: 0x222227))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: .corner(999)).fill(tint).frame(width: max(fraction > 0 ? 2 : 0, g.size.width * min(max(fraction, 0), 1)))
                }
        }
        .frame(height: 4)
        .animation(.smooth, value: fraction)
    }
}

/// One series over the chosen range, with a hover readout.
private struct HistoryChart: View {
    let title: String
    let unit: String
    let color: Color
    let points: [(Date, Double)]
    let domain: ClosedRange<Double>
    let range: Int
    @State private var hover: Date?

    var body: some View {
        let shown = hover.flatMap { h in points.min { abs($0.0.timeIntervalSince(h)) < abs($1.0.timeIntervalSince(h)) } } ?? points.last
        let end = points.last?.0 ?? .now
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(shown.map { format($0.1) } ?? "—").font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
            }
            Chart {
                ForEach(points, id: \.0) { p in
                    AreaMark(x: .value("Time", p.0), y: .value(unit, p.1))
                        .foregroundStyle(color.opacity(0.12))
                    LineMark(x: .value("Time", p.0), y: .value(unit, p.1))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let hover, let shown {
                    RuleMark(x: .value("Time", hover)).foregroundStyle(Color.text2.opacity(0.5))
                    PointMark(x: .value("Time", shown.0), y: .value(unit, shown.1))
                        .foregroundStyle(color).symbolSize(50)
                }
            }
            .chartYScale(domain: domain)
            .chartXScale(domain: end.addingTimeInterval(-Double(range))...end)
            .chartPlotStyle { $0.clipped() }
            .chartXAxis {
                AxisMarks(preset: .aligned, values: .stride(by: .minute, count: range > 600 ? 15 : 1)) {
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.text2)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(v.index == 0 ? Color.hairline : OverviewColor.grid)
                }
            }
            .chartXSelection(value: $hover)
            .frame(height: 140)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, -4)
        .card(padding: 16)
    }

    private func format(_ v: Double) -> String {
        unit == "%" ? String(format: "%.0f%%", v) : unit == "GB" ? String(format: "%.1f GB", v) : String(format: "%.0f %@", v, unit)
    }
}

/// A 12pt rounded bar of segments on a track, with 2pt gaps.
private struct StackBar: View {
    let parts: [(String, Double, Color)]
    let total: Double

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(parts.filter { $0.1 > 0 }, id: \.0) { name, v, color in
                    Rectangle().fill(color)
                        .frame(width: max(2, g.size.width * v / max(1, total)))
                        .help(name + ": " + String(format: "%.1f GB", v / 1e9))
                }
                Spacer(minLength: 0)
            }
            .background(OverviewColor.track)
            .clipShape(RoundedRectangle(cornerRadius: .corner(999)))
        }
        .frame(height: 12)
        .animation(.smooth, value: total)
        .accessibilityHidden(true)
    }
}

/// What holds the memory: each process using the GPU, the rest of the system, and what's free.
private struct MemoryBreakdown: View {
    let sample: SparkMonitor.Sample

    var body: some View {
        let procs = self.procs
        let other = max(0, sample.memUsed - procs.reduce(0) { $0 + $1.bytes })
        let parts = procs.map { ($0.name, Double($0.bytes), $0.color) } + [("System and other", Double(other), OverviewColor.other)]
        Panel(title: "Memory by process") {
            note(String(format: "%.1f GB used · %.1f GB available", gb(sample.memUsed), gb(sample.memAvailable)))
        } content: {
            StackBar(parts: parts, total: Double(sample.memTotal))
            FlowLegend(items: parts.map { ($0.0, String(format: "%.1f GB", $0.1 / 1e9), $0.2) }
                       + [("Available", String(format: "%.1f GB", gb(sample.memAvailable)), nil)])
            if sample.processes.isEmpty {
                Text("No process is using the GPU.").font(.system(size: 12)).foregroundStyle(Color.text2)
            }
            if sample.swapTotal - sample.swapFree > 1 << 30 {
                Label(String(format: "%.1f GB in swap: memory is overcommitted", gb(sample.swapTotal - sample.swapFree)),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(VizColor.warning)
            }
        }
    }

    /// Engine processes in their badge colour, others in the chart slots.
    private var procs: [(name: String, bytes: Int64, color: Color)] {
        sample.processes.prefix(VizColor.series.count).enumerated().map { i, p in
            let engine = ["TensorFold", "vLLM", "Ollama", "ComfyUI"].first { p.name.localizedCaseInsensitiveContains($0) }
            return (p.name, p.bytes, engine.map(EngineBadge.color) ?? VizColor.series[i])
        }
    }
}

/// Swatch, name and a mono value; a nil colour draws an outlined swatch (what's free).
private struct FlowLegend: View {
    let items: [(String, String, Color?)]
    var body: some View {
        FlowLayout {
            ForEach(items, id: \.0) { name, value, color in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: .corner(2)).fill(color ?? OverviewColor.track)
                        .overlay { if color == nil { RoundedRectangle(cornerRadius: .corner(2)).strokeBorder(OverviewColor.trackLine) } }
                        .frame(width: 8, height: 8)
                    Text(name).foregroundStyle(Color.text3).lineLimit(1)
                    Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text).lineLimit(1)
                }
                .font(.system(size: 13))
            }
        }
    }
}

private struct CoresCard: View {
    let samples: [SparkMonitor.Sample]
    var body: some View {
        let now = samples.last
        let cores: [Double] = {
            guard samples.count > 1, let now else { return [] }
            let prev = samples[samples.count - 2]
            return (0..<now.coreCount).map { i in SparkMonitor.cpuPercent("cpu\(i)", from: prev, to: now) ?? 0 }
        }()
        Panel(title: "CPU cores") {
            if let now { note("\(now.coreCount) cores · load " + (now.load.first.map { String(format: "%.2f", $0) } ?? "—"), mono: false) }
        } content: {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(cores.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: .corner(4)).fill(OverviewColor.track)
                        .overlay(alignment: .bottom) {
                            GeometryReader { g in
                                Rectangle().fill(OverviewColor.load)
                                    .frame(height: max(2, g.size.height * min(cores[i], 100) / 100))
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: .corner(4)))
                        .help("Core \(i): \(Int(cores[i]))%")
                }
            }
            .frame(height: 96)
            .animation(.smooth, value: cores)
            .accessibilityElement()
            .accessibilityLabel("CPU cores")
            .accessibilityValue(cores.isEmpty ? "No reading yet" : "Busiest core \(Int(cores.max() ?? 0))%")
            if !cores.isEmpty {
                HStack { Text("0"); Spacer(); Text("\(cores.count - 1)") }
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.text2)
            }
        }
    }
}

private struct TemperaturesCard: View {
    let sample: SparkMonitor.Sample
    var body: some View {
        let rows = [("GPU", sample.gpuTemp), ("System · hottest sensor", sample.zones.max()), ("SSD", sample.nvmeTemp)]
            .compactMap { n, t in t.map { (n, $0) } }
        Panel(title: "Temperatures") { EmptyView() } content: {
            VStack(spacing: 0) {
                ForEach(rows, id: \.0) { name, t in
                    // ponytail: the GPU thresholds stand in for every sensor; they're conservative for system and SSD too.
                    let s = TempStatus(t)
                    HStack {
                        Text(name).font(.system(size: 13))
                        Spacer()
                        Text(String(format: "%.0f °C", t)).font(.system(size: 13, design: .monospaced))
                        Text(s.label).font(.system(size: 12)).foregroundStyle(s.color).frame(minWidth: 44, alignment: .trailing)
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { if name != rows.last?.0 { Hairline() } }
                }
            }
            .padding(.top, -6)
            if !sample.zones.isEmpty {
                note("Sensors " + sample.zones.map { String(format: "%.0f", $0) }.joined(separator: " · ") + " °C")
                    .foregroundStyle(Color.text2)
            }
        }
    }
}

private struct StorageCard: View {
    @Environment(AppState.self) private var state
    let sample: SparkMonitor.Sample
    @State private var measuring = false

    var body: some View {
        let colors = [VizColor.warning, OverviewColor.load, OverviewColor.pink, OverviewColor.memory, OverviewColor.heat]
        let folders = state.sparkStorage?.folders ?? []
        let known = folders.reduce(0) { $0 + $1.1 }
        let parts = folders.enumerated().map { i, f in (f.0, Double(f.1), colors[i % colors.count]) }
            + [(folders.isEmpty ? "Used" : "Other", Double(max(0, sample.diskUsed - known)), OverviewColor.other)]
        Panel(title: "Storage") {
            note(String(format: "%@ GB free of %@ GB", Int(gb(sample.diskFree)).formatted(), Int(gb(sample.diskTotal)).formatted()))
            Spacer().frame(width: 6)
            Button {
                measuring = true
                Task { await state.measureStorage(); measuring = false }
            } label: {
                if measuring { ProgressView().controlSize(.small) } else { Text("Measure again") }
            }
            .buttonStyle(DesignButtonStyle(prominent: false, height: 30))
            .fixedSize()
            .disabled(measuring || state.route == nil)
        } content: {
            StackBar(parts: parts, total: Double(sample.diskTotal))
            FlowLegend(items: parts.map { ($0.0, String(format: "%.1f GB", $0.1 / 1e9), $0.2) }
                       + (state.sparkStorage?.docker.map { [("Docker images", $0, nil)] } ?? []))
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
            if let keys {
                Section {
                    Text("Each key can log in to the Spark as you without a password. Remove any you don't recognise.")
                        .foregroundStyle(.secondary)
                }
                Section("\(keys.count) authorized key\(keys.count == 1 ? "" : "s")") {
                    if keys.isEmpty { Text("No keys.").foregroundStyle(.secondary) }
                    ForEach(keys) { row($0) }
                }
            } else if state.sshTarget != nil, !failed {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .overlay {
            if keys == nil, state.sshTarget == nil {
                ContentUnavailableView("Spark unreachable", systemImage: "bolt.horizontal.circle")
            } else if keys == nil, failed {
                ContentUnavailableView("Couldn't read the keys", systemImage: "key.slash",
                                       description: Text("The Spark didn't answer in time. Try Refresh."))
            }
        }
        .page()
        .pageHeader("SSH Keys") {
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.help("Refresh")
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
                            .background(Color.brand.opacity(0.15), in: RoundedRectangle(cornerRadius: .corner(999))).foregroundStyle(Color.brand)
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

// MARK: Wi-Fi

/// The networks the Spark's Wi-Fi can see, and switching between them, with a warning when switching could cut this
/// Mac off from the Spark.
struct WiFiView: View {
    @Environment(AppState.self) private var state
    @State private var status: WiFi.Status?
    @State private var failed = false
    @State private var busy = false
    @State private var joining: WiFi.Network?
    @State private var password = ""
    @State private var sudoError: String?
    @State private var note: String?
    @State private var scanSheet = false

    var body: some View {
        Form {
            if let status {
                Section { summary(status) }
                if status.device == nil {
                    ContentUnavailableView("No Wi-Fi", systemImage: "wifi.slash",
                                           description: Text("The Spark has no Wi-Fi adapter that NetworkManager manages."))
                } else {
                    Section {
                        if status.networks.isEmpty { Text("No networks found. Try Refresh.").foregroundStyle(.secondary) }
                        ForEach(status.networks) { row($0) }
                    } header: {
                        Text("\(status.networks.count) network\(status.networks.count == 1 ? "" : "s") nearby")
                    } footer: {
                        if status.scanBlocked {
                            HStack(alignment: .firstTextBaseline) {
                                Text("The Spark only scans for networks with your password, so this is its last scan and may be missing some.")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Scan with Password…") { scanSheet = true }.disabled(busy)
                            }
                        }
                    }
                }
            } else if state.sshTarget != nil, !failed {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .overlay {
            if status == nil, state.sshTarget == nil {
                ContentUnavailableView("Spark unreachable", systemImage: "bolt.horizontal.circle")
            } else if status == nil, failed {
                ContentUnavailableView("Couldn't read the Wi-Fi", systemImage: "wifi.exclamationmark",
                                       description: Text("The Spark didn't answer in time. Try Refresh."))
            }
        }
        .page()
        .pageHeader("Wi-Fi") {
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.help("Refresh")
                .disabled(state.sshTarget == nil || busy)
        }
        .task(id: state.sshTarget) { await load() }
        .sheet(isPresented: $scanSheet) {
            SudoPasswordSheet(title: "Scan for Networks", button: "Scan", target: state.sshTarget ?? "", error: nil) { pw in
                await load(sudo: pw)
                return status?.scanBlocked == true ? "That password didn't work." : nil
            }
        }
        .sheet(item: $joining) { n in joinSheet(n) }
        .sheet(isPresented: Binding(get: { sudoError != nil }, set: { if !$0 { sudoError = nil; pending = nil; password = "" } })) {
            SudoPasswordSheet(title: "Switch Wi-Fi", button: "Switch", target: state.sshTarget ?? "", error: sudoError) { pw in
                guard let n = pending else { return nil }
                return await join(n, sudo: pw)
            }
        }
    }

    /// The network being joined while the sudo sheet is up.
    @State private var pending: WiFi.Network?

    @ViewBuilder private func summary(_ s: WiFi.Status) -> some View {
        Label(path(s), systemImage: s.reachedOverWiFi ? "wifi" : "cable.connector")
        if let note { Label(note, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary) }
        if let last = s.last { Label(last, systemImage: "info.circle").foregroundStyle(.secondary) }
    }

    private func path(_ s: WiFi.Status) -> String {
        let over = { (d: String) in d == s.device ? "the Spark's Wi-Fi" : d.isEmpty ? "an unknown link" : "the Spark's wired link (\(d))" }
        return s.viaTailscale ? "This Mac reaches the Spark over Tailscale, through \(over(s.uplink))."
                              : "This Mac reaches the Spark over \(over(s.sshDevice))."
    }

    private func row(_ n: WiFi.Network) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi", variableValue: Double(n.signal) / 100)
                .foregroundStyle(n.inUse ? Color.brand : .secondary)
                .accessibilityLabel("Signal \(n.signal)%")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(n.ssid).font(.headline)
                    if n.secured { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Secured") }
                    if n.inUse {
                        Text("Connected").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.brand.opacity(0.15), in: RoundedRectangle(cornerRadius: .corner(999))).foregroundStyle(Color.brand)
                    }
                }
                Text([n.secured ? n.security : "Open", n.saved ? "Saved" : nil, "\(n.signal)%"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !n.inUse {
                Button("Join…") { password = ""; joining = n }.disabled(busy || state.sshTarget == nil)
            }
        }
        .padding(.vertical, 2)
    }

    /// Only the risks that apply: none when this Mac reaches the Spark over a wire.
    private func warnings(_ n: WiFi.Network, _ s: WiFi.Status) -> [String] {
        guard s.reachedOverWiFi else { return [] }
        let current = s.current?.ssid ?? "the current network"
        var w: [String] = []
        if s.viaTailscale {
            w.append("You're connected over Tailscale, which runs over the Spark's Wi-Fi. If \(n.ssid) has no internet access, Tailscale can't reconnect and you'll lose access to the Spark until someone fixes it at the Spark.")
        } else if s.tailscale {
            w.append("This Mac reaches the Spark over \(current). Once the Spark moves to \(n.ssid), it's only reachable by joining this Mac to \(n.ssid) too, or over Tailscale, which needs \(n.ssid) to have internet access.")
            if state.config.device?.mode == .local {
                w.append("Spark Control is set to use the local network only. Set Connection to Automatic in Settings so it can fall back to Tailscale.")
            }
        } else {
            w.append("This Mac reaches the Spark over \(current), and Tailscale isn't running on the Spark. Once it moves to \(n.ssid), the only way back is to join this Mac to \(n.ssid) too.")
        }
        if !n.secured && (s.viaTailscale || s.tailscale) {
            w.append("Open networks often need a sign-in page (hotels, cafés) that the Spark can't fill in, so it may get no internet access.")
        }
        return w
    }

    private func joinSheet(_ n: WiFi.Network) -> some View {
        let s = status ?? WiFi.Status()
        let w = warnings(n, s)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Join “\(n.ssid)”?").font(.headline)
            if n.secured && !n.saved {
                SecureField("Wi-Fi password", text: $password).textFieldStyle(.roundedBorder)
            }
            ForEach(w, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            Text("If the Spark can't join \(n.ssid) (a wrong password, out of range), it goes back to \(s.current?.ssid ?? "its current network").")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { joining = nil }.keyboardShortcut(.cancelAction)
                Button(w.isEmpty ? "Join" : "Join Anyway", role: w.isEmpty ? nil : .destructive) {
                    joining = nil
                    Task { if let e = await join(n, sudo: nil) { pending = n; sudoError = e } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(n.secured && !n.saved && password.isEmpty)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 440)
    }

    private func load(sudo: String? = nil) async {
        guard let target = state.sshTarget else { return }
        let res = await SSH.run(target, "bash -c \(SSH.quote(WiFi.listScript))", timeout: 30, input: sudo ?? "")
        failed = res.code != 0
        guard !failed else { return }
        let s = WiFi.parse(res.output)
        if let last = s.last { state.event("Wi-Fi: \(last)") }
        status = s
    }

    /// Starts the switch. Returns an error for the sudo sheet when sudo needs a (right) password, else nil.
    private func join(_ n: WiFi.Network, sudo: String?) async -> String? {
        guard let target = state.sshTarget else { return "The Spark is unreachable." }
        busy = true
        defer { busy = false }
        let res = await SSH.run(target, "bash -c \(SSH.quote(WiFi.switchScript(n.ssid)))", timeout: 30,
                                input: password + "\n" + (sudo ?? ""))
        if res.output.contains("__NEEDS_SUDO__") {
            return sudo == nil ? "The Spark needs your password to change its Wi-Fi." : "That password didn't work."
        }
        password = ""
        pending = nil
        guard res.output.contains("__STARTED__") else {
            state.event("Couldn't switch the Spark's Wi-Fi to \(n.ssid): \(res.output)")
            note = "Couldn't start switching to \(n.ssid)."
            return nil
        }
        state.event("Switching the Spark's Wi-Fi to \(n.ssid)")
        note = "Switching to \(n.ssid)…"
        let cutOff = status?.reachedOverWiFi == true
        Task {
            try? await Task.sleep(for: .seconds(cutOff ? 12 : 8))
            if cutOff { state.networkTrouble("the Spark switched Wi-Fi") }  // the shared SSH connection rode the old Wi-Fi
            try? await Task.sleep(for: .seconds(3))
            note = nil
            await load()
        }
        return nil
    }
}
