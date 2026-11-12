// Self-check for request/response rewriting. Run: ./Tests/run.sh
import Foundation

func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { print("FAIL line \(line): \(what)"); exit(1) }
}

let recipe = Recipe(
    name: "Qwen3.8 Flash", startCommand: "qwen-start", stopCommand: "qwen-stop",
    upstreamModel: "Qwen/Qwen3.8-Flash", priceIn: 0.5, priceOut: 2,
    rules: [
        ParamRule(key: "temperature", kind: .default, value: "0.6"),
        ParamRule(key: "max_tokens", kind: .override, value: "8192"),
        ParamRule(key: "seed", kind: .remove),
        ParamRule(key: "chat_template_kwargs", kind: .override, value: #"{"enable_thinking": false}"#),
    ]
)
let plain = Recipe(name: "x", startCommand: "", stopCommand: "", upstreamModel: "x")

// Rules + model rewrite
var body: [String: Any] = ["model": "qwen3.8-flash", "temperature": 0.9, "max_tokens": 100, "seed": 1, "top_k": 20]
check(!Transform.apply(&body, recipe: recipe, path: "/v1/chat/completions", streamUsage: true).isEmpty, "rules report a change")
check(body["model"] as? String == "Qwen/Qwen3.8-Flash", "model renamed to backend ID")
check(body["temperature"] as? Double == 0.9, "default doesn't overwrite a client value")
check(body["max_tokens"] as? Int == 8192, "override replaces")
check(body["seed"] == nil, "remove strips")
check(body["top_k"] as? Int == 20, "unknown params pass through")
check((body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false, "JSON values parse")
check(body["stream_options"] == nil, "no stream options for non-streaming")
check(recipe.apiID == "qwen3.8-flash" && recipe.answers(to: "Qwen/Qwen3.8-Flash"), "api id + upstream match")

// Untouched without rules
var untouched: [String: Any] = ["model": "x", "foo": [1, 2]]
check(Transform.apply(&untouched, recipe: plain, path: "/v1/chat/completions", streamUsage: false).isEmpty, "no rules → unchanged")

// Streaming usage
var stream: [String: Any] = ["model": "x", "stream": true]
check(!Transform.apply(&stream, recipe: plain, path: "/v1/chat/completions", streamUsage: true).isEmpty, "stream usage requested")
check((stream["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true, "include_usage set")
var optedOut: [String: Any] = ["model": "x", "stream": true, "stream_options": ["include_usage": false]]
check(Transform.apply(&optedOut, recipe: plain, path: "/v1/chat/completions", streamUsage: true).isEmpty, "client's choice respected")

// SSE cost injection
let line = Data(#"data: {"id":"1","choices":[],"usage":{"prompt_tokens":1000000,"completion_tokens":500000}}\#n"#.utf8)
let (out, usage) = Transform.sseLine(line, recipe: recipe, inject: true)
check(usage?.prompt == 1_000_000 && usage?.completion == 500_000, "usage parsed")
let obj = (try? JSONSerialization.jsonObject(with: out.dropFirst(6))) as? [String: Any]
check((obj?["usage"] as? [String: Any])?["cost"] as? Double == 1.5, "cost = 1M×$0.5 + 0.5M×$2")
let chunk = Data(#"data: {"choices":[{"delta":{"content":"hi"}}],"usage":null}\#n"#.utf8)
check(Transform.sseLine(chunk, recipe: recipe, inject: true).line == chunk, "token chunks untouched")

// Cache-read pricing: cached prompt tokens at the cache price, the rest at input
var flash = recipe; flash.priceIn = 0.15; flash.priceOut = 0.47; flash.priceCache = 0.016
let cachedLine = Data(#"data: {"choices":[],"usage":{"prompt_tokens":1000000,"completion_tokens":1000000,"prompt_tokens_details":{"cached_tokens":500000}}}\#n"#.utf8)
let (cachedOut, cachedUsage) = Transform.sseLine(cachedLine, recipe: flash, inject: true)
check(cachedUsage?.cached == 500_000, "cached tokens parsed")
let reasoningUsage = Transform.usage(["usage": ["prompt_tokens": 10, "completion_tokens": 63, "completion_tokens_details": ["reasoning_tokens": 17]]])
check(reasoningUsage?.reasoning == 17 && reasoningUsage?.completion == 63, "reasoning tokens parsed (Kilo: Out 46 + Reason 17)")
let cachedCost = (((try? JSONSerialization.jsonObject(with: cachedOut.dropFirst(6))) as? [String: Any])?["usage"] as? [String: Any])?["cost"] as? Double ?? -1
check(abs(cachedCost - (0.075 + 0.008 + 0.47)) < 1e-9, "cost = 0.5M×$0.15 + 0.5M×$0.016 + 1M×$0.47, got \(cachedCost)")
var noCachePrice = flash; noCachePrice.priceCache = nil
check(abs(Transform.cost((1_000_000, 0, 400_000, 0), noCachePrice) - 0.15) < 1e-9, "no cache price → input price")

// Rebuild keeps untouched fields byte-for-byte (key order inside tools/messages drives the prompt cache)
let original = Data(#"{"model":"qwen3.8-flash", "tools":[{"z":1,"a":{"y":"\"q\"","b":[1,{"k":2}]}}],"messages":[{"role":"user","content":"a, b } ]"}],"seed":3,"temperature":0.7}"#.utf8)
var parsed = (try! JSONSerialization.jsonObject(with: original)) as! [String: Any]
let changed = Transform.apply(&parsed, recipe: recipe, path: "/v1/chat/completions", streamUsage: true)
let rebuilt = String(decoding: Transform.rebuild(original, parsed, changed: changed)!, as: UTF8.self)
check(rebuilt.hasPrefix(#"{"model":"Qwen/Qwen3.8-Flash","tools":[{"z":1,"a":{"y":"\"q\"","b":[1,{"k":2}]}}],"messages":[{"role":"user","content":"a, b } ]"}],"temperature":0.7,"#), "untouched bytes kept in order, got \(rebuilt)")
check(!rebuilt.contains("seed") && rebuilt.contains(#""max_tokens":8192"#), "rule changes applied")
check((try? JSONSerialization.jsonObject(with: Data(rebuilt.utf8))) != nil, "rebuilt body is valid JSON")
check(Transform.topLevelMembers([UInt8](#"{"a":1,}"#.utf8)) == nil && Transform.topLevelMembers([UInt8]("[1]".utf8)) == nil, "malformed rejected")

// Re-serialization keeps float values exact
let floats = try! JSONSerialization.jsonObject(with: Data(#"{"temperature":0.7,"top_p":0.95}"#.utf8))
let reObj = (try! JSONSerialization.jsonObject(with: Transform.serialize(floats)!)) as! [String: Any]
let re = String(decoding: Transform.serialize(floats)!, as: UTF8.self)
check(re.contains("0.7") && !re.contains("0.69") && reObj["top_p"] as? Double == 0.95, "floats round-trip, got \(re)")

// Ollama names
check(Transform.ollamaName(manifestPath: "/home/abhi/.ollama/models/manifests/registry.ollama.ai/library/qwen35-abl/latest") == "qwen35-abl:latest", "library name")
check(Transform.ollamaName(manifestPath: "/x/manifests/hf.co/mradermacher/Laguna-S-2.1-Uncensored-i1-GGUF/i1-Q4_K_M")
      == "hf.co/mradermacher/Laguna-S-2.1-Uncensored-i1-GGUF:i1-Q4_K_M", "hf name")
check(Transform.norm("qwen35-abl:latest") == "qwen35-abl", ":latest normalized")

// Routes
let d = Device(baseHost: "aitopatom-049b.local")
check(d.host(.tailscale) == "aitopatom-049b", "tailscale never has .local")
check(d.host(.local) == "aitopatom-049b.local", "local adds .local")
check(Probe.isTailscale("100.101.12.3") && !Probe.isTailscale("192.168.1.20"), "tailscale IP range")

// First-token detection for TTFT: role-only and empty chunks don't count
func sse(_ json: String) -> Data { Data(("data: " + json + "\n").utf8) }
check(!Transform.isTokenChunk(sse(#"{"choices":[{"delta":{"role":"assistant","content":""}}]}"#)), "role chunk isn't a token")
check(Transform.isTokenChunk(sse(#"{"choices":[{"delta":{"reasoning_content":"Hm"}}]}"#)), "reasoning counts as first token")
check(Transform.isTokenChunk(sse(#"{"choices":[{"delta":{"content":"Hi"}}]}"#)), "content counts")
check(Transform.isTokenChunk(sse(#"{"choices":[{"delta":{"tool_calls":[{"index":0}]}}]}"#)), "tool call counts")
check(!Transform.isTokenChunk(sse(#"{"choices":[],"usage":{"prompt_tokens":1}}"#)) && !Transform.isTokenChunk(Data("data: [DONE]\n".utf8)), "usage/DONE aren't tokens")

// Speeds
check(Speed.decode(completion: 101, decodeTime: 2) == 50, "decode = (101-1)/2s")
check(Speed.prefill(prompt: 20_000, cached: 19_200, ttft: 0.4) == 2000, "prefill = uncached/ttft")
check(Speed.prefill(prompt: 100, cached: 100, ttft: 0.2) == nil && Speed.decode(completion: 1, decodeTime: 1) == nil, "no speed without work")

// Per-model port
check(d.backendBase(.local) == "http://aitopatom-049b.local:18300" && d.backendBase(.tailscale, port: 8000) == "http://aitopatom-049b:8000", "per-model port")

// TensorFold catalog and commands
let tfIDs = TensorFold.catalog.map(\.id)
check(Set(tfIDs).count == tfIDs.count, "catalog ids are unique")
check(TensorFold.catalog.allSatisfy { m in ([m.repo] + (m.drafter.map { [$0] } ?? [])).allSatisfy { $0.revision.map { $0.count == 40 } ?? true } },
      "pinned revisions are full commit hashes")
let q27 = TensorFold.model("qwen3.8-27b")!, q36 = TensorFold.model("qwen3.6-35b-a3b-nvfp4")!
let q27Start = TensorFold.startCommand(q27, binary: TensorFold.managedBinary, port: 18300)
check(q27Start.contains("--drafter z-lab/Qwen3.8-27B-DFlash2") && q27Start.contains("--port 18300") && q27Start.contains("--api-key-file"),
      "drafter, port and key are always passed")
check(q27.downloads.count == 2 && q36.downloads.count == 1 && TensorFold.startCommand(q36, binary: "tf", port: 1).contains("--drafter nvidia/Qwen3.6-35B-A3B-NVFP4"),
      "a separate drafter is downloaded; a self-drafter is only a flag")
check(TensorFold.downloadScript(q27, binary: "tf").contains(#"pull '\''TensorFold/Qwen3.8-27B-MLX-4bit'\'' && "$TF" pull '\''z-lab/Qwen3.8-27B-DFlash2'\'' && touch"#),
      "model and drafter download as one job, marked done only when both finish")

func bash(_ script: String, env: [String: String] = [:], syntaxOnly: Bool = false) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = (syntaxOnly ? ["-n"] : []) + ["-c", script]
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try! p.run()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}
for (name, s) in [("status", TensorFold.statusScript()), ("install", TensorFold.installScript()),
                  ("uninstall", TensorFold.uninstallScript(models: TensorFold.catalog)), ("download", TensorFold.downloadScript(q27, binary: "tf")),
                  ("cancel", TensorFold.cancelScript(q27.id)), ("delete", TensorFold.deleteScript(q27)), ("key", TensorFold.apiKeyScript),
                  ("stop", TensorFold.stopCommand), ("manual", TensorFold.manualSteps)] {
    let (code, out) = bash(s, syntaxOnly: true)
    check(code == 0, "\(name) script parses: \(out)")
}
check(TensorFold.installScript().contains("\nMCowBQYDK2VwAyEA80FFo6a9/NXHNX9zBV3/2tM9AbC//mShbseG74mkkGw=\n-----END PUBLIC KEY-----\nKEY\n"),
      "public key heredoc is unindented")

// Status script against a fake Spark home: done, downloading, failed, absent.
let home = FileManager.default.temporaryDirectory.appending(path: "tf-selfcheck-\(getpid())")
let data = home.appending(path: ".local/share/spark-control/tensorfold-data")
try! FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
try! Data().write(to: data.appending(path: "qwen3.5-2b.ok"))
try! Data("› downloading 40%\r› downloading 41%\n".utf8).write(to: data.appending(path: "gemma-4-31b.log"))
try! Data("\(getpid())".utf8).write(to: data.appending(path: "gemma-4-31b.pid"))
try! Data("error: 404\n".utf8).write(to: data.appending(path: "kolibri-1.log"))
let (code, statusOut) = bash(TensorFold.statusScript(), env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
try? FileManager.default.removeItem(at: home)
let st = TensorFold.parseStatus(statusOut)
check(code == 0 && st.engine == .none && st.freeBytes != nil, "status reads engine and free space: \(statusOut)")
check(st.models["qwen3.5-2b"]?.download == .done && st.models["kolibri-1"]?.download == .failed
      && st.models["kolibri-1"]?.message == "error: 404" && st.models["qwen3.8-27b"]?.download == TensorFold.Download.none,
      "download states from markers")
check(st.models["gemma-4-31b"]?.download == .running && st.models["gemma-4-31b"]?.message == "› downloading 41%", "running download shows its last progress line")
check(TensorFold.parseStatus("ENGINE|user|/opt/tf/bin/tensorfold-native|tensorfold 1.2.6\n").engine == .user(path: "/opt/tf/bin/tensorfold-native", version: "tensorfold 1.2.6"),
      "user install detected")

let q36mlx = TensorFold.model("qwen3.6-35b-a3b")!
check(TensorFold.startCommand(q36mlx, binary: "tf", port: 1).contains("--drafter TensorFold/Qwen3.6-35B-A3B-MLX-4bit-MTP") && q36mlx.downloads.count == 1,
      "Qwen3.6 MLX names its own checkpoint as drafter, so CUDA drafts with MTP")
check(TensorFold.addingDrafter(to: "tf serve x", model: "qwen3.6-35b-a3b") == "tf serve x --drafter TensorFold/Qwen3.6-35B-A3B-MLX-4bit-MTP"
      && TensorFold.addingDrafter(to: "tf serve x --drafter y", model: "qwen3.6-35b-a3b") == "tf serve x --drafter y"
      && TensorFold.addingDrafter(to: "qwen-start", model: nil) == "qwen-start", "saved commands gain a missing drafter once, others untouched")

// Context and YaRN
let q36Start = TensorFold.startCommand(q36mlx, binary: "tf", port: 1)
check(q36Start.hasSuffix(" --context 262144") && TensorFold.context(of: q36Start) == .window(262_144), "new models start with their full window")
check(TensorFold.startCommand(TensorFold.model("nemotron-3.5-super-vl")!, binary: "tf", port: 1).hasSuffix(" --context 262144")
      && TensorFold.startCommand(TensorFold.model("lfm2.5-24b-a2b")!, binary: "tf", port: 1).hasSuffix(" --context 131072"),
      "Super VL starts at 262k, LFM at its 131k window")
let yarnCmd = TensorFold.withContext(q36Start, .yarn(4), model: q36mlx)
check(yarnCmd.hasSuffix(" --drafter TensorFold/Qwen3.6-35B-A3B-MLX-4bit-MTP --rope-yarn 4 --context 1048576") && TensorFold.context(of: yarnCmd) == .yarn(4),
      "YaRN x4 replaces the window flag and serves 4x the trained window")
check(TensorFold.withContext(yarnCmd, .engineDefault, model: q36mlx) == q36Start.replacingOccurrences(of: " --context 262144", with: ""),
      "engine default drops both flags and keeps the rest")
check(TensorFold.context(of: "tf serve x --context=65536 --drafter y") == .window(65536), "--context=N is read too")
check(TensorFold.contextOptions(TensorFold.model("gemma-4-31b")!) == [.engineDefault, .window(262_144)]
      && TensorFold.contextOptions(TensorFold.model("nemotron-3.5-super-vl")!) == [.engineDefault, .window(262_144), .window(1_048_576)]
      && TensorFold.contextOptions(q36mlx).contains(.yarn(4)), "YaRN only where TensorFold supports it")

// Drafts toggle
let off = TensorFold.withDrafts(q36Start, false)
check(TensorFold.draftsOn(q36Start) && !TensorFold.draftsOn(off) && off.contains("--drafter ") && TensorFold.withDrafts(off, true) == q36Start
      && TensorFold.withDrafts(off, false) == off, "drafts off adds --no-drafts once and keeps the drafter; on removes it")
check(q36mlx.drafts == "MTP" && q27.drafts == "DFlash drafter" && TensorFold.model("lfm2.5-24b-a2b")!.drafts == nil
      && TensorFold.model("qwen3.6-35b-a3b-nvfp4")!.drafts == "MTP", "draft source per model")

let fnNvfp4 = TensorFold.model("qwen3.8-flash-next-nvfp4")!
check(fnNvfp4.untested && fnNvfp4.drafts == "MTP" && !fnNvfp4.yarn && fnNvfp4.downloads.map(\.spec) == ["nvidia/Qwen3.8-Flash-Next-NVFP4@fc694b54fb0174e0913e6adf86691ef85a4ead47"]
      && TensorFold.catalog.filter(\.untested).count == 1, "Flash Next NVFP4 is the only untested entry, with MTP and the pinned revision")

// Unique names next to another setup of the same model
let taken: Set<String> = ["qwen3.8-27b", "qwen3.8-27b-tensorfold"]
check(TensorFold.uniqueName(q27) { taken.contains($0) } == ("Qwen3.8 27B (TensorFold 2)", "qwen3.8-27b-tensorfold-2")
      && TensorFold.uniqueName(q27) { $0 == "qwen3.8-27b" } == ("Qwen3.8 27B (TensorFold)", "qwen3.8-27b-tensorfold")
      && TensorFold.uniqueName(q27) { _ in false } == ("Qwen3.8 27B", "qwen3.8-27b"), "taken ids get a TensorFold suffix")
check(TensorFold.startCommand(q27, binary: "tf", port: 1, name: "qwen3.8-27b-tensorfold").contains("--name qwen3.8-27b-tensorfold "), "served name in the command")

// Delete keeps folders that were on the Spark before the first download (fake Spark home)
let fake = FileManager.default.temporaryDirectory.appending(path: "tf-keep-\(getpid())")
let hub = fake.appending(path: ".cache/huggingface/hub")
let fm = FileManager.default
try! fm.createDirectory(at: hub.appending(path: "models--z-lab--Qwen3.8-27B-DFlash2"), withIntermediateDirectories: true)
let env = ["HOME": fake.path, "PATH": "/usr/bin:/bin"]
check(bash(TensorFold.downloadScript(q27, binary: "/usr/bin/true") + "\nwait", env: env).0 == 0, "download script runs")
try! fm.createDirectory(at: hub.appending(path: "models--TensorFold--Qwen3.8-27B-MLX-4bit"), withIntermediateDirectories: true)
let del = bash(TensorFold.deleteScript(q27), env: env)
check(fm.fileExists(atPath: hub.appending(path: "models--z-lab--Qwen3.8-27B-DFlash2").path)
      && !fm.fileExists(atPath: hub.appending(path: "models--TensorFold--Qwen3.8-27B-MLX-4bit").path)
      && del.1.contains("Kept models--z-lab--Qwen3.8-27B-DFlash2"),
      "pre-existing drafter kept, app-downloaded model deleted: \(del.1)")
let retry = bash(TensorFold.downloadScript(q27, binary: "/usr/bin/true") + "\nwait", env: env)
check(retry.0 == 0 && fm.fileExists(atPath: fake.appending(path: ".local/share/spark-control/tensorfold-data/qwen3.8-27b.keep").path),
      "a fresh download after delete records again")
try? fm.removeItem(at: fake)

// Benchmark: result parsing, launch script and the Python script itself
let benchLine = Benchmark.marker + #"{"model": "m", "started": "2026-11-11T17:00:00", "exact_sizing": true, "context": 131072, "skipped": [200000], "batch_pp": 1024, "single": [{"pp": 32768, "tg": 128, "ttft_ms": 9000.5, "tpot_ms": 10.0, "pp_tps": 3640.0, "tg_tps": 100.0, "e2e_s": 10.3, "throughput": 3200.0, "peak_mem_gb": null}, {"pp": 65536, "error": "HTTP 400: too long"}], "batch": [{"batch": 1, "tg_tps": 100.0, "speedup": 1.0, "pp_tps": 3000.0, "pp_tps_per_req": 3000.0, "ttft_ms": 300.0, "e2e_s": 2.0}]}"#
let bench = Benchmark.parse(benchLine)
check(bench?.single.count == 2 && bench?.single[0].ppTps == 3640 && bench?.single[1].error == "HTTP 400: too long"
      && bench?.batch.first?.speedup == 1 && bench?.skipped == [200000] && bench?.context == 131072, "benchmark result parses")
check(Benchmark.parse("pp32768/tg128 …") == nil, "ordinary output lines aren't results")
let launch = Benchmark.launchScript(port: 18300, model: "qwen3.6-35b-a3b", keyExpr: "\"$(cat \"$HOME/k\")\"")
check(bash(launch, syntaxOnly: true).0 == 0 && launch.contains("--model 'qwen3.6-35b-a3b'") && launch.contains("\nSPARK_BENCH_PY\n"), "benchmark launch script parses")
check(!Benchmark.launchScript(port: 1, model: "", keyExpr: nil).contains(":1 --model"), "no --model when the backend id is unknown")
let py = FileManager.default.temporaryDirectory.appending(path: "bench-\(getpid()).py")
try! Data(Benchmark.script.utf8).write(to: py)
let pyCheck = bash("python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' \(py.path)", env: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin"])
try? FileManager.default.removeItem(at: py)
check(pyCheck.0 == 0, "benchmark script is valid Python: \(pyCheck.1)")

// vLLM catalog and commands
let vq = VLLM.model("qwen3.6-35b-a3b")!, vg = VLLM.model("gemma-4-26b-a4b")!
let vqStart = VLLM.startCommand(vq, port: 18300, name: "qwen3.6-35b-a3b")
check(VLLM.drafts(of: vqStart) == 3 && VLLM.context(of: vqStart) == 262_144 && vqStart.contains("-p 18300:8000")
      && vqStart.contains("--revision 1355db6a052410cfd62085d94b58866fd0f2c3c5"), "vLLM start command has port, revision, context and suggested drafts")
check(VLLM.drafts(of: VLLM.withDrafts(vqStart, 0, model: vq)) == 0 && VLLM.drafts(of: VLLM.withDrafts(vqStart, 1, model: vq)) == 1
      && VLLM.context(of: VLLM.withContext(vqStart, 65_536)) == 65_536, "vLLM drafts and context flags round-trip")
check(VLLM.startCommand(vg, port: 1, name: "g").contains(#"'{"method":"mtp","model":"google/gemma-4-26B-A4B-it-assistant","num_speculative_tokens":2}'"#),
      "Gemma drafts from its assistant checkpoint")
check(VLLM.catalog.allSatisfy { $0.repo.revision?.count == 40 } && Set(VLLM.catalog.map(\.key)).isDisjoint(with: tfIDs),
      "vLLM models are pinned and their records don't clash with TensorFold's")
for (name, s) in [("vllm start", vqStart), ("vllm stop", VLLM.stopCommand), ("vllm pull", VLLM.pullScript), ("vllm remove", VLLM.removeScript),
                  ("vllm download", VLLM.downloadScript(vg)), ("vllm delete", VLLM.deleteScript(vg))] {
    let (code, out) = bash(s, syntaxOnly: true)
    check(code == 0, "\(name) script parses: \(out)")
}
check(TensorFold.parseStatus("VLLM|ready\nMODEL|vllm-qwen3.6-35b-a3b|running|7|x").vllm == "ready", "vLLM status parses")
check(!TensorFold.uninstallScript(models: TensorFold.catalog).contains(#"rm -rf "$D""#), "removing TensorFold keeps the shared data folder")

// ComfyUI
for (name, s) in [("comfy install", ComfyUI.installScript), ("comfy remove", ComfyUI.removeScript), ("comfy start", ComfyUI.startScript),
                  ("comfy stop", ComfyUI.stopCommand), ("comfy download", ComfyUI.downloadScript(ComfyUI.catalog[0])),
                  ("comfy delete", ComfyUI.deleteScript(ComfyUI.catalog[0]))] {
    let (code, out) = bash(s, syntaxOnly: true)
    check(code == 0, "\(name) script parses: \(out)")
}
let cst = TensorFold.parseStatus("COMFY|v0.45.0|running\nMODEL|comfy-z-image-turbo|running|42|› x")
check(cst.comfyVersion == "v0.45.0" && cst.comfyRunning && cst.models["comfy-z-image-turbo"]?.bytes == 42
      && TensorFold.parseStatus("COMFY||").comfyVersion == nil, "ComfyUI status parses")
check(ComfyUI.catalog.allSatisfy { m in m.files.allSatisfy { $0.url.contains("/resolve/6fc90a3b1b653e935a0d175e260736de25b84df5/") } }
      && ComfyUI.startScript.contains("--listen 127.0.0.1"), "ComfyUI models are pinned and the server stays on the Spark's loopback")

print("All checks passed")
