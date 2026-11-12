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
                Picker("Model", selection: Binding(get: { model?.id }, set: { modelID = $0 })) {
                    ForEach(models) { r in
                        Text(r.name + (state.phase(for: r) == .ready ? "  ·  running" : "")).tag(Optional(r.id))
                    }
                }
                if let model { CopyRow(title: "Model name", value: model.apiID) }
            } header: {
                Text("OpenAI-Compatible API")
            } footer: {
                Text("Use these in any app that supports a custom OpenAI endpoint. A request for a stopped model starts it automatically.")
            }

            Section {
                Picker("Example", selection: $snippet) {
                    ForEach(Snippet.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ZStack(alignment: .topTrailing) {
                    Text(code)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cardBorder))
                    CopyButton(text: code).padding(8)
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
                        Text(r.apiID).font(.body.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        CopyButton(text: r.apiID)
                    }
                }
            }
        }
        .page()
        .navigationTitle("Connect")
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
                Text(value).font(.body.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
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
            Toggle(isOn: $state.config.gateway.syncTools) {
                Text("Keep models up to date")
                Text("When you add, rename, enable or reprice a model, tools that already list Spark Control are updated.")
            }
        } header: {
            Text("Coding Tools")
        } footer: {
            Text("Adds a “Spark Control” provider with your enabled models, their prices, and whether each reasons and takes images (set on each model's page). Kilo Code uses the OpenRouter SDK so it shows each request's cost. The previous file is kept beside it as .spark-control.bak. Restart the tool, or reload its window, to see the change.")
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
