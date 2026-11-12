# Spark Control

Native macOS app that runs models on a DGX Spark and serves them through one
OpenAI-compatible API at `http://localhost:18080/v1`. Nothing is installed on the Spark unless you
install TensorFold from the app: it starts and stops models over SSH and forwards requests to the Spark's port 18300.

## Build & run

```bash
./build-app.sh --install   # builds, copies to /Applications and launches it
./build-app.sh --open      # builds build/Spark Control.app and launches it from there
./Tests/run.sh             # self-check for request rewriting, pricing, routes
```

Needs only Xcode Command Line Tools.

## One-time: key-based SSH

The app signs in with your SSH key. If the Spark doesn't accept it yet, click
**Set Up Key Login…** (Settings → Spark, or on a model's error): enter the Spark password once
and the app installs your key. The password is passed to ssh through a pipe and never stored.

## How it works

- **Recipes**: each model is a start command, a stop command, a backend model ID, and prices.
  Commands run via `bash -ic` on the Spark, so your aliases (`qwen-start`, `laguna-start`, …) work.
  Start output is written to `/tmp/spark-control/start.log` on the Spark and streamed into Logs.
- **Ready check**: polls `:18300/v1/models` (and Ollama's `/api/ps`) until the model appears.
- **Routes**: Local = `<host>.local`, Tailscale = `<host>`. Automatic prefers local.
- **API**: requests pass through untouched, except the model name is renamed to the backend ID, plus any
  per-model parameter rules you set. A request for a stopped model switches to it (configurable).
  Responses get `usage.cost` from the model's prices (toggle in Settings → API).
- **Ports**: each model can override the Spark port (default 18300).
- **Usage**: tokens split like Kilo (In excludes cached, Out excludes reasoning), cache hit rate, and for
  streamed requests time to first token, prefill and decode speed, over 4h / 24h / week / month / year / all.
- **Chat**: built-in chat through the same gateway, with image, PDF and text file attachments.
- **TensorFold** (sidebar → Engines): installs TensorFold's pinned GB10 release into
  `~/.local/share/spark-control/tensorfold` on the Spark (checksum, release signature and every file checked; no sudo),
  or uses one you put on your `PATH`. Lists the models TensorFold has tested on one GB10, downloads each with the
  drafter TensorFold names for it (detached, so it survives the Mac sleeping), and adds it as a model that serves with
  `--drafter` and an API key the gateway sends for you. Deleting a model, or removing TensorFold, asks first and only
  touches what the app downloaded.
  Each catalog row shows what's already on the Spark: "On Spark" for models another setup downloaded (add them
  without downloading again), and "X of Y" with a bar for partial or running downloads.
  Each TensorFold model's page has a Context picker: TensorFold's default, the model's full trained window (the default
  for new models; 262k for Super VL), or YaRN ×2/×4 on the Qwen3.6 models, written into the start command's flags.
- **vLLM** (sidebar → Engines): pulls the official vLLM image, pinned by digest, with Docker (no sudo) and lists NVFP4 models that
  fit one GB10 and carry an MTP head. Downloads use `hf` inside the image as your user, into the same Hugging Face cache.
  Models run as the `spark-vllm` container with the shared API key, 85% of memory, 4 requests at once and prefix
  caching. Each model's page has Context and MTP drafts pickers. Suggested drafts come from published single-Spark
  measurements: 3 for Qwen3.6 35B-A3B (about 100 tok/s, +45%), 2 for Gemma 4 (1.7–1.8×, and 2 beat 4), and 2 elsewhere,
  where nobody has published a sweep. The first start of a model can take 10–15 minutes.
- **ComfyUI** (sidebar → Engines): image generation on the Spark. Install sets up ComfyUI (pinned release) with PyTorch
  for CUDA 13.0 in `~/.local/share/spark-control/comfyui`, following NVIDIA's DGX Spark playbook; no sudo. Starter
  models download straight onto the Spark: Z-Image-Turbo (text to image, about 20 GB) and Qwen-Image-Edit-2511
  (edits an image from an instruction, about 31 GB). **Start and Open** stops the running model,
  starts ComfyUI on the Spark's loopback only, and opens it at `http://127.0.0.1:18188` on this Mac through an SSH
  tunnel. Then Templates → Image → "Z-Image-Turbo: Text to Image" → Run. Starting any model stops ComfyUI, since
  both need the GB10's memory.
- **Spark** (sidebar → Activity): live memory, CPU, GPU, power and temperatures, read over SSH every 2 seconds
  while the page is open (every 15 seconds otherwise, for the menu bar). Memory comes from `/proc/meminfo` because
  the GB10 shares it between CPU and GPU, and per-process GPU memory from `nvidia-smi`.
- **Models** (sidebar, the app's start page): every model in one list. Running, On Spark (your models and downloaded
  catalog models) and Available to Download (TensorFold, vLLM and ComfyUI catalogs), filterable by text or image
  and searchable. Start, Stop, Download and Open work from the list; a name opens that model's own page. The sidebar
  shows only running models.
- **Data**: `~/Library/Application Support/Spark Control/` (`config.json`, `usage.jsonl`, `chats.json`).
