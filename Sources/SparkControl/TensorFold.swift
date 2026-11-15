import Foundation

/// TensorFold on the Spark: the pinned release, the models it has tested on one GB10, and the shell
/// scripts that install it, download models and serve them. Everything lives in the user's home on the
/// Spark; nothing needs sudo.
enum TensorFold {
    /// The release the catalog below was taken from. Bump both together.
    static let version = "1.2.6"
    static let platform = "linux-aarch64"
    static func archive(_ v: String = version) -> String { "tensorfold-\(v)-\(platform)" }
    static func releaseURL(_ v: String = version) -> String { "https://github.com/ashhart/TensorFold/releases/download/v\(v)" }
    /// From packaging/runtime-trust.json. It signs each release's .sha256 file, newer releases included, so
    /// an update this key didn't sign fails before anything on the Spark changes.
    static let publicKey = """
    -----BEGIN PUBLIC KEY-----
    MCowBQYDK2VwAyEA80FFo6a9/NXHNX9zBV3/2tM9AbC//mShbseG74mkkGw=
    -----END PUBLIC KEY-----
    """

    /// Shell expressions, used inside double quotes so $HOME expands on the Spark.
    static let engineDir = "$HOME/.local/share/spark-control/tensorfold"
    static let dataDir = "$HOME/.local/share/spark-control/tensorfold-data"
    static let managedBinary = engineDir + "/current/bin/tensorfold-native"
    static let hubDir = "${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"

    // MARK: Catalog

    struct Repo: Hashable {
        var id: String
        var revision: String?
        /// Folders of the repo the model doesn't use (other quantizations), left out of the download and its size.
        /// `tensorfold pull` fetches every file, so such a repo downloads with `hf download --exclude`.
        var skip: [String] = []
        var spec: String { revision.map { "\(id)@\($0)" } ?? id }
        /// The Hugging Face cache folder name.
        var cacheName: String { "models--" + id.replacingOccurrences(of: "/", with: "--") }
        /// The snapshot folder name: the pinned revision, or what refs/main names (resolved on the Spark).
        var snapshot: String { revision ?? "" }
    }

    struct Model: Identifiable, Hashable {
        /// Also the served model name.
        var id: String
        var name: String
        var repo: Repo
        /// TensorFold's recipe names a drafter, so it's always downloaded and passed with --drafter.
        var drafter: Repo?
        var flags: [String] = []
        var note: String
        /// The checkpoint's trained window (max_position_embeddings in its config.json).
        var window = 262_144
        /// Window new models start with, when the full one is too big for one GB10.
        var startWindow: Int?
        /// TensorFold's --rope-yarn: Qwen3.5 and 3.6 on CUDA only.
        var yarn = false
        /// The checkpoint carries an MTP head to draft with.
        var mtp = false
        /// TensorFold reads the format but has no record of it on one GB10.
        var untested = false

        /// What speculative drafts come from, when anything beyond copies does.
        var drafts: String? {
            if let d = drafter, d.id != repo.id { return "DFlash drafter" }
            return mtp || drafter != nil ? "MTP" : nil
        }

        /// Repos to download, in order. A drafter that is the model's own checkpoint needs nothing extra.
        var downloads: [Repo] { [repo] + (drafter.map { $0.id == repo.id ? [] : [$0] } ?? []) }
    }

    /// The single-GB10 rows of the README's "Pick a model" table at v1.2.6 that `tensorfold pull` serves
    /// as downloaded. Two-Spark, converted, speech and OCR rows are left out.
    static let catalog: [Model] = [
        Model(id: "qwen3.8-27b", name: "Qwen3.8 27B",
              repo: Repo(id: "TensorFold/Qwen3.8-27B-MLX-4bit"),
              drafter: Repo(id: "z-lab/Qwen3.8-27B-DFlash2"),
              flags: ["--vision"],
              note: "MLX 4-bit with images and the DFlash2 drafter."),
        // Abliterated, with the tensors of TensorFold/Vontra's MLX 4-bit (all 2,180 names match), so it serves the
        // same way. Measured on an idle GB10 with DFlash2: the uncensored NVFP4 build drafts as well as stock
        // (154 vs 161 rounds for 512 tokens) at 70 tok/s code, 29 prose; stock MLX 4-bit 103 and 42.
        Model(id: "qwen3.8-27b-uncensored", name: "Qwen3.8 27B Uncensored",
              repo: Repo(id: "orcarouter/Qwen3.8-27B-Uncensored-MLX", revision: "a92a9d3492320048ca96924262d158f75ab5ce8b",
                         skip: ["2-bit", "4-bit", "6-bit", "8-bit", "mtp"]),
              drafter: Repo(id: "z-lab/Qwen3.8-27B-DFlash2"),
              flags: ["--vision"],
              note: "orcarouter's abliterated (refusals removed) MLX 4-bit, with images and the DFlash2 drafter. Downloads only the 4-bit weights (16 GB), with the Spark's hf tool."),
        Model(id: "qwen3.6-35b-a3b", name: "Qwen3.6 35B-A3B",
              repo: Repo(id: "TensorFold/Qwen3.6-35B-A3B-MLX-4bit-MTP", revision: "81169a9bc511a27c1b4eedb77a2cd98ced431847"),
              // On CUDA the MTP layer drafts only when --drafter names the checkpoint itself; without it the
              // server reports "drafts: copies only" (checked on a GB10 with 1.2.6).
              drafter: Repo(id: "TensorFold/Qwen3.6-35B-A3B-MLX-4bit-MTP"),
              note: "MLX 4-bit; MTP drafts from the checkpoint itself.", yarn: true, mtp: true),
        Model(id: "nemotron-3.5-lightning", name: "Nemotron 3.5 Lightning 30B-A3B",
              repo: Repo(id: "TensorFold/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-MLX-4bit"),
              note: "MLX 4-bit; includes its MTP head.", mtp: true),
        Model(id: "nemotron-3.5-lightning-nvfp4", name: "Nemotron 3.5 Lightning NVFP4",
              repo: Repo(id: "nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4"),
              note: "NVIDIA NVFP4.", window: 1_048_576, mtp: true),
        Model(id: "nemotron-3.5-super-vl", name: "Nemotron 3.5 Super VL 120B-A12B",
              repo: Repo(id: "nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4", revision: "82d93699acd3be9e4617c53360fe5b3f5dbeb1b3"),
              flags: ["--vision"],
              note: "NVFP4 with images. 73 GiB of weights: little room for anything else.",
              window: 1_048_576, startWindow: 262_144, mtp: true),
        Model(id: "qwen3.8-flash-next", name: "Qwen3.8 Flash Next",
              repo: Repo(id: "TensorFold/Qwen3.8-Flash-Next-MLX-4bit-MTP"),
              note: "MLX 4-bit with MTP. 73 GiB plus mapped tables: little room for anything else.", mtp: true),
        Model(id: "gemma-4-31b", name: "Gemma 4 31B",
              repo: Repo(id: "mlx-community/gemma-4-31B-it-4bit", revision: "696d436c404745a59f30e4939a658162b0a9e57f"),
              drafter: Repo(id: "z-lab/gemma-4-31B-it-DFlash", revision: "eabd648301ce28583cc14757912e5e0f84e152e1"),
              flags: ["--vision"],
              note: "MLX 4-bit with images and the DFlash drafter."),
        Model(id: "lfm2.5-24b-a2b", name: "LFM2.5 24B-A2B",
              repo: Repo(id: "LiquidAI/LFM2.5-24B-A2B-MLX-4bit", revision: "667408d494bde191c2cb9dd4f4549827816b9275"),
              note: "MLX 4-bit. LFM Open License.", window: 131_072),
        Model(id: "qwen3.5-2b", name: "Qwen3.5 2B",
              repo: Repo(id: "mlx-community/Qwen3.5-2B-MLX-4bit", revision: "93760be4f1f69842a46bc13dbdc0f19e291392a3"),
              note: "Small MLX 4-bit model, text only."),
        // Not in TensorFold's single-GB10 table: it documents this checkpoint at --tp 2 on two GB10s and calls
        // the NVFP4 path experimental. Pinned to the revision blazux/qwen3.8-Flash-DGX serves with vLLM.
        Model(id: "qwen3.8-flash-next-nvfp4", name: "Qwen3.8 Flash Next NVFP4",
              repo: Repo(id: "nvidia/Qwen3.8-Flash-Next-NVFP4", revision: "fc694b54fb0174e0913e6adf86691ef85a4ead47"),
              note: "NVIDIA NVFP4 with MTP, the checkpoint blazux's vLLM recipe serves. About 73 GiB on the GPU; its n-gram table stays mapped from disk.",
              mtp: true, untested: true),
        Model(id: "kolibri-1", name: "Kolibri-1 (research)",
              repo: Repo(id: "Aleph-Alpha/Kolibri-1", revision: "e52eb4627d11516b0c01de49210ab5a4e4061444"),
              note: "Block FP8, text only. A research model."),
    ]

    static func model(_ id: String?) -> Model? { catalog.first { $0.id == id } }

    // MARK: Status

    enum Engine: Equatable {
        case none
        /// Installed by Spark Control.
        case managed(version: String)
        /// On the PATH, installed by the user. Spark Control uses it but never changes it.
        case user(path: String, version: String)

        var binary: String? {
            switch self {
            case .none: nil
            case .managed: TensorFold.managedBinary
            case .user(let path, _): path
            }
        }
    }

    enum Download: Equatable {
        case none, running, done, failed
    }

    struct ModelStatus: Equatable {
        var download = Download.none
        /// Bytes on the Spark for the model and its drafter, including files still downloading. Counted
        /// whoever downloaded them, so models another setup put there show too.
        var bytes: Int64 = 0
        /// Last line of the download log.
        var message = ""
    }

    struct Status: Equatable {
        var engine = Engine.none
        /// The managed version an update replaced, kept so it can be switched back to.
        var previous: String?
        var freeBytes: Int64?
        var models: [String: ModelStatus] = [:]
        /// vLLM's image: "ready", "none" (Docker but no image), "nodocker", or nil before the first check.
        var vllm: String?
        /// ComfyUI's installed release (nil when it isn't installed) and whether its server runs.
        var comfyVersion: String?
        var comfyRunning = false
        /// The managed engine has libjpeg-turbo in its lib/, so --vision serves JPEG images.
        var jpeg = false
    }

    static func statusScript() -> String {
        var s = """
        H="\(hubDir)"; D="\(dataDir)"; E="\(managedBinary)"
        if [ -x "$E" ]; then echo "ENGINE|managed||$(cat "$(dirname "$E")/../VERSION" 2>/dev/null)"
        elif p=$(command -v tensorfold-native); then echo "ENGINE|user|$p|$("$p" --version 2>&1 | head -1)"
        else echo "ENGINE|none||"; fi
        P="\(engineDir)/previous"; [ -L "$P" ] && echo "PREV|$(cat "$P/VERSION" 2>/dev/null)"
        [ -f "\(engineDir)/current/lib/libturbojpeg.so.0" ] && echo "JPEG|1"
        d="$H"; [ -d "$d" ] || d="$HOME"
        echo "FREE|$(df -Pk "$d" | awk 'NR==2{print $4 * 1024}')"
        m() {
          id=$1; shift; dirs=()
          inc=0
          for r in "$@"; do
            n=${r%@*}; v=${r#*@}; [ -n "$v" ] || v=$(cat "$H/$n/refs/main" 2>/dev/null)
            dirs+=("$H/$n/snapshots/$v")
            # Files still downloading. An interrupted download can leave several attempts at one blob
            # (hash.<random>.incomplete), so count the largest per blob, and none once the blob is complete.
            inc=$((inc + $(find "$H/$n/blobs" -maxdepth 1 ! -type d -printf '%f %s\\n' 2>/dev/null | awk '
              {h = $1; if (h ~ /incomplete$/) { sub(/[.].*/, "", h); if ($2 > m[h]) m[h] = $2 } else done[h] = 1}
              END {for (h in m) if (!(h in done)) s += m[h]; print s + 0}')))
          done
          b=$(( $(du -sbcL "${dirs[@]}" 2>/dev/null | tail -1 | cut -f1) + inc ))
          # Done only while every repo is there: a drafter added to a model's entry later still needs downloading.
          all=1; for x in "${dirs[@]}"; do [ -d "$x" ] || all=0; done
          if [ -f "$D/$id.pid" ] && kill -0 "$(cat "$D/$id.pid")" 2>/dev/null; then st=running
          elif [ -f "$D/$id.ok" ] && [ $all = 1 ]; then st=done
          elif [ -f "$D/$id.ok" ]; then st=none
          elif [ -f "$D/$id.log" ]; then st=failed
          else st=none; fi
          last=""; [ -f "$D/$id.log" ] && last=$(tail -c 2000 "$D/$id.log" | tr '\\r' '\\n' | sed 's/\\x1b\\[[0-9;]*m//g' | grep -v -e '^[[:space:]]*$' -e '^Hint:' | tail -1)
          echo "MODEL|$id|$st|${b:-0}|$last"
        }

        """
        for m in catalog {
            s += "m \(SSH.quote(m.id)) " + m.downloads.map { SSH.quote($0.cacheName + "@" + $0.snapshot) }.joined(separator: " ") + "\n"
        }
        return s + VLLM.statusLines + ComfyUI.statusLines
    }

    static func parseStatus(_ output: String) -> Status {
        var st = Status()
        for line in output.split(separator: "\n") {
            let f = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "ENGINE" where f.count >= 4:
                switch f[1] {
                case "managed": st.engine = .managed(version: f[3].trimmingCharacters(in: .whitespaces))
                case "user": st.engine = .user(path: f[2], version: f[3])
                default: st.engine = .none
                }
            case "JPEG":
                st.jpeg = true
            case "PREV" where f.count >= 2 && !f[1].isEmpty:
                st.previous = f[1].trimmingCharacters(in: .whitespaces)
            case "COMFY" where f.count >= 3:
                st.comfyVersion = f[1].isEmpty ? nil : f[1]
                st.comfyRunning = f[2] == "running"
            case "VLLM" where f.count >= 2:
                st.vllm = f[1]
            case "FREE" where f.count >= 2:
                st.freeBytes = Int64(f[1].trimmingCharacters(in: .whitespaces))
            case "MODEL" where f.count >= 4:
                let d: Download = switch f[2] {
                case "running": .running
                case "done": .done
                case "failed": .failed
                default: .none
                }
                st.models[f[1]] = ModelStatus(download: d, bytes: Int64(f[3]) ?? 0, message: f.count > 4 ? f[4] : "")
            default: break
            }
        }
        return st
    }

    // MARK: Install

    /// Checks the Spark, downloads the release, verifies its checksum, the release signature over that
    /// checksum and every unpacked file, checks the new engine runs, then switches `current` to it. Until
    /// that switch the installed version is untouched; after it, that version is kept as `previous`.
    static func installScript(_ v: String = version) -> String {
        """
        set -euo pipefail
        V=\(v); A=\(archive(v)); E="\(engineDir)"
        say() { echo "› $*"; }
        fail() { echo "✗ $*"; exit 1; }
        \(jpegFunction)
        say "Checking the Spark"
        [ "$(uname -m)" = aarch64 ] || fail "This machine's CPU is $(uname -m); the GB10 release needs aarch64."
        g=$(getconf GNU_LIBC_VERSION | awk '{print $2}')
        printf '2.28\\n%s\\n' "$g" | sort -V -C || fail "glibc $g is older than 2.28."
        command -v nvidia-smi >/dev/null || fail "nvidia-smi not found: is the NVIDIA driver installed?"
        drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
        [ "${drv%%.*}" -ge 580 ] 2>/dev/null || fail "NVIDIA driver $drv is older than R580 (CUDA 13)."
        for t in curl sha256sum openssl tar; do command -v $t >/dev/null || fail "$t is missing."; done
        openssl version | grep -q '^OpenSSL [3-9]' || fail "OpenSSL 3 or newer is needed to check the release signature."
        mkdir -p "$E"
        [ "$(df -Pk "$E" | awk 'NR==2{print $4}')" -gt 1048576 ] || fail "Less than 1 GB free in $HOME."
        T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; cd "$T"
        say "Downloading TensorFold $V"
        U=\(releaseURL(v))
        curl -fsSL --remote-name-all "$U/$A.tar.gz" "$U/$A.tar.gz.sha256" "$U/$A.tar.gz.sha256.sig"
        say "Verifying checksum and release signature"
        sha256sum -c "$A.tar.gz.sha256"
        cat > key.pem <<'KEY'
        \(publicKey)
        KEY
        { printf 'tensorfold-native-checksum-v1\\n'; cat "$A.tar.gz.sha256"; } > signed
        openssl pkeyutl -verify -pubin -inkey key.pem -rawin -in signed -sigfile "$A.tar.gz.sha256.sig"
        say "Unpacking"
        tar -xzf "$A.tar.gz"
        (cd "$A" && sha256sum --quiet -c SHA256SUMS)
        add_jpeg "$A"
        say "Checking TensorFold $V runs"
        "$A/bin/tensorfold-native" --version || fail "TensorFold $V doesn't run on this Spark; the installed version is unchanged."
        \(activateScript)
        say "Installed TensorFold $V"
        """
    }

    // MARK: JPEG

    /// TensorFold decodes JPEG only with libjpeg-turbo 3.1.4.1, doesn't ship it, and looks in lib/ beside bin/
    /// (docs/vision.md, "JPEG input"). Without it --vision serves PNG and WebP but refuses every JPEG.
    static let jpegVersion = "3.1.4.1"
    static let jpegDeb = "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/\(jpegVersion)/libjpeg-turbo-official_\(jpegVersion)_arm64.deb"
    /// The release asset's digest on GitHub.
    static let jpegSHA256 = "d3f9d7ddd998758e1850b37153a7904bdcdeb8cf54a782c772780b0bc50dd553"

    /// `add_jpeg DIR` unpacks libturbojpeg.so.0 into DIR/lib without installing the package. Needs $T, say and fail.
    static let jpegFunction = """
    add_jpeg() {
      command -v dpkg-deb >/dev/null || fail "dpkg-deb is missing; it unpacks libjpeg-turbo."
      say "Downloading libjpeg-turbo \(jpegVersion) for JPEG images"
      curl -fsSL -o "$T/jpeg.deb" "\(jpegDeb)"
      echo "\(jpegSHA256)  $T/jpeg.deb" | sha256sum --quiet -c
      rm -rf "$T/jpeg"; dpkg-deb -x "$T/jpeg.deb" "$T/jpeg"
      f=$(find "$T/jpeg" -name 'libturbojpeg.so.0*' -type f | head -1)
      [ -n "$f" ] || fail "libturbojpeg.so.0 isn't in the libjpeg-turbo package."
      mkdir -p "$1/lib"; cp "$f" "$1/lib/libturbojpeg.so.0"
    }
    """

    /// Adds libjpeg-turbo to an engine installed before Spark Control did that.
    static let jpegScript = """
    set -euo pipefail
    say() { echo "› $*"; }
    fail() { echo "✗ $*"; exit 1; }
    T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
    \(jpegFunction)
    add_jpeg "$(readlink -f "\(engineDir)/current")"
    say "JPEG images work once the model is restarted"
    """

    /// Moves the unpacked "$A" in as "$E/$V" and points `current` at it. The version it replaces becomes
    /// `previous`; any older one is deleted. Needs $V, $A and $E.
    static let activateScript = """
    old=$(readlink "$E/current" 2>/dev/null || true)
    rm -rf "$E/$V"; mv "$A" "$E/$V"; ln -sfn "$V" "$E/current"
    [ -n "$old" ] && [ "$old" != "$V" ] && [ -d "$E/$old" ] && ln -sfn "$old" "$E/previous"
    keep=$(readlink "$E/previous" 2>/dev/null || true)
    for d in "$E"/*; do [ -L "$d" ] || [ "$d" = "$E/$V" ] || [ "$d" = "$E/$keep" ] || rm -rf "$d"; done
    """

    /// Swaps `current` and `previous`. Servers already running keep their version until restarted.
    static let rollbackScript = """
    set -euo pipefail
    E="\(engineDir)"
    p=$(readlink "$E/previous"); c=$(readlink "$E/current")
    [ -x "$E/$p/bin/tensorfold-native" ] || { echo "✗ The previous version is missing."; exit 1; }
    ln -sfn "$p" "$E/current"; ln -sfn "$c" "$E/previous"
    echo "› Switched back to TensorFold $(cat "$E/current/VERSION" 2>/dev/null || echo "$p")"
    """

    /// The newest stable release on GitHub (`releases/latest` skips drafts and pre-releases), or nil.
    static func latestStable() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/ashhart/TensorFold/releases/latest"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let tag = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["tag_name"] as? String
        else { return nil }
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return semver(v) == nil ? nil : v
    }

    /// Notes of the stable releases after `installed` up to `target`, newest first, or nil if GitHub can't be read.
    static func releaseNotes(after installed: String, upTo target: String) async -> [(version: String, notes: String)]? {
        guard let url = URL(string: "https://api.github.com/repos/ashhart/TensorFold/releases?per_page=30"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return nil }
        return list.compactMap { r in
            guard r["draft"] as? Bool != true, r["prerelease"] as? Bool != true,
                  let tag = r["tag_name"] as? String else { return nil }
            let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            // An unparseable installed version (a dev build) only gets the target's notes.
            let afterInstalled = semver(installed) == nil ? v == target : isNewer(v, than: installed)
            guard afterInstalled, !isNewer(v, than: target) else { return nil }
            return (v, (r["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .sorted { isNewer($0.version, than: $1.version) }
    }

    /// Inline markdown keeps line breaks, so drop the "# TensorFold X" title, bold the headings and unwrap hard-wrapped lines.
    /// Release notes for SwiftUI's inline markdown, which keeps line breaks: drops the "# TensorFold X" title,
    /// bolds headings, turns bullets into • and unwraps hard-wrapped lines.
    static func tidyNotes(_ s: String) -> String {
        var out: [String] = []
        for raw in s.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") { continue }
            if line.hasPrefix("#") {
                out.append("**" + line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) + "**")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                out.append((raw.hasPrefix(" ") ? "      • " : "• ") + line.dropFirst(2))
            } else if !line.isEmpty, let last = out.last, !last.isEmpty, !last.hasPrefix("**") {
                out[out.count - 1] += " " + line   // a hard-wrapped continuation of the line above
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// Plain X.Y.Z only, so a pre-release or odd tag never counts as an update.
    static func semver(_ v: String) -> [Int]? {
        let p = v.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        return p.count == 3 && !p.contains(nil) ? p.compactMap { $0 } : nil
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = semver(a), let y = semver(b) else { return false }
        return y.lexicographicallyPrecedes(x)
    }

    /// Removes the engine, and with `models`, the listed models' cache folders and the download records.
    static func uninstallScript(models: [Model]) -> String {
        var s = "set -u\nE=\"\(engineDir)\"; D=\"\(dataDir)\"; H=\"\(hubDir)\"\n" + HF.removeFunction
        s += "rm -rf \"$E\" && echo \"› Removed $E\"\n"
        if !models.isEmpty {
            s += models.map(removeFiles).joined()
            // Only TensorFold's records: the folder also holds the API key and vLLM's records.
            s += models.map { "rm -f \"$D/\($0.id)\".ok \"$D/\($0.id)\".log \"$D/\($0.id)\".pid \"$D/\($0.id)\".keep\n" }.joined()
            s += "echo \"› Removed downloaded models\"\n"
        }
        return s
    }

    /// What to run on the Spark to install it by hand.
    static var manualSteps: String {
        """
        V=\(version)
        A=\(archive())
        U=\(releaseURL())
        curl -fLO "$U/$A.tar.gz" -fLO "$U/$A.tar.gz.sha256"
        sha256sum -c "$A.tar.gz.sha256"
        tar -xzf "$A.tar.gz"
        mkdir -p ~/.local/opt && mv "$A" ~/.local/opt/
        echo 'export PATH="$HOME/.local/opt/\(archive())/bin:$PATH"' >> ~/.bashrc
        """
    }

    // MARK: Models

    /// Starts the download detached from SSH so it survives the Mac sleeping. The `.ok` marker is written
    /// only when the model and its drafter both downloaded and verified.
    static func downloadScript(_ m: Model, binary: String) -> String {
        let pulls = m.downloads.map { r in
            guard !r.skip.isEmpty, let rev = r.revision else { return "\"$TF\" pull \(SSH.quote(r.spec))" }
            // hf leaves refs/main alone for a pinned revision; `tensorfold serve REPO` finds the snapshot through it.
            let refs = "\"\(hubDir)/\(r.cacheName)/refs\""
            // One pattern per --exclude: hf reads any further words as file names to download.
            return "\"$HF\" download \(SSH.quote(r.id)) --revision \(rev) "
                + r.skip.map { "--exclude " + SSH.quote("\($0)/*") }.joined(separator: " ")
                + " && mkdir -p \(refs) && printf %s \(rev) > \(refs)/main"
        }.joined(separator: " && ")
        let needsHF = m.downloads.contains { !$0.skip.isEmpty }
            ? #"{ [ -x "$HF" ] || { echo "✗ The Spark needs the Hugging Face CLI (hf) for this model: pip install -U huggingface_hub"; exit 1; }; } && "# : ""
        let job = "\(needsHF)\(pulls) && touch \"$D/\(m.id).ok\""
        return """
        export D="\(dataDir)" TF="\(binary)" HF="$(command -v hf || echo "$HOME/.local/bin/hf")"
        mkdir -p "$D"; rm -f "$D/\(m.id).ok"
        if [ ! -e "$D/\(m.id).log" ]; then
          H="\(hubDir)"; : > "$D/\(m.id).keep"
          for n in \(m.downloads.map { SSH.quote($0.cacheName) }.joined(separator: " ")); do [ -d "$H/$n" ] && echo "$n" >> "$D/\(m.id).keep"; done
        fi
        nohup bash -c \(SSH.quote(job)) > "$D/\(m.id).log" 2>&1 < /dev/null &
        echo $! > "$D/\(m.id).pid"
        """
    }

    /// Stops a detached download by its record id (a TensorFold model id or a vLLM model's key).
    static func cancelScript(_ id: String) -> String {
        """
        D="\(dataDir)"; p=$(cat "$D/\(id).pid" 2>/dev/null) || exit 0
        pkill -TERM -P "$p"; kill "$p" 2>/dev/null; rm -f "$D/\(id).pid"; echo "Download cancelled" >> "$D/\(id).log"
        """
    }

    /// Deletes a model and its drafter from the Hugging Face cache, with its download records.
    static func deleteScript(_ m: Model) -> String {
        "H=\"\(hubDir)\"; D=\"\(dataDir)\"\n" + HF.removeFunction + removeFiles(m)
            + "rm -f \"$D/\(m.id)\".ok \"$D/\(m.id)\".log \"$D/\(m.id)\".pid \"$D/\(m.id)\".keep\n"
    }

    /// Deletes a model's cache folders, except ones that were on the Spark before its first download
    /// (another setup's files, such as a vLLM recipe sharing the same checkpoint). Needs $H, $D and `hfrm`.
    private static func removeFiles(_ m: Model) -> String {
        m.downloads.map {
            let n = SSH.quote($0.cacheName)
            return "grep -qxF \(n) \"$D/\(m.id).keep\" 2>/dev/null && echo \"› Kept \"\(n)\" (it was there before)\" || hfrm \(n)\n"
        }.joined()
    }

    /// Creates the server's API key once (owner-only) and prints it.
    static let apiKeyScript = """
    D="\(dataDir)"; mkdir -p "$D"; umask 077
    [ -s "$D/api-key" ] || openssl rand -hex 24 > "$D/api-key"
    cat "$D/api-key"
    """

    // MARK: Serving

    /// Listens on all addresses so the Mac can reach it, with an API key because of that.
    static func startCommand(_ m: Model, binary: String, port: Int, name: String? = nil) -> String {
        var args = ["\"\(binary)\"", "serve", m.repo.id, "--host", "0.0.0.0", "--port", "\(port)",
                    "--name", name ?? m.id, "--api-key-file", "\"\(dataDir)/api-key\""]
        if let d = m.drafter { args += ["--drafter", d.id] }
        return withContext((args + m.flags).joined(separator: " "), .window(m.startWindow ?? m.window), model: m)
    }

    // MARK: Drafts

    /// On unless the command has --no-drafts. --drafter stays when off: TensorFold accepts both and
    /// reports "drafts: off" (checked on a GB10 with 1.2.6).
    static func draftsOn(_ command: String) -> Bool { !command.contains(" --no-drafts") }

    static func withDrafts(_ command: String, _ on: Bool) -> String {
        let plain = command.replacingOccurrences(of: " --no-drafts", with: "")
        return on ? plain : plain + " --no-drafts"
    }

    // MARK: Images

    static func withVision(_ command: String, _ on: Bool) -> String {
        let plain = command.replacingOccurrences(of: " --vision", with: "")
        return on ? plain + " --vision" : plain
    }

    // MARK: Context

    enum Context: Hashable {
        /// No flag: TensorFold's own default for the family (16k-32k).
        case engineDefault
        case window(Int)
        /// YaRN factor over the trained window, serving window × factor.
        case yarn(Int)

        func label(_ m: Model) -> String {
            switch self {
            case .engineDefault: "TensorFold default"
            case .window(let n): n == m.window ? "Full window (\(n.formatted()))" : "\(n.formatted()) tokens"
            case .yarn(let f): "YaRN ×\(f) (\((m.window * f).formatted()))"
            }
        }
    }

    static func contextOptions(_ m: Model) -> [Context] {
        let windows = Set([m.startWindow ?? m.window, m.window]).sorted()
        return [.engineDefault] + windows.map(Context.window) + (m.yarn ? [.yarn(2), .yarn(4)] : [])
    }

    /// Reads the context a start command asks for.
    static func context(of command: String) -> Context {
        if let f = flagValue("--rope-yarn", in: command).flatMap({ Double($0) }), f > 1 { return .yarn(Int(f)) }
        if let n = flagValue("--context", in: command).flatMap({ Int($0) }), n > 0 { return .window(n) }
        return .engineDefault
    }

    /// Replaces a start command's --context and --rope-yarn flags with the ones for `c`.
    static func withContext(_ command: String, _ c: Context, model m: Model) -> String {
        var s = command
        for flag in ["--context", "--rope-yarn"] {
            s = s.replacing(try! Regex(" \(flag)(=| +)[^ ]+"), with: "")
        }
        switch c {
        case .engineDefault: return s
        case .window(let n): return s + " --context \(n)"
        case .yarn(let f): return s + " --rope-yarn \(f) --context \(m.window * f)"
        }
    }

    private static func flagValue(_ flag: String, in command: String) -> String? {
        guard let m = command.firstMatch(of: try! Regex(" \(flag)(=| +)([^ ]+)")) else { return nil }
        return m.output[2].substring.map(String.init)
    }

    /// A model added before its catalog entry named a drafter gets the flag added to its saved command.
    static func addingDrafter(to command: String, model: String?) -> String {
        guard let d = Self.model(model)?.drafter, !command.contains("--drafter") else { return command }
        return command + " --drafter " + d.id
    }

    /// Likewise --vision, unless Image input was turned off on the model's page.
    static func addingVision(to command: String, model: String?, images: Bool?) -> String {
        guard images != false, Self.model(model)?.flags.contains("--vision") == true, !command.contains("--vision")
        else { return command }
        return withVision(command, true)
    }

    /// A display name and served model id no existing model answers to, so the gateway and the Spark's
    /// /v1/models can tell it apart from another setup of the same model.
    static func uniqueName(_ m: Model, taken: (String) -> Bool) -> (name: String, served: String) {
        for i in 0... {
            let tag = i == 0 ? "" : i == 1 ? "TensorFold" : "TensorFold \(i)"
            let name = tag.isEmpty ? m.name : "\(m.name) (\(tag))"
            let served = tag.isEmpty ? m.id : m.id + "-" + tag.lowercased().replacingOccurrences(of: " ", with: "-")
            let apiID = Recipe(name: name, startCommand: "", stopCommand: "").apiID
            if !taken(name) && !taken(apiID) && !taken(served) { return (name, served) }
        }
        fatalError("unreachable")
    }

    /// SIGTERM so the server keeps its last turn, then SIGKILL if it hangs. Only the server on `port`, so other
    /// TensorFold models keep running. `[t]` keeps the pattern from matching the shell that runs it.
    static func stopCommand(port: Int) -> String {
        let pat = "[t]ensorfold-native serve .*--port \(port)( |$)"
        return "pkill -TERM -f '\(pat)'; for i in $(seq 30); do pgrep -f '\(pat)' >/dev/null || exit 0; sleep 1; done; pkill -KILL -f '\(pat)'"
    }

    /// What models added before several could run were given: it stops every TensorFold server.
    static let legacyStopCommand = #"pkill -TERM -f '[t]ensorfold-native serve'; for i in $(seq 30); do pgrep -f '[t]ensorfold-native serve' >/dev/null || exit 0; sleep 1; done; pkill -KILL -f '[t]ensorfold-native serve'"#

    // MARK: Sizes

    /// Download size from the Hugging Face API, summed over the repos (a model and its drafter).
    static func downloadSize(_ repos: [Repo]) async -> Int64? {
        var total: Int64 = 0
        for r in repos {
            guard let url = URL(string: "https://huggingface.co/api/models/\(r.id)/revision/\(r.revision ?? "main")?blobs=true"),
                  let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let files = obj["siblings"] as? [[String: Any]] else { return nil }
            total += files.reduce(0) { sum, f in
                let name = f["rfilename"] as? String ?? ""
                return r.skip.contains { name.hasPrefix($0 + "/") } ? sum : sum + ((f["size"] as? NSNumber)?.int64Value ?? 0)
            }
        }
        return total
    }
}
