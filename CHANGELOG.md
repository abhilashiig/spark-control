# Changelog

All notable user-facing changes. Versions follow [Semantic Versioning](https://semver.org).
New entries go under **Unreleased**; a release renames that section to the version and date.

## [Unreleased]

### Added
- Several models can run at once. A model starts beside the running ones when its port is free and its memory
  need fits in the Spark's free memory (keeping 12 GB for the system); otherwise the least recently used model,
  ComfyUI included, stops first and a warning says what was stopped. Each model's page has a Memory needed field;
  it's measured on first start when not set, and for vLLM it sets the container's memory share (now about 50 GB
  per model instead of 85% of the Spark). New catalog models get their own port, vLLM models their own container,
  and TensorFold's stop command stops only its own server.
- Models page: your models and every catalog model (TensorFold, vLLM and ComfyUI image models) in one list,
  grouped Running, On Spark and Available to Download, with Text/Image filters and search. Start, stop,
  download and open from the list; a downloaded catalog model starts in one click. The sidebar lists only
  running models under it.
- Spark page (sidebar → Activity): live memory, CPU, GPU, power and temperatures with five-minute history
  charts, memory per process (ComfyUI, vLLM, TensorFold…), per-core load, and storage with what the model
  caches and Docker images take. The menu bar shows memory, GPU load and temperature.
- vLLM engine, next to TensorFold and Ollama under Engines in the sidebar: installs the official vLLM image (pinned by digest) with Docker and serves NVFP4
  models whose MTP head drafts tokens: Qwen3.6 35B-A3B, Qwen3.8 27B, Nemotron 3.5 Lightning,
  Nemotron 3 Super and Gemma 4 26B-A4B. Each model's page picks the context and MTP drafts (Off, 1, 2, 3),
  starting from the value that measured fastest on a Spark.
- ComfyUI engine for image generation: installs ComfyUI with PyTorch for CUDA 13.0 on the Spark (no sudo),
  downloads Z-Image-Turbo onto the Spark, and opens ComfyUI in this Mac's browser through an SSH tunnel; it
  listens only on the Spark, so it isn't reachable from the network. Starting it stops the running model,
  and starting a model stops it.
- ComfyUI starter models open straight to their workflow. Added Qwen-Image-Edit-2511 (about 31 GB) for editing
  an image from an instruction.

## [1.0.0] - 2026-11-12

### Added
- Native macOS app that starts and stops models on a DGX Spark over SSH and serves them through one
  OpenAI-compatible API at `http://localhost:18080/v1`.
- Built-in chat with image, PDF and text attachments.
- Usage and speed statistics (tokens, cache hit rate, time to first token, prefill/decode speed) over
  4h / 24h / week / month / year / all.
- Per-model Spark ports.
- TensorFold catalog: install TensorFold, download tested models with their drafters, pick context length.
- Catalog shows models already on the Spark and partial downloads.
- Benchmarks.
- Release DMGs built by GitHub Actions when a version tag is pushed.
