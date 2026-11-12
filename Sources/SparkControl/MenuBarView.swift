import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let models = state.config.recipes.filter(\.enabled)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
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
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().padding(.horizontal, 10)

            Text("Models")
                .font(.caption.weight(.semibold))
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
                    Group {
                        switch phase {
                        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .starting, .stopping: ProgressView().controlSize(.mini)
                        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        default: Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 16)
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
                    Image(systemName: "stop.circle").frame(width: 16)
                    Text("Stop \(r.name)")
                }
                .disabled(state.isBusy)
            }
            MenuRow(action: { copy(state.apiBaseURL) }) {
                Image(systemName: "link").frame(width: 16)
                Text("Copy API URL")
                Spacer()
                Text(state.apiBaseURL.replacingOccurrences(of: "http://", with: ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            MenuRow(action: {
                openWindow(id: "main")
                NSApp.activate()
            }) {
                Image(systemName: "macwindow").frame(width: 16)
                Text("Open Spark Control")
            }
            MenuRow(action: {
                openSettings()
                NSApp.activate()
            }) {
                Image(systemName: "gearshape").frame(width: 16)
                Text("Settings…")
            }

            Divider().padding(.horizontal, 10).padding(.vertical, 5)

            MenuRow(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power").frame(width: 16)
                Text("Quit Spark Control")
            }
        }
        .padding(.bottom, 6)
        .frame(width: 300)
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
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .secondary)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hover && isEnabled ? Color.primary.opacity(0.1) : .clear)
        )
        .onHover { hover = $0 }
        .padding(.horizontal, 6)
    }
}
