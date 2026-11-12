import Foundation
import Network

struct HTTPRequest {
    var method: String
    var target: String
    var headers: [(String, String)]
    var body: Data

    var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }
    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
}

enum HTTPError: Error { case closed, malformed, tooLarge, chunked }

/// Minimal HTTP/1.1 over Network.framework: one request per connection, then close.
final class HTTPConnection: @unchecked Sendable {
    let nw: NWConnection
    init(_ nw: NWConnection) { self.nw = nw }

    private func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
                if let error { cont.resume(throwing: error) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if done { cont.resume(returning: nil) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    func readRequest() async throws -> HTTPRequest {
        var buf = Data()
        let separator = Data("\r\n\r\n".utf8)
        var end: Range<Data.Index>?
        while end == nil {
            guard let chunk = try await receive() else { throw HTTPError.closed }
            buf.append(chunk)
            end = buf.range(of: separator)
            if end == nil, buf.count > 64 << 10 { throw HTTPError.tooLarge }
        }
        let lines = String(decoding: buf[..<end!.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2 else { throw HTTPError.malformed }
        let headers = lines.dropFirst().compactMap { line -> (String, String)? in
            guard let i = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<i]), line[line.index(after: i)...].trimmingCharacters(in: .whitespaces))
        }
        var req = HTTPRequest(method: String(start[0]), target: String(start[1]), headers: headers,
                              body: Data(buf[end!.upperBound...]))
        // ponytail: no chunked request bodies; every mainstream OpenAI client sends Content-Length.
        if req.header("transfer-encoding")?.lowercased().contains("chunked") == true { throw HTTPError.chunked }
        let length = Int(req.header("content-length") ?? "") ?? 0
        guard length <= 256 << 20 else { throw HTTPError.tooLarge }
        if length > req.body.count, req.header("expect")?.lowercased() == "100-continue" {
            try await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        while req.body.count < length {
            guard let chunk = try await receive() else { throw HTTPError.closed }
            req.body.append(chunk)
        }
        return req
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nw.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func close() {
        nw.send(content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { [nw] _ in nw.cancel() })
    }
}

struct GatewaySnapshot {
    var settings: GatewaySettings
    var recipes: [Recipe]
    var active: Recipe?
    var running: Set<UUID>
}

/// The OpenAI-compatible server clients talk to. Lives in the app; forwards to the Spark.
final class Gateway: @unchecked Sendable {
    private let state: AppState
    private let session: URLSession
    private var listener: NWListener?

    private static let skipRequest: Set<String> = [
        "host", "content-length", "connection", "keep-alive", "transfer-encoding",
        "accept-encoding", "expect", "proxy-connection", "upgrade", "te",
    ]
    private static let skipResponse: Set<String> = [
        "content-length", "content-encoding", "transfer-encoding", "connection", "keep-alive",
    ]
    private static let cors = [
        ("Access-Control-Allow-Origin", "*"),
        ("Access-Control-Allow-Headers", "*"),
        ("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS"),
    ]

    init(state: AppState) {
        self.state = state
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 900 // gap between bytes: long prompts can prefill for minutes
        c.timeoutIntervalForResource = 7200
        c.httpMaximumConnectionsPerHost = 16
        session = URLSession(configuration: c)
    }

    func start(port: Int, lan: Bool) {
        listener?.cancel()
        listener = nil
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let state = state
        do {
            let l: NWListener
            if lan {
                l = try NWListener(using: params, on: p)
            } else {
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: p)
                l = try NWListener(using: params)
            }
            l.stateUpdateHandler = { s in
                let message: String? = switch s {
                case .failed(let e), .waiting(let e): "Port \(port): \(e.localizedDescription)"
                default: nil
                }
                Task { @MainActor in state.gatewayError = message }
            }
            l.newConnectionHandler = { [weak self] nw in
                guard let self else { return nw.cancel() }
                nw.start(queue: .global(qos: .userInitiated))
                Task { await self.serve(HTTPConnection(nw)) }
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
        } catch {
            Task { @MainActor in state.gatewayError = error.localizedDescription }
        }
    }

    private func serve(_ c: HTTPConnection) async {
        defer { c.close() }
        let req: HTTPRequest
        do { req = try await c.readRequest() }
        catch HTTPError.chunked { return await sendError(c, 411, "Chunked request bodies aren't supported. Send Content-Length.") }
        catch HTTPError.tooLarge { return await sendError(c, 413, "Request too large.") }
        catch { return }
        await handle(req, c)
    }

    private func handle(_ req: HTTPRequest, _ c: HTTPConnection) async {
        let s = await state.gatewaySnapshot()
        if req.method == "OPTIONS" {
            try? await c.send(Self.head(204, Self.cors))
            return
        }
        if !s.settings.apiKey.isEmpty, req.header("authorization") != "Bearer \(s.settings.apiKey)" {
            return await sendError(c, 401, "Invalid API key.", type: "authentication_error")
        }

        let path = req.path
        if req.method == "GET", path == "/v1/models" || path == "/v1/models/" {
            return await sendJSON(c, 200, ["object": "list", "data": s.recipes.map { modelObject($0, s) }])
        }
        if req.method == "GET", path.hasPrefix("/v1/models/") {
            let id = String(path.dropFirst("/v1/models/".count)).removingPercentEncoding ?? ""
            guard let r = s.recipes.first(where: { $0.answers(to: id) }) else {
                return await sendError(c, 404, "Model '\(id)' not found.", code: "model_not_found")
            }
            return await sendJSON(c, 200, modelObject(r, s))
        }
        guard path.hasPrefix("/v1/") else { return await sendError(c, 404, "Not found.") }

        var body = req.body.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
        let recipe: Recipe
        if let model = body?["model"] as? String {
            guard let r = s.recipes.first(where: { $0.answers(to: model) }) else {
                return await sendError(c, 404, "Model '\(model)' isn't enabled in Spark Control.", code: "model_not_found")
            }
            recipe = r
        } else if let r = s.active {
            recipe = r
        } else {
            return await sendError(c, 503, "No model is running on the Spark.", type: "server_error")
        }

        do { try await state.ensureRunning(recipe) } catch {
            return await sendError(c, 503, error.localizedDescription, type: "server_error")
        }
        guard let base = await state.backendBase(for: recipe), let url = URL(string: base + req.target) else {
            return await sendError(c, 503, "The Spark is unreachable.", type: "server_error")
        }

        var forwarded = req.body
        if var b = body {
            let changed = Transform.apply(&b, recipe: recipe, path: path, streamUsage: s.settings.streamUsage)
            if !changed.isEmpty, let d = Transform.rebuild(req.body, b, changed: changed) ?? Transform.serialize(b) {
                forwarded = d
                body = b
            }
        }
        let streaming = body?["stream"] as? Bool == true
        let entry = await state.beginRequest(method: req.method, path: path, model: recipe.apiID, body: forwarded)
        let started = Date()

        var up = URLRequest(url: url)
        up.httpMethod = req.method
        if !forwarded.isEmpty { up.httpBody = forwarded }
        for (k, v) in req.headers where !Self.skipRequest.contains(k.lowercased()) {
            up.addValue(v, forHTTPHeaderField: k)
        }
        if let k = recipe.backendKey { up.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }

        var usage: Transform.Usage?
        var status = 0
        var firstToken: Date?
        do {
            if streaming {
                let (bytes, resp) = try await session.bytes(for: up)
                let http = resp as? HTTPURLResponse
                status = http?.statusCode ?? 502
                try await c.send(Self.head(status, Self.forwardHeaders(http)))
                var line = Data(), out = Data()
                for try await byte in bytes {
                    line.append(byte)
                    guard byte == 10 else { continue }
                    if firstToken == nil, Transform.isTokenChunk(line) { firstToken = Date() }
                    let (l, u) = Transform.sseLine(line, recipe: recipe, inject: s.settings.injectCost)
                    if let u { usage = u }
                    out.append(l)
                    // Flush at each event boundary (blank line) so tokens arrive immediately.
                    if line.count <= 2 || out.count > 16_384 {
                        try await c.send(out)
                        out.removeAll(keepingCapacity: true)
                    }
                    line.removeAll(keepingCapacity: true)
                }
                out.append(line)
                if !out.isEmpty { try await c.send(out) }
            } else {
                let (data, resp) = try await session.data(for: up)
                let http = resp as? HTTPURLResponse
                status = http?.statusCode ?? 502
                var payload = data
                if (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json") {
                    let (d, u) = Transform.process(data, recipe: recipe, inject: s.settings.injectCost)
                    usage = u
                    if let d { payload = d }
                }
                try await c.send(Self.head(status, Self.forwardHeaders(http) + [("Content-Length", "\(payload.count)")]) + payload)
            }
        } catch {
            if status == 0 {
                await sendError(c, 502, "Request to the Spark failed: \(error.localizedDescription)", type: "server_error")
                await state.networkTrouble()
            }
            await state.finishRequest(entry, status: status == 0 ? 502 : status, usage: usage, recipe: recipe,
                                      duration: Date().timeIntervalSince(started), error: error.localizedDescription)
            return
        }
        let ended = Date()
        await state.finishRequest(entry, status: status, usage: usage, recipe: recipe,
                                  duration: ended.timeIntervalSince(started),
                                  ttft: firstToken.map { $0.timeIntervalSince(started) },
                                  decodeTime: firstToken.map { ended.timeIntervalSince($0) }, error: nil)
    }

    private func modelObject(_ r: Recipe, _ s: GatewaySnapshot) -> [String: Any] {
        [
            "id": r.apiID, "object": "model", "created": 0, "owned_by": "spark",
            "name": r.name,
            "status": s.running.contains(r.id) ? "running" : "stopped",
            // OpenRouter's format (USD per token, as strings), which Hermes and other clients read.
            "pricing": ["prompt": String(r.priceIn / 1e6), "completion": String(r.priceOut / 1e6),
                        "input_cache_read": String((r.priceCache ?? r.priceIn) / 1e6)],
            "architecture": ["input_modalities": r.takesImages ? ["text", "image"] : ["text"], "output_modalities": ["text"]],
            "supported_parameters": r.hasReasoning ? ["reasoning", "include_reasoning", "tools"] : ["tools"],
        ]
    }

    private static func forwardHeaders(_ r: HTTPURLResponse?) -> [(String, String)] {
        (r?.allHeaderFields ?? [:]).compactMap { k, v -> (String, String)? in
            let key = "\(k)", lower = key.lowercased()
            return skipResponse.contains(lower) || lower.hasPrefix("access-control-") ? nil : (key, "\(v)")
        } + cors
    }

    static func head(_ status: Int, _ headers: [(String, String)]) -> Data {
        var s = "HTTP/1.1 \(status) \(status < 400 ? "OK" : "Error")\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "Connection: close\r\n\r\n"
        return Data(s.utf8)
    }

    private func sendJSON(_ c: HTTPConnection, _ status: Int, _ obj: Any) async {
        let d = Transform.serialize(obj) ?? Data()
        try? await c.send(Self.head(status, [("Content-Type", "application/json"), ("Content-Length", "\(d.count)")] + Self.cors) + d)
    }

    private func sendError(_ c: HTTPConnection, _ status: Int, _ message: String,
                           type: String = "invalid_request_error", code: String? = nil) async {
        await sendJSON(c, status, ["error": ["message": message, "type": type, "code": code.map { $0 as Any } ?? NSNull()]])
    }
}
