import Foundation

/// Live readings from the Spark: memory, CPU, GPU, temperatures and disk, from one read-only shell command.
/// The GB10's CPU and GPU share memory, so `nvidia-smi` reports no GPU memory total ([N/A]); memory comes from
/// /proc/meminfo and per-process GPU allocations from nvidia-smi's compute apps.
enum SparkMonitor {
    static let script = #"""
    awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/{printf "%s ", $2} END{print ""}' /proc/meminfo | sed 's/^/MEM|/'
    grep '^cpu' /proc/stat | sed 's/^/CPU|/'
    echo "LOAD|$(cut -d' ' -f1-3 /proc/loadavg)"
    echo "GPU|$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,power.draw,clocks.sm --format=csv,noheader,nounits 2>/dev/null | head -1)"
    nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null | while IFS=', ' read -r pid mem; do
      echo "PROC|$mem|$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-300)"
    done
    for z in /sys/class/thermal/thermal_zone*/temp; do echo "TZ|$(cat "$z" 2>/dev/null)"; done
    for h in /sys/class/hwmon/hwmon*; do [ "$(cat "$h/name" 2>/dev/null)" = nvme ] && echo "NVME|$(cat "$h/temp1_input")"; done
    echo "DISK|$(df -Pk "$HOME" | awk 'NR==2{print $2 * 1024, $3 * 1024, $4 * 1024}')"
    """#

    struct Process: Hashable {
        var name: String
        var bytes: Int64
    }

    struct Sample {
        var date = Date()
        var memTotal: Int64 = 0
        var memAvailable: Int64 = 0
        var swapTotal: Int64 = 0
        var swapFree: Int64 = 0
        /// /proc/stat jiffies per line: "cpu" for all cores, "cpu0"… per core.
        var cpuTimes: [String: [Int64]] = [:]
        var load: [Double] = []
        var gpuUtil: Double?
        var gpuTemp: Double?
        var power: Double?
        var clock: Double?
        var processes: [Process] = []
        /// Thermal zones in °C, in the kernel's order (the GB10's are all named "acpitz").
        var zones: [Double] = []
        var nvmeTemp: Double?
        var diskTotal: Int64 = 0
        var diskUsed: Int64 = 0
        var diskFree: Int64 = 0

        var memUsed: Int64 { memTotal - memAvailable }
        var coreCount: Int { cpuTimes.keys.filter { $0 != "cpu" }.count }
    }

    static func parse(_ output: String, at date: Date = Date()) -> Sample {
        var s = Sample(date: date)
        for line in output.split(separator: "\n") {
            let f = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2 else { continue }
            let nums = f[1].split(separator: " ")
            switch f[0] {
            case "MEM":
                let kb = nums.compactMap { Int64($0) }
                if kb.count == 4 { (s.memTotal, s.memAvailable, s.swapTotal, s.swapFree) = (kb[0] * 1024, kb[1] * 1024, kb[2] * 1024, kb[3] * 1024) }
            case "CPU":
                if let name = nums.first { s.cpuTimes[String(name)] = nums.dropFirst().compactMap { Int64($0) } }
            case "LOAD":
                s.load = nums.compactMap { Double($0) }
            case "GPU":
                let g = f[1].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
                if g.count == 4 { (s.gpuUtil, s.gpuTemp, s.power, s.clock) = (g[0], g[1], g[2], g[3]) }
            case "PROC" where f.count == 3:
                if let mib = Int64(f[1].trimmingCharacters(in: .whitespaces)) {
                    s.processes.append(Process(name: processName(f[2]), bytes: mib * 1_048_576))
                }
            case "TZ":
                if let m = Double(f[1]) { s.zones.append(m / 1000) }
            case "NVME":
                s.nvmeTemp = Double(f[1]).map { $0 / 1000 }
            case "DISK":
                let b = nums.compactMap { Int64($0) }
                if b.count == 3 { (s.diskTotal, s.diskUsed, s.diskFree) = (b[0], b[1], b[2]) }
            default: break
            }
        }
        // Several processes of one engine (vLLM's API server and engine core) read as one.
        s.processes = Dictionary(grouping: s.processes, by: \.name)
            .map { Process(name: $0.key, bytes: $0.value.reduce(0) { $0 + $1.bytes }) }
            .sorted { $0.bytes > $1.bytes }
        return s
    }

    /// A readable name for a process using the GPU, from its command line.
    static func processName(_ args: String) -> String {
        let a = args.lowercased()
        if a.contains("comfyui") { return "ComfyUI" }
        if a.contains("tensorfold") { return "TensorFold" }
        if a.contains("vllm") { return "vLLM" }
        if a.contains("sglang") { return "SGLang" }
        if a.contains("ollama") { return "Ollama" }
        if a.contains("llama-server") || a.contains("llama.cpp") { return "llama.cpp" }
        let first = args.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Unknown" : (first as NSString).lastPathComponent
    }

    /// Busy share of CPU time between two samples, 0–100, for "cpu" (all cores) or "cpuN".
    static func cpuPercent(_ name: String, from a: Sample, to b: Sample) -> Double? {
        guard let x = a.cpuTimes[name], let y = b.cpuTimes[name], x.count >= 5, y.count >= 5 else { return nil }
        // idle + iowait count as not busy.
        let total = y.reduce(0, +) - x.reduce(0, +)
        let idle = (y[3] + y[4]) - (x[3] + x[4])
        guard total > 0 else { return nil }
        return Double(total - idle) / Double(total) * 100
    }

    /// Only what Spark Control knows lives on the Spark: model caches and engine installs.
    static let storageScript = #"""
    H="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"
    for p in "Hugging Face cache|$H" "ComfyUI|$HOME/.local/share/spark-control/comfyui" "TensorFold|$HOME/.local/share/spark-control/tensorfold"; do
      d=${p#*|}; [ -d "$d" ] && echo "DU|${p%%|*}|$(du -sb "$d" 2>/dev/null | cut -f1)"
    done
    docker system df --format '{{.Type}}|{{.Size}}' 2>/dev/null | sed -n 's/^Images|/DOCKER|/p'
    """#

    /// Name → bytes, plus Docker's own size text for its images.
    static func parseStorage(_ output: String) -> (folders: [(String, Int64)], docker: String?) {
        var folders: [(String, Int64)] = []
        var docker: String?
        for line in output.split(separator: "\n") {
            let f = line.split(separator: "|").map(String.init)
            if f.first == "DU", f.count == 3, let b = Int64(f[2]) { folders.append((f[1], b)) }
            if f.first == "DOCKER", f.count == 2 { docker = f[1].replacingOccurrences(of: #"(\d)([kMGT]?B)$"#, with: "$1 $2", options: .regularExpression) }
        }
        return (folders, docker)
    }

    // MARK: Shutdowns

    /// One boot of the Spark that has ended. `end` is nil when a forced shutdown predates the journal.
    struct Session: Identifiable, Equatable {
        let start: Date
        let end: Date?
        let forced: Bool
        var id: Date { start }
    }

    /// wtmp's boot and shutdown records (Ubuntu writes them anyway), plus the journal's per-boot times, which give
    /// a forced shutdown's last moment. Read-only.
    static let shutdownsScript = #"""
    for f in /var/log/wtmp.1 /var/log/wtmp; do [ -r "$f" ] && last -x -R --time-format iso -f "$f" reboot shutdown; done
    echo "JOURNAL|$(journalctl --list-boots -o json --no-pager 2>/dev/null)"
    """#

    /// Ended boots, newest first, and when the record begins. A boot with no shutdown record before the next boot
    /// was forced (power cut, panic). `last`'s own "crash" label is skipped: it isn't printed for every such boot.
    static func parseShutdowns(_ output: String) -> (sessions: [Session], since: Date?) {
        let iso = ISO8601DateFormatter()
        var events: [(Date, isBoot: Bool)] = []
        var journal: [(first: Date, last: Date)] = []
        for line in output.split(separator: "\n") {
            if line.hasPrefix("JOURNAL|") {
                let json = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(8).utf8))) as? [[String: Any]] ?? []
                journal = json.compactMap { b in
                    guard let f = b["first_entry"] as? Double, let l = b["last_entry"] as? Double else { return nil }
                    return (Date(timeIntervalSince1970: f / 1e6), Date(timeIntervalSince1970: l / 1e6))
                }
                continue
            }
            let fields = line.split(separator: " ")
            guard let kind = fields.first, kind == "reboot" || kind == "shutdown",
                  let date = fields.lazy.compactMap({ iso.date(from: String($0)) }).first else { continue }
            events.append((date, kind == "reboot"))
        }
        events.sort { $0.0 < $1.0 }
        var sessions: [Session] = []
        var boot: Date?
        for e in events {
            if e.isBoot {
                if let b = boot {  // a second boot with no shutdown in between
                    let end = journal.first { abs($0.first.timeIntervalSince(b)) < 120 }?.last
                    sessions.append(Session(start: b, end: end, forced: true))
                }
                boot = e.0
            } else if let b = boot {
                sessions.append(Session(start: b, end: e.0, forced: false))
                boot = nil
            }
        }
        return (sessions.reversed(), events.first?.0)
    }
}
