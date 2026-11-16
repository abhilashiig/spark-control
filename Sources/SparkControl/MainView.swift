import SwiftUI

enum Pane: Hashable {
    case chat, models, model(UUID), connect, discovered, huggingFace, tensorfold, vllm, comfy, spark, sshKeys, wifi, terminal, requests, usage, logs
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
        let pages: [String: Pane] = ["chat": .chat, "models": .models, "tensorfold": .tensorfold, "vllm": .vllm, "ollama": .discovered, "huggingface": .huggingFace,
                                     "comfyui": .comfy, "spark": .spark, "sshkeys": .sshKeys, "wifi": .wifi, "terminal": .terminal,
                                     "requests": .requests, "usage": .usage, "logs": .logs, "connect": .connect]
        return UserDefaults.standard.string(forKey: "startPage").flatMap { pages[$0.lowercased()] } ?? .models
    }()

    @AppStorage("sidebarWidth") private var sidebarWidth = 216.0

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 0) {
            Sidebar(selection: $selection)
                .frame(width: sidebarWidth)
            ResizeHairline(width: $sidebarWidth, range: 180...360)
                .zIndex(1) // the drag strip overhangs the page beside it
            Group {
            switch selection {
            case .model(let id) where state.config.recipes.contains { $0.id == id }:
                ModelView(id: id, selection: $selection).id(id)
            case .chat: ChatView()
            case .models: ModelsView(selection: $selection)
            case .connect: ConnectView()
            case .discovered: DiscoveredView(selection: $selection)
            case .huggingFace: HuggingFaceView()
            case .tensorfold: TensorFoldView(selection: $selection)
            case .vllm: VLLMView(selection: $selection)
            case .comfy: ComfyView(selection: $selection)
            case .spark: SparkView()
            case .sshKeys: SSHKeysView()
            case .wifi: WiFiView()
            case .terminal: TerminalPage()
            case .requests: RequestsView()
            case .usage: UsageView()
            case .logs: LogsView()
            default: ContentUnavailableView("Select a Model", systemImage: "cpu")
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.pageBackground)
        }
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Color.text)
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
        .onAppear { if selection == nil { selection = .models } }
    }
}

/// The design's sidebar: the Spark at the top, page groups, API Access and power at the foot. Flat #F3F3F5, no vibrancy.
private struct Sidebar: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic lights, which sit over the sidebar (the window has no title bar).
            Color.clear.frame(height: 28).contentShape(Rectangle()).gesture(WindowDragGesture())
            DeviceHeader()
            Spacer().frame(height: 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row("Chat", "bubble.left", .chat)
                    row("Models", "cube", .models)
                    // Only what's running (or starting, stopping, failed), and the open one; the rest is on Models.
                    ForEach(state.config.recipes.filter { state.phase(for: $0) != .stopped || selection == .model($0.id) }) { r in
                        item(r.name.isEmpty ? "Untitled" : r.name, .model(r.id)) {
                            ModelAvatar(name: r.name, phase: state.phase(for: r), size: 22)
                        }
                        .padding(.leading, 12)
                    }
                    group("Engines")
                    row("TensorFold", "square.stack.3d.up", .tensorfold)
                    row("vLLM", "cube", .vllm)
                    row("Ollama", "tray", .discovered)
                    row("Hugging Face", "face.smiling", .huggingFace)
                    row("ComfyUI", "photo", .comfy)
                    group("Monitor")
                    row("Overview", "gauge.with.needle", .spark)
                    row("Requests", "arrow.left.arrow.right", .requests)
                    row("Usage", "chart.bar", .usage)
                    row("Logs", "doc.text", .logs)
                    group("Device")
                    row("Terminal", "apple.terminal", .terminal)
                    row("SSH Keys", "key", .sshKeys)
                    row("Wi-Fi", "wifi", .wifi)
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 20)
            HStack(spacing: 4) {
                row("API Access", "powerplug", .connect)
                ShutdownButton().frame(width: 28, height: 28)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
        .background(Color.sidebar)
    }

    private func group(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.text2)
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ title: String, _ symbol: String, _ pane: Pane) -> some View {
        item(title, pane) { LineIcon(symbol: symbol).foregroundStyle(Color.brand) }
    }

    private func item(_ title: String, _ pane: Pane, @ViewBuilder icon: () -> some View) -> some View {
        let on = selection == pane
        return Button { selection = pane } label: {
            HStack(spacing: 9) {
                icon()
                Text(title).font(.system(size: 13, weight: on ? .medium : .regular)).foregroundStyle(Color.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(on ? Color.overlay(0.075) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .hoverFill(Color.overlay(0.04), active: on)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The Spark this window controls, and whether it answers. The menu holds Settings.
private struct DeviceHeader: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(dot).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color.sidebar, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.text).lineLimit(1)
                Text(status).font(.system(size: 11.5)).foregroundStyle(Color.text2).lineLimit(1)
            }
            .help(state.route.flatMap { r in state.config.device.map { "\($0.host(r)) over \(r.label)" } } ?? "")
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .labelStyle(.iconOnly)
                .buttonStyle(GhostIconStyle())
                .help("Settings (⌘,)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .padding(.vertical, 6)
    }

    private var name: String {
        if Demo.on { return "spark" }
        guard let d = state.config.device, !d.base.isEmpty else { return "No Spark" }
        return d.base
    }

    private var status: String {
        if state.config.device == nil { return "Not set up" }
        if state.offline { return "DGX Spark · Offline" }
        return state.route == nil ? "DGX Spark · Connecting…" : "DGX Spark · Online"
    }

    private var dot: Color { state.offline || state.config.device == nil ? .red : state.route == nil ? .orange : Color.running }
}
