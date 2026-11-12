import Foundation

/// ComfyUI on the Spark for image generation: a pinned release in its own Python environment, starter models
/// downloaded straight onto the Spark, and a server that listens only on the Spark itself. The Mac reaches it
/// through an SSH tunnel, so nothing is exposed on the network (ComfyUI has no login).
/// Follows NVIDIA's DGX Spark ComfyUI playbook, at a newer ComfyUI release.
enum ComfyUI {
    static let version = "v0.45.0"
    static let commit = "989d93d0d968e704c589ce0146bb18c77f6b50cc"
    static let git = "https://github.com/Comfy-Org/ComfyUI.git"
    static let dir = "$HOME/.local/share/spark-control/comfyui"
    static var app: String { dir + "/ComfyUI" }
    static var python: String { dir + "/venv/bin/python" }
    /// On the Spark, bound to 127.0.0.1 only.
    static let port = 8188
    /// On the Mac, the tunnel's end.
    static let localPort = 18188

    struct File: Hashable {
        /// Path inside ComfyUI's models folder.
        var path: String
        var url: String
        var size: Int64
    }

    struct Model: Identifiable, Hashable {
        var id: String
        var name: String
        var note: String
        var files: [File]
        /// The built-in ComfyUI template that uses these files; the frontend opens it from `?template=`.
        var template: String
        var key: String { "comfy-" + id }
        var size: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    static let catalog: [Model] = {
        let base = "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/6fc90a3b1b653e935a0d175e260736de25b84df5/split_files/"
        return [
            Model(id: "z-image-turbo", name: "Z-Image-Turbo",
                  note: "Fast text to image, the model NVIDIA's Spark playbook starts with. Open goes straight to its prompt: type and press Run.",
                  files: [
                      File(path: "diffusion_models/z_image_turbo_bf16.safetensors", url: base + "diffusion_models/z_image_turbo_bf16.safetensors", size: 12_309_866_400),
                      File(path: "text_encoders/qwen_3_4b.safetensors", url: base + "text_encoders/qwen_3_4b.safetensors", size: 8_044_982_048),
                      File(path: "vae/ae.safetensors", url: base + "vae/ae.safetensors", size: 335_304_388),
                  ],
                  // Checked in comfyui-workflow-templates 0.11.105: it loads exactly these three file names.
                  template: "image_z_image_turbo"),
        ]
    }()

    static func model(_ key: String) -> Model? { catalog.first { $0.key == key } }

    // MARK: Status

    /// Lines for TensorFold's status script (it defines $D): install state, whether the server runs, and per model
    /// the same MODEL line as downloads elsewhere, with bytes counted from the files (finished and partial).
    static var statusLines: String {
        var s = """
        C="\(dir)"
        if [ -f "$C/installed" ]; then echo "COMFY|$(git -C "\(app)" describe --tags 2>/dev/null)|$(pgrep -f '[s]park-control/comfyui/ComfyUI/main.py' >/dev/null && echo running)"
        else echo "COMFY||"; fi
        cm() {
          id=$1; shift; b=0
          for f in "$@"; do for x in "$C/ComfyUI/models/$f" "$C/ComfyUI/models/$f.part"; do [ -f "$x" ] && b=$((b + $(stat -c %s "$x"))); done; done
          if [ -f "$D/$id.pid" ] && kill -0 "$(cat "$D/$id.pid")" 2>/dev/null; then st=running
          elif [ -f "$D/$id.ok" ]; then st=done
          elif [ -f "$D/$id.log" ]; then st=failed
          else st=none; fi
          last=""; [ -f "$D/$id.log" ] && last=$(tail -c 2000 "$D/$id.log" | tr '\\r' '\\n' | grep -v '^[[:space:]]*$' | tail -1)
          echo "MODEL|$id|$st|$b|$last"
        }

        """
        for m in catalog { s += "cm \(SSH.quote(m.key)) " + m.files.map { SSH.quote($0.path) }.joined(separator: " ") + "\n" }
        return s
    }

    // MARK: Install

    /// Clones the pinned release into its own folder with a Python environment: PyTorch for CUDA 13.0 (what the
    /// GB10's R580 driver runs), then ComfyUI's requirements, which include its web frontend. No sudo.
    /// Run again, it updates an existing install to the pinned release and keeps downloaded models. Only a run that
    /// gets to the end marks it installed, so an interrupted install shows as not installed and Install resumes it.
    static let installScript = """
    set -euo pipefail
    C="\(dir)"
    rm -f "$C/installed"
    say() { echo "› $*"; }
    fail() { echo "✗ $*"; exit 1; }
    [ "$(uname -m)" = aarch64 ] || fail "This machine's CPU is $(uname -m); expected the Spark's aarch64."
    python3 -c 'import venv, ensurepip' 2>/dev/null || fail "Python's venv module is missing: sudo apt install python3-venv"
    command -v git >/dev/null || fail "git is missing."
    [ "$(df -Pk "$HOME" | awk 'NR==2{print $4}')" -gt 15728640 ] || fail "Less than 15 GB free in $HOME."
    mkdir -p "$C"
    if [ -d "$C/ComfyUI/.git" ]; then
      say "Updating ComfyUI to \(version)"
      git -C "$C/ComfyUI" fetch -q --depth 1 origin tag \(version)
    else
      say "Downloading ComfyUI \(version)"
      git clone -q --depth 1 --branch \(version) \(git) "$C/ComfyUI"
    fi
    git -C "$C/ComfyUI" checkout -q \(commit)
    [ -x "$C/venv/bin/python" ] || { say "Creating the Python environment"; python3 -m venv "$C/venv"; }
    P="$C/venv/bin/python"
    "$P" -m pip install -q --upgrade pip
    say "Installing PyTorch for CUDA 13.0 (a few GB)"
    "$P" -m pip install -q --progress-bar off torch torchvision --index-url https://download.pytorch.org/whl/cu130
    say "Installing ComfyUI's requirements"
    "$P" -m pip install -q --progress-bar off -r "$C/ComfyUI/requirements.txt"
    "$P" -c 'import torch; assert torch.cuda.is_available(), "PyTorch cannot see the GPU"; print("› GPU:", torch.cuda.get_device_name(0), "· PyTorch", torch.__version__)'
    touch "$C/installed"
    say "Installed ComfyUI \(version)"
    """

    static let removeScript = """
    pkill -TERM -f '[s]park-control/comfyui/ComfyUI/main.py'
    rm -rf "\(dir)" && echo "› Removed ComfyUI and its models"
    rm -f "\(TensorFold.dataDir)"/comfy-*
    """

    // MARK: Models

    /// Downloads with curl, resumable, into `.part` files that are renamed only when complete. Detached from SSH.
    static func downloadScript(_ m: Model) -> String {
        let job = m.files.map { f in
            let dest = "$M/" + f.path
            return "[ -f \"\(dest)\" ] || { mkdir -p \"$(dirname \"\(dest)\")\" && echo \"› \(f.path)\" && curl -fL --retry 5 -C - -o \"\(dest).part\" \(SSH.quote(f.url)) && mv \"\(dest).part\" \"\(dest)\"; }"
        }.joined(separator: " && ") + " && touch \"$D/\(m.key).ok\""
        return """
        export D="\(TensorFold.dataDir)" M="\(app)/models"
        mkdir -p "$D"; rm -f "$D/\(m.key).ok"
        nohup bash -c \(SSH.quote(job)) > "$D/\(m.key).log" 2>&1 < /dev/null &
        echo $! > "$D/\(m.key).pid"
        """
    }

    static func deleteScript(_ m: Model) -> String {
        "M=\"\(app)/models\"; D=\"\(TensorFold.dataDir)\"\n"
            + m.files.map { "rm -f \"$M/\($0.path)\" \"$M/\($0.path).part\"\n" }.joined()
            + "rm -f \"$D/\(m.key)\".ok \"$D/\(m.key)\".log \"$D/\(m.key)\".pid\n"
    }

    // MARK: Server

    /// Starts the server detached, listening on the Spark's loopback only, and waits until it answers.
    /// TORCH_DISABLE_NATIVE_JIT: PyTorch 2.14 routes some ops (the text encoder's matmul) to Triton kernels, and
    /// Triton compiles a helper against Python.h, which DGX OS doesn't ship without `sudo apt install python3.12-dev`.
    /// Switching that routing off uses the regular CUDA libraries instead (checked on a GB10 with torch 2.14.1+cu130).
    static let startScript = """
    C="\(dir)"; L="$C/server.log"
    pgrep -f '[s]park-control/comfyui/ComfyUI/main.py' >/dev/null && exit 0
    cd "$C/ComfyUI"
    TORCH_DISABLE_NATIVE_JIT=1 nohup "$C/venv/bin/python" "$C/ComfyUI/main.py" --listen 127.0.0.1 --port \(port) --disable-auto-launch > "$L" 2>&1 < /dev/null &
    for i in $(seq 180); do
      curl -fs -o /dev/null http://127.0.0.1:\(port)/system_stats && { echo "› ComfyUI is ready"; exit 0; }
      kill -0 $! 2>/dev/null || { tail -20 "$L"; exit 1; }
      sleep 1
    done
    echo "✗ ComfyUI didn't answer within 3 minutes"; tail -20 "$L"; exit 1
    """

    /// Also run before any model starts, since both need the GB10's memory. `[s]` keeps pkill off its own shell.
    static let stopCommand = #"pkill -TERM -f '[s]park-control/comfyui/ComfyUI/main.py' && sleep 3; pkill -KILL -f '[s]park-control/comfyui/ComfyUI/main.py'; true"#
}
