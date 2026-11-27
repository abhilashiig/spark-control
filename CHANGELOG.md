# Changelog

All notable user-facing changes. Versions follow [Semantic Versioning](https://semver.org).
New entries go under **Unreleased**; a release renames that section to the version and date.

## [Unreleased]

### Added
- Overview: a Shutdowns card lists recent shutdowns and flags forced ones (power cut or crash, no clean shutdown), with an All / Forced filter. It reads the Spark's own boot records, going back as far as Ubuntu keeps them.

### Changed
- Smart plug: after a shutdown, the plug now turns off only once its power meter shows the Spark drawing about 1 W, rechecking every 5 seconds, so power is no longer cut while the Spark is still shutting down. If it still draws more after 5 minutes, the plug stays on.

### Fixed
- Requests: the close button and the Request/JSON/Response/Headers tabs stay pinned while you scroll a request's detail, so a long conversation no longer hides them.
- Requests: on narrow windows the table scrolls sideways instead of clipping columns, so every column stays reachable. The detail panel keeps its 400 pt width while the table has room to shrink, and narrows to 320 pt only once the window runs out of space.

## [1.15.0] - 2026-11-26

### Added
- Qwen3.8 27B on vLLM: a Coding agent adapter switch on its page serves Harness Hub's super-adapter, a LoRA trained for coding agents such as pi, Hermes Agent and OpenCode. It's off by default, takes 4 GB more memory and decodes about half as fast. Already downloaded the model? Press Download once more to fetch the adapter (about 2 GB).
- Settings → Smart Plug (Optional): remote power-on for your DGX Spark using a local Wi-Fi smart plug (currently supports TP-Link Tapo/Kasa plugs on TPAP firmware with automatic LAN discovery, MAC-based DHCP recovery, macOS Keychain password storage, live reachability gating so Power On Spark is hidden when away without local access, running-Spark safety guard on manual Turn Off, automatic plug power-off 10 seconds after Spark disconnects on shutdown, and one-click Power On Spark from the sidebar and menu bar).

### Changed
- Models: each row shows the model's Model ID (the name clients use) instead of its backend model ID, and the side panel calls it Model ID. The panel no longer shows the backend's port and direct endpoint, which skipped the gateway; clients connect through API Access.
- The request detail on the Requests page now shows the conversation as readable messages (with the parameters and tool names above them); long messages collapse with Show All, and the raw body moved to a JSON tab that wraps instead of scrolling sideways.
- Request bodies up to 1 MB are kept instead of 64 KB, so long agent requests no longer show up as one unformatted line. Older requests keep their stats but drop their body once ~4 MB is in use.
- Spark Control is now open source under the BSD 3-Clause License. The name and logo stay trademarks (see TRADEMARKS.md).

### Fixed
- The API now answers only to a model's model ID (the one listed by /v1/models and shown on its page). It used to also accept a model's backend ID, so a request could go to a different model that shared it (for example a custom Qwen3.8 27B serving as `qwen3.8-27b`) and fail with "isn't running". Clients set to a backend ID or a model's display name should switch to its model ID.
- Open at Login stays on after an update. Each new version used to show it as off and drop the app from Login Items.
- Requests: a request body over 1 MB no longer shows as an empty box that scrolls forever. It shows the first 1 MB as text and says the rest wasn't kept.

## [1.14.0] - 2026-11-25

### Fixed
- Thinking level in Pi, Kilo Code and Hermes now reaches the model. Qwen3.8 models (and Arete) get their own low, medium or xhigh effort instead of always thinking at xhigh, Inkling gets every level, gpt-oss gets low, medium or high, and other models switch thinking on or off. Pi's config is updated on launch.
- Kilo Code, Pi and Hermes now know each model's context window, read from its context setting. Custom models whose window can't be read get 250K, or the Context Window set on their page.
- Arete 27B is recognised as a reasoning model, so Pi and Kilo Code offer its thinking levels and its page shows Thinking Effort.

### Added
- Thinking Effort on a reasoning model's page: the effort used when a request doesn't set one, such as Medium or Low for Qwen3.8 models that think too long, or Off.
- Pi and Kilo Code list each model's own thinking levels once each: Off, Low, Medium and X-High for Qwen3.8 models, Off through X-High for Inkling, Low to High for gpt-oss, and Off and On for the rest. Kilo gets these as its reasoning variants.
- Requests shows a thinking badge next to the model (Off, On, or the effort level) as the gateway sent it. It turns amber when thinking was off but the model reasoned anyway.

### Changed
- Shorter copy across the app: fewer captions and explanations, terser tooltips and buttons (Send Test, Open Config, Restore). API Access drops its intro, section notes and the Use in Snippet action.
- API Access is redesigned: pick This Mac or Another computer and a model, and the base URL and a curl, Python, JavaScript or .env snippet update to match. Send Test Request runs it and shows the reply. Kilo Code, Pi and Hermes each get a card with their sync status, Open Config and Restore Previous (puts back the file from before Spark Control changed it). The model list is a table with each model's ID, memory, type and status, plus Copy ID and Use in Snippet.
- The Ember theme is now Nebula, with a cool violet in place of orange, in both Appearance and the Terminal. If you chose Ember, you get Nebula automatically.

## [1.13.0] - 2026-11-24

### Changed
- New look: a darker graphite theme with light primary buttons. The sidebar shows the Spark as a card, lists running models with their memory, and keeps a memory meter, Settings and power at the foot. Models is now a table with Engine, Context, Speculative, Memory and Fit columns, a Start or Chat button on each row, and a memory bar split by model and system reserve. A model's page has stat cards (memory, 24h requests and tokens, benchmark) and tabs; Requests has filters, a latency bar per request and a detail panel with prefill and decode speed and Copy as cURL; Usage, Overview, Chat and the TensorFold, vLLM and ComfyUI catalogs follow the same look. API Access, Hugging Face, Ollama, SSH Keys, Wi-Fi and Settings use the same cards in place of the system's grouped forms. ⌘K jumps to any page or model.

### Added
- Settings → General → Appearance: Soft Light (light with the whites toned down) and Soft Dark (dark lifted to charcoal), between Light and Dark.
- Settings → General → Appearance: NVIDIA, a black theme with NVIDIA green buttons and highlights, square corners and uppercase titles.
- Terminal: an NVIDIA colour theme (black with an NVIDIA green cursor).
- Settings → General → Appearance: Ember, the NVIDIA theme's black, square look with orange in place of green. The Terminal has a matching Ember colour theme.
- Settings: Cap GPU Clock and Switch Models Automatically are the same on every Mac connected to the Spark. The GPU cap shows what's set on the Spark, and Switch Models Automatically is shared with the model list.
- Models: a Model's Own Sampling switch on each model's page (off by default). When on, the temperature, top_p, top_k, min_p and penalty values coding tools send are dropped, so the model runs with its maker's recommended defaults. Parameter Rules still apply on top.

### Changed
- TensorFold models with images accept up to 64 images in a conversation instead of 4, with a 65,536-token image budget so each image keeps about the same detail. Models already set up get the new limits too; a limit you set by hand is kept.

### Fixed
- Terminal: ⌘K clears the terminal again instead of opening Search or jump to.
- Settings: pop-up menus no longer show in light colours while a dark theme is chosen.
- Overview: the stat cards and the CPU cores and Temperatures cards fill the page width instead of leaving empty space on the right, the last time on each chart is no longer cut off, legends wrap evenly, and Docker image sizes read "102 GB" like the rest.
- Requests: Copy as cURL asks for the model by its API name, so the copied command works against Spark Control's API.
- TensorFold's Check for Updates says Up to Date (or Couldn't Check) instead of doing nothing visible.
- Set Up Spark (in Settings) can be cancelled and opens with your current Spark filled in.
- Starting a model, and everything else the app runs on the Spark, works when the Spark's login shell is zsh. It failed with "no matches found: /tmp/spark-control/start-…-*.log" even though the model had started.
- Activity: a streamed reply whose output arrived all at once (vLLM sends tool calls that way) shows "—" for TTFT and Decode instead of an impossible speed like 11,000 tok/s, and no longer skews the Decode and Prefill averages.
- vLLM models now report cached prompt tokens, so Cached and Prefill on the Activity page are real instead of always 0. Takes effect the next time each model starts.

## [1.12.1] - 2026-11-24

### Added
- vLLM: Inkling 2 Mini (Thinking Machines' 26B-A3B with images and a 1M-token window). No vLLM release serves it yet, so it runs on vLLM's own preview image: Download pulls that image (11 GB) along with the model, and Delete removes both. It doesn't need the vLLM install at the top of the page. Settings come from vLLM's DGX Spark recipe and haven't been measured here yet.

### Changed
- vLLM models started with a reasoning parser now count as reasoning models in Chat and the coding tools without flipping the toggle, and Inkling models count as taking images.
- vLLM models with a 1M-token window (Inkling 2 Mini, Nemotron 3.5 Lightning) offer a 524,288-token context too.
- Inkling 2 Mini: its MTP drafts setting offers only Off or 7 tokens, the one count its drafter accepts; other counts made it fail to start.
- Inkling 2 Mini: choosing a larger context raises its Memory to what that context needs (about 53 GB for 512k, 77 GB for 1M), so it no longer fails to start with "KV cache is needed, which is larger than the available KV cache memory". A model already set to a context that doesn't fit gets the extra memory the next time the app opens.

### Fixed
- TensorFold install and update no longer fail partway through the download with no reason. A failed request through the gateway, or a change in the Mac's network, closed the app's SSH connection to the Spark and killed the install with it; the connection is now kept while it still answers, and the Logs page says when it has to reconnect. Downloads also retry, and a failed install names the step that failed.
- Benchmark: the warm-up now covers the prompt sizes it measures, so a server compiling kernels on first use no longer shows up as a slow first prompt or a slow 1× concurrent row (one Inkling run read 422 t/s prefill there instead of about 2,400).

## [1.12.0] - 2026-11-18

The redesign is out of beta. This release includes everything in 1.12.0-beta.1, plus:

### Added
- Codebase indexing on the Spark: pull a small embedding model with Ollama (say `qwen3-embedding:0.6b`), then click Set Up next to Kilo Code indexing on the Connect page. Any model with "embed" in its name is offered, from a menu when there are several; it's added and turned on if needed. It replaces Kilo Code's indexing provider (after a warning if one is set) and turns indexing on for every workspace. Embedding models stay out of Chat and the coding tools' model lists.
- TensorFold: Arete 27B (Nous Research's fine-tune of Qwen3.8 27B), MLX 4-bit with images and the DFlash2 drafter.
- Settings → Spark: optionally cap the Spark's GPU clock at 2200 MHz (stock 3003) so it runs cooler and quieter. Off by default. Once on, it's checked every time the app connects and kept across reboots; turning it off removes the cap. Asks for your Spark password only if sudo needs one.

### Fixed
- The sidebar lists running models under Models again, as before the redesign; click one to open it.
- The sidebar can be resized again: drag its edge. The width is remembered.
- Chat: the model name no longer runs into the profile and effort buttons in a narrow window, and says "Spark unreachable" instead of promising to load the model while the Spark is offline.
- Chat list: a chat from six days ago shows its weekday like the rest of that day's chats, not its date.
- Ollama pulls and Hugging Face downloads now show their progress. A pull that was still running or had failed stopped the page from updating, so it looked like nothing was happening.
- Wi-Fi and SSH Keys show "Spark unreachable" centred on the page, like Terminal, instead of in a card.

### Changed
- Models added from Ollama work with a stock Ollama install: they use port 11434, Ollama's default, so they can run beside models on the Spark's model port, and start and stop through Ollama's API instead of `ollama-start` / `ollama-stop` shell commands. Installing Ollama from the app now opens it to your Mac on that port; an existing install needs `OLLAMA_HOST=0.0.0.0:11434` set for its service.
- Uses less memory: image thumbnails in Chat are kept small, and the Requests page keeps at most about 4 MB of request bodies (older requests drop off sooner when prompts are long).
- Less text on every page: explanations that repeated what the controls already show are gone, and the rest are shorter. Warnings that prevent surprises (gated models, slow first starts, what a delete removes) stay.

## [1.12.0-beta.1] - 2026-11-17

### Added
- Notifications when a model is running, stops, stops responding or fails to start; when a download (Hugging Face, Ollama or a catalog model) finishes or fails, even with its page closed; when an install or removal finishes; and when a benchmark finishes. They show while Spark Control isn't the app in front, and can be turned off in System Settings.
- Settings → General → Appearance: System (follows macOS's light or dark mode), Light or Dark.
- Chat: thinking effort per chat for reasoning models: Off (no thinking, fastest), Low, Medium or High (the model thinks as long as it needs, as before). Low and Medium cap how long it thinks, which is faster but can make hard answers less careful.
- Chat: Retry under a reply generates it again from the same question (handy after an error or a weak answer). Messages after it are replaced.

### Changed
- New look: a flat, light window with a sidebar showing the Spark and whether it's online, pages grouped under Engines, Monitor and Device, and API Access at the foot. Every page has a simple title bar with its controls; Settings is in the menu under the Spark's name. "Spark" is now called Overview and "Connect" is API Access.
- Models is now a list of what's loaded and the rest of your library, with a memory bar and a details panel. The panel loads, stops or opens the model in Chat, and before loading shows how much memory it needs and which models it would unload. Settings and benchmarks open from the panel's Settings link or by double-clicking a model.
- Chat: search your chats; the model and whether it's loaded sit at the top of the conversation, and the message box says what sending will load and unload. Chat statistics, Show Chat Files and deleting chats are in the conversation's More (…) menu.
- TensorFold, vLLM and ComfyUI pages: each engine leads with its install button, and its models are listed with their size, a Download button, and Add to Models once downloaded.
- The app now notices when the Spark goes away (shut down or off the network) and shows it as unreachable, instead of showing "No model running".
- Menu bar: when the Spark is offline or a model fails, the icon stays the Spark Control bolt with a small warning badge instead of switching to a generic warning triangle.

## [1.11.0] - 2026-11-16

### Added
- Chat page: ⌘- or ⇧-click several chats and delete them together (right-click or the Delete key), delete all chats from the toolbar's More menu, and open the folder holding your chats and their attachments in Finder.
- Wi-Fi page: see the networks the Spark's Wi-Fi can reach, with signal, security and which ones it has saved, and switch it to another. When you reach the Spark over its Wi-Fi (directly or over Tailscale), you're told first how you could lose access: the new network has to be one this Mac joins too, or have internet access for Tailscale. If the Spark can't join the new network, it goes back to the one it was on. The Spark only lets you scan for networks over SSH with your password, so without it the list is from the Spark's last scan, and Scan with Password… gets a fresh one.

### Changed
- A model's API model name is fixed once it's added or first started, so renaming the model no longer changes the name your clients and chats use. Models you already have keep their current API name. To get a different one, add the model again.
- TensorFold and vLLM models show their backend model ID read-only: it's the name their start command serves.

### Fixed
- A TensorFold or vLLM model whose backend model ID didn't match the name its start command serves (for example after switching a model from vLLM to TensorFold) no longer sits at "Starting" until it times out. The ID now follows the start command, so the model is ready as soon as it loads.

## [1.10.0] - 2026-11-15

### Added
- Hugging Face page: everything in the Spark's Hugging Face cache with its size, whoever downloaded it, plus what's downloading now and what a running model is using. Delete a model you no longer need: one that's serving or downloading can't be deleted, and models in Spark Control that use it are named first.
- Hugging Face page: search Hugging Face's models from the toolbar, with each repo's download size, popularity and whether it's gated, and download one onto the Spark with progress. Downloads keep going if the Mac sleeps, can be cancelled, and are refused when the repo is bigger than the Spark's free disk.
- Hugging Face page: Clean Up removes the partial files that interrupted downloads leave behind, even after a later download finished, without touching the model itself.
- Hugging Face page: install the `hf` tool on the Spark with one click (no sudo), and sign the Spark in to Hugging Face with an access token, or sign it out, so gated models download. The token is checked with Hugging Face first and isn't kept on your Mac.
- Ollama: search ollama.com from the Ollama page and pull models onto the Spark, with progress. Each model lists every size it comes in, and Fits in Memory (on by default) shows only the sizes that fit in the Spark's memory. Turn it off to see them all.
- Ollama: install Ollama on the Spark from the Ollama page. It asks for your Spark password for sudo if needed and doesn't keep it.

### Fixed
- TensorFold: Qwen3.8 27B finds weights you downloaded under the repo's old name, Vontra/Qwen3.8-27B-MLX-4bit, instead of downloading 16 GB again. Download (or Resume) links the new name to that folder and leaves the folder as it is, so scripts that use the old name keep working. Deleting the model from TensorFold never deletes those files.
- Deleting a model downloaded with a recent `hf` (2.x) now frees its disk space. These keep their files in a store shared between models, which deleting the model's folder left behind.
- TensorFold: models downloaded with `hf` (Qwen3.8 27B Uncensored) no longer go missing from `hf cache ls` and `hf cache rm`.
- Chat: the chat list can be resized again by dragging its edge (lost in 1.9.3), remembers its width, and narrows with the window instead of holding the window wide.

## [1.9.3] - 2026-11-15

### Added
- TensorFold: Update now shows the release notes of every version between the installed one and the update before you confirm, so you can decide whether to update.
- vLLM: Qwen3.8 27B Uncensored (orcarouter's abliterated NVFP4 + FP8 build, with images and MTP). It's gated on Hugging Face: accept its terms and run `hf auth login` on the Spark before downloading.
- TensorFold: Qwen3.8 27B Uncensored (orcarouter's abliterated MLX 4-bit) with images and the DFlash2 drafter, the fastest way to run it on a Spark: about 70 tok/s on code and 29 on prose measured with its NVFP4 sibling, against 21 and 16 under vLLM, and more expected from the 4-bit weights. It downloads only the 4-bit weights (16 GB of the repo's 94 GB) and needs the Spark's `hf` tool.
- vLLM: Qwen3.8 27B Uncensored serves 8 requests at once instead of 4: about 150 tok/s in all on code and 111 on prose with 8 clients on a Spark, against a cap at 4 before. A single request runs as before. Already-added copies pick this up at their next start.

### Fixed
- Chat: the chat list keeps its width when you switch chats instead of jumping between wide and narrow.
- vLLM: Qwen3.8 27B Uncensored no longer fails to start with "Error in memory profiling" when the Spark's free memory changes during start-up (another model stopping, the page cache shrinking). Its context memory now has a fixed size, sized from the Memory setting, so vLLM skips that check.
- Starting a model again while an earlier start was still running no longer shows the new start as failed ("exited with code 137"): each start now has its own log.
- Engines: a model counts as downloaded only while every repo it needs is on the Spark, so a drafter added to a model later shows as still to download instead of failing at start.
- vLLM: downloads now use the Spark's Hugging Face login (`hf auth login`), so gated models download instead of failing with "Access denied … requires approval".
- vLLM: a model that fails to start now shows as failed within seconds; before, it stayed on "Starting…" until the startup timeout (40 minutes by default).
- Engines: a failed download now shows the actual error instead of a Hugging Face hint line, and a gated model explains how to get access, with a link to its page.

## [1.9.2] - 2026-11-14

### Fixed
- TensorFold: Qwen3.8 27B now starts with image input. It ships a vision encoder but was started text-only, so images sent to it were refused. Models already added pick it up at their next start.
- TensorFold: the Image input toggle now adds or removes --vision in the start command, so the model actually serves images; before, it only changed what coding tools were told.
- Chat: sending images to a model that doesn't take them now explains how to turn Image input on, instead of failing with the server's error.
- TensorFold: image models no longer refuse JPEG images with "libturbojpeg.so.0 is required". Installing or updating TensorFold now adds the libjpeg-turbo 3.1.4.1 library it needs, checked against its published SHA-256 and kept inside the engine's folder, with no sudo needed. If TensorFold is already installed, use Add JPEG Support on the TensorFold page.

## [1.9.1] - 2026-11-14

### Added
- TensorFold: when a newer stable TensorFold release is out, the engine row offers to update to it. The update is checked against TensorFold's signing key and test-run on the Spark before it replaces the installed version; if anything fails, the installed version stays as it was. Running models keep their version until restarted.
- TensorFold: after an update, Switch Back returns to the version you had before.

### Fixed
- Terminal: opening the page while the app was still connecting to the Spark no longer leaves it empty; the first shell opens as soon as the Spark is reachable.

### Changed
- First-run setup no longer comes filled in with an example hostname and user; enter your own Spark's.

## [1.9.0] - 2026-11-13

### Added
- Terminal: the usual Terminal.app shortcuts while a shell has the keyboard: ⌘T new tab, ⌘W close tab, ⌘1–9, ⌘⇧[ ⌘⇧] and ⌃Tab to switch tabs, ⌘K to clear, and ⌘+ ⌘− ⌘0 for text size (remembered). Copy, paste and Select All work as before.

### Fixed
- Terminal: a colour theme no longer tints the sidebar and the rest of the window.

## [1.8.0] - 2026-11-13

### Added
- Spark: a DGX Dashboard button opens NVIDIA's DGX Dashboard in your browser through an SSH tunnel, so you don't have to set one up yourself.
- SSH Keys page: lists every key that can log in to the Spark as you, with when and from where each last logged in, so you can remove any you don't recognise. This Mac's own key is marked and can't be removed, and a backup of the keys file is kept on the Spark.
- Terminal page: shells on the Spark in tabs (⌘T for a new one), with full colour, mouse and resizing so tools like vim, htop and tmux work. Tabs stay open while you use other pages. Pick a colour theme from the toolbar: System (follows light and dark mode), Solarized Dark, Solarized Light, Dracula or Nord.

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
