import SwiftUI
import Charts
import UniformTypeIdentifiers

// MARK: Requests

struct RequestsView: View {
    @Environment(AppState.self) private var state
    @State private var selected: RequestEntry.ID?
    @State private var search = ""
    /// A snapshot while paused; new requests keep arriving underneath.
    @State private var frozen: [RequestEntry]?
    @State private var status = StatusFilter.all
    @State private var model: String?
    @State private var client: String?
    @State private var endpoint: String?

    enum StatusFilter: Hashable { case all, success, errors }

    private var source: [RequestEntry] { frozen ?? state.requests }

    private func matches(_ e: RequestEntry, status s: StatusFilter) -> Bool {
        switch s {
        case .all: true
        case .success: e.status > 0 && e.status < 400
        case .errors: e.status >= 400 || e.error != nil
        }
    }

    private var shown: [RequestEntry] {
        source.filter { e in
            guard matches(e, status: status) else { return false }
            if let model, e.model != model { return false }
            if let client, e.client != client { return false }
            if let endpoint, e.path != endpoint { return false }
            guard !search.isEmpty else { return true }
            return [e.model, e.client, e.path, e.method, e.userAgent, e.error ?? "", String(e.status)]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        let shown = shown
        let current = source.first { $0.id == selected }
        VStack(spacing: 0) {
            ActivityHeader(title: "Requests") {
                LivePill(paused: frozen != nil)
            } trailing: {
                HeaderSearch(text: $search, prompt: "Search model, client, endpoint", width: 260)
                Button(frozen == nil ? "Pause" : "Resume") { frozen = frozen == nil ? state.requests : nil }
                    .buttonStyle(DesignButtonStyle(prominent: false, height: 34))
                    .fixedSize()
            }
            filterBar
            Hairline()
            HStack(spacing: 0) {
                table(shown)
                if let current {
                    Hairline(vertical: true)
                    RequestDetail(entry: current, gatewayBase: gatewayBase) { selected = nil }
                        .frame(width: 400)
                        .background(Color.sidebar)
                }
            }
        }
        .background(Color.pageBackground)
    }

    private var gatewayBase: String { "http://localhost:\(state.config.gateway.port)" }

    // MARK: Filters

    private var filterBar: some View {
        HStack(spacing: 10) {
            StatusSegments(selection: $status, options: [
                (.all, "All", source.count),
                (.success, "Success", nil),
                (.errors, "Errors", nil),
            ])
            filterMenu("Model", $model, source.map(\.model))
            filterMenu("Client", $client, source.map(\.client))
            filterMenu("Endpoint", $endpoint, source.map(\.path))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    private func filterMenu(_ title: String, _ value: Binding<String?>, _ all: [String]) -> some View {
        let options = Array(Set(all.filter { !$0.isEmpty })).sorted()
        return Menu {
            ForEach(options, id: \.self) { o in Button(o) { value.wrappedValue = o } }
            if value.wrappedValue != nil {
                Divider()
                Button("Any \(title)") { value.wrappedValue = nil }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: value.wrappedValue == nil ? "plus" : "xmark").font(.system(size: 10, weight: .semibold))
                Text(value.wrappedValue.map { "\(title): \($0)" } ?? title).lineLimit(1)
            }
            .font(.system(size: 13))
            .foregroundStyle(value.wrappedValue == nil ? Color.text3 : Color.text)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(value.wrappedValue == nil ? Color.clear : Color.overlay(0.05), in: RoundedRectangle(cornerRadius: .corner(9), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: .corner(9), style: .continuous)
                .strokeBorder(Color(light: 0xD4D4D8, dark: 0x2E2E34), style: StrokeStyle(lineWidth: 1, dash: value.wrappedValue == nil ? [3, 3] : [])))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(options.isEmpty)
        .accessibilityLabel("Filter by \(title)")
    }

    // MARK: Table

    private func table(_ rows: [RequestEntry]) -> some View {
        let longest = rows.map(\.duration).max() ?? 0
        return ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                Section {
                    ForEach(rows) { e in
                        RequestRow(entry: e, selected: e.id == selected, longest: longest)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = selected == e.id ? nil : e.id }
                            .accessibilityAddTraits(e.id == selected ? [.isButton, .isSelected] : .isButton)
                        Rectangle().fill(Color(light: 0xF4F4F5, dark: 0x1A1A1E)).frame(height: 1)
                    }
                    emptyState(rows)
                } header: {
                    RequestColumns.header
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func emptyState(_ rows: [RequestEntry]) -> some View {
        VStack(spacing: 6) {
            if !source.isEmpty && rows.isEmpty {
                Text("No requests match").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.text)
                Text("Try another search or filter.").foregroundStyle(Color.text3)
            } else if frozen != nil {
                Text("Paused").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.text)
                Text("New requests show again when you resume.").foregroundStyle(Color.text3)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(Color.running).frame(width: 7, height: 7)
                        .phaseAnimator([0.35, 1]) { v, o in v.opacity(o) }
                    Text("Listening for new requests").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.text)
                }
                (Text("Anything sent to ") + Text(state.apiBaseURL).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.text)
                    + Text(" appears here as it happens."))
                    .foregroundStyle(Color.text3)
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 13))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

/// Column widths shared by the header and rows.
private enum RequestColumns {
    static let time: CGFloat = 96, status: CGFloat = 52, client: CGFloat = 170, tokens: CGFloat = 92, latency: CGFloat = 170, cost: CGFloat = 72

    static var header: some View {
        HStack(spacing: 14) {
            Text("Time").frame(width: time, alignment: .leading)
            Text("Status").frame(width: status, alignment: .leading)
            Text("Model").frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            Text("Client · endpoint").frame(width: client, alignment: .leading)
            Text("Tokens").frame(width: tokens, alignment: .trailing)
            Text("Latency").frame(width: latency, alignment: .leading)
            Text("Cost").frame(width: cost, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.text2)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(Color.pageBackground)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

private struct RequestRow: View {
    let entry: RequestEntry
    let selected: Bool
    let longest: Double
    @State private var hover = false

    var body: some View {
        let e = entry
        HStack(spacing: 14) {
            Text(e.date, format: .dateTime.hour().minute().second())
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text3)
                .frame(width: RequestColumns.time, alignment: .leading)
            StatusBadge(entry: e).frame(width: RequestColumns.status, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: .corner(2)).fill(ModelColor.of(e.model)).frame(width: 8, height: 8)
                Text(e.model.isEmpty ? "—" : e.model).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.text)
                    .lineLimit(2)
                if let t = e.thinking { ThinkingBadge(level: t, ignored: t == "Off" && e.reasoning > 0) }
            }
            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.client.isEmpty ? "Unknown" : e.client).font(.system(size: 13)).foregroundStyle(Color.text).lineLimit(1)
                Text("\(e.method) \(e.path)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.text2)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: RequestColumns.client, alignment: .leading)
            Text(e.prompt > 0 || e.completion > 0 ? "\(e.prompt.compact) → \(e.completion.compact)" : "—")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text)
                .frame(width: RequestColumns.tokens, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) {
                TimingBar(entry: e)
                    .frame(width: max(24, 150 * (longest > 0 ? e.duration / longest : 0)), height: 5)
                    .opacity(e.duration > 0 ? 1 : 0)
                Text(e.latencyText).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.text3).lineLimit(1)
            }
            .frame(width: RequestColumns.latency, alignment: .leading)
            Text(e.status == 0 ? "—" : e.cost.usd).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text)
                .frame(width: RequestColumns.cost, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(selected ? Color(light: 0xF4F4F5, dark: 0x15151A) : hover ? Color.overlay(0.025) : .clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(Color.brand).frame(width: 2) } }
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
    }
}

private struct StatusBadge: View {
    let entry: RequestEntry
    var body: some View {
        let failed = entry.status >= 400 || entry.error != nil
        let color = entry.status == 0 && !failed ? Color.text2 : failed ? Color.danger : Color.running
        Text(entry.status == 0 ? (failed ? "ERR" : "…") : "\(entry.status)")
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: .corner(5), style: .continuous))
            .fixedSize()
    }
}

/// Thinking as the gateway forwarded it; amber when it was off but the model reasoned anyway.
private struct ThinkingBadge: View {
    let level: String
    let ignored: Bool
    var body: some View {
        let color = ignored ? VizColor.warning : Color.text2
        Label(level, systemImage: "brain")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: .corner(5), style: .continuous))
            .fixedSize()
            .help(ignored ? "Thinking was off, but the model reasoned anyway" : "Thinking \(level.lowercased())")
            .accessibilityLabel(ignored ? "Thinking off, ignored by the model" : "Thinking \(level.lowercased())")
    }
}

/// Time to first token, then decoding, as one bar.
private struct TimingBar: View {
    static let first = Color(light: 0xD97706, dark: 0xFBBF24)
    static let decode = Color(light: 0x5B6CF0, dark: 0x8B9DFF)
    let entry: RequestEntry

    var body: some View {
        GeometryReader { g in
            let total = max(entry.duration, 0.0001)
            let ttft = min(entry.ttft ?? 0, total)
            HStack(spacing: ttft > 0 && ttft < total ? 1 : 0) {
                if entry.ttft == nil {
                    Rectangle().fill(Color.text2.opacity(0.5))
                } else {
                    Rectangle().fill(Self.first).frame(width: g.size.width * ttft / total)
                    Rectangle().fill(Self.decode)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: .corner(999)))
        }
        .accessibilityHidden(true)
    }
}

private struct RequestDetail: View {
    let entry: RequestEntry
    let gatewayBase: String
    let close: () -> Void
    @State private var tab = Tab.request
    @State private var copied = false

    enum Tab: String, CaseIterable { case request = "Request", response = "Response", headers = "Headers" }

    var body: some View {
        let e = entry
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        StatusBadge(entry: e)
                        Text("\(e.method) \(e.path)").font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button(action: close) { Label("Close", systemImage: "xmark") }
                            .buttonStyle(GhostIconStyle())
                            .help("Close")
                    }
                    Text("\(e.model) · from \(e.client.isEmpty ? "Unknown" : e.client) · \(e.date.formatted(.dateTime.hour().minute().second()))")
                        .font(.system(size: 12.5)).foregroundStyle(Color.text3).textSelection(.enabled)
                    if let err = e.error {
                        Text(err).font(.system(size: 12)).foregroundStyle(Color.danger).textSelection(.enabled).padding(.top, 2)
                    }
                }
                .padding(20)
                Hairline()
                timing.padding(20)
                Hairline()
                tokens.padding(20)
                Hairline()
                body(e).padding(20)
            }
        }
    }

    private var timing: some View {
        let e = entry
        return VStack(alignment: .leading, spacing: 12) {
            Text("Timing").font(.system(size: 13, weight: .semibold))
            TimingBar(entry: e).frame(height: 8).opacity(e.duration > 0 ? 1 : 0.3)
            HStack(alignment: .top, spacing: 0) {
                metric("First token", e.ttft.map(Self.secs) ?? "—", swatch: TimingBar.first)
                metric("Prefill", Speed.prefill(prompt: e.prompt, cached: e.cached ?? 0, ttft: e.ttft).map(UsageView.tps) ?? "—", swatch: nil)
                metric("Decode", Speed.decode(completion: e.completion, decodeTime: e.decodeTime).map(UsageView.tps) ?? "—", swatch: TimingBar.decode)
                metric("Total", e.duration > 0 ? Self.secs(e.duration) : "—", swatch: nil)
            }
        }
    }

    private func metric(_ label: String, _ value: String, swatch: Color?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let swatch { RoundedRectangle(cornerRadius: .corner(2)).fill(swatch).frame(width: 8, height: 8) }
                Text(label).foregroundStyle(Color.text3)
            }
            .font(.system(size: 12))
            Text(value).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tokens: some View {
        let e = entry
        let rows: [(String, String)] = [
            ("Input", e.prompt.formatted()), ("Cached", e.cached.formatted()),
            ("Reasoning", e.reasoning.formatted()), ("Output", max(0, e.completion - e.reasoning).formatted()),
            ("Cost", e.cost.usd),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            Text("Tokens").font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                ForEach(rows, id: \.0) { k, v in
                    HStack {
                        Text(k).foregroundStyle(Color.text3)
                        Spacer()
                        Text(v).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color.text)
                    }
                    .font(.system(size: 13))
                }
            }
        }
    }

    private func body(_ e: RequestEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue)
                            .font(.system(size: 13, weight: tab == t ? .medium : .regular))
                            .foregroundStyle(tab == t ? Color.text : Color.text3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) { if tab == t { Rectangle().fill(Color.text).frame(height: 2) } }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == t ? .isSelected : [])
                }
                Spacer(minLength: 8)
                Button(copied ? "Copied" : "Copy as cURL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(curl(e), forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.link)
            }
            .overlay(alignment: .bottom) { Hairline() }
            if tab == .request {
                Text("As sent to the Spark")
                    .font(.system(size: 12)).foregroundStyle(Color.text2)
            }
            ScrollView(.horizontal) {
                Text(text(e, tab))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(light: 0x3F3F46, dark: 0xD4D4D8))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(light: 0xFAFAFA, dark: 0x0A0A0B), in: RoundedRectangle(cornerRadius: .corner(10), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: .corner(10), style: .continuous).strokeBorder(Color.cardBorder))
        }
    }

    private func text(_ e: RequestEntry, _ tab: Tab) -> String {
        switch tab {
        case .request:
            return Self.pretty(e.forwarded)
        case .response:
            // Only the outcome is kept, not the reply body.
            var lines = ["status: \(e.status == 0 ? "in progress" : String(e.status))"]
            if let err = e.error { lines.append("error: \(err)") }
            lines += ["prompt_tokens: \(e.prompt)", "cached_tokens: \(e.cached)", "reasoning_tokens: \(e.reasoning)",
                      "completion_tokens: \(e.completion)", "cost: \(e.cost.usd)"]
            if let t = e.ttft { lines.append("time_to_first_token: \(Self.secs(t))") }
            if e.duration > 0 { lines.append("duration: \(Self.secs(e.duration))") }
            return lines.joined(separator: "\n")
        case .headers:
            return ["Client: \(e.client.isEmpty ? "Unknown" : e.client)", "User-Agent: \(e.userAgent.isEmpty ? "—" : e.userAgent)",
                    "Method: \(e.method)", "Path: \(e.path)", "Model: \(e.model)"].joined(separator: "\n")
        }
    }

    private func curl(_ e: RequestEntry) -> String {
        // The forwarded body names the backend model; the gateway only knows the API name.
        var json = e.forwarded
        if var obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], obj["model"] != nil {
            obj["model"] = e.model
            if let data = try? JSONSerialization.data(withJSONObject: obj) { json = String(decoding: data, as: UTF8.self) }
        }
        let body = Self.pretty(json).replacingOccurrences(of: "'", with: "'\\''")
        return "curl \(gatewayBase)\(e.path) \\\n  -H 'Content-Type: application/json' \\\n  -d '\(body)'"
    }

    static func pretty(_ json: String) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
           let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: data, as: UTF8.self)
        }
        return json.isEmpty ? "(empty)" : json
    }

    static func secs(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(2))) + " s" }
}

/// A green "Live" pill, grey while paused.
private struct LivePill: View {
    let paused: Bool
    var body: some View {
        let c = paused ? Color.text2 : Color.running
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(paused ? "Paused" : "Live")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(c)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(c.opacity(0.12), in: RoundedRectangle(cornerRadius: .corner(999)))
    }
}

/// Segments with an optional count after a label ("All 12").
private struct StatusSegments<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String, Int?)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label, count in
                let on = value == selection
                Button { selection = value } label: {
                    HStack(spacing: 5) {
                        Text(label)
                        if let count { Text("\(count)").foregroundStyle(Color.text3) }
                    }
                    .font(.system(size: 13, weight: on ? .medium : .regular))
                    .foregroundStyle(on ? Color.text : Color.text3)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(on ? Color.thumb : .clear, in: RoundedRectangle(cornerRadius: .corner(6), style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color(light: 0xF4F4F5, dark: 0x131316), in: RoundedRectangle(cornerRadius: .corner(9), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .corner(9), style: .continuous).strokeBorder(Color(light: 0xE4E4E7, dark: 0x26262B)))
    }
}

/// Like `PageHeader`, with a view beside the title and an optional subtitle.
private struct ActivityHeader<Accessory: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Text(title).pageTitle()
                    accessory
                }
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.text3).lineLimit(1) }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.leading, 28)
        .padding(.trailing, 20)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .background { Color.pageBackground.gesture(WindowDragGesture()) }
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// A stable colour per model name, shared by Requests and Usage.
private enum ModelColor {
    static let palette = [Color(light: 0x5B6CF0, dark: 0x8B9DFF), Color(light: 0x0D9488, dark: 0x5EEAD4),
                          Color(light: 0xD97706, dark: 0xFBBF24), Color(light: 0xDB2777, dark: 0xF472B6),
                          Color(light: 0x16A34A, dark: 0x4ADE80), Color(light: 0xEA580C, dark: 0xFB923C)]

    static func of(_ name: String) -> Color {
        // djb2: String.hashValue is seeded per launch, so it would reshuffle colours on every start.
        let h = name.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        return palette[Int(h % UInt64(palette.count))]
    }
}

// MARK: Usage

struct UsageView: View {
    @Environment(AppState.self) private var state
    @State private var period = Period.day
    @State private var confirmReset = false

    enum Period: String, CaseIterable, Identifiable {
        case fourHours = "4h", day = "24h", week = "Week", month = "Month", year = "Year", all = "All"
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
        var phrase: String {
            switch self {
            case .fourHours: "last 4 hours"
            case .day: "last 24 hours"
            case .week: "last 7 days"
            case .month: "last 30 days"
            case .year: "last year"
            case .all: "all time"
            }
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
        let clients = Dictionary(grouping: records, by: { $0.client ?? "Unknown" })
            .map { Stats(model: $0.key, $0.value) }
            .sorted { ($0.cost, $0.requests) > ($1.cost, $1.requests) }

        VStack(spacing: 0) {
            ActivityHeader(title: "Usage", subtitle: "Requests through Spark Control’s API, \(period.phrase)") {
                EmptyView()
            } trailing: {
                Segments(selection: $period, options: Period.allCases.map { ($0, $0.rawValue) })
                Button("Export CSV") { export(records) }
                    .buttonStyle(DesignButtonStyle(prominent: false, height: 34))
                    .fixedSize()
                    .disabled(records.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    totals(total, models: rows.count, clients: clients.count)
                    performance(total, records: records, models: rows)
                    section("By model") { byModel(rows) }
                    section("By client") { byClient(clients) }
                    resetCard
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 48)
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.pageBackground)
        .confirmationDialog("Reset all usage history?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { state.resetUsage() }
        } message: {
            Text("Deletes the usage history on this Mac.")
        }
    }

    static func tps(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(v < 100 ? 1 : 0))) + " tok/s" }
    static func secs(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(v < 10 ? 2 : 1))) + "s" }
    static func percent(_ v: Double) -> String { v.formatted(.percent.precision(.fractionLength(1))) }

    // MARK: Totals

    private func totals(_ t: Stats, models: Int, clients: Int) -> some View {
        let tiles: [(String, String, String)] = [
            ("Cost", t.cost.usd, "at your model pricing"),
            ("Requests", t.requests.formatted(), "\(models) model\(models == 1 ? "" : "s") · \(clients) client\(clients == 1 ? "" : "s")"),
            ("Tokens in", t.prompt.formatted(), "\(t.cached.formatted()) read from cache"),
            ("Cache hit rate", t.hitRate.map(Self.percent) ?? "—", "\(t.output.formatted()) out · \(t.reasoning.formatted()) reasoning"),
        ]
        return HStack(spacing: 0) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { i, tile in
                VStack(alignment: .leading, spacing: 6) {
                    Text(tile.0).font(.system(size: 13)).foregroundStyle(Color.text3)
                    Text(tile.1).font(.system(size: 26, weight: .semibold)).tracking(-0.8).foregroundStyle(Color.text)
                        .lineLimit(1).minimumScaleFactor(0.6).monospacedDigit()
                    Text(tile.2).font(.system(size: 12)).foregroundStyle(Color.text2).lineLimit(1)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                if i < tiles.count - 1 { Hairline(vertical: true) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(14), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .corner(14), style: .continuous).strokeBorder(Color.cardBorder))
    }

    // MARK: Performance

    private func performance(_ t: Stats, records: [UsageRecord], models: [Stats]) -> some View {
        let stats: [(String, String)] = [
            ("Decode", t.decodeTPS.map(Self.tps) ?? "—"),
            ("Prefill", t.prefillTPS.map(Self.tps) ?? "—"),
            ("Time to first token", t.avgTTFT.map(Self.secs) ?? "—"),
            ("TTFT median", t.ttftPercentile(0.5).map(Self.secs) ?? "—"),
            ("TTFT p95", t.ttftPercentile(0.95).map(Self.secs) ?? "—"),
            ("Avg prompt", t.avgPrompt.map { $0.compact } ?? "—"),
            ("Avg output", t.avgOutput.map { $0.compact } ?? "—"),
        ]
        let points = records.compactMap { r in
            Speed.decode(completion: r.completion, decodeTime: r.decodeTime).map { (date: r.date, model: r.model, tps: $0) }
        }
        let charted = Array(Set(points.map(\.model))).sorted()
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Performance").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Heavily cached requests show low prefill").font(.system(size: 12)).foregroundStyle(Color.text2)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 16) {
                ForEach(stats, id: \.0) { k, v in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(k).font(.system(size: 12)).foregroundStyle(Color.text2)
                        Text(v).font(.system(size: 16, weight: .medium, design: .monospaced)).foregroundStyle(Color.text)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
            if points.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 14) {
                            ForEach(charted, id: \.self) { m in
                                HStack(spacing: 6) {
                                    Circle().fill(ModelColor.of(m)).frame(width: 8, height: 8)
                                    Text(charted.count == 1 ? "\(m) · decode tok/s" : m).lineLimit(1)
                                }
                            }
                        }
                        Spacer()
                        if let avg = t.decodeTPS { Text("avg \(avg.formatted(.number.precision(.fractionLength(1))))") }
                    }
                    .font(.system(size: 12)).foregroundStyle(Color.text3)
                    Chart(points, id: \.date) { p in
                        LineMark(x: .value("Time", p.date), y: .value("Decode tok/s", p.tps), series: .value("Model", p.model))
                            .foregroundStyle(by: .value("Model", p.model))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Time", p.date), y: .value("Decode tok/s", p.tps))
                            .foregroundStyle(by: .value("Model", p.model))
                            .symbolSize(22)
                    }
                    .chartForegroundStyleScale(domain: charted, range: charted.map(ModelColor.of))
                    .chartLegend(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisGridLine().foregroundStyle(Color.hairline)
                            AxisValueLabel().font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.text2)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel().font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.text2)
                        }
                    }
                    .frame(height: 160)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(14), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .corner(14), style: .continuous).strokeBorder(Color.cardBorder))
    }

    // MARK: Tables

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private static let modelColumns = ["Requests", "In", "Cached", "Out", "Reasoning", "Hit rate", "Decode", "Prefill", "TTFT", "Cost"]

    @ViewBuilder private func byModel(_ rows: [Stats]) -> some View {
        if rows.isEmpty {
            empty
        } else {
            ScrollView(.horizontal) {
                Grid(alignment: .trailing, horizontalSpacing: 20, verticalSpacing: 0) {
                    GridRow {
                        Text("Model").gridColumnAlignment(.leading)
                        ForEach(Self.modelColumns, id: \.self) { Text($0) }
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.text2)
                    .padding(.vertical, 12)
                    Hairline().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows) { r in
                        GridRow {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: .corner(2)).fill(ModelColor.of(r.model)).frame(width: 8, height: 8)
                                Text(r.model).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.text)
                                    .textSelection(.enabled).help(r.model)
                            }
                            .frame(minWidth: 200, alignment: .leading)
                            cell(r.requests.formatted())
                            cell(r.input.compact)
                            cell(r.cached > 0 ? r.cached.compact : nil)
                            cell(r.output > 0 ? r.output.compact : nil)
                            cell(r.reasoning > 0 ? r.reasoning.compact : nil)
                            cell(r.cached > 0 ? r.hitRate.map(Self.percent) : nil)
                            cell(r.decodeTPS.map { $0.formatted(.number.precision(.fractionLength(1))) })
                            cell(r.prefillTPS.map { $0.formatted(.number.precision(.fractionLength(0))) })
                            cell(r.avgTTFT.map { $0.formatted(.number.precision(.fractionLength(2))) + " s" })
                            cell(r.cost.usd)
                        }
                        .padding(.vertical, 14)
                        if r.id != rows.last?.id { Hairline().gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .padding(.horizontal, 16)
                .frame(minWidth: 860)
            }
            .scrollIndicators(.automatic)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: .corner(14), style: .continuous).strokeBorder(Color.cardBorder))
        }
    }

    private func cell(_ v: String?) -> some View {
        Text(v ?? "—").font(.system(size: 12, design: .monospaced)).foregroundStyle(v == nil ? Color.text2 : Color.text)
    }

    @ViewBuilder private func byClient(_ clients: [Stats]) -> some View {
        if clients.isEmpty {
            empty
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(clients) { c in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(c.model).font(.system(size: 14, weight: .semibold)).lineLimit(1).textSelection(.enabled)
                            Spacer()
                            Text(c.cost.usd).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.text)
                        }
                        VStack(spacing: 8) {
                            kv("Requests", c.requests.formatted())
                            kv("Tokens in / out", "\(c.prompt.compact) / \(c.output.compact)")
                            kv("Cache hit", c.hitRate.map(Self.percent) ?? "—")
                        }
                    }
                    .padding(16)
                    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(14), style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: .corner(14), style: .continuous).strokeBorder(Color.cardBorder))
                }
            }
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(Color.text2)
            Spacer()
            Text(v).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text)
        }
        .font(.system(size: 13))
    }

    private var empty: some View {
        Text("No usage in this period.").font(.system(size: 13)).foregroundStyle(Color.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: .corner(14), style: .continuous).strokeBorder(Color.cardBorder))
    }

    private var resetCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Reset usage").font(.system(size: 13, weight: .semibold))
                Text("Clears all counters and history. This can’t be undone.").font(.system(size: 12)).foregroundStyle(Color.text3)
            }
            Spacer()
            Button("Reset…") { confirmReset = true }
                .buttonStyle(PillButtonStyle(tint: .danger))
                .disabled(state.usage.isEmpty)
        }
        .padding(16)
        .background(Color.danger.opacity(0.04), in: RoundedRectangle(cornerRadius: .corner(14), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .corner(14), style: .continuous).strokeBorder(Color.danger.opacity(0.3)))
    }

    // MARK: Export

    private func export(_ records: [UsageRecord]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Spark Control usage.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let iso = ISO8601DateFormatter()
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func n(_ d: Double?) -> String { d.map { String($0) } ?? "" }
        var csv = "date,model,client,prompt_tokens,cached_tokens,completion_tokens,reasoning_tokens,cost_usd,ttft_s,decode_s\n"
        for r in records {
            csv += [iso.string(from: r.date), q(r.model), q(r.client ?? ""), String(r.prompt), String(r.cached ?? 0),
                    String(r.completion), String(r.reasoning ?? 0), String(r.cost), n(r.ttft), n(r.decodeTime)].joined(separator: ",") + "\n"
        }
        do { try csv.write(to: url, atomically: true, encoding: .utf8) } catch { NSSound.beep() }
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
        .pageHeader("Logs") {
            Button { state.logs.removeAll() } label: { Label("Clear", systemImage: "trash") }.help("Clear Logs")
        }
    }
}

private extension RequestEntry {
    var latencyText: String {
        guard duration > 0 else { return status == 0 ? "…" : "—" }
        let t = duration.formatted(.number.precision(.fractionLength(2))) + " s"
        return Speed.decode(completion: completion, decodeTime: decodeTime).map { t + " · " + UsageView.tps($0) } ?? t
    }
}
