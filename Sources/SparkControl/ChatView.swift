import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: Model

struct ChatAttachment: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case image, text }
    var id = UUID()
    var name: String
    var kind: Kind
    var mime = "text/plain"
    /// Base64 JPEG for images, the extracted text otherwise.
    var payload: String
}

struct ChatMessage: Codable, Identifiable {
    var id = UUID()
    var role: String
    var content = ""
    var reasoning = ""
    var attachments: [ChatAttachment] = []
    var stats: String?
    var error: String?
}

struct Chat: Codable, Identifiable {
    var id = UUID()
    var title = "New Chat"
    var model = ""
    var system = ""
    var messages: [ChatMessage] = []
    var updated = Date()
}

/// Chats live in chats.json next to the config. They go through the local gateway, so model
/// switching, parameter rules, usage and speed stats all apply exactly as for any other client.
@MainActor @Observable
final class ChatStore {
    var chats: [Chat]
    var selection: UUID?
    var streamingChat: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let url = Store.dir.appending(path: "chats.json")
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 900 // model switches and long prefills can take minutes
        c.timeoutIntervalForResource = 7200
        return URLSession(configuration: c)
    }()

    init() {
        // ponytail: one JSON file with images inline; fine for personal use, move attachments to files if it grows large.
        chats = (try? JSONDecoder().decode([Chat].self, from: Data(contentsOf: Self.url))) ?? []
        selection = chats.first?.id
    }

    func save() { try? JSONEncoder().encode(chats).write(to: Self.url, options: .atomic) }
    func index(_ id: UUID) -> Int? { chats.firstIndex { $0.id == id } }

    @discardableResult
    func newChat(model: String) -> UUID {
        let c = Chat(model: model)
        chats.insert(c, at: 0)
        selection = c.id
        save()
        return c.id
    }

    func delete(_ id: UUID) {
        if streamingChat == id { stop() }
        chats.removeAll { $0.id == id }
        if selection == id { selection = chats.first?.id }
        save()
    }

    func update(_ id: UUID, _ change: (inout Chat) -> Void) {
        guard let i = index(id) else { return }
        change(&chats[i])
        save()
    }

    func stop() { task?.cancel() }

    func send(_ text: String, attachments: [ChatAttachment], chatID: UUID, baseURL: String, apiKey: String) {
        guard let i = index(chatID), streamingChat == nil else { return }
        chats[i].messages.append(ChatMessage(role: "user", content: text, attachments: attachments))
        if chats[i].title == "New Chat" {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            chats[i].title = t.isEmpty ? (attachments.first?.name ?? "New Chat") : String(t.prefix(60))
        }
        let request = makeRequest(chats[i], baseURL: baseURL, apiKey: apiKey)
        let reply = ChatMessage(role: "assistant")
        chats[i].messages.append(reply)
        chats[i].updated = .now
        let moved = chats.remove(at: i)
        chats.insert(moved, at: 0)
        save()
        streamingChat = chatID
        task = Task {
            await stream(request, chatID: chatID, replyID: reply.id)
            streamingChat = nil
            save()
        }
    }

    private func makeRequest(_ chat: Chat, baseURL: String, apiKey: String) -> URLRequest {
        var messages: [[String: Any]] = []
        if !chat.system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": chat.system])
        }
        for m in chat.messages {
            if m.role == "user" {
                messages.append(["role": "user", "content": Self.userContent(m)])
            } else if !m.content.isEmpty {
                messages.append(["role": "assistant", "content": m.content])
            }
        }
        let body: [String: Any] = [
            "model": chat.model, "messages": messages,
            "stream": true, "stream_options": ["include_usage": true],
        ]
        var r = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.httpBody = Transform.serialize(body)
        return r
    }

    /// Plain string when there are no attachments; otherwise text (with files inlined) plus image parts.
    private static func userContent(_ m: ChatMessage) -> Any {
        let files = m.attachments.filter { $0.kind == .text }
        let images = m.attachments.filter { $0.kind == .image }
        var text = m.content
        for f in files { text += "\n\n<file name=\"\(f.name)\">\n\(f.payload)\n</file>" }
        if images.isEmpty { return text }
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        for img in images {
            parts.append(["type": "image_url", "image_url": ["url": "data:\(img.mime);base64,\(img.payload)"]])
        }
        return parts
    }

    private func stream(_ request: URLRequest, chatID: UUID, replyID: UUID) async {
        func edit(_ change: (inout ChatMessage) -> Void) {
            guard let c = index(chatID), let m = chats[c].messages.firstIndex(where: { $0.id == replyID }) else { return }
            change(&chats[c].messages[m])
        }
        let start = Date()
        var first: Date?
        var completion: Int?
        do {
            let (bytes, resp) = try await Self.session.bytes(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                var body = ""
                for try await line in bytes.lines { body += line }
                let message = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])
                    .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "HTTP \(http.statusCode)"
                edit { $0.error = message }
                return
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                if let u = obj["usage"] as? [String: Any] { completion = u["completion_tokens"] as? Int }
                guard let d = (obj["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { continue }
                let text = d["content"] as? String ?? ""
                let thought = d["reasoning_content"] as? String ?? d["reasoning"] as? String ?? ""
                guard !text.isEmpty || !thought.isEmpty else { continue }
                if first == nil { first = Date() }
                edit { $0.content += text; $0.reasoning += thought }
            }
        } catch {
            if !Task.isCancelled { edit { $0.error = error.localizedDescription } }
        }
        let end = Date()
        var parts: [String] = []
        if let first, let c = completion, let tps = Speed.decode(completion: c, decodeTime: end.timeIntervalSince(first)) {
            parts.append(UsageView.tps(tps))
            parts.append("\(c.formatted()) tokens")
        }
        if let first { parts.append(UsageView.secs(first.timeIntervalSince(start)) + " to first token") }
        if Task.isCancelled { parts.append("Stopped") }
        edit { $0.stats = parts.isEmpty ? nil : parts.joined(separator: " · ") }
    }

    // MARK: Attachments

    static let importTypes: [UTType] = [.image, .pdf, .plainText, .text, .sourceCode, .json, .commaSeparatedText, .xml, .yaml, .data]

    /// Reads a file into an attachment: images are downscaled to JPEG, PDFs and text become text.
    static func attachment(from url: URL) -> Result<ChatAttachment, AppError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .image) == true {
            guard let image = NSImage(contentsOf: url), let jpeg = jpeg(image, maxSide: 2048) else {
                return .failure(AppError("Couldn't read the image \(name)."))
            }
            return .success(ChatAttachment(name: name, kind: .image, mime: "image/jpeg", payload: jpeg.base64EncodedString()))
        }
        if type?.conforms(to: .pdf) == true {
            guard let text = PDFDocument(url: url)?.string, !text.isEmpty else {
                return .failure(AppError("\(name) has no extractable text (scanned PDF?)."))
            }
            return .success(ChatAttachment(name: name, kind: .text, payload: text))
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(AppError("Couldn't read \(name).")) }
        guard data.count <= 4 << 20 else { return .failure(AppError("\(name) is larger than 4 MB.")) }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(AppError("\(name) isn't a text, PDF or image file."))
        }
        return .success(ChatAttachment(name: name, kind: .text, payload: text))
    }

    private static func jpeg(_ image: NSImage, maxSide: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let w = max(1, Int(CGFloat(cg.width) * scale)), h = max(1, Int(CGFloat(cg.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white) // transparent areas become white, not black
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

// MARK: Views

struct ChatView: View {
    @Environment(AppState.self) private var state
    @Environment(ChatStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HSplitView {
            List(selection: $store.selection) {
                ForEach(store.chats) { chat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title).lineLimit(1)
                        Text(chat.updated, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(chat.id)
                    .contextMenu {
                        Button("Delete Chat", role: .destructive) { store.delete(chat.id) }
                    }
                }
            }
            .frame(minWidth: 170, idealWidth: 210, maxWidth: 300)

            Group {
                if let id = store.selection, store.index(id) != nil {
                    Conversation(chatID: id).id(id)
                } else {
                    ContentUnavailableView {
                        Label("No Chat Selected", systemImage: "bubble.left.and.bubble.right")
                    } actions: {
                        Button("New Chat") { store.newChat(model: defaultModel) }
                    }
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Chat")
        .toolbar {
            Button { store.newChat(model: defaultModel) } label: { Label("New Chat", systemImage: "square.and.pencil") }
                .help("New Chat")
        }
    }

    private var defaultModel: String {
        (state.activeRecipe ?? state.config.recipes.first(where: \.enabled))?.apiID ?? ""
    }
}

private struct Conversation: View {
    @Environment(AppState.self) private var state
    @Environment(ChatStore.self) private var store
    let chatID: UUID
    @State private var text = ""
    @State private var pending: [ChatAttachment] = []
    @State private var importing = false
    @State private var problem: String?
    @State private var editingSystem = false
    @FocusState private var focused: Bool

    private var chat: Chat? { store.index(chatID).map { store.chats[$0] } }
    private var streaming: Bool { store.streamingChat == chatID }
    private var models: [Recipe] { state.config.recipes.filter(\.enabled) }

    var body: some View {
        let chat = chat
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Model", selection: Binding(
                    get: { chat?.model ?? "" },
                    set: { m in store.update(chatID) { $0.model = m } })) {
                    ForEach(models) { r in Text(r.name).tag(r.apiID) }
                }
                .labelsHidden()
                .fixedSize()
                if let r = models.first(where: { $0.apiID == chat?.model }) {
                    StatusDot(phase: state.phase(for: r))
                    if state.phase(for: r) != .ready {
                        Text(state.config.gateway.autoSwap ? "Starts on first message" : "Not running")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { editingSystem.toggle() } label: {
                    Label("System Prompt", systemImage: chat?.system.isEmpty == false ? "text.bubble.fill" : "text.bubble")
                }
                .help("System Prompt")
                .popover(isPresented: $editingSystem, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("System Prompt").font(.headline)
                        TextEditor(text: Binding(
                            get: { chat?.system ?? "" },
                            set: { s in store.update(chatID) { $0.system = s } }))
                            .font(.body)
                            .frame(width: 380, height: 160)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(14)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(chat?.messages ?? []) { m in
                            MessageView(message: m, live: streaming && m.id == chat?.messages.last?.id)
                                .id(m.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(20)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .overlay {
                    if chat?.messages.isEmpty ?? true {
                        ContentUnavailableView("Start a Conversation", systemImage: "bubble.left.and.text.bubble.right",
                                               description: Text("Drop images, PDFs or text files here to attach them."))
                    }
                }
                .onChange(of: chat?.messages.last?.content.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat?.messages.last?.reasoning.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat?.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }

            composer
        }
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true }
        .fileImporter(isPresented: $importing, allowedContentTypes: ChatStore.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .alert("Couldn't Attach File", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
        .onAppear { focused = true }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pending) { a in
                            AttachmentChip(attachment: a) { pending.removeAll { $0.id == a.id } }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button { importing = true } label: { Image(systemName: "paperclip").font(.system(size: 15)) }
                    .buttonStyle(.borderless)
                    .help("Attach Files")
                TextField("Message \(models.first(where: { $0.apiID == chat?.model })?.name ?? "the model")…",
                          text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .focused($focused)
                    .onSubmit(send)
                if streaming {
                    Button { store.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 22)) }
                        .buttonStyle(.borderless)
                        .help("Stop")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                        .buttonStyle(.borderless)
                        .disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send (Return)")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .frame(maxWidth: 892)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool {
        !streaming && chat?.model.isEmpty == false
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty)
    }

    private func send() {
        guard canSend else { return }
        let key = state.config.gateway.apiKey.isEmpty ? "sk-local" : state.config.gateway.apiKey
        store.send(text, attachments: pending, chatID: chatID, baseURL: state.apiBaseURL, apiKey: key)
        text = ""
        pending = []
    }

    private func add(_ urls: [URL]) {
        var failures: [String] = []
        for url in urls {
            switch ChatStore.attachment(from: url) {
            case .success(let a): pending.append(a)
            case .failure(let e): failures.append(e.localizedDescription)
            }
        }
        if !failures.isEmpty { problem = failures.joined(separator: "\n") }
    }
}

private struct MessageView: View {
    let message: ChatMessage
    let live: Bool
    @State private var showThoughts = false

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.attachments.isEmpty {
                        HStack(spacing: 6) { ForEach(message.attachments) { AttachmentChip(attachment: $0) } }
                    }
                    if !message.content.isEmpty {
                        Text(message.content)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !message.reasoning.isEmpty {
                    DisclosureGroup(isExpanded: $showThoughts) {
                        Text(message.reasoning)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Label(live && message.content.isEmpty ? "Thinking…" : "Thoughts", systemImage: "brain")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if !message.content.isEmpty { MarkdownText(text: message.content) }
                if live && message.content.isEmpty && message.reasoning.isEmpty {
                    ProgressView().controlSize(.small)
                }
                if let error = message.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if !live {
                    HStack(spacing: 10) {
                        if let stats = message.stats {
                            Text(stats).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if !message.content.isEmpty { CopyButton(text: message.content).font(.caption) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Inline Markdown per paragraph, fenced code blocks rendered as monospaced boxes.
private struct MarkdownText: View {
    let text: String

    var body: some View {
        let segments = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { i, segment in
                if i % 2 == 1 {
                    CodeBlock(raw: segment)
                } else if !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(Self.render(segment)).textSelection(.enabled).lineSpacing(2)
                }
            }
        }
    }

    private static func render(_ s: String) -> AttributedString {
        // Headings aren't inline Markdown; show them bold.
        let lines = s.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.drop { $0 == "#" }
            return t.count < line.count && t.hasPrefix(" ") ? "**\(t.dropFirst())**" : String(line)
        }
        let joined = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: joined, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(joined)
    }
}

private struct CodeBlock: View {
    let raw: String

    var body: some View {
        let lines = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let language = lines.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let code = (lines.count > 1 ? String(lines[1]) : "").trimmingCharacters(in: .newlines)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: code).font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal) {
                Text(code)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AttachmentChip: View {
    let attachment: ChatAttachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if attachment.kind == .image, let image = Thumbnails.image(for: attachment) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
            }
            Text(attachment.name).font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Decoded thumbnails, so images aren't re-decoded on every streamed token.
@MainActor
private enum Thumbnails {
    static var cache: [UUID: NSImage] = [:]
    static func image(for a: ChatAttachment) -> NSImage? {
        if let hit = cache[a.id] { return hit }
        guard let data = Data(base64Encoded: a.payload), let image = NSImage(data: data) else { return nil }
        cache[a.id] = image
        return image
    }
}
