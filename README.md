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
- **TensorFold** (sidebar → Catalog): installs TensorFold's pinned GB10 release into
  `~/.local/share/spark-control/tensorfold` on the Spark (checksum, release signature and every file checked; no sudo),
  or uses one you put on your `PATH`. Lists the models TensorFold has tested on one GB10, downloads each with the
  drafter TensorFold names for it (detached, so it survives the Mac sleeping), and adds it as a model that serves with
  `--drafter` and an API key the gateway sends for you. Deleting a model, or removing TensorFold, asks first and only
  touches what the app downloaded.
  Each catalog row shows what's already on the Spark: "On Spark" for models another setup downloaded (add them
  without downloading again), and "X of Y" with a bar for partial or running downloads.
  Each TensorFold model's page has a Context picker: TensorFold's default, the model's full trained window (the default
  for new models; 262k for Super VL), or YaRN ×2/×4 on the Qwen3.6 models, written into the start command's flags.
- **Data**: `~/Library/Application Support/Spark Control/` (`config.json`, `usage.jsonl`, `chats.json`).
