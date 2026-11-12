import SwiftUI

enum Pane: Hashable {
    case chat, models, model(UUID), connect, discovered, tensorfold, vllm, comfy, spark, requests, usage, logs
}

struct MainView: View {
    @Environment(AppState.self) private var state
    @State private var selection: Pane? = .models

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right").tag(Pane.chat)
                }
                Section("Models") {
                    Label("All Models", systemImage: "square.grid.2x2").tag(Pane.models)
                    // Only what's running (or starting, stopping, failed); the rest is on the Models page.
                    ForEach(state.config.recipes.filter { state.phase(for: $0) != .stopped || selection == .model($0.id) }) { r in
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
                Section("Engines") {
                    Label("TensorFold", systemImage: "square.stack.3d.up").tag(Pane.tensorfold)
                    Label("vLLM", systemImage: "shippingbox").tag(Pane.vllm)
                    Label("Ollama", systemImage: "magnifyingglass").tag(Pane.discovered)
                    Label("ComfyUI", systemImage: "photo.on.rectangle.angled").tag(Pane.comfy)
                }
                Section("Activity") {
                    Label("Spark", systemImage: "gauge.with.dots.needle.50percent").tag(Pane.spark)
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
            case .chat: ChatView()
            case .models: ModelsView(selection: $selection)
            case .connect: ConnectView()
            case .discovered: DiscoveredView(selection: $selection)
            case .tensorfold: TensorFoldView(selection: $selection)
            case .vllm: VLLMView(selection: $selection)
            case .comfy: ComfyView(selection: $selection)
            case .spark: SparkView()
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
