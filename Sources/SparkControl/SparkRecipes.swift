import Foundation

/// Community setups tuned for one DGX Spark: a git repo pinned to a tested commit, with its own setup, start and
/// stop scripts (usually a patched vLLM or TensorFold image built with Docker). Listed for models where such a
/// recipe is faster on a GB10 than the stock engines. Spark Control clones into ~/<dir> and runs the recipe's own
/// scripts; a folder that is already there is used as it is and never changed.
enum SparkRecipes {
    struct Entry: Identifiable, Hashable {
        var id: String
        var name: String
        /// What it serves with, for the catalog.
        var engine: String
        var git: String
        var commit: String
        /// Folder under the Spark user's home.
        var dir: String
        /// Run in the folder, detached: builds the image, downloads and prepares the weights. Idempotent.
        var setup: String
        /// Run in the folder; `{port}` is replaced with the port to serve on. Returns once the API answers.
        var start: String
        var stop: String
        /// The model id the server answers to.
        var served: String
        /// What setup downloads, for the size and how much is already on the Spark.
        var weights: [TensorFold.Repo]
        var note: String

        /// Download records share TensorFold's data folder, so they get a prefix no catalog model has.
        var key: String { "recipe-" + id }
        var repoName: String { git.replacingOccurrences(of: "https://github.com/", with: "").replacingOccurrences(of: ".git", with: "") }

        func startCommand(port: Int) -> String {
            "cd ~/\(dir) && " + start.replacingOccurrences(of: "{port}", with: "\(port)")
        }
        var stopCommand: String { "cd ~/\(dir) && \(stop)" }
    }

    static let catalog: [Entry] = [
        Entry(id: "qwen3.8-flash-next", name: "Qwen3.8 Flash Next", engine: "vLLM 0.32, patched",
              git: "https://github.com/blazux/qwen3.8-Flash-DGX.git", commit: "b0aa8b77604139557169387b2fa8386355d8b651",
              dir: "qwen3.8-Flash-DGX",
              setup: "./flash setup", start: "./flash serve default PORT={port} && ./flash wait", stop: "./flash stop",
              served: "qwen3.8-flash-next",
              weights: [TensorFold.Repo(id: "nvidia/Qwen3.8-Flash-Next-NVFP4", revision: "fc694b54fb0174e0913e6adf86691ef85a4ead47")],
              note: "NVIDIA NVFP4 with the n-gram table mapped from NVMe, fp8 side layers, MTP, 500k context. About 34 tok/s single-stream on a GX10 (blazux's numbers). Other profiles (speed, concurrent, context-1m, dflash) replace \"default\" in the start command."),
        Entry(id: "qwen3.8-27b", name: "Qwen3.8 27B", engine: "TensorFold 0.6.0, patched",
              git: "https://github.com/MiaAI-Lab/Qwen3.8-27B-DGX-Spark-TensorFold.git", commit: "c11ff138871cf43d12898d79dbfa4dc952d17ca4",
              dir: "Qwen3.8-27B-DGX-Spark-TensorFold",
              setup: "scripts/prepare.sh", start: "PORT={port} ./start.sh", stop: "./stop.sh",
              served: "Qwen3.8-27B",
              weights: [TensorFold.Repo(id: "Vontra/Qwen3.8-27B-MLX-4bit"), TensorFold.Repo(id: "z-lab/Qwen3.8-27B-DFlash2")],
              note: "MLX 4-bit with the DFlash2 drafter, 8 parallel requests, 262k context, FP8 attention cache, images and video."),
    ]

    static func entry(_ id: String?) -> Entry? { catalog.first { $0.id == id } }

    /// Lines for TensorFold's status script: the clone's commit, and `m` for setup state and bytes on the Spark.
    static var statusLines: String {
        catalog.map { e in
            "echo \"RDIR|\(e.id)|$(git -C ~/\(e.dir) rev-parse HEAD 2>/dev/null)\"\n"
                + "m \(SSH.quote(e.key)) " + e.weights.map { SSH.quote($0.cacheName + "@" + $0.snapshot) }.joined(separator: " ") + "\n"
        }.joined()
    }

    /// Clones at the pinned commit when the folder isn't there, then runs the recipe's setup, detached from SSH.
    /// The `.ok` marker is written only when setup succeeds.
    static func setupScript(_ e: Entry) -> String {
        let job = """
        set -e
        if [ ! -d ~/\(e.dir) ]; then
          echo "› Cloning \(e.repoName) at \(e.commit.prefix(7))"
          git clone -q \(SSH.quote(e.git)) ~/\(e.dir)
          git -C ~/\(e.dir) checkout -q \(e.commit)
        fi
        cd ~/\(e.dir)
        echo "› Running \(e.setup)"
        \(e.setup)
        touch "$D/\(e.key).ok"
        """
        return """
        export D="\(TensorFold.dataDir)"
        mkdir -p "$D"; rm -f "$D/\(e.key).ok"
        command -v docker >/dev/null || { echo "Docker isn't installed on the Spark."; exit 1; }
        nohup bash -c \(SSH.quote(job)) > "$D/\(e.key).log" 2>&1 < /dev/null &
        echo $! > "$D/\(e.key).pid"
        """
    }
}
