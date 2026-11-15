import Foundation

/// vLLM on the Spark: the official image pinned by digest, NVFP4 models with an MTP head that drafts from the
/// checkpoint itself, and the commands that serve them in Docker. Downloads, records and the API key share
/// TensorFold's folders so both engines see the same Hugging Face cache.
enum VLLM {
    static let version = "0.33.0"
    /// vllm/vllm-openai:v0.33.0 (multi-arch; the Spark pulls the arm64 build). Bump with `version`.
    static let image = "vllm/vllm-openai@sha256:d825baf9ce4b1b6bfc5ecc7b79880c7e6748c65a72d697ce3d47607aafa84c6e"
    /// Each model runs in its own container, so several can run side by side.
    static func container(_ served: String) -> String { "spark-vllm-" + served }
    /// What vLLM's --gpu-memory-utilization is a fraction of on a GB10 (torch's 124,544 MiB).
    static let gb10Memory = 130_594_021_376.0

    struct Model: Identifiable, Hashable {
        /// Also the served model name, after the `vllm-` record prefix is dropped.
        var id: String
        var name: String
        var repo: TensorFold.Repo
        /// A separate MTP drafter (Gemma 4's assistant checkpoints); nil drafts from the model's own MTP head.
        var drafter: TensorFold.Repo?
        /// Drafted tokens per step that measured fastest on a Spark, or 2 where nobody has published a sweep.
        var suggested = 2
        var parsers: [String] = []
        var flags: [String] = []
        var window = 262_144
        /// Context new models start with, when the full window leaves too little room for the KV cache.
        var startWindow: Int?
        /// Memory it may take, in GB: weights plus room for context. vLLM claims all of it at start.
        var memoryGB: Double = 50
        /// Requests decoded together (--max-num-seqs).
        var maxSeqs = 4
        /// Measured memory besides the KV cache (weights, activations, CUDA graphs), in GB. With it the KV cache gets
        /// a fixed size (memory minus this), which skips vLLM's start-up memory profiling: on the GB10's unified
        /// memory that check fails ("Error in memory profiling") whenever free memory moves while it measures.
        var footprintGB: Double?
        var note: String

        /// Download records live in TensorFold's data folder, so they get a prefix no TensorFold model has.
        var key: String { "vllm-" + id }
        var downloads: [TensorFold.Repo] { [repo] + (drafter.map { [$0] } ?? []) }
    }

    static let qwenParsers = ["--reasoning-parser", "qwen3", "--enable-auto-tool-choice", "--tool-call-parser", "qwen3_coder"]
    static let nemotronParsers = ["--reasoning-parser", "nemotron_v3", "--enable-auto-tool-choice", "--tool-call-parser", "qwen3_coder"]

    /// NVFP4 checkpoints that fit one GB10 and carry MTP. Sources for each suggestion are in the README.
    static let catalog: [Model] = [
        Model(id: "qwen3.6-35b-a3b", name: "Qwen3.6 35B-A3B",
              repo: .init(id: "nvidia/Qwen3.6-35B-A3B-NVFP4", revision: "1355db6a052410cfd62085d94b58866fd0f2c3c5"),
              suggested: 3, parsers: qwenParsers,
              note: "NVIDIA NVFP4. MTP ×3 measured about 100 tok/s single-stream on a GB10, +45% over no drafts."),
        Model(id: "qwen3.8-27b", name: "Qwen3.8 27B",
              repo: .init(id: "nvidia/Qwen3.8-27B-NVFP4", revision: "482ca0f3832238542f8f5295dde86b5f22711d80"),
              parsers: qwenParsers,
              note: "NVIDIA NVFP4, the model NVIDIA's Spark vLLM playbook picks for 128 GB. Dense, so slower per token than the MoE models."),
        // llm-compressor mixed precision (NVFP4 MLPs, FP8 attention and a calibrated FP8 KV cache, read from
        // config.json), so no --quantization or --kv-cache-dtype. Gated with auto-approval on Hugging Face.
        Model(id: "qwen3.8-27b-uncensored", name: "Qwen3.8 27B Uncensored",
              repo: .init(id: "orcarouter/Qwen3.8-27B-Uncensored-NVFP4", revision: "d350e02d82203d5bf07a1e203c997581f235f407"),
              // 8 requests at once: 151 tok/s in all on code at 8 (GB10, MTP x2), where 4 capped it. Footprint
              // measured 29.1-30.1 GiB at 0.38 (KV 17.2-18.2 GiB), plus margin.
              parsers: qwenParsers, memoryGB: 50, maxSeqs: 8, footprintGB: 32.5,
              note: "Abliterated (refusals removed) NVFP4 + FP8 build with images and MTP. Accept its terms on Hugging Face and sign the Spark in with hf auth login before downloading."),
        Model(id: "nemotron-3.5-lightning", name: "Nemotron 3.5 Lightning 30B-A3B",
              repo: .init(id: "nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4", revision: "bee7596271d1495f6992ae224aefde4410e816b8"),
              parsers: nemotronParsers, flags: ["--trust-remote-code"], window: 1_048_576, startWindow: 262_144,
              note: "NVIDIA NVFP4 with a 1M-token window; starts at 262k."),
        Model(id: "nemotron-3-super", name: "Nemotron 3 Super 120B-A12B",
              repo: .init(id: "nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4", revision: "ff433f5493e25d631c9f12b5d55c674229923d02"),
              parsers: nemotronParsers, flags: ["--trust-remote-code"], startWindow: 131_072, memoryGB: 105,
              note: "NVIDIA NVFP4, the model vLLM's own Spark guide serves (about 23 tok/s without drafts). 75 GiB of weights, so it starts at 131k."),
        Model(id: "gemma-4-26b-a4b", name: "Gemma 4 26B-A4B",
              repo: .init(id: "nvidia/Gemma-4-26B-A4B-NVFP4", revision: "a19cfe00be84568a6867111c9a68c9c44fdcffe6"),
              drafter: .init(id: "google/gemma-4-26B-A4B-it-assistant"), memoryGB: 45,
              note: "NVIDIA NVFP4 with Google's MTP assistant. Two drafted tokens measured 1.7–1.8× over none on a GB10, and beat four."),
    ]

    static func model(_ id: String?) -> Model? { catalog.first { $0.id == id } }

    // MARK: Status, install, download

    /// Lines for TensorFold's status script: whether the image is pulled, and `m` per model.
    static var statusLines: String {
        "docker image inspect \(image) >/dev/null 2>&1 && echo 'VLLM|ready' || { command -v docker >/dev/null && echo 'VLLM|none' || echo 'VLLM|nodocker'; }\n"
            + catalog.map { m in
                "m \(SSH.quote(m.key)) " + m.downloads.map { SSH.quote($0.cacheName + "@" + $0.snapshot) }.joined(separator: " ") + "\n"
            }.joined()
    }

    static let pullScript = """
    set -eo pipefail
    command -v docker >/dev/null || { echo "✗ Docker isn't installed on the Spark."; exit 1; }
    docker info >/dev/null 2>&1 || { echo "✗ This user can't run Docker. Add it to the docker group: sudo usermod -aG docker $USER"; exit 1; }
    echo "› Pulling vLLM \(version) (about 26 GB on disk)"
    docker pull \(image) 2>&1 | grep --line-buffered -v -E 'Waiting|Downloading|Extracting|Verifying|Pulling fs layer' || true
    docker image inspect \(image) >/dev/null
    echo "› vLLM \(version) is ready"
    """

    static let removeScript = "docker ps -aq --filter name=^spark-vllm | xargs -r docker rm -f >/dev/null 2>&1; docker rmi \(image) && echo '› Removed the vLLM image'"

    /// Downloads with the `hf` tool inside the vLLM image, so the Spark needs nothing else installed, as the
    /// Spark's user so the cache stays theirs (TensorFold and `hf` can still update or delete it). Detached
    /// from SSH; the `.ok` marker is written only when every repo downloaded. Drafters follow `main`, which
    /// is what vLLM resolves offline.
    static func downloadScript(_ m: Model) -> String {
        let pulls = m.downloads.map { r in
            "hf download \(SSH.quote(r.id))" + (r.revision.map { " --revision \($0)" } ?? "")
        }.joined(separator: " && ")
        // The container's HOME is /tmp, so it can't see `hf auth login`'s token: mount it read-only (gated repos
        // need it) and pass HF_TOKEN through when set, keeping the token itself out of the process list.
        let job = """
        T="${HF_TOKEN_PATH:-${HF_HOME:-$HOME/.cache/huggingface}/token}"; A=(); [ -f "$T" ] && A=(-v "$T:/tmp/hf-token:ro" -e HF_TOKEN_PATH=/tmp/hf-token)
        docker run --rm --user "$(id -u):$(id -g)" --entrypoint bash -v "$H:/hub" -e HF_HUB_CACHE=/hub -e HOME=/tmp -e HF_TOKEN "${A[@]}" \(image) -c \(SSH.quote(pulls)) && touch "$D/\(m.key).ok"
        """
        return """
        export D="\(TensorFold.dataDir)" H="\(TensorFold.hubDir)"
        mkdir -p "$D" "$H"; rm -f "$D/\(m.key).ok"
        if [ ! -e "$D/\(m.key).log" ]; then
          : > "$D/\(m.key).keep"
          for n in \(m.downloads.map { SSH.quote($0.cacheName) }.joined(separator: " ")); do [ -d "$H/$n" ] && echo "$n" >> "$D/\(m.key).keep"; done
        fi
        nohup bash -c \(SSH.quote(job)) > "$D/\(m.key).log" 2>&1 < /dev/null &
        echo $! > "$D/\(m.key).pid"
        """
    }

    static func deleteScript(_ m: Model) -> String {
        "H=\"\(TensorFold.hubDir)\"; D=\"\(TensorFold.dataDir)\"\n" + HF.removeFunction
            + m.downloads.map {
                let n = SSH.quote($0.cacheName)
                return "grep -qxF \(n) \"$D/\(m.key).keep\" 2>/dev/null && echo \"› Kept \"\(n)\" (it was there before)\" || hfrm \(n)\n"
            }.joined()
            + "rm -f \"$D/\(m.key)\".ok \"$D/\(m.key)\".log \"$D/\(m.key)\".pid \"$D/\(m.key)\".keep\n"
    }

    // MARK: Serving

    /// Runs in the foreground so its log reaches Logs and a crash fails the start. Offline, so it serves only
    /// what's downloaded. vLLM, FlashInfer and Triton compile caches persist between starts.
    static func startCommand(_ m: Model, port: Int, name: String, total: Double = gb10Memory) -> String {
        var args = ["docker rm -f \(container(name)) >/dev/null 2>&1;", "exec docker run --rm --name \(container(name))",
                    "--gpus all --ipc=host -p \(port):8000",
                    "-v \"\(TensorFold.hubDir):/root/.cache/huggingface/hub\"",
                    "-v \"$HOME/.cache/spark-control-vllm:/root/.cache\"",
                    "-e HF_HUB_OFFLINE=1", image,
                    m.repo.id] + (m.repo.revision.map { ["--revision", $0] } ?? [])
        args += ["--served-model-name", name, "--api-key", "\"$(cat \"\(TensorFold.dataDir)/api-key\")\"",
                 "--max-num-seqs \(m.maxSeqs)", "--enable-prefix-caching"]
        args += m.parsers + m.flags
        let cmd = withMemory(withContext(args.joined(separator: " "), m.startWindow ?? m.window), m.memoryGB, total: total,
                             footprint: m.footprintGB)
        return withDrafts(cmd, m.suggested, model: m)
    }

    static func stopCommand(_ served: String) -> String {
        "docker stop -t 30 \(container(served)) >/dev/null 2>&1; docker rm -f \(container(served)) >/dev/null 2>&1; true"
    }

    /// The share of the Spark's memory the command lets vLLM take.
    static func memoryFraction(of command: String) -> Double? {
        flagValue("--gpu-memory-utilization", in: command).flatMap { Double($0) }
    }

    /// Sets --gpu-memory-utilization, which the app counts memory by, and with a measured footprint the fixed
    /// KV cache size that goes with it.
    static func withMemory(_ command: String, _ gb: Double, total: Double = gb10Memory, footprint: Double? = nil) -> String {
        let f = min(0.95, max(0.05, gb * 1e9 / total))
        let plain = command.replacing(try! Regex(" --(gpu-memory-utilization|kv-cache-memory-bytes)(=| +)[^ ]+"), with: "")
        let kv = footprint.map { String(format: " --kv-cache-memory-bytes %.0f", max(2, gb - $0) * 1e9) } ?? ""
        return plain + String(format: " --gpu-memory-utilization %.2f", f) + kv
    }

    /// Keeps a saved command of a model with a measured footprint in step with its entry: the fixed KV cache (at
    /// the memory the command already has); once, when that first appears, the request limit; and flags an earlier
    /// version added that measured no gain. Other models' commands are left as they are.
    static func synced(_ command: String, model id: String?) -> String {
        guard let m = model(id), m.footprintGB != nil else { return command }
        var c = command
        if !c.contains("--kv-cache-memory-bytes") {
            c = c.replacing(try! Regex(" --max-num-seqs(=| +)[0-9]+"), with: " --max-num-seqs \(m.maxSeqs)")
        }
        for dropped in [" --async-scheduling", #" --compilation-config '{"pass_config":{"fuse_act_quant":true},"max_cudagraph_capture_size":64}'"#,
                        #" --kernel-config '{"enable_flashinfer_autotune":true}'"#, " --max-num-batched-tokens 8192"] {
            c = c.replacingOccurrences(of: dropped, with: "")
        }
        if let f = memoryFraction(of: c) { c = withMemory(c, f * gb10Memory / 1e9, footprint: m.footprintGB) }
        return c
    }

    // MARK: Flags

    static func context(of command: String) -> Int? {
        flagValue("--max-model-len", in: command).flatMap { Int($0) }
    }

    static func withContext(_ command: String, _ tokens: Int) -> String {
        command.replacing(try! Regex(" --max-model-len(=| +)[^ ]+"), with: "") + " --max-model-len \(tokens)"
    }

    static func contextOptions(_ m: Model) -> [Int] {
        Set([32_768, 65_536, 131_072, m.startWindow ?? m.window, m.window].filter { $0 <= m.window }).sorted()
    }

    /// Drafted tokens per step in the command's --speculative-config; 0 when there is none.
    static func drafts(of command: String) -> Int {
        guard let m = command.firstMatch(of: try! Regex(#"--speculative-config '[^']*"num_speculative_tokens": *(\d+)"#)) else { return 0 }
        return m.output[1].substring.flatMap { Int($0) } ?? 0
    }

    static func withDrafts(_ command: String, _ n: Int, model m: Model) -> String {
        let plain = command.replacing(try! Regex(" --speculative-config '[^']*'"), with: "")
        guard n > 0 else { return plain }
        let draft = m.drafter.map { #""model":"\#($0.id)","# } ?? ""
        return plain + #" --speculative-config '{"method":"mtp",\#(draft)"num_speculative_tokens":\#(n)}'"#
    }

    private static func flagValue(_ flag: String, in command: String) -> String? {
        guard let m = command.firstMatch(of: try! Regex(" \(flag)(=| +)([^ ]+)")) else { return nil }
        return m.output[2].substring.map(String.init)
    }
}
