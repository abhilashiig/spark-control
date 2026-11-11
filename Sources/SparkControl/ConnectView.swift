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
    /// Most clients refuse an empty key, so give them a harmless one when none is set.
    private var key: String { state.config.gateway.apiKey.isEmpty ? "sk-local" : state.config.gateway.apiKey }

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
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    CopyButton(text: code).padding(8)
                }
            } header: {
                Text("Quick Start")
            }

            Section("All Models") {
                if models.isEmpty {
                    Text("No enabled models.").foregroundStyle(.secondary)
                }
                ForEach(models) { r in
                    HStack {
                        StatusDot(phase: state.phase(for: r))
                        Text(r.name)
                        Spacer()
                        Text(r.apiID).font(.body.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        CopyButton(text: r.apiID)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
