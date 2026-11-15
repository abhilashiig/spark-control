import Foundation

/// The Hugging Face cache and CLI on the Spark: what is downloaded or downloading, whether the Spark is signed in,
/// and the scripts that install `hf`, sign in and delete. Repos come from the cache folders, so downloads made by
/// TensorFold, vLLM's container or by hand all show.
enum HF {
    /// Where `hf auth login` keeps the token; vLLM's download container mounts the same file.
    static let tokenPath = "${HF_TOKEN_PATH:-${HF_HOME:-$HOME/.cache/huggingface}/token}"

    struct Repo: Identifiable, Hashable {
        enum State: String { case idle = "", downloading = "download", inUse = "serve" }
        /// model, dataset or space.
        var type: String
        var repo: String
        /// On disk, following hf 2.x's links into the shared blob store.
        var bytes: Int64
        /// Unfinished files (`*.incomplete`), included in `bytes`.
        var partial: Int64
        var state: State
        /// The command line of the process downloading or serving it.
        var user: String
        var id: String { cacheName }
        var cacheName: String { "\(type)s--" + repo.replacingOccurrences(of: "/", with: "--") }
    }

    struct Status: Equatable {
        /// nil when the `hf` CLI isn't installed.
        var version: String?
        var signedIn = false
        var repos: [Repo] = []
    }

    /// A repo is in use when a process names it (`tensorfold serve ORG/NAME`, `vllm serve ORG/NAME@REV`) or its
    /// cache path; downloading when that process downloads or pulls, or an unfinished file changed in the last 2 min.
    /// Spark Control's own scripts (`bash -c …`) are skipped: their text names catalog repos.
    static let statusScript = #"""
    H="\#(TensorFold.hubDir)"; HF=$(command -v hf || echo "$HOME/.local/bin/hf"); T="\#(tokenPath)"
    echo "HF|$([ -x "$HF" ] && NO_COLOR=1 "$HF" version 2>/dev/null | awk '/version:/{print $NF; exit}')|$([ -s "$T" ] && echo 1)"
    P=$(ps -eo args= | grep -vE '^(ba)?sh -i?c ' | cut -c1-400)
    for d in "$H"/models--* "$H"/datasets--* "$H"/spaces--*; do
      [ -d "$d" ] && [ ! -L "$d" ] || continue  # a link is a repo's new name pointing at its old folder (TensorFold.adoptScript)
      n=${d##*/}; id=${n#*--}; id=${id//--//}
      u=$(printf '%s\n' "$P" | awk -v id="$id" -v n="$n" '{for (i = 1; i <= NF; i++) if ($i == id || index($i, id "@") == 1 || index($i "/", "/" n "/")) { print; exit }}')
      st=; [ -n "$u" ] && st=serve
      case " $u " in *" download "*|*" pull "*|*snapshot_download*) st=download;; esac
      [ -n "$(find "$d" -name '*.incomplete' -mmin -2 2>/dev/null | head -1)" ] && st=download
      echo "REPO|${n%%s--*}|$id|$(du -sbL "$d" 2>/dev/null | cut -f1)|$(find "$d" -name '*.incomplete' -printf '%s\n' 2>/dev/null | awk '{s += $1} END {print s + 0}')|$st|$u"
    done
    """#

    static func parseStatus(_ output: String) -> Status {
        var s = Status()
        for line in output.split(separator: "\n") {
            let f = line.split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            if f.first == "HF", f.count >= 3 { (s.version, s.signedIn) = (f[1].isEmpty ? nil : f[1], f[2] == "1") }
            if f.first == "REPO", f.count == 7 {
                s.repos.append(Repo(type: f[1], repo: f[2], bytes: Int64(f[3]) ?? 0, partial: Int64(f[4]) ?? 0,
                                    state: Repo.State(rawValue: f[5]) ?? .idle, user: f[6]))
            }
        }
        s.repos.sort { $0.bytes > $1.bytes }
        return s
    }

    /// `hfrm CACHE-FOLDER` deletes a repo from the cache at $H. hf 2.x keeps blobs in a store shared between repos
    /// (hub/blobs), which only `hf cache rm` knows how to release; plain rm frees nothing there. hf skips a repo whose
    /// ref ends in a newline (earlier Spark Control versions wrote those), so refs are tidied first. rm -rf takes what's left.
    static let removeFunction = #"""
    hfrm() {
      for f in "$H/$1"/refs/*; do [ -f "$f" ] && printf %s "$(cat "$f")" > "$f"; done
      local HF id=${1#*--}; HF=$(command -v hf || echo "$HOME/.local/bin/hf")
      [ -x "$HF" ] && "$HF" cache rm "${1%%s--*}/${id//--//}" -y >/dev/null 2>&1
      rm -rf "${H:?}/$1"
    }

    """#

    /// Deletes a repo and clears the download marks of catalog models that use it (`records`), so their pages offer
    /// Download again instead of claiming the files are there.
    static func deleteScript(_ r: Repo, records: [String]) -> String {
        "H=\"\(TensorFold.hubDir)\"; D=\"\(TensorFold.dataDir)\"\n" + removeFunction
            + "hfrm \(SSH.quote(r.cacheName)) && echo \"› Deleted \(r.repo)\"\n"
            + records.map { "rm -f \"$D/\($0)\".ok \"$D/\($0)\".keep\n" }.joined()
    }

    /// Removes a repo's leftover partial files: an interrupted download leaves `*.incomplete` behind even after a
    /// later one finishes, and hf never cleans them up. Files touched in the last 2 minutes are left alone. Unlike
    /// `hf cache prune`, it doesn't touch revisions no ref points to (vLLM serves pinned ones).
    static func cleanScript(_ r: Repo) -> String {
        "H=\"\(TensorFold.hubDir)\"; find \"$H\"/\(SSH.quote(r.cacheName)) -name '*.incomplete' -mmin +2 -delete && echo \"› Removed unfinished files of \(r.repo)\""
    }

    /// Hugging Face's own installer: its own Python environment, linked into ~/.local/bin. No sudo.
    static let installScript = """
    set -euo pipefail
    command -v curl >/dev/null || { echo "✗ curl is missing."; exit 1; }
    curl -LsSf https://hf.co/cli/install.sh | bash
    """

    /// Reads the token from stdin and saves it where `hf auth login` would, owner-only.
    static let loginScript = """
    T="\(tokenPath)"; mkdir -p "$(dirname "$T")"; umask 077; IFS= read -r t; printf %s "$t" > "$T" && echo "› Signed in"
    """

    static let logoutScript = "rm -f \"\(tokenPath)\" && echo '› Signed out'"

    /// Asks Hugging Face who the Spark's token belongs to. The header goes through stdin (printf is a builtin), so the
    /// token never shows in the process list.
    static let whoamiScript = """
    T="\(tokenPath)"; [ -s "$T" ] || exit 0
    printf 'Authorization: Bearer %s' "$(cat "$T")" | curl -fsS -m 15 -H @- https://huggingface.co/api/whoami-v2
    """

    /// The account name in a whoami-v2 answer.
    static func accountName(_ json: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["name"] as? String
    }

    /// Checks a token with Hugging Face before it goes to the Spark. Returns the account name, or nil if it's refused.
    static func whoami(token: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://huggingface.co/api/whoami-v2")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return accountName(String(decoding: data, as: UTF8.self))
    }
}

/// Ollama on the Spark: install, search ollama.com's library with each tag's download size, and pull. ollama.com has
/// no search API, so results are read from its pages.
enum Ollama {
    struct Tag: Hashable {
        /// What `ollama pull` takes, e.g. qwen3.8:27b-q4_K_M.
        var name: String
        var bytes: Int64
    }

    struct Result: Identifiable, Hashable {
        var id: String
        var summary: String
        var tags: [Tag]
    }

    struct Pull: Identifiable, Hashable {
        enum State: String { case running, done, failed }
        var id: String
        var state: State
        var last: String
        var percent: Double? {
            guard let m = last.firstMatch(of: try! Regex(#"(\d+)%"#)), let s = m.output[1].substring else { return nil }
            return Double(s).map { $0 / 100 }
        }
    }

    struct Status: Equatable {
        /// nil when Ollama isn't installed.
        var version: String?
        var pulls: [Pull] = []
    }

    // MARK: Search

    /// Local models only (cloud-only ones can't be pulled), most popular first (the default order).
    static func searchURL(_ query: String) -> URL {
        var c = URLComponents(string: "https://ollama.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "c", value: "local")]
        return c.url!
    }

    /// Each result is `<a href="/library/NAME" …><h2 …>` with a `line-clamp-2` paragraph for its summary.
    static func parseSearch(_ html: String) -> [(name: String, summary: String)] {
        html.components(separatedBy: "<a href=\"/library/").dropFirst().compactMap { part in
            guard let name = part.split(separator: "\"", maxSplits: 1).first.map(String.init),
                  !name.contains(":"), !name.contains("/"), part.prefix(2000).contains("<h2") else { return nil }
            let summary = part.firstMatch(of: try! Regex(#"<p class="mt-1 line-clamp-2[^"]*">([^<]*)</p>"#))?.output[1].substring.map(String.init) ?? ""
            return (name, entities(summary).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Each tag has a mobile row, `<a href="/library/NAME:TAG" class="md:hidden …">`, whose text reads
    /// `DIGEST • 18GB • 256K context window`. Cloud tags have no size and are skipped.
    static func parseTags(_ html: String) -> [Tag] {
        var seen = Set<String>()
        return html.components(separatedBy: "href=\"/library/").compactMap { part in
            guard let q = part.firstIndex(of: "\""), part[q...].hasPrefix("\" class=\"md:hidden") else { return nil }
            let name = String(part[..<q])
            guard name.contains(":"), !name.hasSuffix("cloud"), seen.insert(name).inserted,
                  let m = part.firstMatch(of: try! Regex(#"• ([0-9.]+)\s*([KMGT]?B) •"#)),
                  let n = m.output[1].substring.flatMap({ Double($0) }), let u = m.output[2].substring else { return nil }
            let unit: Double = ["KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12][String(u)] ?? 1
            return Tag(name: name, bytes: Int64(n * unit))
        }
    }

    private static func entities(_ s: String) -> String {
        [("&amp;", "&"), ("&#39;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">")]
            .reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    private static func page(_ url: URL) async -> String? {
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The first page of results (20 models) with every tag's size, fetched side by side. nil if ollama.com can't be read.
    static func search(_ query: String) async -> [Result]? {
        guard let html = await page(searchURL(query)) else { return nil }
        let found = parseSearch(html)
        let tags = await withTaskGroup(of: (String, [Tag]).self) { group in
            for f in found {
                group.addTask {
                    let url = URL(string: "https://ollama.com/library/\(f.name)/tags")!
                    return (f.name, await page(url).map(parseTags) ?? [])
                }
            }
            return await group.reduce(into: [String: [Tag]]()) { $0[$1.0] = $1.1 }
        }
        return found.map { Result(id: $0.name, summary: $0.summary, tags: tags[$0.name] ?? []) }
    }

    /// ponytail: weights only, plus the system reserve; the KV cache for a long context needs more on top.
    static func fits(_ bytes: Int64, memory: Int64, reserve: Int64) -> Bool { bytes + reserve <= memory }

    // MARK: Pulls

    /// The record name for a pull in TensorFold's data folder: "/" can't be in a file name.
    static func key(_ name: String) -> String { "ollama-" + name.replacingOccurrences(of: "/", with: "~") }

    /// Pulls detached from SSH, like every other download. `ollama pull` needs the server: if it isn't up, it's started
    /// with `sudo -n` (a stock install keeps it running; a setup that starts it on demand allows that without a password)
    /// and stopped again afterwards unless a model was loaded meanwhile. Run in an interactive shell, so an OLLAMA_HOST
    /// set in ~/.bashrc points the client at the right port.
    static func pullScript(_ name: String) -> String {
        let k = key(name)
        let job = """
        up() { ollama list >/dev/null 2>&1; }
        s=; if ! up; then sudo -n systemctl start ollama 2>/dev/null && s=1; for i in $(seq 30); do up && break; sleep 1; done; fi
        if ! up; then [ -n "$s" ] && sudo -n systemctl stop ollama; echo "✗ Ollama isn't running on the Spark and couldn't be started without a password. Start it (sudo systemctl start ollama), then retry."; exit 1; fi
        ollama pull \(SSH.quote(name)); r=$?
        [ -n "$s" ] && [ -z "$(ollama ps 2>/dev/null | tail -n +2)" ] && sudo -n systemctl stop ollama
        [ $r = 0 ] && touch "$D/\(k).ok"; exit $r
        """
        return """
        export D="\(TensorFold.dataDir)"; mkdir -p "$D"; rm -f "$D/\(k).ok"
        nohup bash -c \(SSH.quote(job)) > "$D/\(k).log" 2>&1 < /dev/null &
        echo $! > "$D/\(k).pid"
        """
    }

    /// The installed version, and each pull's state and last progress line (ANSI codes and \r redraws removed).
    /// A finished pull's records are removed once reported: the model then shows among the installed ones.
    static let statusScript = #"""
    D="\#(TensorFold.dataDir)"
    command -v ollama >/dev/null && echo "OLLAMA|$(ollama -v 2>&1 | grep -o '[0-9]*\.[0-9]*\.[0-9]*' | tail -1)"
    for l in "$D"/ollama-*.log; do
      [ -f "$l" ] || continue; k=${l%.log}; k=${k##*/}
      if [ -f "$D/$k.pid" ] && kill -0 "$(cat "$D/$k.pid")" 2>/dev/null; then st=running
      elif [ -f "$D/$k.ok" ]; then st=done; else st=failed; fi
      echo "PULL|${k#ollama-}|$st|$(tail -c 3000 "$l" | tr '\r' '\n' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | grep -v '^[[:space:]]*$' | tail -1)"
      [ $st = done ] && rm -f "$D/$k.log" "$D/$k.pid" "$D/$k.ok"
    done
    """#

    static func parseStatus(_ output: String) -> Status {
        var s = Status()
        for line in output.split(separator: "\n") {
            let f = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            if f.first == "OLLAMA", f.count == 2 { s.version = f[1].isEmpty ? "?" : f[1] }
            if f.first == "PULL", f.count == 4, let st = Pull.State(rawValue: f[2]) {
                s.pulls.append(Pull(id: f[1].replacingOccurrences(of: "~", with: "/"), state: st,
                                    last: f[3].trimmingCharacters(in: .whitespaces)))
            }
        }
        return s
    }

    static func dismissScript(_ name: String) -> String {
        let k = key(name)
        return "D=\"\(TensorFold.dataDir)\"; rm -f \"$D/\(k).log\" \"$D/\(k).pid\" \"$D/\(k).ok\""
    }

    /// ollama.com's installer, run as root: it adds a system service, which over SSH can't ask for a password midway.
    static let installCommand = "sh -c " + SSH.quote("curl -fsSL https://ollama.com/install.sh | sh")
}
