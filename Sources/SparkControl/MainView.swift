import SwiftUI

enum Pane: Hashable {
    case model(UUID), connect, discovered, requests, usage, logs
}

struct MainView: View {
    @Environment(AppState.self) private var state
    @State private var selection: Pane?

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            List(selection: $selection) {
                Section("Models") {
                    ForEach(state.config.recipes) { r in
                        HStack(spacing: 8) {
                            StatusDot(phase: state.phase(for: r))
                            Text(r.name.isEmpty ? "Untitled" : r.name)
                                .foregroundStyle(r.enabled ? .primary : .secondary)
                            Spacer()
                            if !r.enabled {
                                Text("Off").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .tag(Pane.model(r.id))
                    }
                }
                Section("API") {
                    Label("Connect", systemImage: "link").tag(Pane.connect)
                }
                Section("Ollama") {
                    Label("Discovered", systemImage: "magnifyingglass").tag(Pane.discovered)
                }
                Section("Activity") {
                    Label("Requests", systemImage: "arrow.left.arrow.right").tag(Pane.requests)
                    Label("Usage", systemImage: "chart.bar.xaxis").tag(Pane.usage)
                    Label("Logs", systemImage: "text.alignleft").tag(Pane.logs)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            .safeAreaInset(edge: .bottom, spacing: 0) { ConnectionFooter() }
            .toolbar {
                ToolbarItem {
                    Button { selection = .model(state.addRecipe()) } label: {
                        Label("Add Model", systemImage: "plus")
                    }
                    .help("Add Model")
                }
            }
        } detail: {
            switch selection {
            case .model(let id) where state.config.recipes.contains { $0.id == id }:
                ModelView(id: id, selection: $selection).id(id)
            case .connect: ConnectView()
            case .discovered: DiscoveredView(selection: $selection)
            case .requests: RequestsView()
            case .usage: UsageView()
            case .logs: LogsView()
            default: ContentUnavailableView("Select a Model", systemImage: "cpu")
            }
        }
        .sheet(isPresented: $state.showSetup) { DeviceSetupView() }
        .onAppear {
            if selection == nil { selection = state.config.recipes.first.map { .model($0.id) } }
        }
    }
}

private struct ConnectionFooter: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: state.route?.symbol ?? "bolt.horizontal.circle")
                    .foregroundStyle(state.route == nil ? Color.red : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.route?.label ?? "Spark Unreachable").font(.callout.weight(.medium))
                    Text(state.route.flatMap { r in state.config.device?.host(r) } ?? "Check Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}
