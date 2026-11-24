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

    @AppStorage("sidebarWidth") private var sidebarWidth = 240.0

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
        .onAppear {
            if selection == nil { selection = .models }
            // `-startPage model` opens the first model's page.
            if UserDefaults.standard.string(forKey: "startPage")?.lowercased() == "model", let r = state.config.recipes.first { selection = .model(r.id) }
        }
    }
}

/// The sidebar: the Spark and Settings, page groups, what's running, and memory and power at the foot.
private struct Sidebar: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic lights, which sit over the sidebar (the window has no title bar).
            Color.clear.frame(height: 28).contentShape(Rectangle()).gesture(WindowDragGesture())
            DeviceCard()
            JumpButton(selection: $selection).padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row("Chat", "bubble.left", .chat)
                    row("Models", "cube", .models)
                    row("API Access", "chevron.left.forwardslash.chevron.right", .connect)
                    // Only what's running (or starting, stopping, failed), and the open one; the rest is on Models.
                    let live = state.config.recipes.filter { state.phase(for: $0) != .stopped || selection == .model($0.id) }
                    if !live.isEmpty {
                        group("Running")
                        ForEach(live) { r in
                            item(r.name.isEmpty ? "Untitled" : r.name, .model(r.id)) {
                                StatusDot(phase: state.phase(for: r))
                                    .padding(3)
                                    .background(Circle().fill(state.phase(for: r).color.opacity(0.15)))
                                    .frame(width: 16, height: 16)
                            } trailing: {
                                if let need = state.memoryNeed(r) {
                                    Text("\(Int((Double(need) / 1e9).rounded())) GB")
                                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.text2)
                                }
                            }
                        }
                    }
                    group("Engines")
                    row("TensorFold", "square.stack.3d.up", .tensorfold)
                    row("vLLM", "triangle", .vllm)
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
                .padding(.top, 10)
            }
            .scrollIndicators(.never)
            Spacer(minLength: 16)
            HStack(spacing: 6) {
                MemoryMeter()
                ShutdownButton().frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
        .background(Color.sidebar)
    }

    private func group(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .tracking(0.44)
            .foregroundStyle(Color.text2)
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ title: String, _ symbol: String, _ pane: Pane) -> some View {
        let on = selection == pane
        return item(title, pane) { LineIcon(symbol: symbol, size: 16).foregroundStyle(on ? Color.link : Color.text2) } trailing: { EmptyView() }
    }

    private func item(_ title: String, _ pane: Pane, @ViewBuilder icon: () -> some View, @ViewBuilder trailing: () -> some View) -> some View {
        let on = selection == pane
        return Button { selection = pane } label: {
            HStack(spacing: 10) {
                icon()
                Text(title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(on ? Color.text : Color(light: 0x3F3F46, dark: 0xB4B4BC)).lineLimit(1)
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(on ? Color(light: 0xE4E4E7, dark: 0x1C1C21) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .hoverFill(Color.overlay(0.03), radius: 8, active: on)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// "Search or jump to…": ⌘K opens a field that filters pages and models; Return opens the first match.
private struct JumpButton: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                Text("Search or jump to…").frame(maxWidth: .infinity, alignment: .leading)
                Text("⌘K").font(.system(size: 11)).foregroundStyle(Color.text3)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(light: 0xD4D4D8, dark: 0x2E2E34)))
            }
            .font(.system(size: 13)).foregroundStyle(Color.text2)
            .padding(.horizontal, 10).frame(height: 34)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(light: 0xE4E4E7, dark: 0x222227)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .popover(isPresented: $open, arrowEdge: .trailing) { JumpList(selection: $selection, open: $open) }
    }
}

private struct JumpList: View {
    @Environment(AppState.self) private var state
    @Binding var selection: Pane?
    @Binding var open: Bool
    @State private var query = ""
    @FocusState private var focused: Bool

    private static let pages: [(String, String, Pane)] = [
        ("Chat", "bubble.left", .chat), ("Models", "cube", .models), ("TensorFold", "square.stack.3d.up", .tensorfold),
        ("vLLM", "triangle", .vllm), ("Ollama", "tray", .discovered), ("Hugging Face", "face.smiling", .huggingFace),
        ("ComfyUI", "photo", .comfy), ("Overview", "gauge.with.needle", .spark), ("Requests", "arrow.left.arrow.right", .requests),
        ("Usage", "chart.bar", .usage), ("Logs", "doc.text", .logs), ("Terminal", "apple.terminal", .terminal),
        ("SSH Keys", "key", .sshKeys), ("Wi-Fi", "wifi", .wifi), ("API Access", "chevron.left.forwardslash.chevron.right", .connect),
    ]

    private var matches: [(String, String, Pane)] {
        let all = Self.pages + state.config.recipes.map { ($0.name.isEmpty ? "Untitled" : $0.name, "cpu", Pane.model($0.id)) }
        return query.isEmpty ? all : all.filter { $0.0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search or jump to…", text: $query)
                .textFieldStyle(.plain).font(.system(size: 14)).padding(12)
                .focused($focused)
                .onSubmit { if let m = matches.first { go(m.2) } }
            Hairline()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(matches, id: \.2) { title, symbol, pane in
                        Button { go(pane) } label: {
                            HStack(spacing: 10) {
                                LineIcon(symbol: symbol, size: 16).foregroundStyle(Color.text2)
                                Text(title).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 30)
                            .hoverFill(radius: 7).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 300)
        .onAppear { focused = true }
    }

    private func go(_ pane: Pane) { selection = pane; open = false }
}

/// The Spark this window controls, and whether it answers.
private struct DeviceCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            BoltTile(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.text).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 6, height: 6)
                    Text(status).lineLimit(1)
                }
                .font(.system(size: 12)).foregroundStyle(Color.text3)
            }
            Spacer(minLength: 0)
            SettingsLink { LineIcon(symbol: "gearshape") }
                .buttonStyle(GhostIconStyle(size: 30))
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(minHeight: 40)
        .help(state.route.flatMap { r in state.config.device.map { "\($0.host(r)) over \(r.label)" } } ?? "")
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

/// Unified memory in use, from the last Spark reading.
private struct MemoryMeter: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let total = state.sparkMemoryTotal
        let used = state.spark.last?.memUsed ?? 0
        VStack(spacing: 8) {
            HStack {
                Text("Memory").foregroundStyle(Color.text3)
                Spacer()
                Text("\(Int((Double(used) / 1e9).rounded())) / \(Int((Double(total) / 1e9).rounded())) GB")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text)
            }
            .font(.system(size: 12))
            GeometryReader { g in
                Capsule().fill(Color(light: 0xE4E4E7, dark: 0x222227))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.text).frame(width: g.size.width * min(1, Double(used) / Double(max(1, total))))
                    }
            }
            .frame(height: 4)
        }
        .padding(12)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.cardBorder))
        .accessibilityElement(children: .combine)
    }
}
