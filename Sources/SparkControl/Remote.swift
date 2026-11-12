import Foundation
import Network

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
    /// Atomically sets a new value and returns the old one.
    func exchange(_ new: T) -> T { lock.withLock { defer { v = new }; return v } }
}

/// Runs commands on the Spark with the system ssh client and your existing keys.
enum SSH {
    private static let options = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=6",
        "-o", "ServerAliveInterval=15",
        "-o", "StrictHostKeyChecking=accept-new",
    ]

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Wraps a command so your aliases and shell functions work, exactly as typed in a terminal.
    static func interactive(_ command: String) -> String { "bash -ic \(quote(command))" }

    @discardableResult
    /// `input` is written to the remote command's stdin (e.g. a password for `sudo -S`), never to the command line.
    static func run(_ target: String, _ remote: String, timeout: TimeInterval = 60, input: String? = nil,
                    onLine: (@Sendable (String) -> Void)? = nil) async -> (code: Int32, output: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = options + [target, remote]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let stdin = input.map { _ in Pipe() }
            p.standardInput = stdin ?? FileHandle.nullDevice
            let lines = LineBuffer(onLine)
            pipe.fileHandleForReading.readabilityHandler = { h in lines.feed(h.availableData) }
            p.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                lines.feed(pipe.fileHandleForReading.readDataToEndOfFile())
                lines.flush()
                cont.resume(returning: (p.terminationStatus, lines.all))
            }
            do { try p.run() } catch {
                cont.resume(returning: (-1, error.localizedDescription))
                return
            }
            if let stdin, let input {
                stdin.fileHandleForWriting.write(Data((input + "\n").utf8))
                try? stdin.fileHandleForWriting.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
    }
}

extension SSH {
    /// Forwards `local` on this Mac's loopback to `remote` on the Spark's loopback until the process ends.
    static func forward(_ target: String, local: Int, remote: Int) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = options + ["-N", "-o", "ExitOnForwardFailure=yes", "-L", "127.0.0.1:\(local):127.0.0.1:\(remote)", target]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return (try? p.run()) == nil ? nil : p
    }

    /// Adds this Mac's public key to the Spark's authorized_keys using the password once.
    /// ssh runs this app as its askpass helper; the password reaches it over stdin and is never stored.
    static func installKey(_ target: String, password: String) async -> (ok: Bool, message: String) {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        var pubURL = ["id_ed25519", "id_ecdsa", "id_rsa"].map { ssh.appending(path: "\($0).pub") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        if pubURL == nil {
            let gen = Process()
            gen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            gen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", ssh.appending(path: "id_ed25519").path]
            try? gen.run()
            gen.waitUntilExit()
            pubURL = ssh.appending(path: "id_ed25519.pub")
        }
        guard let pubURL, let key = try? String(contentsOf: pubURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return (false, "Couldn't read or create an SSH key in ~/.ssh.") }
        let k = quote(key)
        let remote = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qxF \(k) ~/.ssh/authorized_keys || echo \(k) >> ~/.ssh/authorized_keys)"

        let result: (Int32, String) = await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "ConnectTimeout=8",
                "-o", "StrictHostKeyChecking=accept-new",
                target, remote,
            ]
            var env = ProcessInfo.processInfo.environment
            env["SSH_ASKPASS"] = Bundle.main.executablePath
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["SPARK_CONTROL_ASKPASS"] = "1"
            p.environment = env
            let input = Pipe(), output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = output
            p.terminationHandler = { p in
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                cont.resume(returning: (p.terminationStatus, text))
            }
            do { try p.run() } catch {
                cont.resume(returning: (-1, error.localizedDescription))
                return
            }
            // ssh doesn't read its own stdin until after login, so the askpass child gets this line.
            input.fileHandleForWriting.write(Data((password + "\n").utf8))
            try? input.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
        }
        guard result.0 == 0 else {
            let text = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, text.contains("Permission denied") ? "Wrong password." : (text.isEmpty ? "SSH failed." : text))
        }
        let check = await run(target, "true", timeout: 10)
        return check.code == 0 ? (true, "Key login is set up.") : (false, "Key was added, but key login still fails: \(check.output)")
    }
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private(set) var all = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(_ onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func feed(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.withLock {
            pending.append(d)
            while let i = pending.firstIndex(of: 10) {
                emit(String(decoding: pending[pending.startIndex..<i], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...i)
            }
        }
    }

    func flush() {
        lock.withLock {
            if !pending.isEmpty { emit(String(decoding: pending, as: UTF8.self)) }
            pending.removeAll()
        }
    }

    private func emit(_ raw: String) {
        let line = raw.replacing(#/\x1B\[[0-9;?]*[A-Za-z]/#, with: "").trimmingCharacters(in: .init(charactersIn: "\r"))
        // Harmless noise from running an interactive bash without a terminal.
        if line.contains("cannot set terminal process group") || line.contains("no job control in this shell") { return }
        all += line + "\n"
        onLine?(line)
    }
}

enum Probe {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.timeoutIntervalForResource = 5
        return URLSession(configuration: c)
    }()

    /// What is serving on the model port. `loaded` is Ollama's /api/ps (nil for other servers).
    struct Backend {
        var loaded: [String]?
        var listed: [String]

        func serves(_ model: String) -> Bool {
            if model.isEmpty { return true }
            let m = Transform.norm(model)
            if let loaded, !loaded.isEmpty { return loaded.contains(m) }
            return listed.contains(m)
        }
    }

    static func backend(_ base: String, key apiKey: String? = nil) async -> Backend? {
        guard let listed = await ids(base + "/v1/models", "data", "id", apiKey) else { return nil }
        return Backend(loaded: await ids(base + "/api/ps", "models", "name", apiKey), listed: listed)
    }

    private static func ids(_ url: String, _ list: String, _ key: String, _ apiKey: String?) async -> [String]? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = obj[list] as? [[String: Any]] else { return nil }
        return items.compactMap { ($0[key] as? String).map(Transform.norm) }
    }

    /// TCP reachability. Returns the resolved IP, or nil if unreachable.
    static func tcp(_ host: String, _ port: Int, timeout: Double = 2) async -> String? {
        guard !host.isEmpty, let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let done = Box(false)
            let finish: @Sendable (String?) -> Void = { ip in
                if !done.exchange(true) { cont.resume(returning: ip) }
                conn.cancel()
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let h, _)? = conn.currentPath?.remoteEndpoint {
                        finish("\(h)".components(separatedBy: "%")[0])
                    } else {
                        finish(host)
                    }
                case .failed, .waiting: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    static func isTailscale(_ ip: String) -> Bool {
        if ip.lowercased().hasPrefix("fd7a:115c:a1e0") { return true }
        let p = ip.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 100 && (64...127).contains(p[1])
    }
}
