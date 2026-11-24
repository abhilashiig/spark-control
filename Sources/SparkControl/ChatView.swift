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
    /// Replies only: what the request used, for the chat's stats.
    var usage: UsageRecord?
}

struct Chat: Codable, Identifiable {
    var id = UUID()
    var title = "New Chat"
    var model = ""
    var profile: UUID?
    /// Extra instructions for this chat, sent after the profile's prompt.
    var system = ""
    var messages: [ChatMessage] = []
    var updated = Date()
    /// A `ThinkingEffort` raw value; nil is High. A string, so an unknown value can't fail decoding every chat.
    var effort: String?
}

/// How long a reasoning model thinks before answering. Built on what the Spark's Qwen servers honour:
/// enable_thinking turns thinking off, and vLLM's thinking_token_budget caps it (reasoning_effort is ignored).
enum ThinkingEffort: String, CaseIterable, Identifiable {
    case off, low, medium, high
    var id: Self { self }
    var label: String { rawValue.capitalized }

    var detail: String {
        switch self {
        case .off: "No thinking: fastest replies"
        case .low: "Thinks briefly, up to about 1,000 tokens"
        case .medium: "Thinks up to about 4,000 tokens"
        case .high: "Thinks as long as the model needs"
        }
    }

    init(_ raw: String?) { self = raw.flatMap(Self.init(rawValue:)) ?? .high }

    func apply(to body: inout [String: Any]) {
        switch self {
        case .off: body["chat_template_kwargs"] = ["enable_thinking": false]
        case .low: body["thinking_token_budget"] = 1024
        case .medium: body["thinking_token_budget"] = 4096
        case .high: break
        }
    }
}

/// Chats live in chats.json next to the config. They go through the local gateway, so model
/// switching, parameter rules, usage and speed stats all apply exactly as for any other client.
@MainActor @Observable
final class ChatStore {
    var chats: [Chat]
    var selection: UUID?
    var streamingChat: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    static let url = Store.dir.appending(path: "chats.json")
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
    func newChat(model: String, profiles: [ChatProfile]) -> UUID {
        // Keep the profile of the most recent chat, so a run of coding chats stays on Coding.
        let profile = chats.first?.profile.flatMap { p in profiles.contains { $0.id == p } ? p : nil } ?? profiles.first?.id
        let c = Chat(model: model, profile: profile)
        chats.insert(c, at: 0)
        selection = c.id
        save()
        return c.id
    }

    /// Attachments are stored inline in chats.json, so removing a chat removes its uploads too.
    func delete(_ ids: Set<UUID>) {
        if let s = streamingChat, ids.contains(s) { stop() }
        chats.removeAll { ids.contains($0.id) }
        if let s = selection, ids.contains(s) { selection = chats.first?.id }
        save()
    }

    func update(_ id: UUID, _ change: (inout Chat) -> Void) {
        guard let i = index(id) else { return }
        change(&chats[i])
        save()
    }

    func stop() { task?.cancel() }

    /// Replaces a sent message and everything after it, then sends the new text with its original attachments.
    func resend(_ messageID: UUID, text: String, chatID: UUID, profiles: [ChatProfile], baseURL: String, apiKey: String) {
        guard streamingChat == nil, let i = index(chatID),
              let m = chats[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        let attachments = chats[i].messages[m].attachments
        chats[i].messages.removeSubrange(m...)
        send(text, attachments: attachments, chatID: chatID, profiles: profiles, baseURL: baseURL, apiKey: apiKey)
    }

    func send(_ text: String, attachments: [ChatAttachment], chatID: UUID, profiles: [ChatProfile], baseURL: String, apiKey: String) {
        guard let i = index(chatID), streamingChat == nil else { return }
        chats[i].messages.append(ChatMessage(role: "user", content: text, attachments: attachments))
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsTitle = chats[i].title == "New Chat"
        if needsTitle {
            chats[i].title = question.isEmpty ? (attachments.first?.name ?? "New Chat") : String(question.prefix(60))
        }
        let request = makeRequest(chats[i], profiles: profiles, baseURL: baseURL, apiKey: apiKey)
        let reply = ChatMessage(role: "assistant")
        chats[i].messages.append(reply)
        chats[i].updated = .now
        let moved = chats.remove(at: i)
        chats.insert(moved, at: 0)
        save()
        streamingChat = chatID
        if needsTitle && !question.isEmpty {
            let fallback = chats[0].title, model = chats[0].model
            Task { await generateTitle(question, fallback: fallback, chatID: chatID, model: model, baseURL: baseURL, apiKey: apiKey) }
        }
        task = Task {
            await stream(request, chatID: chatID, replyID: reply.id)
            streamingChat = nil
            save()
        }
    }

    private func makeRequest(_ chat: Chat, profiles: [ChatProfile], baseURL: String, apiKey: String) -> URLRequest {
        var messages: [[String: Any]] = []
        let system = [profiles.first { $0.id == chat.profile }?.system ?? "", chat.system]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        for m in chat.messages {
            if m.role == "user" {
                messages.append(["role": "user", "content": Self.userContent(m)])
            } else if !m.content.isEmpty {
                messages.append(["role": "assistant", "content": m.content])
            }
        }
        var body: [String: Any] = [
            "model": chat.model, "messages": messages,
            "stream": true, "stream_options": ["include_usage": true],
        ]
        ThinkingEffort(chat.effort).apply(to: &body)
        return Self.post(body, baseURL: baseURL, apiKey: apiKey)
    }

    /// Asks the chat's model for a short title; the question stays as the title until it answers,
    /// and a title the user changed meanwhile is kept.
    private func generateTitle(_ question: String, fallback: String, chatID: UUID, model: String, baseURL: String, apiKey: String) async {
        let body: [String: Any] = [
            "model": model, "max_tokens": 300,
            // Reasoning models would spend the token budget thinking about a title.
            "chat_template_kwargs": ["enable_thinking": false],
            "messages": [
                ["role": "system", "content": "Write a short title, at most 6 words, for a chat that starts with the user's message below. Reply with the title only: no quotes, no trailing punctuation."],
                ["role": "user", "content": String(question.prefix(4000))],
            ],
        ]
        guard let (data, _) = try? await Self.session.data(for: Self.post(body, baseURL: baseURL, apiKey: apiKey)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = ((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
              let title = Transform.chatTitle(content),
              let i = index(chatID), chats[i].title == fallback else { return }
        chats[i].title = title
        save()
    }

    private static func post(_ body: [String: Any], baseURL: String, apiKey: String) -> URLRequest {
        var r = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue("Chat", forHTTPHeaderField: ClientTool.header)
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
        var usage: Transform.Usage?
        var cost = 0.0
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
                if let u = Transform.usage(obj) {
                    usage = u
                    completion = u.completion
                    cost = (obj["usage"] as? [String: Any])?["cost"] as? Double ?? 0
                }
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
        edit {
            $0.stats = parts.isEmpty ? nil : parts.joined(separator: " · ")
            $0.usage = usage.map { u in
                UsageRecord(date: end, model: "", prompt: u.prompt, completion: u.completion, cached: u.cached, reasoning: u.reasoning,
                            cost: cost, ttft: first.map { $0.timeIntervalSince(start) }, decodeTime: first.map { end.timeIntervalSince($0) })
            }
        }
    }

    // MARK: Attachments

    static let importTypes: [UTType] = [.image, .pdf, .plainText, .text, .sourceCode, .json, .commaSeparatedText, .xml, .yaml, .data]

    /// Reads a file into attachments: images are downscaled to JPEG, PDFs and text become text,
    /// and scanned PDFs (no text layer) become one image per page.
    static func attachments(from url: URL) -> Result<[ChatAttachment], AppError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .image) == true {
            guard let image = NSImage(contentsOf: url), let jpeg = jpeg(image, maxSide: 2048) else {
                return .failure(AppError("Couldn't read the image \(name)."))
            }
            return .success([ChatAttachment(name: name, kind: .image, mime: "image/jpeg", payload: jpeg.base64EncodedString())])
        }
        if type?.conforms(to: .pdf) == true {
            guard let pdf = PDFDocument(url: url) else { return .failure(AppError("Couldn't read the PDF \(name).")) }
            if let text = pdf.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .success([ChatAttachment(name: name, kind: .text, payload: text)])
            }
            let maxPages = 20
            guard pdf.pageCount <= maxPages else {
                return .failure(AppError("\(name) is a scanned PDF with \(pdf.pageCount) pages; at most \(maxPages) can be attached as images."))
            }
            var pages: [ChatAttachment] = []
            for i in 0..<pdf.pageCount {
                guard let page = pdf.page(at: i),
                      let jpeg = jpeg(page.thumbnail(of: NSSize(width: 2048, height: 2048), for: .mediaBox), maxSide: 2048) else {
                    return .failure(AppError("Couldn't render page \(i + 1) of \(name)."))
                }
                let label = pdf.pageCount == 1 ? name : "\(name) p\(i + 1)"
                pages.append(ChatAttachment(name: label, kind: .image, mime: "image/jpeg", payload: jpeg.base64EncodedString()))
            }
            return pages.isEmpty ? .failure(AppError("\(name) has no pages.")) : .success(pages)
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(AppError("Couldn't read \(name).")) }
        guard data.count <= 4 << 20 else { return .failure(AppError("\(name) is larger than 4 MB.")) }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(AppError("\(name) isn't a text, PDF or image file."))
        }
        return .success([ChatAttachment(name: name, kind: .text, payload: text)])
    }

    static func jpeg(_ image: NSImage, maxSide: CGFloat) -> Data? {
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
    @AppStorage("chatListWidth") private var listWidth = 280.0
    @State private var picked: Set<UUID> = []
    @State private var toDelete: Set<UUID> = []
    @State private var search = ""

    var body: some View {
        @Bindable var store = store
        // Not an HSplitView: it re-split on every chat switch (the conversation is rebuilt by .id), so the list jumped.
        // The list keeps the width dragged on its divider, shrinking only when the window is too narrow.
        let visible = store.chats.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    HStack {
                        Text("Chats").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.text)
                        Spacer()
                        Button { store.newChat(model: defaultModel, profiles: state.config.profiles) } label: {
                            Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.text)
                                .frame(width: 32, height: 32)
                                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(8), style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: .corner(8), style: .continuous).strokeBorder(Color(light: 0xE4E4E7, dark: 0x26262B)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("n")
                        .help("New Chat (⌘N)")
                        .accessibilityLabel("New Chat")
                    }
                    .padding(.horizontal, 4)
                    HeaderSearch(text: $search, prompt: "Search chats", width: nil)
                }
                .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 4)
                .background { Color.pageBackground.gesture(WindowDragGesture()) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Self.groups(visible), id: \.0) { label, chats in
                            Text(label.uppercased())
                                .font(.system(size: 11, weight: .medium)).tracking(0.44).foregroundStyle(Color.text2)
                                .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(chats) { chat in chatRow(chat, visible) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                // ⌘/⇧-click picks several chats; Delete removes them. The conversation shows the one picked last.
                .focusable()
                .focusEffectDisabled()
                .onDeleteCommand { delete(picked) }
            }
            .onAppear { picked = store.selection.map { [$0] } ?? [] }
            .onChange(of: picked) { if picked.count == 1 { store.selection = picked.first } }
            .onChange(of: store.selection) { if !(store.selection.map(picked.contains) ?? picked.isEmpty) { picked = store.selection.map { [$0] } ?? [] } }
            .frame(minWidth: 200, maxWidth: listWidth)
            .layoutPriority(1) // sized first; the HStack still reserves the conversation's minimum width

            ResizeHairline(width: $listWidth, range: 200...420)

            Group {
                if let id = store.selection, store.index(id) != nil {
                    Conversation(chatID: id) { toDelete = Set(store.chats.map(\.id)) }.id(id)
                } else {
                    ContentUnavailableView {
                        Label("No Chat Selected", systemImage: "bubble.left.and.bubble.right")
                    } actions: {
                        Button("New Chat") { store.newChat(model: defaultModel, profiles: state.config.profiles) }
                    }
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog(toDelete.count == store.chats.count ? "Delete all \(toDelete.count) chats?" : "Delete \(toDelete.count) chats?",
                            isPresented: Binding(get: { !toDelete.isEmpty }, set: { if !$0 { toDelete = [] } })) {
            Button("Delete", role: .destructive) { store.delete(toDelete); toDelete = [] }
        } message: {
            Text("Their messages and attachments are removed. This can't be undone.")
        }
    }

    private func chatRow(_ chat: Chat, _ visible: [Chat]) -> some View {
        let recipe = state.config.recipes.first { $0.apiID == chat.model }
        let on = picked.contains(chat.id)
        return VStack(alignment: .leading, spacing: 3) {
            Text(chat.title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? Color.text : Color(light: 0x3F3F46, dark: 0xD4D4D8)).lineLimit(1)
            Text(recipe?.name ?? chat.model).font(.system(size: 12)).foregroundStyle(on ? Color.text3 : Color.text2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(on ? Color(light: 0xE4E4E7, dark: 0x1C1C21) : .clear, in: RoundedRectangle(cornerRadius: .corner(9), style: .continuous))
        .hoverFill(Color.overlay(0.03), radius: 9, active: on)
        .help(Self.day(chat.updated))
        .contentShape(Rectangle())
        .onTapGesture { click(chat.id, visible) }
        .contextMenu {
            let ids = on ? picked : [chat.id]
            Button(ids.count == 1 ? "Delete Chat" : "Delete \(ids.count) Chats…", role: .destructive) { delete(ids) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { picked = [chat.id] }
    }

    /// A click picks one chat, ⌘ adds or removes one, ⇧ picks the run from the last picked.
    private func click(_ id: UUID, _ visible: [Chat]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            picked.formSymmetricDifference([id])
        } else if flags.contains(.shift), let anchor = store.selection,
                  let a = visible.firstIndex(where: { $0.id == anchor }), let b = visible.firstIndex(where: { $0.id == id }) {
            picked = Set(visible[min(a, b)...max(a, b)].map(\.id))
        } else {
            picked = [id]
        }
    }

    /// Consecutive chats under "Today", "Yesterday" or their date ("12 Nov"), keeping the list's order.
    private static func groups(_ chats: [Chat]) -> [(String, [Chat])] {
        var out: [(String, [Chat])] = []
        for c in chats {
            let cal = Calendar.current
            let label = cal.isDateInToday(c.updated) ? "Today" : cal.isDateInYesterday(c.updated) ? "Yesterday"
                : c.updated.formatted(.dateTime.day().month(.abbreviated))
            if out.last?.0 == label { out[out.count - 1].1.append(c) } else { out.append((label, [c])) }
        }
        return out
    }

    /// "14:05" today, "Thu" this week, "3 Nov" before that.
    private static func day(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        let cal = Calendar.current
        if let week = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: .now)), d >= week {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    /// One chat goes at once, as before; several ask first.
    private func delete(_ ids: Set<UUID>) {
        if ids.count == 1 { store.delete(ids) } else if !ids.isEmpty { toDelete = ids }
    }

    private var defaultModel: String {
        (state.activeRecipe ?? state.config.recipes.first(where: \.enabled))?.apiID ?? ""
    }
}

private struct Conversation: View {
    @Environment(AppState.self) private var state
    @Environment(ChatStore.self) private var store
    let chatID: UUID
    var onDeleteAll: () -> Void = {}
    @State private var text = ""
    @State private var showStats = false
    @State private var pending: [ChatAttachment] = []
    @State private var importing = false
    @State private var problem: String?
    @State private var editingSystem = false
    @State private var editingProfiles = false
    @FocusState private var focused: Bool

    private var chat: Chat? { store.index(chatID).map { store.chats[$0] } }
    private var profile: ChatProfile? { state.config.profiles.first { $0.id == chat?.profile } }
    private var streaming: Bool { store.streamingChat == chatID }
    private var models: [Recipe] { state.config.recipes.filter { $0.enabled && !$0.isEmbedding } }

    var body: some View {
        let chat = chat
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                modelMenu(chat)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Menu {
                        Picker("Profile", selection: Binding(
                            get: { chat?.profile },
                            set: { p in store.update(chatID) { $0.profile = p } })) {
                            ForEach(state.config.profiles) { Text($0.name.isEmpty ? "Untitled" : $0.name).tag(Optional($0.id)) }
                            Text("No Profile").tag(UUID?.none)
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Button("Edit Profiles…") { editingProfiles = true }
                    } label: {
                        Text(profile?.name ?? "No Profile").font(.system(size: 13)).lineLimit(1).headerPill()
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Profile: the system prompt this chat uses")
                    .sheet(isPresented: $editingProfiles) { ProfilesEditor(selection: chat?.profile ?? state.config.profiles.first?.id) }
                    if current?.hasReasoning == true || chat?.effort != nil {
                        let effort = ThinkingEffort(chat?.effort)
                        Menu {
                            Section("Thinking Effort") {
                                ForEach(ThinkingEffort.allCases) { e in
                                    Toggle(isOn: Binding(get: { effort == e },
                                                         set: { _ in store.update(chatID) { $0.effort = e == .high ? nil : e.rawValue } })) {
                                        Text(e.label)
                                        Text(e.detail)
                                    }
                                }
                            }
                        } label: {
                            Text(effort == .off ? "Thinking off" : "\(effort.label) effort").font(.system(size: 13)).lineLimit(1).headerPill()
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Thinking effort: how long the model reasons before answering. Less is faster, more is more careful.")
                    }
                    Button { editingSystem.toggle() } label: {
                        LineIcon(symbol: "slider.horizontal.3", size: 16).headerPill(square: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chat Instructions")
                    .overlay(alignment: .topTrailing) {
                        if chat?.system.isEmpty == false { Circle().fill(Color.brand).frame(width: 6, height: 6).offset(x: -4, y: 4) }
                    }
                    .help("Extra instructions for this chat")
                    .popover(isPresented: $editingSystem, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Instructions for This Chat").font(.headline)
                            Text(profile.map { "Sent after the \($0.name) profile's prompt." } ?? "Sent as the system prompt.")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: Binding(
                                get: { chat?.system ?? "" },
                                set: { s in store.update(chatID) { $0.system = s } }))
                                .font(.body)
                                .frame(width: 380, height: 160)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: .corner(6)))
                        }
                        .padding(14)
                    }
                    Menu {
                        Button("Chat Statistics") { showStats = true }
                        Button("Show Chat Files in Finder") {
                            let file = ChatStore.url
                            if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                            else { NSWorkspace.shared.open(Store.dir) }
                        }
                        Divider()
                        Button("Delete Chat", role: .destructive) { store.delete([chatID]) }
                        Button("Delete All Chats…", role: .destructive, action: onDeleteAll)
                    } label: {
                        LineIcon(symbol: "ellipsis", size: 16).headerPill(square: true)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                    .popover(isPresented: $showStats, arrowEdge: .bottom) {
                        ChatStats(messages: chat?.messages ?? [], window: current?.contextWindow).padding(14)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .frame(minHeight: 64)
            .background { Color.pageBackground.gesture(WindowDragGesture()) }
            .overlay(alignment: .bottom) { Hairline() }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(chat?.messages ?? []) { m in
                            MessageView(message: m, live: streaming && m.id == chat?.messages.last?.id,
                                        tag: ModelAvatar.tag(current?.name ?? chat?.model ?? ""),
                                        engine: current.map(state.engineName) ?? "Custom",
                                        onEdit: store.streamingChat != nil ? nil : { text in
                                            store.resend(m.id, text: text, chatID: chatID, profiles: state.config.profiles, baseURL: state.apiBaseURL,
                                                         apiKey: state.toolGateway.apiKey)
                                        },
                                        onRetry: store.streamingChat != nil ? nil : retry(m, in: chat?.messages ?? []))
                                .id(m.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: 712)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity)
                }
                .background(Color.pageBackground)
                .overlay {
                    if chat?.messages.isEmpty ?? true {
                        Text("Start a conversation").font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.text)
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

    private var current: Recipe? { models.first { $0.apiID == chat?.model } }

    /// Regenerates a reply by sending the question before it again; that reply and everything after it are replaced.
    private func retry(_ reply: ChatMessage, in messages: [ChatMessage]) -> (() -> Void)? {
        guard reply.role != "user", let i = messages.firstIndex(where: { $0.id == reply.id }),
              let question = messages[..<i].last(where: { $0.role == "user" }) else { return nil }
        return {
            store.resend(question.id, text: question.content, chatID: chatID, profiles: state.config.profiles,
                         baseURL: state.apiBaseURL, apiKey: state.toolGateway.apiKey)
        }
    }

    /// The chat's model, centred, with whether it's loaded beneath.
    private func modelMenu(_ chat: Chat?) -> some View {
        Menu {
            Picker("Model", selection: Binding(
                get: { chat?.model ?? "" },
                set: { m in store.update(chatID) { $0.model = m } })) {
                ForEach(models) { r in Text(r.name).tag(r.apiID) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 10) {
                Circle().fill(modelDot).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(current?.name ?? "Choose a model").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.text).lineLimit(1)
                    if current != nil {
                        Text(modelStatus).font(.system(size: 11))
                            .foregroundStyle(current.map { state.phase(for: $0).isFailure } == true ? Color.danger : Color.text3).lineLimit(1)
                    }
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.text2)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(10), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: .corner(10), style: .continuous).strokeBorder(Color(light: 0xE4E4E7, dark: 0x26262B)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model for this chat")
    }

    private var modelDot: Color {
        guard let r = current else { return Color.text2 }
        if state.offline { return Color.danger }
        let p = state.phase(for: r)
        return p == .ready ? Color.running : p == .stopped ? Color.text2 : p.isFailure ? Color.danger : Color(light: 0xD97706, dark: 0xFBBF24)
    }

    /// "Loading · 111 GB · Custom".
    private var modelStatus: String {
        guard let r = current else { return "" }
        let p = state.phase(for: r)
        let phase = state.offline ? Phase.offline.label : p == .stopped ? "Not loaded" : p == .starting ? "Loading" : p.label
        return ([phase] + [state.memoryNeed(r).map { String(format: "%.0f GB", Double($0) / 1e9) }, state.engineName(r)].compactMap { $0 })
            .joined(separator: " · ")
    }

    /// While the chat's model starts: a card above the composer, as the reply waits for it.
    @ViewBuilder private var loadingCard: some View {
        if let r = current, state.phase(for: r) == .starting {
            let others = state.runningRecipes.filter { $0.id != r.id }.map(\.name)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(light: 0xD97706, dark: 0xFBBF24)).frame(width: 8, height: 8)
                        Text("Loading \(r.name) into memory").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.text)
                    }
                    Spacer(minLength: 0)
                    if let need = state.memoryNeed(r) {
                        Text(String(format: "%.0f GB", Double(need) / 1e9)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.text3)
                    }
                }
                ProgressView().progressViewStyle(.linear).tint(Color(light: 0xD97706, dark: 0xFBBF24))
                Text("Your message sends as soon as the model is ready." + (others.isEmpty ? "" :
                    " \(others.formatted(.list(type: .and))) \(others.count == 1 ? "keeps" : "keep") running alongside it."))
                    .font(.system(size: 12)).foregroundStyle(Color.text3)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(12), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: .corner(12), style: .continuous).strokeBorder(Color.cardBorder))
            .accessibilityElement(children: .combine)
        }
    }

    /// What sending will load and unload, when the chat's model isn't running yet.
    private var swapNote: String? {
        guard !state.offline, let r = current, state.phase(for: r) == .stopped, state.config.gateway.autoSwap else { return nil }
        let size = state.memoryNeed(r).map { String(format: " (%.0f GB)", Double($0) / 1e9) } ?? ""
        let stops = state.stopsToStart(r).map(\.name)
        return "Sending loads \(r.name)\(size)" + (stops.isEmpty ? "." : " and unloads \(stops.formatted(.list(type: .and))).")
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
            TextField("Ask anything", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Color.text)
                .lineSpacing(4)
                .padding(4)
                .lineLimit(2...10)
                .focused($focused)
                .onSubmit(send)
                .newlineOnShiftReturn()
            HStack(spacing: 4) {
                Button { importing = true } label: {
                    Image(systemName: "paperclip").font(.system(size: 13)).foregroundStyle(Color.text3)
                        .frame(width: 32, height: 32)
                        .overlay(RoundedRectangle(cornerRadius: .corner(8), style: .continuous).strokeBorder(Color(light: 0xE4E4E7, dark: 0x26262B)))
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Attach Files")
                    .help("Attach Files")
                    // ⌘V: images and copied files become attachments; anything else pastes as usual.
                    .background { Button("Paste", action: paste).keyboardShortcut("v").opacity(0).frame(width: 0, height: 0) }
                Spacer()
                if streaming {
                    Button { store.stop() } label: { RoundIcon(symbol: "stop.fill", fill: Color.primaryFill, icon: Color.primaryText) }
                        .buttonStyle(PressableStyle())
                        .help("Stop")
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button(action: send) { RoundIcon(symbol: "arrow.up", fill: canSend ? Color.primaryFill : Color(light: 0xE4E4E7, dark: 0x26262B),
                                                     icon: canSend ? Color.primaryText : Color.text2) }
                        .buttonStyle(PressableStyle())
                        .disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send (Return). Shift-Return adds a new line.")
                }
            }
        }
        .animation(.snappy, value: streaming)
        .padding(12)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(14), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .corner(14), style: .continuous)
            .strokeBorder(focused ? Color.brand.opacity(0.45) : Color(light: 0xD4D4D8, dark: 0x2E2E34), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: focused)
        .frame(maxWidth: 712)
        .safeAreaInset(edge: .top, spacing: 12) {
            VStack(spacing: 10) {
                loadingCard
                if let swapNote {
                    Text(swapNote).font(.system(size: 12)).foregroundStyle(Color.text2).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 712)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(Color.pageBackground)
    }

    private var canSend: Bool {
        !streaming && chat?.model.isEmpty == false
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty)
    }

    private func send() {
        guard canSend else { return }
        if pending.contains(where: { $0.kind == .image }),
           let r = state.config.recipes.first(where: { $0.apiID == chat?.model }), !r.takesImages {
            problem = "\(r.name) doesn't take images. Turn on Image input on its page and restart it, or remove the images."
            return
        }
        store.send(text, attachments: pending, chatID: chatID, profiles: state.config.profiles, baseURL: state.apiBaseURL,
                   apiKey: state.toolGateway.apiKey)
        text = ""
        pending = []
    }

    private func paste() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls)
        } else if pb.string(forType: .string) == nil, let image = NSImage(pasteboard: pb) {
            guard let jpeg = ChatStore.jpeg(image, maxSide: 2048) else { problem = "Couldn't read the pasted image."; return }
            pending.append(ChatAttachment(name: "Pasted Image", kind: .image, mime: "image/jpeg", payload: jpeg.base64EncodedString()))
        } else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        }
    }

    private func add(_ urls: [URL]) {
        var failures: [String] = []
        for url in urls {
            switch ChatStore.attachments(from: url) {
            case .success(let a): pending += a
            case .failure(let e): failures.append(e.localizedDescription)
            }
        }
        if !failures.isEmpty { problem = failures.joined(separator: "\n") }
    }
}

private struct RoundIcon: View {
    let symbol: String
    let fill: Color
    var icon = Color.white
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(icon)
            .frame(width: 32, height: 32)
            .background(fill, in: RoundedRectangle(cornerRadius: .corner(8), style: .continuous))
    }
}

private struct MessageView: View {
    let message: ChatMessage
    let live: Bool
    /// The model's tile ("3.8") and engine, for the reply's avatar.
    var tag = ""
    var engine = "Custom"
    /// Nil while a reply is streaming.
    var onEdit: ((String) -> Void)?
    var onRetry: (() -> Void)?
    @State private var showThoughts = false
    @State private var editing = false
    @State private var draft = ""
    @State private var hovering = false

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 120)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.attachments.isEmpty {
                        HStack(spacing: 6) { ForEach(message.attachments) { AttachmentChip(attachment: $0) } }
                    }
                    if editing {
                        TextField("Message", text: $draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...14)
                            .onSubmit(save)
                            .newlineOnShiftReturn()
                            .onExitCommand { editing = false }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(minWidth: 320)
                            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: .corner(14), style: .continuous))
                        HStack {
                            Button("Cancel") { editing = false }
                            Button("Save & Resend", action: save)
                                .buttonStyle(.borderedProminent)
                                .disabled(onEdit == nil || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.attachments.isEmpty))
                        }
                        .controlSize(.small)
                        Text("Replies after this message are replaced.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        if !message.content.isEmpty {
                            let bubble = UnevenRoundedRectangle(topLeadingRadius: .corner(14), bottomLeadingRadius: .corner(14), bottomTrailingRadius: .corner(4),
                                                                topTrailingRadius: .corner(14), style: .continuous)
                            Text(message.content)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.text)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color(light: 0xF4F4F5, dark: 0x1C1C21), in: bubble)
                                .overlay(bubble.strokeBorder(Color(light: 0xE4E4E7, dark: 0x26262B)))
                        }
                        Button { startEditing() } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help("Edit")
                            .opacity(hovering && onEdit != nil ? 1 : 0)
                            .disabled(onEdit == nil)
                    }
                }
            }
            .onHover { hovering = $0 }
            .contextMenu { Button("Edit") { startEditing() }.disabled(onEdit == nil) }
        } else {
            HStack(alignment: .top, spacing: 14) {
                Text(tag)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(EngineBadge.text(engine))
                    .minimumScaleFactor(0.6).lineLimit(1).padding(.horizontal, 2)
                    .frame(width: 28, height: 28)
                    .background(EngineBadge.color(engine).opacity(0.14), in: RoundedRectangle(cornerRadius: .corner(8), style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    if !message.reasoning.isEmpty {
                        Button { withAnimation(.snappy) { showThoughts.toggle() } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                    .rotationEffect(.degrees(showThoughts ? 90 : 0))
                                Text(live && message.content.isEmpty ? "Thinking…"
                                     : message.usage?.reasoning.map { "Thought for \($0.formatted()) tokens" } ?? "Thought process")
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Color.text3)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: .corner(7), style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: .corner(7), style: .continuous).strokeBorder(Color.cardBorder))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(showThoughts ? "Expanded" : "Collapsed")
                        if showThoughts {
                            Text(message.reasoning)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.text2)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 12)
                                .overlay(alignment: .leading) { Rectangle().fill(Color.hairline).frame(width: 2) }
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
                            .padding(10)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: .corner(10), style: .continuous))
                    }
                    if !live {
                        HStack(spacing: 2) {
                            if !message.content.isEmpty {
                                CopyButton(text: message.content).buttonStyle(GhostIconStyle()).help("Copy")
                            }
                            if let onRetry {
                                Button(action: onRetry) { Label("Retry", systemImage: "arrow.clockwise") }
                                    .buttonStyle(GhostIconStyle())
                                    .help("Retry: generate this reply again. Messages after it are replaced.")
                            }
                            if let stats = message.stats {
                                Text(stats).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.text2).padding(.leading, 8)
                            }
                        }
                        .padding(.leading, -6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension MessageView {
    private func startEditing() {
        draft = message.content
        editing = true
    }

    private func save() {
        guard let onEdit, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.attachments.isEmpty else { return }
        editing = false
        onEdit(draft)
    }
}

extension View {
    /// Return submits; Shift-Return and Option-Return insert a line break at the cursor, as in other chat apps.
    func newlineOnShiftReturn() -> some View {
        onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.shift) || press.modifiers.contains(.option) else { return .ignored }
            NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
            return .handled
        }
    }
}

/// Add, rename, rewrite and delete profiles. Changes apply to every chat using the profile from its next message.
private struct ProfilesEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var selection: UUID?
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            HSplitView {
                List(selection: $selection) {
                    ForEach(state.config.profiles) { Text($0.name.isEmpty ? "Untitled" : $0.name).tag($0.id) }
                        .onMove { state.config.profiles.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minWidth: 150, idealWidth: 170, maxWidth: 220)
                Group {
                    if let i = state.config.profiles.firstIndex(where: { $0.id == selection }) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Name", text: $state.config.profiles[i].name).textFieldStyle(.roundedBorder)
                            Text("System prompt").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $state.config.profiles[i].system)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: .corner(6)))
                        }
                        .padding(14)
                    } else {
                        ContentUnavailableView("Select a Profile", systemImage: "person.crop.square")
                    }
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button {
                    let p = ChatProfile(name: "New Profile", system: "")
                    state.config.profiles.append(p)
                    selection = p.id
                } label: { Image(systemName: "plus") }
                .help("Add Profile")
                Button { confirmDelete = true } label: { Image(systemName: "minus") }
                    .help("Delete Profile")
                    .disabled(selection == nil)
                Menu("Restore") {
                    ForEach(ChatProfile.defaults, id: \.name) { d in
                        Button(d.name) {
                            if let i = state.config.profiles.firstIndex(where: { $0.id == d.id || $0.name == d.name }) {
                                state.config.profiles[i].system = d.system
                                selection = state.config.profiles[i].id
                            } else {
                                state.config.profiles.append(d)
                                selection = d.id
                            }
                        }
                    }
                }
                .fixedSize()
                .help("Bring back a built-in profile, or reset its prompt")
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .frame(width: 680, height: 440)
        .confirmationDialog("Delete “\(state.config.profiles.first { $0.id == selection }?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                state.config.profiles.removeAll { $0.id == selection }
                selection = state.config.profiles.first?.id
            }
        } message: {
            Text("Chats using it keep their own instructions and continue without a profile.")
        }
    }
}

/// Totals for the chat's replies, shown while hovering its icon.
private struct ChatStats: View {
    let messages: [ChatMessage]
    let window: Int?

    var body: some View {
        let records = messages.compactMap(\.usage)
        let s = UsageView.Stats(records)
        // The last request's prompt holds the whole conversation so far; its reply is added to the next one.
        let used = records.last.map { $0.prompt + $0.completion }
        return VStack(alignment: .leading, spacing: 10) {
            Text("This Chat").font(.headline)
            if records.isEmpty {
                Text("No replies with usage yet.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    row("Context used", used.map { u in
                        window.map { "\(u.compact) of \($0.compact) (\(UsageView.percent(Double(u) / Double($0))))" } ?? "\(u.compact) tokens"
                    } ?? "—")
                    Divider().gridCellUnsizedAxes(.horizontal)
                    row("Decode", s.decodeTPS.map(UsageView.tps) ?? "—")
                    row("Prefill", s.prefillTPS.map(UsageView.tps) ?? "—")
                    row("Time to first token", s.avgTTFT.map(UsageView.secs) ?? "—")
                    Divider().gridCellUnsizedAxes(.horizontal)
                    row("Replies", s.requests.formatted())
                    row("In", s.input.compact)
                    row("Cache read", s.cached.compact)
                    row("Cache hit rate", s.hitRate.map(UsageView.percent) ?? "—")
                    row("Out", s.output.compact)
                    row("Reasoning", s.reasoning.compact)
                    row("Cost", s.cost.usd)
                }
                .monospacedDigit()
            }
        }
        .frame(minWidth: 260, alignment: .leading)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).gridColumnAlignment(.trailing)
        }
    }
}

private extension Recipe {
    /// Context the start command asks for, when the app can tell (vLLM and TensorFold models).
    var contextWindow: Int? {
        if let n = VLLM.context(of: startCommand) { return n }
        guard let m = TensorFold.model(tensorfold) else { return nil }
        switch TensorFold.context(of: startCommand) {
        case .window(let n): return n
        case .yarn(let f): return m.window * f
        case .engineDefault: return nil
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
                    Text(Self.render(segment)).font(.system(size: 14)).foregroundStyle(Color(light: 0x27272A, dark: 0xE4E4E7)).textSelection(.enabled).lineSpacing(7)
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
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: .corner(10), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: .corner(10), style: .continuous).strokeBorder(Color.cardBorder))
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
                    .clipShape(RoundedRectangle(cornerRadius: .corner(4)))
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
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: .corner(8), style: .continuous))
    }
}

/// Decoded thumbnails, so images aren't re-decoded on every streamed token.
@MainActor
private enum Thumbnails {
    static var cache: [UUID: NSImage] = [:]
    static func image(for a: ChatAttachment) -> NSImage? {
        if let hit = cache[a.id] { return hit }
        // A small thumbnail, not the full image: the chip is 26pt, and a 2048px bitmap would cost ~16 MB each.
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary
        guard let data = Data(base64Encoded: a.payload), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        cache[a.id] = image
        return image
    }
}

private extension View {
    /// The conversation header's 34pt outlined controls.
    func headerPill(square: Bool = false) -> some View {
        foregroundStyle(Color(light: 0x3F3F46, dark: 0xD4D4D8))
            .padding(.horizontal, square ? 0 : 10)
            .frame(width: square ? 34 : nil, height: 34)
            .overlay(RoundedRectangle(cornerRadius: .corner(8), style: .continuous).strokeBorder(Color(light: 0xE4E4E7, dark: 0x26262B)))
            .hoverFill(Color.overlay(0.04), radius: 8)
            .contentShape(Rectangle())
    }
}
