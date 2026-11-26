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

// Model's own sampling: client sampling stripped, rules still apply after
var own = plain; own.modelSampling = true; own.rules = [ParamRule(key: "presence_penalty", kind: .default, value: "1.5")]
var sampled: [String: Any] = ["model": "x", "temperature": 0.2, "top_p": 1, "presence_penalty": 0, "max_tokens": 9]
Transform.apply(&sampled, recipe: own, path: "/v1/chat/completions", streamUsage: false)
check(sampled["temperature"] == nil && sampled["top_p"] == nil && sampled["max_tokens"] as? Int == 9, "client sampling stripped")
check(sampled["presence_penalty"] as? Double == 1.5, "rules apply after stripping")

// Untouched without rules
var untouched: [String: Any] = ["model": "x", "foo": [1, 2]]
check(Transform.apply(&untouched, recipe: plain, path: "/v1/chat/completions", streamUsage: false).isEmpty, "no rules → unchanged")

// Streaming usage
var stream: [String: Any] = ["model": "x", "stream": true]
check(!Transform.apply(&stream, recipe: plain, path: "/v1/chat/completions", streamUsage: true).isEmpty, "stream usage requested")
check((stream["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true, "include_usage set")
var optedOut: [String: Any] = ["model": "x", "stream": true, "stream_options": ["include_usage": false]]
check(Transform.apply(&optedOut, recipe: plain, path: "/v1/chat/completions", streamUsage: true).isEmpty, "client's choice respected")

// Thinking level → what each model's template accepts
func think(_ r: Recipe, _ b: [String: Any]) -> [String: Any] {
    var b = b; Transform.apply(&b, recipe: r, path: "/v1/chat/completions", streamUsage: false); return b
}
func kw(_ b: [String: Any]) -> Bool? { (b["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool }
let q38 = Recipe(name: "Qwen3.8 Flash", startCommand: "", stopCommand: "")
let onOff36 = Recipe(name: "Qwen3.6 35B", startCommand: "", stopCommand: "")
let oss = Recipe(name: "gpt-oss-120b", startCommand: "", stopCommand: "")
let ink = Recipe(name: "Inkling 2 Mini", startCommand: "", stopCommand: "")
// Qwen3.8: only low/medium/xhigh (anything else raises in its template), off through enable_thinking
let q38Off = think(q38, ["reasoning_effort": "none"])
check(q38Off["reasoning_effort"] == nil && kw(q38Off) == false, "Qwen3.8: off → enable_thinking false, effort dropped")
check(think(q38, ["reasoning_effort": "high"])["reasoning_effort"] as? String == "xhigh"
      && think(q38, ["reasoning_effort": "minimal"])["reasoning_effort"] as? String == "low"
      && think(q38, ["reasoning": ["effort": "medium"]])["reasoning_effort"] as? String == "medium"
      && think(q38, ["reasoning_effort": "max"])["reasoning_effort"] as? String == "xhigh"
      && kw(think(q38, ["reasoning_effort": "low"])) == nil, "Qwen3.8: levels mapped to low/medium/xhigh, kwargs left alone")
let q38Own = think(q38, ["reasoning_effort": "high", "chat_template_kwargs": ["enable_thinking": false]])
check(kw(q38Own) == false && q38Own["reasoning_effort"] as? String == "xhigh", "client's enable_thinking wins, effort still made valid")
// On/off models
let q36Off = think(onOff36, ["reasoning_effort": "minimal"]), q36On = think(onOff36, ["reasoning": ["effort": "high"], "chat_template_kwargs": ["foo": 1]])
check(kw(q36Off) == false && q36Off["reasoning_effort"] == nil && kw(q36On) == true
      && (q36On["chat_template_kwargs"] as? [String: Any])?["foo"] as? Int == 1, "on/off models: minimal = off, high = on, other kwargs kept")
// gpt-oss can't stop thinking; Inkling takes every standard name; numbers and unknown names pass untouched
check(think(oss, ["reasoning_effort": "xhigh"])["reasoning_effort"] as? String == "high"
      && think(oss, ["reasoning_effort": "none"])["reasoning_effort"] as? String == "low" && kw(think(oss, ["reasoning_effort": "none"])) == nil,
      "gpt-oss: clamped to low/medium/high, never off")
check(think(ink, ["reasoning_effort": "minimal"])["reasoning_effort"] as? String == "minimal"
      && think(ink, ["reasoning_effort": "max"])["reasoning_effort"] as? String == "xhigh"
      && think(ink, ["reasoning_effort": "none"])["reasoning_effort"] as? String == "none"
      && think(ink, ["reasoning_effort": 0.5])["reasoning_effort"] as? Double == 0.5
      && think(q38, ["reasoning_effort": "auto"])["reasoning_effort"] as? String == "auto", "Inkling: names pass; numbers and unknowns untouched")
// The model's default effort fills in only when the request has none
var q38Low = q38; q38Low.effort = "low"
var q36Off2 = onOff36; q36Off2.effort = "none"
check(think(q38Low, [:])["reasoning_effort"] as? String == "low" && think(q38Low, ["reasoning_effort": "high"])["reasoning_effort"] as? String == "xhigh"
      && kw(think(q36Off2, [:])) == false && think(q38, [:]).isEmpty && think(Recipe(name: "x", startCommand: "", stopCommand: ""), ["reasoning_effort": "high"])["reasoning_effort"] as? String == "high",
      "default effort only when unset; no default or no reasoning → untouched")
check(Transform.thinkingLabel(q38Off) == "Off" && Transform.thinkingLabel(q36On) == "On" && Transform.thinkingLabel(think(q38, ["reasoning_effort": "high"])) == "X-High"
      && Transform.thinkingLabel(["reasoning_effort": 0.5]) == "0.5" && Transform.thinkingLabel(["reasoning_effort": "none"]) == "Off"
      && Transform.thinkingLabel([:]) == nil, "thinking label from the forwarded body")

// Request bodies read as a conversation
let chat = Transform.messages(["system": [["type": "text", "text": "Be brief."]], "messages": [
    ["role": "user", "content": [["type": "text", "text": "Hi"], ["type": "image_url", "image_url": [:]]]],
    ["role": "assistant", "content": NSNull(), "tool_calls": [["function": ["name": "ls", "arguments": "{}"]]]],
    ["role": "tool", "content": "a.txt"],
] as [[String: Any]]])
check(chat.map(\.role) == ["system", "user", "assistant", "tool"], "message roles in order")
check(chat[0].text == "Be brief." && chat[1].text == "Hi\n\n[image_url]" && chat[2].text == "→ ls({})", "message text")
let resp = Transform.messages(["instructions": "x", "input": [["type": "function_call", "name": "ls", "arguments": "{}"],
                                                             ["type": "function_call_output", "output": "a.txt"]]])
check(resp.map(\.role) == ["system", "assistant", "tool"] && resp[1].text == "→ ls({})", "Responses input items")

// Long request bodies split into drawable pieces
let big = String(repeating: "x", count: 9000) + "\n" + String(repeating: "line\n", count: 2000)
let pieces = Transform.chunks(big)
check(pieces.joined() == big && pieces.allSatisfy { $0.count <= 4000 }, "chunks keep every character, none too long")
check(pieces.dropFirst(3).allSatisfy { $0.last == "\n" }, "chunks cut after a newline when there is one")
check(Transform.chunks("") == [""], "empty text is one chunk")

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
let d = Device(baseHost: "spark-1a2b.local")
check(d.host(.tailscale) == "spark-1a2b", "tailscale never has .local")
check(d.host(.local) == "spark-1a2b.local", "local adds .local")
check(Probe.isTailscale("100.101.12.3") && !Probe.isTailscale("192.168.1.20"), "tailscale IP range")
let idleOllama = Probe.Backend(loaded: [], listed: ["laguna", "qwen35-abl"])
check(!idleOllama.serves("laguna") && !idleOllama.serves(""), "an idle Ollama serves none of its pulled models")
check(Probe.Backend(loaded: ["qwen35-abl"], listed: ["laguna", "qwen35-abl"]).serves("qwen35-abl:latest"), "Ollama serves what it has loaded")
check(Probe.Backend(loaded: nil, listed: ["qwen3.8-27b"]).serves("qwen3.8-27b"), "other servers serve what they list")

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
check(d.backendBase(.local) == "http://spark-1a2b.local:18300" && d.backendBase(.tailscale, port: 8000) == "http://spark-1a2b:8000", "per-model port")

// TensorFold catalog and commands
let tfIDs = TensorFold.catalog.map(\.id)
check(Set(tfIDs).count == tfIDs.count, "catalog ids are unique")
check(TensorFold.catalog.allSatisfy { m in ([m.repo] + (m.drafter.map { [$0] } ?? [])).allSatisfy { $0.revision.map { $0.count == 40 } ?? true } },
      "pinned revisions are full commit hashes")
let q27 = TensorFold.model("qwen3.8-27b")!, q36 = TensorFold.model("qwen3.6-35b-a3b")!
let qu = TensorFold.model("qwen3.8-27b-uncensored")!
// Run the download with stub hf and tensorfold that log their arguments, in a scratch home.
let quHome = FileManager.default.temporaryDirectory.appending(path: "tf-skip-\(getpid())")
try! FileManager.default.createDirectory(at: quHome.appending(path: "bin"), withIntermediateDirectories: true)
for tool in ["hf", "tf"] {
    let f = quHome.appending(path: "bin/\(tool)")
    try! Data("#!/bin/sh\necho \"\(tool) $*\" >> \"$HOME/calls\"\n".utf8).write(to: f)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
}
let quDL = TensorFold.downloadScript(qu, binary: quHome.appending(path: "bin/tf").path)
_ = bash(quDL + "\nwait", env: ["HOME": quHome.path, "PATH": quHome.appending(path: "bin").path + ":/usr/bin:/bin"])
Thread.sleep(forTimeInterval: 1)
let quCalls = (try? String(contentsOf: quHome.appending(path: "calls"), encoding: .utf8)) ?? ""
let quRef = (try? String(contentsOf: quHome.appending(path: ".cache/huggingface/hub/models--orcarouter--Qwen3.8-27B-Uncensored-MLX/refs/main"), encoding: .utf8)) ?? ""
let quOK = FileManager.default.fileExists(atPath: quHome.appending(path: ".local/share/spark-control/tensorfold-data/qwen3.8-27b-uncensored.ok").path)
try? FileManager.default.removeItem(at: quHome)
check(quCalls == "hf download orcarouter/Qwen3.8-27B-Uncensored-MLX --revision a92a9d3492320048ca96924262d158f75ab5ce8b --exclude 2-bit/* --exclude 4-bit/* --exclude 6-bit/* --exclude 8-bit/* --exclude mtp/*\ntf pull z-lab/Qwen3.8-27B-DFlash2\n"
      && quRef == "a92a9d3492320048ca96924262d158f75ab5ce8b" && quOK && !TensorFold.downloadScript(q27, binary: "tf").contains("download"),
      "a repo with skipped folders downloads only its weights with hf and points refs/main at the pinned revision, without the newline hf rejects: \(quCalls)")
let q27Start = TensorFold.startCommand(q27, binary: TensorFold.managedBinary, port: 18300)
check(TensorFold.tidyNotes("# TensorFold 1.2.9\n\nFaster decode and\nfixes.\n\n## Speed\n\n- **A**: two streams\n  decode faster.\n  - nested\n") ==
      "Faster decode and fixes.\n\n**Speed**\n\n• **A**: two streams decode faster.\n      • nested",
      "release notes lose the title, unwrap lines and keep bullets")
check(q27Start.contains("--drafter z-lab/Qwen3.8-27B-DFlash2") && q27Start.contains("--port 18300") && q27Start.contains("--api-key-file"),
      "drafter, port and key are always passed")
check(q27.downloads.count == 2 && q36.downloads.count == 1 && TensorFold.startCommand(q36, binary: "tf", port: 1).contains("--drafter TensorFold/Qwen3.6-35B-A3B-MLX-4bit-MTP"),
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
for (name, s) in [("status", TensorFold.statusScript()), ("install", TensorFold.installScript()), ("jpeg", TensorFold.jpegScript),
                  ("uninstall", TensorFold.uninstallScript(models: TensorFold.catalog)), ("download", TensorFold.downloadScript(q27, binary: "tf")),
                  ("cancel", TensorFold.cancelScript(q27.id)), ("delete", TensorFold.deleteScript(q27)), ("key", TensorFold.apiKeyScript),
                  ("stop", TensorFold.stopCommand(port: 18300)), ("legacy stop", TensorFold.legacyStopCommand), ("manual", TensorFold.manualSteps)] {
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
let q2 = TensorFold.model("qwen3.5-2b")!.repo
try! FileManager.default.createDirectory(at: home.appending(path: ".cache/huggingface/hub/\(q2.cacheName)/snapshots/\(q2.snapshot)"), withIntermediateDirectories: true)
try! Data().write(to: data.appending(path: "lfm2.5-24b-a2b.ok"))  // marker left, files gone
try! Data("› downloading 40%\r› downloading 41%\n".utf8).write(to: data.appending(path: "gemma-4-31b.log"))
try! Data("\(getpid())".utf8).write(to: data.appending(path: "gemma-4-31b.pid"))
try! Data("error: 404\n".utf8).write(to: data.appending(path: "kolibri-1.log"))
let (code, statusOut) = bash(TensorFold.statusScript(), env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
try? FileManager.default.removeItem(at: home)
let st = TensorFold.parseStatus(statusOut)
check(code == 0 && st.engine == .none && st.freeBytes != nil, "status reads engine and free space: \(statusOut)")
check(st.models["qwen3.5-2b"]?.download == .done && st.models["kolibri-1"]?.download == .failed
      && st.models["kolibri-1"]?.message == "error: 404" && st.models["qwen3.8-27b"]?.download == TensorFold.Download.none
      && st.models["lfm2.5-24b-a2b"]?.download == TensorFold.Download.none,
      "download states from markers; a marker counts only while every repo is there")
check(st.models["gemma-4-31b"]?.download == .running && st.models["gemma-4-31b"]?.message == "› downloading 41%", "running download shows its last progress line")
// Updates: only a newer plain X.Y.Z counts; each install keeps the version it replaced, rollback swaps them.
check(TensorFold.isNewer("1.2.10", than: "1.2.9") && TensorFold.isNewer("2.0.0", than: "1.9.9") && !TensorFold.isNewer("1.2.6", than: "1.2.6")
      && !TensorFold.isNewer("1.2.5", than: "1.2.6") && !TensorFold.isNewer("1.3.0-rc1", than: "1.2.6") && TensorFold.semver("1.3") == nil,
      "version comparison")
check(bash(TensorFold.installScript("1.3.0"), syntaxOnly: true).0 == 0 && TensorFold.installScript("1.3.0").contains("V=1.3.0; A=tensorfold-1.3.0-linux-aarch64") && TensorFold.installScript("1.3.0").contains("download/v1.3.0\n"),
      "install script takes a version")
let up = FileManager.default.temporaryDirectory.appending(path: "tf-update-\(getpid())")
func fakeInstall(_ v: String) -> Int32 {
    bash("""
    set -euo pipefail; mkdir -p "$HOME"; cd "$HOME"; E="\(TensorFold.engineDir)"; mkdir -p "$E"; V=\(v); A=pkg-$V
    mkdir -p "$A/bin"; echo $V > "$A/VERSION"; printf '#!/bin/sh\\necho %s\\n' $V > "$A/bin/tensorfold-native"; chmod +x "$A/bin/tensorfold-native"
    \(TensorFold.activateScript)
    """, env: ["HOME": up.path, "PATH": "/usr/bin:/bin"]).0
}
func upStatus() -> TensorFold.Status { TensorFold.parseStatus(bash(TensorFold.statusScript(), env: ["HOME": up.path, "PATH": "/usr/bin:/bin"]).1) }
check(fakeInstall("1.2.6") == 0 && upStatus().engine == .managed(version: "1.2.6") && upStatus().previous == nil, "first install has nothing to switch back to")
check(!upStatus().jpeg && bash(#"mkdir -p "$HOME/.local/share/spark-control/tensorfold/current/lib" && touch "$_/libturbojpeg.so.0""#,
      env: ["HOME": up.path, "PATH": "/usr/bin:/bin"]).0 == 0 && upStatus().jpeg, "status sees libjpeg-turbo beside the engine")
check(TensorFold.installScript().contains("add_jpeg \"$A\"\n"), "install adds libjpeg-turbo before switching")
check(fakeInstall("1.2.7") == 0 && fakeInstall("1.3.0") == 0 && upStatus().engine == .managed(version: "1.3.0") && upStatus().previous == "1.2.7",
      "update keeps the version it replaced")
let engineDir = up.appending(path: ".local/share/spark-control/tensorfold").path
check((try? FileManager.default.contentsOfDirectory(atPath: engineDir).sorted()) == ["1.2.7", "1.3.0", "current", "previous"], "older versions are deleted")
check(bash(TensorFold.rollbackScript, env: ["HOME": up.path, "PATH": "/usr/bin:/bin"]).0 == 0 && upStatus().engine == .managed(version: "1.2.7")
      && upStatus().previous == "1.3.0", "switching back swaps current and previous")
check(fakeInstall("1.2.7") == 0 && upStatus().previous == "1.3.0", "reinstalling the current version keeps previous")
try? FileManager.default.removeItem(at: up)

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
      && TensorFold.model("qwen3.6-35b-a3b-nvfp4") == nil, "draft source per model; the NVFP4 Qwen3.6 is gone (TensorFold can't run it)")

let fnNvfp4 = TensorFold.model("qwen3.8-flash-next-nvfp4")!
check(fnNvfp4.untested && fnNvfp4.drafts == "MTP" && !fnNvfp4.yarn && fnNvfp4.downloads.map(\.spec) == ["nvidia/Qwen3.8-Flash-Next-NVFP4@fc694b54fb0174e0913e6adf86691ef85a4ead47"]
      && TensorFold.catalog.filter(\.untested).count == 1, "Flash Next NVFP4 is the only untested entry, with MTP and the pinned revision")

// A repo Hugging Face renamed: the download links the new name to the old folder and leaves that folder alone.
let renHome = FileManager.default.temporaryDirectory.appending(path: "tf-renamed-\(getpid())")
let renHub = renHome.appending(path: ".cache/huggingface/hub")
try! FileManager.default.createDirectory(at: renHub.appending(path: "models--Vontra--Qwen3.8-27B-MLX-4bit/snapshots/abc"), withIntermediateDirectories: true)
_ = bash(TensorFold.downloadScript(q27, binary: "/usr/bin/true") + "\nwait", env: ["HOME": renHome.path, "PATH": "/usr/bin:/bin"])
let renKeep = (try? String(contentsOf: renHome.appending(path: ".local/share/spark-control/tensorfold-data/\(q27.id).keep"), encoding: .utf8)) ?? ""
check(FileManager.default.fileExists(atPath: renHub.appending(path: "models--TensorFold--Qwen3.8-27B-MLX-4bit/snapshots/abc").path)
      && (try? FileManager.default.destinationOfSymbolicLink(atPath: renHub.appending(path: "models--TensorFold--Qwen3.8-27B-MLX-4bit").path)) == "models--Vontra--Qwen3.8-27B-MLX-4bit"
      && (try? FileManager.default.destinationOfSymbolicLink(atPath: renHub.appending(path: "models--Vontra--Qwen3.8-27B-MLX-4bit").path)) == nil
      && renKeep.contains("models--TensorFold--Qwen3.8-27B-MLX-4bit"),
      "a renamed repo's new name links to the untouched old folder, kept on delete: \(renKeep)")
try? FileManager.default.removeItem(at: renHome)

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

for (cmd, code) in [("echo hi; exec false", "1"), ("true # comment", "0")] {
    check(bash(SSH.withExitLine(cmd)).1.contains("__SPARK_EXIT__" + code), "start commands report their exit code, even through exec: \(cmd)")
}
// vLLM catalog and commands
let vq = VLLM.model("qwen3.6-35b-a3b")!, vg = VLLM.model("gemma-4-26b-a4b")!
let vqStart = VLLM.startCommand(vq, port: 18300, name: "qwen3.6-35b-a3b")
check(VLLM.drafts(of: vqStart) == 3 && VLLM.context(of: vqStart) == 262_144 && vqStart.contains("-p 18300:8000")
      && vqStart.contains("--revision 1355db6a052410cfd62085d94b58866fd0f2c3c5"), "vLLM start command has port, revision, context and suggested drafts")
let vqOld = vqStart.replacingOccurrences(of: " --enable-prompt-tokens-details", with: "")
check(VLLM.synced(vqOld, model: vq.id).components(separatedBy: "--enable-prompt-tokens-details").count == 2
      && VLLM.synced(vqStart, model: vq.id).components(separatedBy: "--enable-prompt-tokens-details").count == 2,
      "vLLM commands report cached tokens, saved ones gain the flag once")
// vLLM: the 27B's coding-agent adapter toggles on and off, and the backend model ID follows it
let v27 = VLLM.model("qwen3.8-27b")!
let v27Start = VLLM.startCommand(v27, port: 18302, name: "qwen3-8-27b")
let v27On = VLLM.withAdapter(v27Start, true, model: v27)
var v27Recipe = Recipe(name: "Qwen3.8 27B", startCommand: v27On, stopCommand: ""); v27Recipe.vllm = v27.id
check(!VLLM.adapterOn(v27Start) && VLLM.adapterOn(v27On) && VLLM.withAdapter(v27On, false, model: v27) == v27Start
      && VLLM.withAdapter(v27On, true, model: v27) == v27On && v27.downloads.count == 2
      && v27On.contains("--max-lora-rank 128 --lora-modules qwen3-8-27b-super=/root/.cache/huggingface/hub/models--harness-hub--Qwen3.8-27B-super-adapter/snapshots/3358a71529ce56aba0095addd6a60a66d7c4228b")
      && v27Recipe.servedName == "qwen3-8-27b-super" && VLLM.drafts(of: v27On) == 2
      && VLLM.withAdapter(vqStart, true, model: vq) == vqStart,
      "the 27B's adapter switches on and off once, is served as <name>-super, and models without one ignore it")
// vLLM: request limit, fixed KV cache (skips the memory profiling that fails on the GB10), and saved commands kept in step
let vu = VLLM.model("qwen3.8-27b-uncensored")!
let vuStart = VLLM.startCommand(vu, port: 18301, name: "u")
check(vuStart.contains("--max-num-seqs 8") && vuStart.contains("--kv-cache-memory-bytes 17500000000")
      && vuStart.contains(#"'{"method":"mtp","num_speculative_tokens":2}'"#) && !vqStart.contains("--kv-cache-memory-bytes"),
      "uncensored 27B starts with 8 requests and a fixed KV cache; models without a measured footprint keep profiling")
let vu60 = VLLM.withMemory(vuStart, 60, footprint: vu.footprintGB)
check(vu60.contains("--kv-cache-memory-bytes 27500000000") && vu60.components(separatedBy: "--kv-cache-memory-bytes").count == 2
      && vu60.components(separatedBy: "--gpu-memory-utilization").count == 2, "changing memory resizes the KV cache once")
let vuSaved = vuStart.replacingOccurrences(of: "--max-num-seqs 8", with: "--max-num-seqs 4")
    .replacingOccurrences(of: " --kv-cache-memory-bytes 17500000000", with: "")
    + #" --max-num-batched-tokens 8192 --async-scheduling --compilation-config '{"pass_config":{"fuse_act_quant":true},"max_cudagraph_capture_size":64}' --kernel-config '{"enable_flashinfer_autotune":true}'"#
let vuSynced = VLLM.synced(vuSaved, model: vu.id)
check(vuSynced.contains("--max-num-seqs 8") && vuSynced.contains("--kv-cache-memory-bytes") && !vuSynced.contains("async")
      && !vuSynced.contains("kernel-config") && !vuSynced.contains("batched") && VLLM.synced(vuSynced, model: vu.id) == vuSynced
      && VLLM.synced(vqStart, model: vq.id) == vqStart
      && VLLM.synced(vqStart.replacingOccurrences(of: "--max-num-seqs 4", with: "--max-num-seqs 16"), model: vq.id).contains("--max-num-seqs 16")
      && VLLM.synced(vuSynced.replacingOccurrences(of: "--max-num-seqs 8", with: "--max-num-seqs 12"), model: vu.id).contains("--max-num-seqs 12"),
      "saved commands get the limit and KV size once, lose unmeasured flags, and keep later edits; other models are untouched")
check(bash(vuSynced, syntaxOnly: true).0 == 0, "the synced start command parses")
check(VLLM.drafts(of: VLLM.withDrafts(vqStart, 0, model: vq)) == 0 && VLLM.drafts(of: VLLM.withDrafts(vqStart, 1, model: vq)) == 1
      && VLLM.context(of: VLLM.withContext(vqStart, 65_536)) == 65_536, "vLLM drafts and context flags round-trip")
check(VLLM.startCommand(vg, port: 1, name: "g").contains(#"'{"method":"mtp","model":"google/gemma-4-26B-A4B-it-assistant","num_speculative_tokens":2}'"#),
      "Gemma drafts from its assistant checkpoint")
check(VLLM.catalog.allSatisfy { $0.repo.revision?.count == 40 } && Set(VLLM.catalog.map(\.key)).isDisjoint(with: tfIDs),
      "vLLM models are pinned and their records don't clash with TensorFold's")
// A model on its own vLLM image: started, downloaded, deleted and checked with that image, and drafts its own way
let vi = VLLM.model("inkling-2-mini")!, viStart = VLLM.startCommand(vi, port: 1, name: "i")
check(viStart.contains(vi.image! + " thinkingmachines/Inkling-2-Mini") && !viStart.contains(VLLM.image)
      && viStart.contains(#"'{"method":"dspark","draft_sample_method":"probabilistic","num_speculative_tokens":7}'"#) && VLLM.drafts(of: viStart) == 7
      && VLLM.downloadScript(vi).contains("docker pull " + vi.image!) && VLLM.deleteScript(vi).contains("docker rmi " + vi.image!)
      && VLLM.statusLines.contains("IMG='" + vi.image! + "' m 'vllm-inkling-2-mini'") && !VLLM.downloadScript(vg).contains("docker pull"),
      "Inkling runs, downloads and deletes with its own image; other models use the shared one")
var viRecipe = Recipe(name: "Inkling 2 Mini", startCommand: viStart, stopCommand: "", upstreamModel: "inkling-2-mini")
check(VLLM.contextOptions(vi) == [32_768, 65_536, 131_072, 262_144, 524_288, 1_048_576] && !VLLM.contextOptions(vq).contains(524_288),
      "1M-window models offer 512k; 262k models don't")
// Inkling's memory follows its context: 262k fits the default 50 GB, 512k and 1M raise it; saved commands are fixed on load
let vi512 = VLLM.withContext(viStart, 524_288), viRaised = VLLM.synced(vi512, model: vi.id)
check(VLLM.memoryFraction(of: viStart) == 0.38 && VLLM.memoryFraction(of: VLLM.fitted(vi512, vi))! * VLLM.gb10Memory / 1e9 >= 53
      && VLLM.memoryFraction(of: VLLM.fitted(VLLM.withContext(viStart, 1_048_576), vi))! * VLLM.gb10Memory / 1e9 >= 77
      && viRaised == VLLM.fitted(vi512, vi) && VLLM.synced(viRaised, model: vi.id) == viRaised
      && VLLM.fitted(VLLM.withMemory(vi512, 90), vi) == VLLM.withMemory(vi512, 90) && VLLM.fitted(vqStart, vq) == vqStart,
      "a larger context raises memory to fit one full request, never lowers it, and leaves unmeasured models alone")
check(viRecipe.hasReasoning && viRecipe.takesImages, "Inkling counts as reasoning (its --reasoning-parser) and takes images")
viRecipe.reasoning = false
check(!viRecipe.hasReasoning, "the reasoning toggle still overrides the guess")
for (name, s) in [("vllm start", vqStart), ("inkling download", VLLM.downloadScript(vi)), ("inkling delete", VLLM.deleteScript(vi)), ("status", TensorFold.statusScript()), ("vllm stop", VLLM.stopCommand("q")), ("tf stop", TensorFold.stopCommand(port: 18301)), ("vllm pull", VLLM.pullScript), ("vllm remove", VLLM.removeScript),
                  ("vllm download", VLLM.downloadScript(vg)), ("vllm delete", VLLM.deleteScript(vg))] {
    let (code, out) = bash(s, syntaxOnly: true)
    check(code == 0, "\(name) script parses: \(out)")
}
check(VLLM.downloadScript(vg).contains("HF_TOKEN_PATH=/tmp/hf-token"), "vLLM downloads see the hf auth login token, so gated repos download")
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
check(ComfyUI.catalog.allSatisfy { m in m.files.allSatisfy { f in f.url.contains(try! Regex("/resolve/[0-9a-f]{40}/")) && f.url.hasSuffix("/" + (f.path as NSString).lastPathComponent) } }
      && ComfyUI.startScript.contains("--listen 127.0.0.1") && ComfyUI.startScript.contains("TORCH_DISABLE_NATIVE_JIT=1 nohup") && !ComfyUI.catalog.contains { $0.template.isEmpty }, "ComfyUI models are pinned and the server stays on the Spark's loopback")

// Spark monitor, from a GB10's real output
let mon1 = SparkMonitor.parse("""
MEM|127533224 91119260 16777212 16776892 
CPU|cpu  98941 629 120915 22947236 19078 0 5465 0 0 0
CPU|cpu0 5000 0 6000 1140000 900 0 200 0 0 0
LOAD|0.98 0.59 0.38
GPU|96, 80, 89.05, 2340
PROC|29441|/home/abhi/.local/share/spark-control/comfyui/venv/bin/python /home/abhi/.local/share/spark-control/comfyui/ComfyUI/main.py --listen 127.0.0.1
PROC|1000|python3 -m vllm.entrypoints.openai.api_server
PROC|2000|VLLM::EngineCore vllm
TZ|87600
TZ|71100
NVME|54850
DISK|3936289308672 617997856768 3118262317056
""")
check(mon1.memTotal == 127533224 * 1024 && mon1.memUsed == (127533224 - 91119260) * 1024 && mon1.gpuTemp == 80 && mon1.power == 89.05
      && mon1.zones == [87.6, 71.1] && mon1.nvmeTemp == 54.85 && mon1.diskFree == 3118262317056 && mon1.coreCount == 1,
      "Spark monitor sample parses")
check(mon1.processes.map(\.name) == ["ComfyUI", "vLLM"] && mon1.processes[1].bytes == 3000 * 1_048_576,
      "GPU processes are named and an engine's processes are summed")
var mon2 = mon1
mon2.cpuTimes["cpu0"] = [5300, 0, 6100, 1140600, 900, 0, 0, 0, 0, 0].map { Int64($0) }
mon2.cpuTimes["cpu0"]![6] = 200
check(SparkMonitor.cpuPercent("cpu0", from: mon1, to: mon2) == 40, "CPU busy share comes from jiffy deltas")
check(SparkMonitor.parse("GPU|[N/A], [N/A], [N/A], [N/A]").gpuUtil == nil, "missing GPU readings stay empty")
let store = SparkMonitor.parseStorage("DU|Hugging Face cache|285788099522\nDU|ComfyUI|58777820794\nDOCKER|96.61GB")
check(store.folders.count == 2 && store.folders[0].1 == 285788099522 && store.docker == "96.61 GB", "storage parses")
check(bash(SparkMonitor.script, syntaxOnly: true).0 == 0 && bash(SparkMonitor.storageScript, syntaxOnly: true).0 == 0, "monitor scripts parse")

// Running side by side
check(VLLM.memoryFraction(of: vqStart) == 0.38 && VLLM.memoryFraction(of: VLLM.withMemory(vqStart, 65)) == 0.5
      && vqStart.contains("--name spark-vllm-qwen3.6-35b-a3b "), "vLLM takes its model's memory share and its own container")
check(TensorFold.stopCommand(port: 18301).contains("--port 18301( |$)") && !TensorFold.stopCommand(port: 18301).contains("--port 18300"),
      "TensorFold stops only the server on its port")
check(bash("p='[t]ensorfold-native serve .*--port 18301( |$)'; echo 'tensorfold-native serve m --host 0.0.0.0 --port 18301 --name x' | grep -Eq \"$p\" && ! echo 'tensorfold-native serve m --port 183010 --name x' | grep -Eq \"$p\"").0 == 0,
      "the port pattern matches its port and not a longer one")
var legacy = Recipe(name: "Q", startCommand: "docker rm -f spark-vllm >/dev/null 2>&1; exec docker run --rm --name spark-vllm --gpus all", stopCommand: "x", upstreamModel: "q")
legacy.vllm = "qwen3.6-35b-a3b"
var legacyTF = Recipe(name: "T", startCommand: "tf serve", stopCommand: TensorFold.legacyStopCommand)
legacyTF.tensorfold = "qwen3.8-27b"
check(legacy.migrated(defaultPort: 18300).startCommand.contains("--name spark-vllm-q ")
      && legacy.migrated(defaultPort: 18300).stopCommand == VLLM.stopCommand("q")
      && legacyTF.migrated(defaultPort: 18300).stopCommand == TensorFold.stopCommand(port: 18300),
      "models added earlier are migrated to stop only themselves")
var switched = Recipe(name: "U", startCommand: "\"$HOME/tf\" serve org/M --port 18304 --name m-tensorfold --api-key-file k", stopCommand: "x", upstreamModel: "m")
switched.tensorfold = "m"
var vlServed = Recipe(name: "V", startCommand: "exec docker run --rm --name spark-vllm-m img org/M --served-model-name m --api-key k", stopCommand: "x", upstreamModel: "old")
vlServed.vllm = "m"
check(switched.migrated(defaultPort: 18300).upstreamModel == "m-tensorfold" && vlServed.servedName == "m"
      && Recipe(name: "P", startCommand: "ollama run --name x", stopCommand: "").servedName == nil,
      "the backend model ID follows the name the start command serves")
var renamed = Recipe(name: "Qwen3.8 27B (TensorFold)", startCommand: "x", stopCommand: "").migrated(defaultPort: 18300)
renamed.name = "Qwen Uncensored"
var unset = Recipe(name: "New", startCommand: "", stopCommand: "")
unset.freezeAPI()
check(renamed.apiID == "qwen3.8-27b-tensorfold" && renamed.answers(to: "qwen3.8-27b-tensorfold") && unset.api == nil,
      "renaming a model keeps its API model name; a blank model's isn't fixed yet")

// Configs saved by older versions still load: missing keys take their defaults.
let oldConfig = #"{"recipes":[{"id":"6F9A4C3E-1B2D-4E5F-8A7B-9C0D1E2F3A4B","name":"Old","startCommand":"s","stopCommand":"t","enabled":false,"rules":[]}],"gateway":{"port":18081}}"#
let old = try? JSONDecoder().decode(Config.self, from: Data(oldConfig.utf8))
check(old?.recipes.first?.name == "Old" && old?.recipes.first?.enabled == false && old?.recipes.first?.memoryMeasured == false
      && old?.recipes.first?.timeout == 600 && old?.gateway.port == 18081 && old?.gateway.autoSwap == true,
      "a config from an older version loads, with defaults for newer fields")
var full = Config.seed
full.recipes[0].memoryGB = 42
full.recipes[0].memoryMeasured = true
check((try? JSONDecoder().decode(Config.self, from: JSONEncoder().encode(full))) == full, "a saved config reads back unchanged")

// Model list shared through the Spark
let mine = Recipe(name: "Mine", startCommand: "m", stopCommand: "")
let theirs = Recipe(name: "Theirs", startCommand: "t --context 65536", stopCommand: "")
let shared = SharedModels(updated: Date(timeIntervalSince1970: 100), recipes: [theirs])
check(shared.merged(into: [mine], local: Date(timeIntervalSince1970: 200)) == nil
      && shared.merged(into: [mine], local: Date(timeIntervalSince1970: 50)) == [theirs]
      && shared.merged(into: Config.seed.recipes + [mine, theirs, Recipe(name: "New Model", startCommand: " ", stopCommand: "")], local: nil) == [theirs, mine]
      && SharedModels(updated: .now, recipes: [theirs, Recipe(name: "New Model", startCommand: "", stopCommand: "")]).merged(into: [], local: nil) == [theirs],
      "the newer list wins; a Mac's first sync keeps its own models but not the starter ones or blank ones")
check((try? JSONDecoder().decode(SharedModels.self, from: JSONEncoder().encode(shared)))?.recipes == [theirs], "the shared list reads back")
check((try? JSONDecoder().decode(SharedModels.self, from: JSONEncoder().encode(SharedModels(updated: .now, recipes: [], autoSwap: false))))?.autoSwap == false
      && (try? JSONDecoder().decode(SharedModels.self, from: JSONEncoder().encode(shared)))?.autoSwap == nil, "auto-switch is shared")

// Coding tool configs
let gw = ClientTool.Gateway(baseURL: "http://localhost:18080/v1", apiKey: "sk-local")
var vl = Recipe(name: "Qwen3.8 27B", startCommand: "x", stopCommand: "", priceIn: 0.2, priceOut: 0.8)
let textOnly = Recipe(name: "Nemotron Lightning", startCommand: "x", stopCommand: "")
check(Recipe(name: "Arete 27B", startCommand: "tensorfold serve", stopCommand: "", tensorfold: "arete-27b").hasReasoning, "a model with known effort levels reasons")
check(vl.hasReasoning && vl.takesImages && textOnly.hasReasoning && !textOnly.takesImages, "capabilities guessed from the name")
check(!Recipe(name: "Qwen3.6", startCommand: "tensorfold serve", stopCommand: "", tensorfold: "q").takesImages
      && Recipe(name: "Gemma", startCommand: "tensorfold serve --vision", stopCommand: "", tensorfold: "g").takesImages,
      "TensorFold models take images only with --vision")
let tfq = Recipe(name: "Qwen3.8 27B", startCommand: "tensorfold serve q --drafter d", stopCommand: "", tensorfold: "qwen3.8-27b")
var tfOff = tfq; tfOff.images = false
check(tfq.migrated(defaultPort: 8000).takesImages && !tfOff.migrated(defaultPort: 8000).takesImages
      && TensorFold.withVision(TensorFold.withVision(tfq.startCommand, true), false) == tfq.startCommand
      && TensorFold.withVision(TensorFold.withVision(tfq.startCommand, true), true) == TensorFold.withVision(tfq.startCommand, true),
      "saved Qwen3.8 27B gains --vision unless turned off; the flag toggles cleanly")
var tfOld = tfq; tfOld.startCommand += " --vision"
var tfHand = tfq; tfHand.startCommand += " --vision --vision-max-images 8"
check(tfOld.migrated(defaultPort: 8000).startCommand.hasSuffix(" --vision --vision-max-images 64 --vision-image-tokens 65536")
      && tfHand.migrated(defaultPort: 8000).startCommand.hasSuffix(" --vision --vision-max-images 8 --vision-image-tokens 65536")
      && TensorFold.withVision(tfHand.startCommand, false) == tfq.startCommand
      && TensorFold.startCommand(TensorFold.model("gemma-4-31b")!, binary: "tf", port: 1).contains(" --vision --vision-max-images 64 --vision-image-tokens 65536"),
      "image limits: new and saved models get 64 images in 65,536 tokens, a hand-set limit stays, Images off drops them all")
vl.images = false
check(!vl.takesImages, "the toggle overrides the guess")
vl.images = nil

let kiloIn = """
{
  "$schema": "https://app.kilo.ai/config.json",
  // a comment
  "provider": { "other": { "name": "Other" }, "spark-control": { "name": "Old" } },
  "model": "openrouter/x",
}
"""
let kiloOut = try! ClientTool.kilo.apply(to: kiloIn, models: [vl, textOnly], gateway: gw)
let kj = try! JSONSerialization.jsonObject(with: Data(kiloOut.utf8)) as! [String: Any]
let kp = (kj["provider"] as! [String: Any])
let sc = kp["spark-control"] as! [String: Any]
let kvl = (sc["models"] as! [String: Any])["qwen3.8-27b"] as! [String: Any]
check(kp["other"] != nil && kj["model"] as? String == "openrouter/x" && sc["npm"] as? String == "@openrouter/ai-sdk-provider"
      && (sc["options"] as! [String: Any])["apiKey"] as? String == "sk-local"
      && kvl["attachment"] as? Bool == true && kvl["reasoning"] as? Bool == true
      && (kvl["cost"] as! [String: Any])["output"] as? Double == 0.8
      && ((sc["models"] as! [String: Any])["nemotron-lightning"] as! [String: Any])["attachment"] as? Bool == false,
      "Kilo: provider replaced via the OpenRouter SDK, the rest kept")
let kv = kvl["variants"] as! [String: [String: Any]]
func effort(_ v: [String: Any]?) -> String? { (v?["reasoning"] as? [String: Any])?["effort"] as? String }
check(Set(kv.filter { $0.value["disabled"] == nil }.keys) == ["off", "low", "medium", "xhigh"]
      && effort(kv["off"]) == "none" && effort(kv["xhigh"]) == "xhigh"
      && ["none", "minimal", "high", "max"].allSatisfy { kv[$0]?["disabled"] as? Bool == true },
      "Kilo: Qwen3.8 variants off, low, medium, xhigh; Kilo's other effort names disabled")
let onOff = ClientTool.kilo.apply
let q36Kilo = ((try! JSONSerialization.jsonObject(with: Data(try! onOff("", [Recipe(name: "Qwen3.6 35B", startCommand: "x", stopCommand: "")], gw).utf8)) as! [String: Any])["provider"] as! [String: Any])
let q36v = (((q36Kilo["spark-control"] as! [String: Any])["models"] as! [String: Any])["qwen3.6-35b"] as! [String: Any])["variants"] as! [String: [String: Any]]
check(Set(q36v.filter { $0.value["disabled"] == nil }.keys) == ["off", "on"] && effort(q36v["on"]) == "high", "Kilo: on/off models get Off and On")
check(try! ClientTool.kilo.apply(to: kiloOut, models: [vl, textOnly], gateway: gw) == kiloOut && ClientTool.kilo.isAdded(kiloOut),
      "Kilo: applying twice changes nothing")

let ixIn = #"{"indexing": {"provider": "openrouter", "model": "openai/text-embedding-3-small", "dimension": 1536, "vectorStore": "lancedb", "openrouter": {"apiKey": "k"}}, "model": "x"}"#
let ix = ClientTool.kiloIndexing(in: try! ClientTool.kiloIndexing(ixIn, model: "qwen3-embedding-0.6b", dimension: 1024, gateway: gw))!
check(ix["enabled"] as? Bool == true && ix["provider"] as? String == "openai-compatible" && ix["model"] as? String == "qwen3-embedding-0.6b"
      && ix["dimension"] as? Int == 1024 && (ix["openai-compatible"] as? [String: Any])?["baseUrl"] as? String == "http://localhost:18080/v1"
      && ix["vectorStore"] as? String == "lancedb" && (ix["openrouter"] as? [String: Any])?["apiKey"] as? String == "k"
      && ClientTool.kiloIndexing(in: "") == nil,
      "Kilo indexing: provider, model and dimension replaced; other providers' keys and the vector store kept")
check(Recipe(name: "qwen3-embedding", startCommand: "x", stopCommand: "").isEmbedding
      && Recipe(name: "nomic-embed-text", startCommand: "x", stopCommand: "").isEmbedding && !vl.isEmbedding,
      "embedding models are told apart from chat models")
let oe = Ollama.commands("qwen3-embedding:0.6b", embedding: true), oc = Ollama.commands("qwen3:8b", embedding: false)
check(oe.start.hasSuffix(#"/api/embed -d '{"model":"qwen3-embedding:0.6b","input":"x","keep_alive":-1}' >/dev/null"#)
      && oe.stop.hasSuffix(#""keep_alive":0}' >/dev/null"#)
      && oc.start.hasSuffix(#"/api/generate -d '{"model":"qwen3:8b","keep_alive":-1}' >/dev/null"#)
      && oc.start.hasPrefix("curl -sf http://localhost:11434/api/version >/dev/null || sudo -n systemctl start ollama;"),
      "Ollama models load and unload through its API: embedding models through /api/embed")

let piOut = try! ClientTool.pi.apply(to: #"{"providers": {"homelab": {"baseUrl": "http://x"}}}"#, models: [vl], gateway: gw)
let pp = (try! JSONSerialization.jsonObject(with: Data(piOut.utf8)) as! [String: Any])["providers"] as! [String: Any]
let pm = ((pp["spark-control"] as! [String: Any])["models"] as! [[String: Any]])[0]
check(pp["homelab"] != nil && pm["id"] as? String == "qwen3.8-27b" && pm["input"] as? [String] == ["text", "image"]
      && (pm["cost"] as! [String: Any]).count == 4, "Pi: model with images, reasoning and all four cost rates")
let lm = pm["thinkingLevelMap"] as! [String: Any]
check(lm["off"] as? String == "none" && lm["low"] as? String == "low" && lm["medium"] as? String == "medium" && lm["xhigh"] as? String == "xhigh"
      && lm["minimal"] is NSNull && lm["high"] is NSNull && lm["max"] is NSNull
      && ((pp["spark-control"] as! [String: Any])["compat"] as! [String: Any])["supportsReasoningEffort"] == nil,
      "Pi: Qwen3.8 offers off, low, medium and xhigh once each")
check(Recipe(name: "gpt-oss-120b", startCommand: "", stopCommand: "").thinkingChoices == ["low", "medium", "high"]
      && Recipe(name: "Inkling 2 Mini", startCommand: "", stopCommand: "").thinkingChoices == ["none", "minimal", "low", "medium", "high", "xhigh"]
      && Recipe(name: "Qwen3.6 35B", startCommand: "", stopCommand: "").thinkingChoices == ["none", "high"],
      "thinking choices: gpt-oss can't turn off, Inkling has every distinct level, on/off models get off and on")
check(ClientTool.pi.isAdded(try! ClientTool.pi.apply(to: "", models: [], gateway: gw)), "Pi: a missing file gets created")
var long = vl; long.startCommand = "vllm serve q --max-model-len 131072"
let ctxPi = ((try! JSONSerialization.jsonObject(with: Data(try! ClientTool.pi.apply(to: "", models: [long, vl], gateway: gw).utf8)) as! [String: Any])["providers"] as! [String: Any])["spark-control"] as! [String: Any]
check((ctxPi["models"] as! [[String: Any]]).map { $0["contextWindow"] as? Int } == [131_072, 250_000]
      && (kvl["limit"] as? [String: Int])?["context"] == 250_000
      && (try! ClientTool.hermes.apply(to: "", models: [long], gateway: gw)).contains("      context_length: 131072"),
      "context from the start command, 250K when it can't be read, in all three tools")
var setCtx = vl; setCtx.context = 64_000
var saved = setCtx; saved.effort = "low"
let reloaded = try! JSONDecoder().decode(Recipe.self, from: try! JSONEncoder().encode(saved))
check(reloaded.context == 64_000 && reloaded.effort == "low", "context window and thinking effort survive a save and reload")
check(setCtx.contextWindow == 64_000 && { var l = long; l.context = 64_000; return l.contextWindow == 131_072 }(),
      "a hand-set context fills in only where the start command doesn't say")

let yaml = """
# Hermes
model:
  default: "qwen"
providers:
  homelab:
    name: Homelab
    models:
      qwen: {}
onboarding:
  seen: true
"""
let y1 = try! ClientTool.hermes.apply(to: yaml, models: [vl], gateway: gw)
check(y1.hasPrefix("# Hermes\nmodel:\n  default: \"qwen\"\nproviders:\n  spark-control:\n") && y1.contains("    homelab:") == false
      && y1.contains("  homelab:\n    name: Homelab") && y1.contains("      supports_vision: true") && y1.hasSuffix("onboarding:\n  seen: true"),
      "Hermes: provider added under providers, everything else untouched")
let y2 = try! ClientTool.hermes.apply(to: y1, models: [textOnly], gateway: gw)
check(!y2.contains("qwen3.8-27b") && y2.contains("\"nemotron-lightning\":\n        supports_vision: false")
      && y2.contains("  homelab:\n    name: Homelab") && y2.hasSuffix("onboarding:\n  seen: true")
      && y2.components(separatedBy: "spark-control:").count == 2, "Hermes: updating replaces only its own block")
check(try! ClientTool.hermes.apply(to: y2, models: [textOnly], gateway: gw) == y2, "Hermes: applying twice changes nothing")
check(try! ClientTool.hermes.apply(to: "model: x\n", models: [], gateway: gw) == "model: x\nproviders:\n  spark-control:\n    name: Spark Control\n    base_url: \"http://localhost:18080/v1\"\n    api_key: \"sk-local\"\n    api_mode: chat_completions\n    extra_headers:\n      X-Spark-Client: \"Hermes\"\n    models: {}\n",
      "Hermes: providers section created when missing")
check((try? ClientTool.hermes.apply(to: "providers: {a: 1}\n", models: [], gateway: gw)) == nil, "Hermes: inline YAML is left alone")

// Client names
check(Transform.client(spark: "Kilo Code", title: "Other", userAgent: "ai-sdk/openrouter/1.2.3") == "Kilo Code", "our header wins")
check(Transform.client(spark: nil, title: "Hermes Agent", userAgent: "OpenAI/Python 1.40.0") == "Hermes Agent", "then X-Title")
check(Transform.client(spark: nil, title: " ", userAgent: "OpenAI/Python 1.40.0") == "OpenAI/Python"
      && Transform.client(spark: nil, title: nil, userAgent: "curl/8.7.1") == "curl"
      && Transform.client(spark: nil, title: nil, userAgent: "ai-sdk/openrouter/v2.0.1 runtime/bun") == "ai-sdk/openrouter"
      && Transform.client(spark: nil, title: nil, userAgent: "MyTool") == "MyTool"
      && Transform.client(spark: nil, title: nil, userAgent: nil) == "Unknown", "else the User-Agent product without its version")
check(y2.contains("    extra_headers:\n      X-Spark-Client: \"Hermes\"") && kiloOut.contains("\"X-Spark-Client\" : \"Kilo Code\"")
      && piOut.contains("\"X-Spark-Client\" : \"Pi\""), "tool configs name themselves")

// Chat profiles shared through the Spark
let casual = ChatProfile.defaults[0], mineP = ChatProfile(name: "Mine", system: "x")
var edited = casual; edited.system = "changed"
let withProfiles = SharedModels(updated: Date(timeIntervalSince1970: 100), recipes: [], profiles: [edited])
check(withProfiles.mergedProfiles(into: [casual], local: Date(timeIntervalSince1970: 200)) == nil
      && withProfiles.mergedProfiles(into: [casual], local: Date(timeIntervalSince1970: 50)) == [edited]
      && withProfiles.mergedProfiles(into: [casual, mineP], local: nil) == [edited, mineP]
      && shared.mergedProfiles(into: [casual], local: nil) == nil,
      "newer profiles win; a first sync keeps this Mac's extra ones; a file without profiles keeps this Mac's")
check(Set(ChatProfile.defaults.map(\.id)).count == 5,
      "default profiles have fixed, distinct ids")
check((try? JSONDecoder().decode(Config.self, from: Data(#"{"recipes": []}"#.utf8)))?.profiles.count ?? 0 >= 5, "an old config gets profiles")
check((try? JSONDecoder().decode(SharedModels.self, from: JSONEncoder().encode(withProfiles)))?.profiles == [edited], "shared profiles read back")

check(Transform.chatTitle("<think>hmm</think>\n\n**Title: \"Fixing SSH timeouts.\"**\nmore") == "Fixing SSH timeouts", "title cleaned")
check(Transform.chatTitle("  \n") == nil, "empty title rejected")

// SSH keys page: parsing authorized_keys + sshd's last logins, and removing one key
let edKey = "AAAAC3NzaC1lZDI1NTE5AAAAINIt8RdpF0lXvUca/Wm7vx/katw7wF2bKmnQnlozIIDc"
let keysOut = """
# comment line
ssh-ed25519 \(edKey) test@box

from="10.0.0.0/8",no-pty ssh-ed25519 \(edKey.replacingOccurrences(of: "Dc", with: "Dd"))
"""
let parsedKeys = (keys: SSHKeys.keys(keysOut), logins: SSHKeys.logins("SHA256:imyUCfBXgOBOe/eaKRCXC94Z3QtVnWEjNYyhUGSdWio 1763038479.5 192.168.1.5\n"))
check(parsedKeys.keys.count == 2, "two keys, comments and blanks skipped")
check(parsedKeys.keys[0].comment == "test@box" && parsedKeys.keys[0].options.isEmpty, "comment parsed")
check(parsedKeys.keys[1].options == #"from="10.0.0.0/8",no-pty"# && parsedKeys.keys[1].comment.isEmpty, "options parsed")
check(parsedKeys.keys[0].fingerprint == "SHA256:imyUCfBXgOBOe/eaKRCXC94Z3QtVnWEjNYyhUGSdWio", "fingerprint matches ssh-keygen -l")
check(parsedKeys.logins[parsedKeys.keys[0].fingerprint]?.from == "192.168.1.5", "last login matched to key")

let keysHome = FileManager.default.temporaryDirectory.appending(path: "selfcheck-\(getpid())")
try! FileManager.default.createDirectory(at: keysHome.appending(path: ".ssh"), withIntermediateDirectories: true)
let akURL = keysHome.appending(path: ".ssh/authorized_keys")
try! keysOut.write(to: akURL, atomically: true, encoding: .utf8)
func removeKey(_ blob: String) -> Int32 { bash(SSHKeys.removeScript(blob), env: ["HOME": keysHome.path, "PATH": "/usr/bin:/bin"]).0 }
check(removeKey(edKey) == 0, "remove script succeeds")
let left = SSHKeys.keys(try! String(contentsOf: akURL, encoding: .utf8))
check(left.count == 1 && left[0].options.hasPrefix("from="), "only the chosen key is removed")
check(removeKey(left[0].blob) == 0 && SSHKeys.keys(try! String(contentsOf: akURL, encoding: .utf8)).isEmpty, "removing the last key works")
check(FileManager.default.fileExists(atPath: akURL.path + ".spark-control.bak"), "backup kept")
try? FileManager.default.removeItem(at: keysHome)

// Wi-Fi
let wifi = WiFi.parse("""
dev:wlP9s9
saved:Home\\:5G
saved:Office
wifi:*:72:WPA2:Office
wifi: :80:WPA2 WPA3:Home\\:5G
wifi: :40:WPA2:Home\\:5G
wifi: :65::Cafe
wifi: :30:WPA2:
wifi: :55:WPA2:Office
ssh:wlP9s9
up:wlP9s9
ts:1
last:Joined Office.
""")
check(wifi.device == "wlP9s9" && wifi.tailscale && wifi.last == "Joined Office.", "wifi status lines parse")
check(wifi.networks.map(\.ssid) == ["Office", "Home:5G", "Cafe"], "one row per network, hidden skipped, connected first then signal")
check(wifi.networks[0].inUse && wifi.networks[0].signal == 72 && wifi.networks[0].saved, "connected network keeps its best signal")
check(wifi.networks[1].saved && wifi.networks[1].signal == 80 && wifi.networks[1].security == "WPA2 WPA3", "escaped colon in SSID and saved match")
check(!wifi.networks[2].secured && !wifi.networks[2].saved, "open network")
check(wifi.reachedOverWiFi && !wifi.viaTailscale, "SSH over the Wi-Fi")
check(WiFi.parse("dev:wlan0\nssh:tailscale0\nup:wlan0\n").reachedOverWiFi, "Tailscale riding the Wi-Fi counts")
check(!WiFi.parse("dev:wlan0\nssh:tailscale0\nup:enP7s7\n").reachedOverWiFi && !WiFi.parse("dev:wlan0\nssh:enP7s7\n").reachedOverWiFi, "wired links don't")
check(WiFi.parse("ssh:enP7s7\n").device == nil && !WiFi.parse("ssh:enP7s7\n").reachedOverWiFi, "no Wi-Fi adapter")
check(WiFi.parse("noscan:1\n").scanBlocked && !wifi.scanBlocked, "refused scan noted")
for (name, s) in [("wifi list", WiFi.listScript), ("wifi switch", WiFi.switchScript("it's: \"odd\" $net"))] {
    let (code, out) = bash(s, syntaxOnly: true)
    check(code == 0, "\(name) script parses: \(out)")
}

// Hugging Face cache and Ollama
let hfStatus0 = HF.Repo(type: "model", repo: "a/b", bytes: 0, partial: 0, state: .idle, user: "")
for (name, s) in [("hf status", HF.statusScript), ("hf delete", HF.deleteScript(HF.Repo(type: "model", repo: "a/b", bytes: 0, partial: 0, state: .idle, user: ""), records: ["x"])),
                  ("hf install", HF.installScript), ("hf clean", HF.cleanScript(hfStatus0)), ("hf login", HF.loginScript), ("hf logout", HF.logoutScript), ("hf whoami", HF.whoamiScript),
                  ("ollama status", Ollama.statusScript), ("ollama pull", Ollama.pullScript("library/x:1b")), ("ollama dismiss", Ollama.dismissScript("x:1b")),
                  ("ollama install", Ollama.installCommand), ("vllm delete", VLLM.deleteScript(VLLM.catalog[0]))] {
    let (code, out) = bash(s, syntaxOnly: true)
    check(code == 0, "\(name) script parses: \(out)")
}
let hfStatus = HF.parseStatus("""
HF|2.1.1|1
REPO|model|z-lab/Qwen3.8-27B-DFlash2|3800000000|0||
REPO|model|TensorFold/Qwen3.6-35B-A3B-MLX-4bit-MTP|20900000000|0|serve|/x/tensorfold-native serve TensorFold/Qwen3.6-35B-A3B-MLX-4bit-MTP --port 18302
REPO|dataset|org/data|10|5|download|hf download org/data --repo-type dataset
""")
check(hfStatus.version == "2.1.1" && hfStatus.signedIn && hfStatus.repos.count == 3, "hf status parses")
check(hfStatus.repos[0].repo == "TensorFold/Qwen3.6-35B-A3B-MLX-4bit-MTP" && hfStatus.repos[0].state == .inUse
      && SparkMonitor.processName(hfStatus.repos[0].user) == "TensorFold", "repos sort by size and name their user")
check(hfStatus.repos[2].cacheName == "datasets--org--data" && hfStatus.repos[2].state == .downloading, "dataset cache name and download state")
check(HF.parseStatus("HF||\n").version == nil && !HF.parseStatus("HF||\n").signedIn, "no hf, no token")
check(HF.accountName(#"{"type":"user","name":"someone","orgs":[{"name":"org"}]}"#) == "someone", "whoami gives the user, not an org")

// hfrm: tidies a ref hf would skip, asks hf to remove the repo, then removes what's left.
let hfHub = FileManager.default.temporaryDirectory.appending(path: "selfcheck-hub-\(getpid())")
try! FileManager.default.createDirectory(at: hfHub.appending(path: "models--a--b/refs"), withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: hfHub.appending(path: "bin"), withIntermediateDirectories: true)
try! "abc123\n".write(to: hfHub.appending(path: "models--a--b/refs/main"), atomically: true, encoding: .utf8)
let fakeHF = hfHub.appending(path: "bin/hf")
try! "#!/bin/bash\nprintf '%s|' \"$@\" > \"$H/hf-args\"; cat \"$H/models--a--b/refs/main\" > \"$H/ref-seen\"\n".write(to: fakeHF, atomically: true, encoding: .utf8)
try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeHF.path)
let rm = bash("H=\(hfHub.path); export H\n" + HF.removeFunction + "hfrm models--a--b", env: ["PATH": hfHub.path + "/bin:/usr/bin:/bin", "HOME": hfHub.path])
check(rm.0 == 0, "hfrm runs: \(rm.1)")
check((try? String(contentsOf: hfHub.appending(path: "hf-args"), encoding: .utf8)) == "cache|rm|model/a/b|-y|", "hfrm asks hf to remove model/a/b")
check((try? String(contentsOf: hfHub.appending(path: "ref-seen"), encoding: .utf8)) == "abc123", "the ref lost its newline before hf saw it")
check(!FileManager.default.fileExists(atPath: hfHub.appending(path: "models--a--b").path), "the repo folder is gone")
try? FileManager.default.removeItem(at: hfHub)
check(TensorFold.deleteScript(q27).contains("hfrm 'models--z-lab--Qwen3.8-27B-DFlash2'") && !TensorFold.deleteScript(q27).contains("rm -rf \"$H/\"'"),
      "catalog deletes go through hfrm")

let searchHTML = """
<li><a href="/library/qwen3.8" class="group grid"><div><h2 title="qwen3.8"><span>qwen3.8</span></h2></div>
<p class="mt-1 line-clamp-2 text-[15px]">Qwen3.8 &amp; friends.</p></a></li>
<li><a href="/library/llama3.2" class="group grid"><div><h2 title="llama3.2"><span>llama3.2</span></h2></div>
<p class="mt-1 line-clamp-2 text-[15px]">Small.</p></a></li>
"""
let found = Ollama.parseSearch(searchHTML)
check(found.map(\.name) == ["qwen3.8", "llama3.2"] && found[0].summary == "Qwen3.8 & friends.", "search results parse")
let tagsHTML = """
<a href="/library/qwen3.8:latest" class="md:hidden flex"><span class="font-mono">e118e4d12a70</span> • 18GB • 256K context window •</a>
<div><a href="/library/qwen3.8:latest" class="group-hover:underline">qwen3.8:latest</a><p>18GB</p></div>
<a href="/library/qwen3.8:480b-cloud" class="md:hidden flex"><span>abc</span> • 256K context window •</a>
<a href="/library/qwen3.8:27b-bf16" class="md:hidden flex"><span class="font-mono">22130167c4c2</span> • 56GB • 256K context window •</a>
<a href="/library/qwen3.8:1b" class="md:hidden flex"><span class="font-mono">22130167c4c3</span> • 815MB • 32K context window •</a>
"""
let tags = Ollama.parseTags(tagsHTML)
check(tags == [Ollama.Tag(name: "qwen3.8:latest", bytes: 18_000_000_000), Ollama.Tag(name: "qwen3.8:27b-bf16", bytes: 56_000_000_000),
               Ollama.Tag(name: "qwen3.8:1b", bytes: 815_000_000)], "tags parse with sizes; cloud tags skipped; no size borrowed from the next tag")
check(Ollama.fits(105_000_000_000, memory: 130_594_021_376, reserve: 12_000_000_000)
      && !Ollama.fits(120_000_000_000, memory: 130_594_021_376, reserve: 12_000_000_000), "fits leaves the system reserve")
check(Ollama.searchURL("qwen coder").absoluteString == "https://ollama.com/search?q=qwen%20coder&c=local", "search asks for local models")
let ost = Ollama.parseStatus("OLLAMA|0.40.11\nJOB|ollama|user~model:7b|running|pulling 6e4c38e1172f:  45% ▕██▏ 2.1 GB/4.7 GB\nJOB|ollama|x:1b|failed|Error: pull model manifest: file does not exist\nJOB|hf|a~b|failed|x\n")
check(ost.version == "0.40.11" && ost.pulls.count == 2 && ost.pulls[0].id == "user/model:7b" && ost.pulls[0].percent == 0.45
      && ost.pulls[1].state == .failed && ost.pulls[1].percent == nil, "ollama status parses pulls")
check(Ollama.key("user/model:7b") == "ollama-user~model:7b" && Ollama.parseStatus("").version == nil, "pull records name and no Ollama")
check(Ollama.pullScript("x:1b").contains("ollama pull '\\''x:1b'\\''"), "pull quotes the model name")

// Hugging Face search and download, and the shared job records (fake Spark home with a stub hf)
let hfFound = HF.parseSearch(Data(#"[{"id":"Qwen/Qwen3.8-27B","downloads":6547772,"likes":20065,"gated":false,"library_name":"transformers"},{"id":"meta-llama/Llama-4","downloads":5,"likes":1,"gated":"manual"},{"x":1}]"#.utf8))
check(hfFound.count == 2 && hfFound[0].id == "Qwen/Qwen3.8-27B" && !hfFound[0].gated && hfFound[0].library == "transformers"
      && hfFound[1].gated && hfFound[1].library == nil, "hf search results parse; gated is false or a string")
check(HF.searchURL("qwen 27b").absoluteString.contains("search=qwen%2027b&sort=downloads&direction=-1&limit=20"), "hf search asks for the most downloaded")
let jobHome = FileManager.default.temporaryDirectory.appending(path: "selfcheck-jobs-\(getpid())")
let jobBin = jobHome.appending(path: ".local/bin")
try! FileManager.default.createDirectory(at: jobBin, withIntermediateDirectories: true)
try! "#!/bin/sh\nprintf 'Fetching 3 files:  33%%\\r'; echo \"$*\" > \"$HOME/hf-args\"; [ \"$2\" = ok/repo ]\n".write(to: jobBin.appending(path: "hf"), atomically: true, encoding: .utf8)
try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jobBin.appending(path: "hf").path)
let jobEnv = ["HOME": jobHome.path, "PATH": "/usr/bin:/bin"]
_ = bash(HF.downloadScript("ok/repo") + "\nwait", env: jobEnv)
_ = bash(HF.downloadScript("bad/repo") + "\nwait", env: jobEnv)
Thread.sleep(forTimeInterval: 0.5)
let jobOut = bash(Jobs.lines("hf"), env: jobEnv).1
let hfJobs = Jobs.parse(jobOut, "hf")
check((try? String(contentsOf: jobHome.appending(path: "hf-args"), encoding: .utf8)).map { $0.hasPrefix("download ") } == true, "the download runs hf download")
check(hfJobs.count == 2 && hfJobs.contains { $0.id == "ok/repo" && $0.state == .done }
      && hfJobs.contains { $0.id == "bad/repo" && $0.state == .failed && $0.last.contains("33%") }, "jobs report done and failed with the last progress line: \(jobOut)")
let jobAgain = bash(Jobs.lines("hf"), env: jobEnv)
check(Jobs.parse(jobAgain.1, "hf").map(\.id) == ["bad/repo"], "a finished job's records are removed once reported")
check(jobAgain.0 == 0, "the job report exits 0 when the last job isn't done, or the refresh drops it")
check(bash(Jobs.dismiss(HF.key("bad/repo")), env: jobEnv).0 == 0 && Jobs.parse(bash(Jobs.lines("hf"), env: jobEnv).1, "hf").isEmpty, "dismiss clears a failed job")
try? FileManager.default.removeItem(at: jobHome)

// GPU cap: does nothing (and asks for no sudo) when the Mac-side test box has no unit and no nvidia-smi.
check(bash(GPUCap.script, syntaxOnly: true).0 == 0, "GPU cap script parses")
check(bash("exec </dev/null; set -- off\n" + GPUCap.script).1.contains("__OK__"), "uncapping with no unit is a no-op")
check(!bash("exec </dev/null; set -- on\n" + GPUCap.script).1.contains("__NEEDS_SUDO__"), "capping checks nvidia-smi before sudo")
check(GPUCap.unit.contains("-lgc 0,\(GPUCap.mhz)") && GPUCap.unit.contains("-rgc"), "unit caps on start, resets on stop")

// Tapo TPAP (SPAKE2+) crypto primitives & Config persistence
check(TapoP256.isOnCurve(TapoP256.G) && TapoP256.isOnCurve(TapoP256.M) && TapoP256.isOnCurve(TapoP256.N), "P-256 generator points on curve")
check(TapoP256.mul(TapoP256.n, TapoP256.G) == nil, "n * G == identity")
check(TapoP256.add(TapoP256.mul(U256(12345, 0, 0, 0), TapoP256.M), TapoP256.mul(U256(67890, 0, 0, 0), TapoP256.M))
      == TapoP256.mul(U256(12345 + 67890, 0, 0, 0), TapoP256.M), "P-256 scalar multiplication linearity")
let tapoKey = Data([0x2b,0x7e,0x15,0x16,0x28,0xae,0xd2,0xa6,0xab,0xf7,0x15,0x88,0x09,0xcf,0x4f,0x3c])
let tapoNonce = Data([0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18,0x19,0x1a,0x1b])
let tapoMsg = Data(#"{"method":"set_device_info","params":{"device_on":true}}"#.utf8)
let tapoCT = try! TapoCrypto.aesCCMEncrypt(key: tapoKey, nonce: tapoNonce, plaintext: tapoMsg, tagLength: 16)
check((try? TapoCrypto.aesCCMDecrypt(key: tapoKey, nonce: tapoNonce, ciphertextAndTag: tapoCT, tagLength: 16)) == tapoMsg, "AES-128-CCM round-trip")
// Regression test: Data slice with non-zero startIndex (like raw.dropFirst(4) from /ds responses) must not crash.
let tapoFramed = Data([0, 0, 0, 1]) + tapoCT
check((try? TapoCrypto.aesCCMDecrypt(key: tapoKey, nonce: tapoNonce, ciphertextAndTag: tapoFramed.dropFirst(4), tagLength: 16)) == tapoMsg, "AES-128-CCM decrypts non-zero-based Data slices")
let tapoCMAC = try! TapoCrypto.aesCMAC(key: tapoKey, message: Data())
check(tapoCMAC.map { String(format: "%02x", $0) }.joined() == "bb1d6929e95937287fa37d129b756746", "AES-CMAC RFC 4493 empty vector")
let tapoCfg = try! JSONDecoder().decode(Config.self, from: Data(#"{"recipes":[]}"#.utf8))
check(!tapoCfg.tapo.enabled && tapoCfg.tapo.powerCycleDelaySeconds == 10, "old configs default TapoPlugConfig cleanly")

print("All checks passed")
