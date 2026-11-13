# Changelog

All notable user-facing changes. Versions follow [Semantic Versioning](https://semver.org).
New entries go under **Unreleased**; a release renames that section to the version and date.

## [Unreleased]

### Added
- Spark: a DGX Dashboard button opens NVIDIA's DGX Dashboard in your browser through an SSH tunnel, so you don't have to set one up yourself.
- SSH Keys page: lists every key that can log in to the Spark as you, with when and from where each last logged in, so you can remove any you don't recognise. This Mac's own key is marked and can't be removed, and a backup of the keys file is kept on the Spark.
- Terminal page: shells on the Spark in tabs (⌘T for a new one), with full colour, mouse and resizing so tools like vim, htop and tmux work. Tabs stay open while you use other pages. Pick a colour theme from the toolbar: System (follows light and dark mode), Solarized Dark, Solarized Light, Dracula or Nord.

### Fixed
- SSH Keys: keys show right away and each one's last login fills in a moment later, instead of the page loading for 20 seconds or more, and no longer says "Spark unreachable" when loading took too long.

## [1.7.0] - 2026-11-13

### Added
- Chat: paste images (⌘V), such as screenshots copied to the clipboard, or files copied in Finder, to attach them.

### Fixed
- Ollama: a running Ollama with no model loaded (for example while downloading one) no longer shows an Ollama model as running, so stopping or switching models can no longer stop Ollama mid-download.
- Models: the window no longer breaks (blank model list, sidebar pushed under the toolbar) when starting a model stops another one.
- Spark charts: time labels no longer pile on top of each other and the charts always show the last five minutes instead of rescaling as readings arrive. The CPU Cores and Temperatures cards are now the same height.

## [1.6.0] - 2026-11-12

### Added
- Chat: a new chat is titled by its model from your first message. Your question is shown as the title until then.
- Requests: search by model, client, endpoint, status or error.

### Changed
- The menu bar icon is the new bolt in black and white, filled while a model runs.
- A fresh look matching the iPhone app: rounded cards on a soft background, colourful model avatars with live status, coloured engine badges and sidebar icons, a redesigned Spark dashboard, and chat with avatars, gradient bubbles and a floating composer.

## [1.5.0] - 2026-11-12

### Changed
- Chat: scanned PDFs (no selectable text) are attached as one image per page, up to 20 pages, instead of failing. The model needs image input to read them.
- New app icon: a glowing green bolt on dark glass.

## [1.4.0] - 2026-11-12

### Added
- The app's version is shown in Settings → General and next to Quit in the menu bar.

### Changed
- Commands to the Spark share one SSH connection instead of logging in each time: about 0.2 s per command instead of 0.6 s, and the Spark no longer records a new login every few seconds. It's reopened after a network change.

## [1.3.0] - 2026-11-12

### Added
- Connect → Coding Tools adds Spark Control as a provider to Kilo Code, Pi and Hermes with one click, listing your enabled models with their prices and whether each reasons and takes images. Kilo Code is set up to show each request's cost. Tools you've added are kept up to date as models change (can be turned off); the previous config is kept as a `.spark-control.bak` file.
- Requests and Usage show which app sent each request: Kilo Code, Pi, Hermes (set up from Coding Tools) and Chat by name, any other app by the name it sends (X-Title or its User-Agent). Usage has a By Client breakdown.
- Chat: edit a message you sent (hover it and click the pencil, or right-click → Edit). Save & Resend replaces the replies after it.
- Chat: hover the gauge at the top for the chat's stats: context used (of the model's window when known), decode and prefill speed, time to first token, tokens, cache hit rate and cost.
- Chat profiles: each chat uses a profile with its own system prompt, picked from the menu at the top of the chat. Comes with Casual, Abliterated, Mathematics, Coding and Legal; add, edit, reorder, delete or restore them under Edit Profiles…. A chat's own instructions are sent after its profile's prompt. Profiles are kept on the Spark with the model list, so every Mac using it shares them.
- Each model's page has Reasoning and Image input switches, guessed from the model until you set them.

### Fixed
- Chat: Shift-Return (or Option-Return) adds a new line; Return sends.

### Changed
- `/v1/models` lists prices in OpenRouter's format (USD per token) plus each model's input types and reasoning support, so clients like Hermes can price requests.

## [1.2.1] - 2026-11-12

### Changed
- Models page lists only the models you've added to Spark Control. Downloaded but not-added models and image models stay on their engine's page, so the Text/Image filter is gone.

### Removed
- Qwen3.6 35B-A3B NVFP4 from the TensorFold list: TensorFold can't run it. It's still available under vLLM.

## [1.2.0] - 2026-11-12

### Added
- Models table sorts by any column (click its header), and remembers the choice.

### Fixed
- Models page: on a large or full-screen window the sidebar and page no longer get cut off at the top and bottom.

### Changed
- Models table: Start and Stop are round green and red buttons, so they read as buttons.
- The menu bar icon is the new app icon's dial and spark in black and white, following the menu bar's colour. The spark is filled while a model runs.

## [1.1.0] - 2026-11-12

### Added
- New app icon: an amber spark in a dial on midnight indigo.
- Several models can run at once. A model starts beside the running ones when its port is free and its memory
  need fits in the Spark's free memory (keeping 12 GB for the system); otherwise the least recently used model,
  ComfyUI included, stops first and a warning says what was stopped. Each model's page has a Memory needed field;
  it's measured on first start when not set, and for vLLM it sets the container's memory share (now about 50 GB
  per model instead of 85% of the Spark). New catalog models get their own port, vLLM models their own container,
  and TensorFold's stop command stops only its own server.
- Your models and each one's settings (context, MTP drafts, memory, prices, parameter rules…) are kept on the
  Spark in `~/.config/spark-control/models.json`, so every Mac running Spark Control sees the same list.
  A Mac connecting for the first time takes the Spark's list and adds any models of its own; after that the
  most recent change wins.
- Models page: a table of every model on the Spark, showing engine, status, context, drafts, memory, size on
  disk and port, with Text/Image filters and search. Start and stop from the table, double-click for a model's
  settings (or click the ⓘ next to its name), and a downloaded catalog model starts in one click. New models are downloaded from each engine's
  page, linked below the table with a short guide to picking one and to adding your own custom models. The sidebar lists only running models under it.
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

### Changed
- Shut Down Spark… moved from Settings to the foot of the sidebar, apart from everything else, still with a confirmation.
- Connect is now the last item in the sidebar.

### Fixed
- A model added with + and left without a start command is no longer saved; it's dropped when you leave its page.


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
