# Spark Control

Native macOS app that runs models on a DGX Spark and serves them through one
OpenAI-compatible API at `http://localhost:18080/v1`. Nothing is installed on the Spark:
the app starts and stops models over SSH and forwards requests to the Spark's port 18300.

## Build & run

```bash
./build-app.sh --install   # builds, copies to /Applications and launches it
./build-app.sh --open      # builds build/Spark Control.app and launches it from there
./Tests/run.sh             # self-check for request rewriting, pricing, routes
```

Needs only Xcode Command Line Tools.

## One-time: key-based SSH

The app can't type passwords, so the Spark must accept your SSH key:

```bash
ssh-keygen -t ed25519            # skip if ~/.ssh/id_ed25519 exists
ssh-copy-id abhi@aitopatom-049b.local
```

## How it works

- **Recipes**: each model is a start command, a stop command, a backend model ID, and prices.
  Commands run via `bash -ic` on the Spark, so your aliases (`qwen-start`, `laguna-start`, …) work.
  Start output is written to `/tmp/spark-control/start.log` on the Spark and streamed into Logs.
- **Ready check**: polls `:18300/v1/models` (and Ollama's `/api/ps`) until the model appears.
- **Routes**: Local = `<host>.local`, Tailscale = `<host>`. Automatic prefers local.
- **API**: requests pass through untouched, except the model name is renamed to the backend ID, plus any
  per-model parameter rules you set. A request for a stopped model switches to it (configurable).
  Responses get `usage.cost` from the model's prices (toggle in Settings → API).
- **Data**: `~/Library/Application Support/Spark Control/` (`config.json`, `usage.jsonl`).
