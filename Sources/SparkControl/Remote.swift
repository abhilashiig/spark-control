import Foundation
import Network
import CryptoKit

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

    /// Commands share one connection per host, kept open a minute after the last: no new login (key exchange,
    /// auth, session, auth.log line) on the Spark for every reading, and ~0.2 s instead of ~0.6 s per command.
    /// The path lives in ~/.ssh because macOS caps socket paths near 104 characters; %C is a hash of host and user.
    /// LogLevel=ERROR keeps ssh's notices (e.g. two first commands racing to open it) out of command output.
    private static let shared = [
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=~/.ssh/spark-control-%C",
        "-o", "ControlPersist=60",
        "-o", "LogLevel=ERROR",
    ]

    /// Closes the shared connection to `target`, e.g. after a network change left it pointing at a dead route.
    static func disconnect(_ target: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = shared + ["-O", "exit", target]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Wraps a command so your aliases and shell functions work, exactly as typed in a terminal.
    static func interactive(_ command: String) -> String { "bash -ic \(quote(command))" }
    /// Runs `command` in a subshell and then prints `__SPARK_EXIT__<code>`, so the line still appears when the command
    /// ends in `exec` (vLLM's do). Newlines, so a trailing `#` comment can't swallow the `)`.
    static func withExitLine(_ command: String) -> String { "(\n\(command)\n); echo __SPARK_EXIT__$?" }

    @discardableResult
    /// `input` is written to the remote command's stdin (e.g. a password for `sudo -S`), never to the command line.
    static func run(_ target: String, _ remote: String, timeout: TimeInterval = 60, input: String? = nil,
                    onLine: (@Sendable (String) -> Void)? = nil) async -> (code: Int32, output: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            // Commands are written for bash; the user's login shell may be zsh, where an unmatched glob is an error.
            p.arguments = options + shared + [target, "bash -c " + quote(remote)]
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

        /// Ollama lists every pulled model but serves only what it has loaded: an idle Ollama (say, up for a pull) serves nothing.
        func serves(_ model: String) -> Bool {
            if let loaded { return model.isEmpty ? !loaded.isEmpty : loaded.contains(Transform.norm(model)) }
            return model.isEmpty || listed.contains(Transform.norm(model))
        }
    }

    static func backend(_ base: String, key apiKey: String? = nil) async -> Backend? {
        async let listed = ids(base + "/v1/models", "data", "id", apiKey)
        async let loaded = ids(base + "/api/ps", "models", "name", apiKey)
        guard let listed = await listed else { return nil }
        return Backend(loaded: await loaded, listed: listed)
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

/// The SSH keys allowed to log in to the Spark as you (~/.ssh/authorized_keys), and the last login of each.
enum SSHKeys {
    struct Key: Identifiable, Hashable {
        var type: String
        var blob: String
        var comment: String
        /// Restrictions written before the key, like from="…" or command="…".
        var options: String
        var id: String { blob }
        /// As sshd logs it and `ssh-keygen -l` prints it.
        var fingerprint: String {
            guard let d = Data(base64Encoded: blob) else { return "?" }
            return "SHA256:" + Data(SHA256.hash(data: d)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        }
    }

    struct Login: Hashable {
        var date: Date
        var from: String
    }

    static let keysCommand = "cat ~/.ssh/authorized_keys 2>/dev/null || true"
    /// Per key fingerprint, the time and address of its last login in 90 days of sshd's log (nothing when the log
    /// isn't readable). Filtering by sshd's identifier uses the journal's index: ~1 s instead of ~20 s scanning every message.
    static let loginsScript = """
    journalctl -q -o short-unix --since -90days -t sshd -t sshd-session -g "Accepted publickey for $USER " 2>/dev/null | awk '{ last[$NF] = $1 " " $9 } END { for (k in last) print k, last[k] }'
    """

    static func keys(_ output: String) -> [Key] { output.split(separator: "\n").map(String.init).compactMap(key) }

    static func logins(_ output: String) -> [String: Login] {
        var logins: [String: Login] = [:]
        for l in output.split(separator: "\n") {
            let f = l.split(separator: " ").map(String.init)
            if f.count == 3, let t = Double(f[1]) { logins[f[0]] = Login(date: Date(timeIntervalSince1970: t), from: f[2]) }
        }
        return logins
    }

    static func key(_ line: String) -> Key? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
        let tokens = t.split(separator: " ").map(String.init)
        guard let i = tokens.indices.dropLast().first(where: { i in
            ["ssh-", "ecdsa-", "sk-"].contains { tokens[i].hasPrefix($0) } && Data(base64Encoded: tokens[i + 1]) != nil
        }) else { return nil }
        return Key(type: tokens[i], blob: tokens[i + 1], comment: tokens[(i + 2)...].joined(separator: " "),
                   options: tokens[..<i].joined(separator: " "))
    }

    /// Drops the line holding `blob` from authorized_keys, keeping the previous file as authorized_keys.spark-control.bak.
    static func removeScript(_ blob: String) -> String {
        """
        set -e; f="$HOME/.ssh/authorized_keys"; cp -p "$f" "$f.spark-control.bak"
        { grep -vF -- \(SSH.quote(blob)) "$f" || [ $? -eq 1 ]; } > "$f.tmp"
        chmod 600 "$f.tmp"; mv "$f.tmp" "$f"
        """
    }

    /// Fingerprints of this Mac's public keys in ~/.ssh: the ones Spark Control logs in with.
    static func localFingerprints() -> Set<String> {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "pub" }.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).flatMap(key)?.fingerprint
        })
    }
}

extension SSH {
    /// A login shell for the Terminal page. Its own connection rather than the shared one (a network change closes
    /// that), and unlike commands it may prompt, e.g. for a password when no key works.
    static func shellArguments(_ target: String) -> [String] {
        ["-t", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=15", "-o", "StrictHostKeyChecking=accept-new", target]
    }
}

/// The Spark's Wi-Fi through NetworkManager's nmcli: nearby networks, how this Mac reaches the Spark, and switching
/// with a way back to the previous network when the new one can't be joined.
enum WiFi {
    struct Network: Identifiable, Hashable {
        var ssid: String
        var signal: Int
        var security: String
        var inUse: Bool
        var saved = false
        var id: String { ssid }
        var secured: Bool { !security.isEmpty && security != "--" }
    }

    struct Status {
        /// The Wi-Fi interface; nil when the Spark has none (or no nmcli).
        var device: String?
        var networks: [Network] = []
        /// Interface this app's SSH session arrives on, and the one the default route (and so Tailscale) leaves by.
        var sshDevice = ""
        var uplink = ""
        var tailscale = false
        /// The Spark refused a fresh scan, so the list may be missing networks.
        var scanBlocked = false
        /// How the previous switch ended, read once.
        var last: String?
        var current: Network? { networks.first(where: \.inUse) }
        var viaTailscale: Bool { sshDevice.hasPrefix("tailscale") }
        /// This Mac reaches the Spark over its Wi-Fi: directly, or over Tailscale riding on it.
        var reachedOverWiFi: Bool { device != nil && (sshDevice == device || (viaTailscale && uplink == device)) }
    }

    static let log = "$HOME/.cache/spark-control-wifi.log"

    /// Asks for a fresh scan first: allowed over SSH only by polkit or sudo, so a Spark password may come on stdin.
    /// Without one the list is NetworkManager's last scan, which can be down to the network it's on (noscan:1).
    static let listScript = """
    IFS= read -r sp
    if { nmcli device wifi rescan || sudo -n nmcli device wifi rescan || { [ -n "$sp" ] && printf '%s\\n' "$sp" | sudo -S -p '' nmcli device wifi rescan; }; } >/dev/null 2>&1
    then sleep 5; else echo noscan:1; fi
    nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print "dev:"$1}'
    nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$NF ~ /wireless/ {sub(/:[^:]*$/,""); print "saved:"$0}'
    nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID device wifi list --rescan no 2>/dev/null | sed 's/^/wifi:/'
    # A link-local client address names its interface (fe80::…%wlan0), which ip route can't look up.
    set -- $SSH_CONNECTION
    case "$1" in *%*) echo "ssh:${1##*%}" ;; ?*) ip -o route get "$1" 2>/dev/null | sed -n 's/.* dev \\([^ ]*\\).*/ssh:\\1/p' ;; esac
    ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \\([^ ]*\\).*/up:\\1/p'
    tailscale status >/dev/null 2>&1 && echo ts:1
    f="\(log)"; [ -f "$f" ] && tail -n 1 "$f" | sed 's/^/last:/' && rm -f "$f"
    true
    """

    static func parse(_ out: String) -> Status {
        var s = Status(), saved = Set<String>(), found: [Network] = []
        for line in out.split(separator: "\n") {
            guard let i = line.firstIndex(of: ":") else { continue }
            let v = String(line[line.index(after: i)...])
            switch line[..<i] {
            case "dev": s.device = s.device ?? v
            case "saved": saved.insert(unescape(v))
            case "ssh": s.sshDevice = v
            case "up": s.uplink = v
            case "ts": s.tailscale = true
            case "noscan": s.scanBlocked = true
            case "last": s.last = v
            case "wifi":
                // IN-USE:SIGNAL:SECURITY:SSID. Only the SSID can hold an (escaped) colon, so it's everything after the third.
                let f = v.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                guard f.count == 4, case let ssid = unescape(f[3]), !ssid.isEmpty else { continue }
                let n = Network(ssid: ssid, signal: Int(f[1]) ?? 0, security: f[2], inUse: f[0] == "*")
                // One row per network, though each access point and band is listed apart.
                if let j = found.firstIndex(where: { $0.ssid == ssid }) {
                    found[j].signal = max(found[j].signal, n.signal)
                    found[j].inUse = found[j].inUse || n.inUse
                } else { found.append(n) }
            default: break
            }
        }
        s.networks = found.map { var n = $0; n.saved = saved.contains(n.ssid); return n }
            .sorted { ($0.inUse ? 1 : 0, $0.signal) > ($1.inUse ? 1 : 0, $1.signal) }
        return s
    }

    /// nmcli's terse output escapes `:` and `\` with a backslash.
    static func unescape(_ s: String) -> String { s.replacing(#/\\(.)/#) { String($0.1) } }

    /// Reads the network's password, then the Spark password for sudo, from stdin (either line may be empty). Starts the
    /// switch detached, so it finishes, or falls back to the previous network, after this SSH session drops with the
    /// old Wi-Fi. Prints __STARTED__, or __NEEDS_SUDO__ when nmcli isn't allowed and sudo needs a (right) password.
    static func switchScript(_ ssid: String) -> String {
        let job = """
        exec >"$3" 2>&1
        # connect only looks in the last scan, which goes stale without one (a scan over SSH needs this job's rights).
        nmcli device wifi list --rescan yes >/dev/null 2>&1
        wp=$(cat "$2" 2>/dev/null); rm -f "$2"
        old=$(nmcli -t -f UUID,TYPE connection show --active | awk -F: '$2 ~ /wireless/ {print $1; exit}')
        # ponytail: `device wifi connect` takes the password only as an argument, so it shows in ps while nmcli runs.
        r=$(if [ -n "$wp" ]; then nmcli -w 45 device wifi connect "$1" password "$wp"; else nmcli -w 45 device wifi connect "$1"; fi 2>&1) && { echo "Joined $1."; exit; }
        r=$(printf '%s' "$r" | tail -n 1)
        if [ -n "$old" ] && nmcli -w 45 connection up uuid "$old" >/dev/null 2>&1; then echo "Couldn't join $1, so the Spark went back to its previous Wi-Fi. $r"
        else echo "Couldn't join $1. $r"; fi
        """
        return """
        IFS= read -r wp; IFS= read -r sp
        log="\(log)"; mkdir -p "${log%/*}"; rm -f "$log"
        p=$(nmcli -t -f PERMISSION,VALUE general permissions 2>/dev/null)
        if printf '%s\\n' "$p" | grep -q 'network-control:yes' && printf '%s\\n' "$p" | grep -q 'settings.modify.system:yes'; then pre=
        elif sudo -n true 2>/dev/null || { [ -n "$sp" ] && printf '%s\\n' "$sp" | sudo -S -p '' -v 2>/dev/null; }; then pre="sudo -n"
        else echo __NEEDS_SUDO__; exit 3; fi
        pf=$(umask 077; mktemp); printf %s "$wp" > "$pf"
        $pre setsid -f bash -c \(SSH.quote(job)) _ \(SSH.quote(ssid)) "$pf" "$log" </dev/null >/dev/null 2>&1 && echo __STARTED__ || rm -f "$pf"
        """
    }
}

/// Caps the Spark's GPU clock with a systemd unit that runs `nvidia-smi -lgc` at boot, so the cap survives reboots.
/// Stock max is 3003 MHz; capping lowers heat and power for a smaller loss in speed.
enum GPUCap {
    static let mhz = 2200
    static let unitName = "gpu-clock-limit"

    static let unit = """
    [Unit]
    Description=Cap GPU clock at \(mhz) MHz
    After=nvidia-persistenced.service

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/usr/bin/nvidia-smi -lgc 0,\(mhz)
    ExecStop=/usr/bin/nvidia-smi -rgc

    [Install]
    WantedBy=multi-user.target
    """

    /// `bash -c script _ on|off`. Reads the Spark password for sudo from stdin (may be empty). Changes nothing, and
    /// needs no sudo, when the Spark is already as asked. Prints __OK__ (plus __CHANGED__ if it changed something),
    /// or __NEEDS_SUDO__ when sudo needs a (right) password.
    static let script = #"""
    IFS= read -r sp
    f=/etc/systemd/system/\#(unitName).service
    unit=\#(SSH.quote(unit))
    if [ "$1" = on ]; then
      [ "$(cat "$f" 2>/dev/null)" = "$unit" ] && systemctl is-enabled -q \#(unitName) && systemctl is-active -q \#(unitName) && { echo __OK__; exit; }
      [ -x /usr/bin/nvidia-smi ] || { echo "nvidia-smi isn't installed on the Spark."; exit 1; }
    else
      [ -e "$f" ] || { echo __OK__; exit; }
    fi
    sudo -n true 2>/dev/null || { [ -n "$sp" ] && printf '%s\n' "$sp" | sudo -S -p '' -v 2>/dev/null; } || { echo __NEEDS_SUDO__; exit 3; }
    if [ "$1" = on ]; then
      printf '%s\n' "$unit" | sudo -n tee "$f" >/dev/null && sudo -n systemctl daemon-reload \
        && sudo -n systemctl enable -q \#(unitName) && sudo -n systemctl restart \#(unitName)
    else
      sudo -n systemctl disable -q --now \#(unitName); sudo -n rm -f "$f" && sudo -n systemctl daemon-reload
    fi && echo __CHANGED__ && echo __OK__
    """#
}
