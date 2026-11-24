import SwiftUI

/// Everything a client needs, ready to copy: where to call, a snippet to try, the coding tools set up here, and
/// every model's ID.
struct ConnectView: View {
    @Environment(AppState.self) private var state
    @State private var modelID: UUID?
    @State private var snippet = Snippet.curl
    @State private var fromLAN = false
    @State private var testing = false
    @State private var reply: String?

    enum Snippet: String, CaseIterable, Identifiable {
        case curl = "curl", python = "Python", javascript = "JavaScript", env = ".env"
        var id: Self { self }
    }

    private var models: [Recipe] { state.config.recipes.filter(\.enabled) }
    private var model: Recipe? { models.first { $0.id == modelID } ?? state.activeRecipe ?? models.first }
    private var key: String { state.toolGateway.apiKey }
    private var keySet: Bool { !state.config.gateway.apiKey.isEmpty }
    /// The gateway runs on this Mac: localhost here, its Bonjour name from elsewhere on the network.
    private var baseURL: String {
        fromLAN ? "http://\(ProcessInfo.processInfo.hostName):\(state.config.gateway.port)/v1" : state.apiBaseURL
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                PageSection(title: "Connect") {
                    // Side by side always; a wide snippet scrolls inside its card instead of stacking the cards.
                    HStack(alignment: .top, spacing: 16) { settings.frame(width: 400); code }
                }
                ToolsSection()
                PageSection(title: "Models") { table }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .background(Color.pageBackground)
        .pageHeader("API Access") { endpointPill }
        .onChange(of: model?.id) { reply = nil }
    }

    private var endpointPill: some View {
        let running = state.runningRecipes.count
        let (color, text): (Color, String) = state.gatewayError != nil ? (.danger, "Endpoint error")
            : running == 0 ? (Color.text2, "No model running")
            : (.running, "Serving \(running) model\(running == 1 ? "" : "s")")
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(color.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.3)))
        .help(state.gatewayError ?? "")
    }

    // MARK: Connect

    private var settings: some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 16) {
            field("Calling from") {
                Segments(selection: $fromLAN, options: [(false, "This Mac"), (true, "Another computer")])
            }
            if fromLAN && !state.config.gateway.allowLAN {
                HStack(spacing: 8) {
                    Text("Off for other devices.").font(.system(size: 12)).foregroundStyle(Color.text2)
                    Spacer(minLength: 0)
                    Button("Allow") { state.config.gateway.allowLAN = true }.buttonStyle(PillButtonStyle())
                }
            }
            field("Base URL") { CopyField(value: baseURL) }
            field("Model") {
                Picker("Model", selection: Binding(get: { model?.id }, set: { modelID = $0 })) {
                    ForEach(models) { r in
                        Text(r.name + (state.phase(for: r) == .ready ? "  ·  running" : "")).tag(Optional(r.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                if let model {
                    HStack {
                        Text("id: " + model.apiID).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.text2)
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        CopyLink(title: "Copy ID", text: model.apiID)
                    }
                    .padding(.top, 4)
                }
            }
            Hairline()
            if keySet {
                field("API key") { CopyField(value: key) }
            } else {
                Label {
                    Text("No API key needed")
                } icon: {
                    Image(systemName: "lock")
                }
                .font(.system(size: 12)).foregroundStyle(Color.text2)
            }
        }
        .card()
    }

    private func field<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.text)
            content()
        }
    }

    private var code: some View {
        VStack(spacing: 0) {
            HStack {
                Segments(selection: $snippet, options: Snippet.allCases.map { ($0, $0.rawValue) })
                Spacer()
                CopyLink(title: "Copy", text: codeText, pill: true)
            }
            .padding(12)
            Hairline()
            ScrollView([.vertical, .horizontal]) {
                Text(codeText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.text)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(16)
            }
            .defaultScrollAnchor(.topLeading)
            .frame(minHeight: 200, maxHeight: .infinity)
            .background(Color.well.opacity(0.5))
            if let reply {
                Hairline()
                ScrollView {
                    Text(reply).font(.system(size: 12)).foregroundStyle(Color.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                .frame(maxHeight: 140)
            }
            Hairline()
            HStack(spacing: 12) {
                let running = model.map { state.phase(for: $0) == .ready } ?? false
                Button { Task { await sendTest() } } label: {
                    if testing { ProgressView().controlSize(.small) } else { Label("Send Test", systemImage: "play") }
                }
                .buttonStyle(PillButtonStyle(filled: true))
                .disabled(testing || !running || model?.isEmbedding == true)
                if !running && model?.isEmbedding != true {
                    Text("Start the model to test it").font(.system(size: 12)).foregroundStyle(Color.text2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(14), style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: .corner(14), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .corner(14), style: .continuous).strokeBorder(Color.cardBorder))
    }

    /// The curl snippet's request, sent to the gateway on this Mac.
    private func sendTest() async {
        guard let m = model?.apiID else { return }
        testing = true
        defer { testing = false }
        var r = URLRequest(url: URL(string: state.apiBaseURL + "/chat/completions")!, timeoutInterval: 300)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": m, "messages": [["role": "user", "content": "Hello"]]])
        do {
            let (data, _) = try await URLSession.shared.data(for: r)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            reply = message?["content"] as? String ?? String(decoding: data, as: UTF8.self)
        } catch {
            reply = error.localizedDescription
        }
    }

    private var codeText: String {
        let url = baseURL, m = model?.apiID ?? "MODEL"
        let auth = keySet ? "\n  -H \"Authorization: Bearer \(key)\" \\" : ""
        switch snippet {
        case .curl:
            return """
            curl \(url)/chat/completions \\\(auth)
              -H "Content-Type: application/json" \\
              -d '{
                "model": "\(m)",
                "messages": [{"role": "user", "content": "Hello"}]
              }'
            """
        case .python:
            return """
            from openai import OpenAI

            client = OpenAI(base_url="\(url)", api_key="\(key)")
            reply = client.chat.completions.create(
                model="\(m)",
                messages=[{"role": "user", "content": "Hello"}],
            )
            print(reply.choices[0].message.content)
            """
        case .javascript:
            return """
            import OpenAI from "openai";

            const client = new OpenAI({ baseURL: "\(url)", apiKey: "\(key)" });
            const reply = await client.chat.completions.create({
              model: "\(m)",
              messages: [{ role: "user", content: "Hello" }],
            });
            console.log(reply.choices[0].message.content);
            """
        case .env:
            return """
            OPENAI_BASE_URL="\(url)"
            OPENAI_API_BASE="\(url)"
            OPENAI_API_KEY="\(key)"
            OPENAI_MODEL="\(m)"
            """
        }
    }

    // MARK: Models

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                ForEach(["Model", "ID", "Memory", "Type", "Status"], id: \.self) { Text($0) }
                Text("").gridColumnAlignment(.trailing)
            }
            .font(.system(size: 12)).foregroundStyle(Color.text2)
            .padding(.vertical, 12)
            if models.isEmpty {
                Hairline().gridCellUnsizedAxes(.horizontal)
                Text("No enabled models.").foregroundStyle(Color.text2).padding(.vertical, 12).gridCellColumns(6)
            }
            ForEach(models) { r in
                let phase = state.phase(for: r)
                Hairline().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(r.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.text).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(r.apiID).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text3)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(r.memoryGB.map { "\(Int($0.rounded())) GB" } ?? "—").foregroundStyle(Color.text3)
                    Text(r.isEmbedding ? "Embedding" : "Chat").foregroundStyle(Color.text3)
                    HStack(spacing: 6) {
                        StatusDot(phase: phase, size: 7)
                        Text(phase.label).foregroundStyle(phase == .ready ? Color.running : Color.text2).lineLimit(1)
                    }
                    CopyLink(title: "Copy ID", text: r.apiID, pill: true).gridColumnAlignment(.trailing)
                }
                .font(.system(size: 13))
                .padding(.vertical, 9)
                .background(phase == .ready ? Color.brand.opacity(0.07) : .clear)
            }
        }
        .padding(.horizontal, 16)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(14), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .corner(14), style: .continuous).strokeBorder(Color.cardBorder))
    }
}

/// A titled block of the page: title left, grey note right, content below.
private struct PageSection<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).sectionTitle()
                Spacer(minLength: 16)
                if let note { Text(note).font(.system(size: 12)).foregroundStyle(Color.text2).multilineTextAlignment(.trailing) }
            }
            content
        }
    }
}

/// A monospaced value in a well with a Copy button.
private struct CopyField: View {
    let value: String
    var body: some View {
        HStack(spacing: 8) {
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            CopyLink(title: "Copy", text: value, pill: true)
        }
        .padding(.leading, 12).padding(.trailing, 4).frame(height: 40)
        .background(Color.well, in: RoundedRectangle(cornerRadius: .corner(9), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .corner(9), style: .continuous).strokeBorder(Color.cardBorder))
    }
}

/// A text button that copies, and says so for a moment: a link, or an outlined pill.
private struct CopyLink: View {
    let title: String
    let text: String
    var pill = false
    @State private var copied = false
    var body: some View {
        let button = Button(copied ? "Copied" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        }
        if pill {
            button.buttonStyle(PillButtonStyle())
        } else {
            button.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.link)
        }
    }
}

/// Adds Spark Control as a provider to coding tools installed on this Mac, with each model's prices and whether it
/// reasons and takes images.
private struct ToolsSection: View {
    @Environment(AppState.self) private var state
    @State private var replacing: String?
    @State private var picked: String?

    var body: some View {
        @Bindable var state = state
        let models = state.toolModels, gateway = state.toolGateway
        let _ = state.toolsChanged
        PageSection(title: "Coding tools", note: "Restart a tool after a change.") {
            HStack(alignment: .top, spacing: 12) {
                ForEach(ClientTool.allCases) { tool in
                    card(tool, status: tool.status(models: models, gateway: gateway))
                }
            }
            VStack(spacing: 0) {
                Toggle(isOn: $state.config.gateway.syncTools) {
                    Text("Keep tool configs in sync")
                }
                .padding(16)
                if FileManager.default.fileExists(atPath: ClientTool.kilo.folder.path) {
                    Hairline()
                    indexing(gateway).padding(16)
                }
            }
            .font(.system(size: 13))
            .labeledContentStyle(DesignRowStyle())
            .toggleStyle(DesignToggleStyle())
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(14), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: .corner(14), style: .continuous).strokeBorder(Color.cardBorder))
        }
    }

    private func card(_ tool: ClientTool, status: ClientTool.Status) -> some View {
        let bak = tool.file.appendingPathExtension("spark-control.bak")
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tool.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.text)
                Spacer()
                badge(status)
            }
            Text(tool.file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.text2).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 12) {
                switch status {
                case .notAdded: Button("Add") { state.writeTool(tool) }.buttonStyle(PillButtonStyle(filled: true))
                case .outdated: Button("Update") { state.writeTool(tool) }.buttonStyle(PillButtonStyle(filled: true))
                default: EmptyView()
                }
                if status != .notInstalled && FileManager.default.fileExists(atPath: tool.file.path) {
                    Button("Open Config") { NSWorkspace.shared.activateFileViewerSelecting([tool.file]) }
                        .buttonStyle(PillButtonStyle())
                        .help("Show in Finder")
                }
                if FileManager.default.fileExists(atPath: bak.path) {
                    Button("Restore") {
                        do {
                            _ = try FileManager.default.replaceItemAt(tool.file, withItemAt: bak)
                            state.event("Restored \(tool.name)'s previous config")
                        } catch {
                            state.event("⚠︎ Couldn't restore \(tool.name)'s config: \(error.localizedDescription)")
                        }
                        state.toolsChanged = Date()
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.link)
                    .help("Put back the file from before the last change")
                }
            }
            .padding(.top, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }

    private func badge(_ s: ClientTool.Status) -> some View {
        let (color, text): (Color, String) = switch s {
        case .notInstalled: (Color.text2, "Not installed")
        case .notAdded: (Color.text2, "Not added")
        case .upToDate: (.running, "Synced")
        case .outdated: (VizColor.warning, "Models changed")
        case .unreadable: (.danger, "Config unreadable")
        }
        return Label(text, systemImage: s == .upToDate ? "checkmark" : "circle.fill")
            .labelStyle(BadgeLabel())
            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 8).frame(height: 22)
            .background(color.opacity(0.12), in: Capsule())
    }

    private struct BadgeLabel: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) { configuration.icon.imageScale(.small); configuration.title }
        }
    }

    /// Points Kilo's codebase indexing at an embedding model (any with "embed" in its name), picked from a menu when
    /// there are several, after a warning when that replaces the indexing settings Kilo has.
    @ViewBuilder private func indexing(_ g: ClientTool.Gateway) -> some View {
        let all = state.embedders
        let ix = ClientTool.kiloIndexing(in: (try? String(contentsOf: ClientTool.kilo.file, encoding: .utf8)) ?? "")
        let current = (ix?["model"] as? String).map { m in ((ix?["provider"] as? String).map { $0 + " · " } ?? "") + m }
        let inUse = ix?["enabled"] as? Bool == true && (ix?["openai-compatible"] as? [String: Any])?["baseUrl"] as? String == g.baseURL
            ? all.first { $0.recipe?.apiID == ix?["model"] as? String } : nil
        let chosen = all.first { $0.id == picked } ?? inUse ?? all.first
        LabeledContent {
            HStack(spacing: 8) {
                if state.indexingBusy {
                    ProgressView().controlSize(.small)
                    Text("Starting \(chosen?.name ?? "model")…").foregroundStyle(.secondary)
                } else if let chosen {
                    if all.count > 1 {
                        Picker("Embedding model", selection: Binding { chosen.id } set: { picked = $0 }) {
                            ForEach(all) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } else {
                        Text(chosen.name).foregroundStyle(.secondary)
                    }
                    if chosen == inUse {
                        Text("In use").foregroundStyle(.secondary)
                    } else {
                        Button(inUse == nil ? "Set Up" : "Switch") {
                            if let current { replacing = current } else { Task { await state.setUpKiloIndexing(chosen) } }
                        }
                    }
                } else {
                    Text("No embedding model").foregroundStyle(.secondary)
                }
            }
        } label: {
            Text("Codebase search for Kilo Code")
            if let e = state.indexingError, !state.indexingBusy {
                Text(e).foregroundStyle(.red)
            } else if all.isEmpty {
                Text("Needs an embedding model, e.g. qwen3-embedding:0.6b from Ollama.")
            }
        }
        .task { if state.discovered == nil { await state.discover() } }
        .alert("Replace Kilo Code's indexing settings?", isPresented: Binding { replacing != nil } set: { if !$0 { replacing = nil } }) {
            Button("Replace", role: .destructive) {
                if let chosen { Task { await state.setUpKiloIndexing(chosen) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kilo Code indexes with \(replacing ?? "another provider") now. It will use \(chosen?.name ?? "the Spark") instead, for every workspace, and re-index each codebase from scratch. The previous file is kept as .spark-control.bak.")
        }
    }

}
