import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let models = state.config.recipes.filter(\.enabled)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BoltTile(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spark").font(.headline)
                    Text(state.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let s = state.spark.last, Date().timeIntervalSince(s.date) < 60 {
                        Text(String(format: "%.0f / %.0f GB", Double(s.memUsed) / 1e9, Double(s.memTotal) / 1e9)
                             + (s.gpuUtil.map { String(format: " · GPU %.0f%%", $0) } ?? "")
                             + (s.gpuTemp.map { String(format: " · %.0f °C", $0) } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                }
                Spacer()
                RouteBadge(route: state.route)
            }
            .card(padding: 12, radius: 14)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Text("MODELS")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 2)

            if models.isEmpty {
                Text("No enabled models")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
            ForEach(models) { r in
                let phase = state.phase(for: r)
                MenuRow(action: { state.start(r) }) {
                    ModelAvatar(name: r.name, phase: phase, size: 22)
                    Text(r.name).lineLimit(1)
                    Spacer()
                    if r.priceIn + r.priceOut > 0 {
                        Text("\(r.priceIn.usd) / \(r.priceOut.usd)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(state.isBusy || state.route == nil || phase == .ready)
            }

            Divider().padding(.horizontal, 10).padding(.vertical, 5)

            ForEach(state.runningRecipes) { r in
                MenuRow(action: { state.stop(r) }) {
                    IconTile(symbol: "stop.fill", tint: .red, size: 22)
                    Text("Stop \(r.name)")
                }
                .disabled(state.isBusy)
            }
            MenuRow(action: { copy(state.apiBaseURL) }) {
                IconTile(symbol: "link", tint: .purple, size: 22)
                Text("Copy API URL")
                Spacer()
                Text(state.apiBaseURL.replacingOccurrences(of: "http://", with: ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            MenuRow(action: {
                openWindow(id: "main")
                NSApp.activate()
            }) {
                IconTile(symbol: "macwindow", tint: .brand, size: 22)
                Text("Open Spark Control")
            }
            MenuRow(action: {
                openSettings()
                NSApp.activate()
            }) {
                IconTile(symbol: "gearshape.fill", tint: .gray, size: 22)
                Text("Settings…")
            }

            Divider().padding(.horizontal, 10).padding(.vertical, 5)

            MenuRow(action: { NSApp.terminate(nil) }) {
                IconTile(symbol: "power", tint: .secondary, size: 22)
                Text("Quit Spark Control")
                Spacer()
                Text("v" + Bundle.main.appVersion).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 6)
        .frame(width: 310)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// A menu-style row: full-width hit area with a subtle hover highlight.
private struct MenuRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hover = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .secondary)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hover && isEnabled ? Color.brand.opacity(0.14) : .clear)
        )
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
        .padding(.horizontal, 6)
    }
}
