import SwiftUI

enum Pane: Hashable {
    case chat, models, model(UUID), connect, discovered, tensorfold, vllm, comfy, spark, sshKeys, terminal, requests, usage, logs
}

/// `--args -demo YES`: the mode the README's screenshots are taken in. Full screen, a generic hostname, and
/// Terminal tabs that show nvidia-smi under a plain prompt, so no screenshot shows the Spark's real name,
/// login, addresses or login banner.
enum Demo {
    static let on = UserDefaults.standard.bool(forKey: "demo")
}

struct MainView: View {
    @Environment(AppState.self) private var state
    /// `open -a "Spark Control" --args -startPage terminal` opens on that page (how the README's screenshots are taken).
    @State private var selection: Pane? = {
        let pages: [String: Pane] = ["chat": .chat, "models": .models, "tensorfold": .tensorfold, "vllm": .vllm, "ollama": .discovered,
                                     "comfyui": .comfy, "spark": .spark, "sshkeys": .sshKeys, "terminal": .terminal,
                                     "requests": .requests, "usage": .usage, "logs": .logs, "connect": .connect]
        return UserDefaults.standard.string(forKey: "startPage").flatMap { pages[$0.lowercased()] } ?? .models
    }()

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    SidebarLabel("Chat", "bubble.left.and.bubble.right.fill", .brand).tag(Pane.chat)
                }
                Section("Models") {
                    SidebarLabel("All Models", "square.grid.2x2.fill", .sparkNavy).tag(Pane.models)
                    // Only what's running (or starting, stopping, failed); the rest is on the Models page.
                    ForEach(state.config.recipes.filter { state.phase(for: $0) != .stopped || selection == .model($0.id) }) { r in
                        HStack(spacing: 8) {
                            ModelAvatar(name: r.name, phase: state.phase(for: r), size: 22)
                            Text(r.name.isEmpty ? "Untitled" : r.name)
                                .lineLimit(1)
                                .foregroundStyle(r.enabled ? .primary : .secondary)
                            Spacer()
                            if !r.enabled {
                                Text("Off").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .tag(Pane.model(r.id))
                    }
                }
                Section("Engines") {
                    SidebarLabel("TensorFold", "square.stack.3d.up.fill", .indigo).tag(Pane.tensorfold)
                    SidebarLabel("vLLM", "shippingbox.fill", .teal).tag(Pane.vllm)
                    SidebarLabel("Ollama", "magnifyingglass", .brown).tag(Pane.discovered)
                    SidebarLabel("ComfyUI", "photo.on.rectangle.angled", .pink).tag(Pane.comfy)
                }
                Section("Activity") {
                    SidebarLabel("Spark", "gauge.with.dots.needle.67percent", .orange).tag(Pane.spark)
                    SidebarLabel("SSH Keys", "key.fill", .yellow).tag(Pane.sshKeys)
                    SidebarLabel("Terminal", "terminal.fill", .mint).tag(Pane.terminal)
                    SidebarLabel("Requests", "arrow.left.arrow.right", .blue).tag(Pane.requests)
                    SidebarLabel("Usage", "chart.bar.xaxis", .green).tag(Pane.usage)
                    SidebarLabel("Logs", "text.alignleft", .gray).tag(Pane.logs)
                }
                Section("API") {
                    SidebarLabel("Connect", "link", .purple).tag(Pane.connect)
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
            case .sshKeys: SSHKeysView()
            case .terminal: TerminalPage()
            case .requests: RequestsView()
            case .usage: UsageView()
            case .logs: LogsView()
            default: ContentUnavailableView("Select a Model", systemImage: "cpu")
            }
        }
        .sheet(isPresented: $state.showSetup) { DeviceSetupView() }
        .onAppear {
            guard Demo.on else { return }
            Task { @MainActor in  // the window may not exist yet on first appear
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(300))
                    if let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
                        if !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
                        return
                    }
                }
            }
        }
        // A model added with + and left without a start command is dropped once you leave its page.
        .onChange(of: selection) { old, _ in
            if case .model(let id) = old { state.config.recipes.removeAll { $0.id == id && $0.isBlank } }
        }
        .onAppear {
            if selection == nil { selection = state.config.recipes.first.map { .model($0.id) } }
        }
    }
}

private struct SidebarLabel: View {
    let title: String
    let symbol: String
    let tint: Color
    init(_ title: String, _ symbol: String, _ tint: Color) { (self.title, self.symbol, self.tint) = (title, symbol, tint) }
    var body: some View {
        Label { Text(title) } icon: { IconTile(symbol: symbol, tint: tint) }
    }
}

private struct ConnectionFooter: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 30, height: 30)
                Image(systemName: state.route?.symbol ?? "bolt.horizontal.circle")
                    .font(.footnote.weight(.semibold)).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(state.route?.label ?? "Spark Unreachable").font(.callout.weight(.semibold))
                Text(Demo.on ? "spark.local" : state.route.flatMap { r in state.config.device?.host(r) } ?? "Check Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            SettingsLink { Image(systemName: "gearshape.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Settings")
            ShutdownButton()
        }
        .card(padding: 12, radius: 14)
        .padding(10)
    }

    private var tint: Color { state.route == nil ? .red : state.runningRecipes.isEmpty ? .secondary : .green }
}
