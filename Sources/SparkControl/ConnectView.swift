import SwiftUI

/// Everything a client needs, ready to copy.
struct ConnectView: View {
    @Environment(AppState.self) private var state
    @State private var modelID: UUID?
    @State private var snippet = Snippet.curl

    enum Snippet: String, CaseIterable, Identifiable {
        case curl = "curl", python = "Python", javascript = "JavaScript", env = "Environment"
        var id: Self { self }
    }

    private var models: [Recipe] { state.config.recipes.filter(\.enabled) }
    private var model: Recipe? { models.first { $0.id == modelID } ?? state.activeRecipe ?? models.first }
    private var key: String { state.toolGateway.apiKey }

    var body: some View {
        Form {
            Section {
                CopyRow(title: "Base URL", value: state.apiBaseURL)
                CopyRow(title: "API key", value: key,
                        note: state.config.gateway.apiKey.isEmpty ? "No key required; any value works" : nil)
                LabeledContent("Model") {
                    Picker("Model", selection: Binding(get: { model?.id }, set: { modelID = $0 })) {
                        ForEach(models) { r in
                            Text(r.name + (state.phase(for: r) == .ready ? "  ·  running" : "")).tag(Optional(r.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let model { CopyRow(title: "Model name", value: model.apiID) }
            } header: {
                Text("OpenAI-Compatible API")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Segments(selection: $snippet, options: Snippet.allCases.map { ($0, $0.rawValue) })
                    ZStack(alignment: .topTrailing) {
                        Text(code)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.text)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.cardBorder))
                        CopyButton(text: code).padding(6)
                    }
                }
            } header: {
                Text("Quick Start")
            }

            ToolsSection()

            Section("All Models") {
                if models.isEmpty {
                    Text("No enabled models.").foregroundStyle(.secondary)
                }
                ForEach(models) { r in
                    HStack(spacing: 10) {
                        ModelAvatar(name: r.name, phase: state.phase(for: r), size: 24)
                        Text(r.name).fontWeight(.medium)
                        Spacer()
                        Text(r.apiID).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text2).textSelection(.enabled)
                        CopyButton(text: r.apiID)
                    }
                }
            }
        }
        .page()
        .pageHeader("API Access")
    }

    private var code: String {
        let url = state.apiBaseURL, m = model?.apiID ?? "MODEL"
        switch snippet {
        case .curl:
            return """
            curl \(url)/chat/completions \\
              -H "Authorization: Bearer \(key)" \\
              -H "Content-Type: application/json" \\
              -d '{"model": "\(m)", "messages": [{"role": "user", "content": "Hello"}]}'
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
            export OPENAI_BASE_URL="\(url)"
            export OPENAI_API_BASE="\(url)"
            export OPENAI_API_KEY="\(key)"
            export OPENAI_MODEL="\(m)"
            """
        }
    }
}

private struct CopyRow: View {
    let title: String
    let value: String
    var note: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                CopyButton(text: value)
            }
        } label: {
            Text(title)
            if let note { Text(note) }
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
        Section {
            ForEach(ClientTool.allCases) { tool in
                let status = tool.status(models: models, gateway: gateway)
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(label(status)).foregroundStyle(status == .upToDate ? Color.secondary : Color.primary)
                        switch status {
                        case .notAdded: Button("Add") { state.writeTool(tool) }
                        case .outdated: Button("Update") { state.writeTool(tool) }
                        case .upToDate:
                            Button { NSWorkspace.shared.activateFileViewerSelecting([tool.file]) } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                        default: EmptyView()
                        }
                    }
                } label: {
                    Text(tool.name)
                    Text(tool.file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                }
            }
            if FileManager.default.fileExists(atPath: ClientTool.kilo.folder.path) {
                indexing(gateway)
            }
            Toggle("Keep models up to date", isOn: $state.config.gateway.syncTools)
        } header: {
            Text("Coding Tools")
        } footer: {
            Text("Restart the tool, or reload its window, to see the change. The previous file is kept as .spark-control.bak.")
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
            Text("Kilo Code indexing")
            if let e = state.indexingError, !state.indexingBusy {
                Text(e).foregroundStyle(.red)
            } else if all.isEmpty {
                Text("Pull a model with \"embed\" in its name on the Ollama page, say qwen3-embedding:0.6b.")
            } else {
                Text("Semantic codebase search, with embeddings made on the Spark.")
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

    private func label(_ s: ClientTool.Status) -> String {
        switch s {
        case .notInstalled: "Not installed"
        case .notAdded: "Not added"
        case .upToDate: "Up to date"
        case .outdated: "Models changed"
        case .unreadable: "Config unreadable"
        }
    }
}
