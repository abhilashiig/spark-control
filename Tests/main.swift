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

print("All checks passed")
