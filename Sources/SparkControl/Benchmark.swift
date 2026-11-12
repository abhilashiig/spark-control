import Foundation

/// The oMLX-style benchmark (spark-omlx-bench.py), run on the Spark against a model's own port so the
/// memory column is real and the network isn't timed.
enum Benchmark {
    struct Single: Codable, Hashable {
        var pp: Int
        var tg: Int?
        var ttftMs: Double?
        var tpotMs: Double?
        var ppTps: Double?
        var tgTps: Double?
        var e2eS: Double?
        var throughput: Double?
        var peakMemGb: Double?
        var error: String?
    }

    struct Batch: Codable, Hashable {
        var batch: Int
        var tgTps: Double?
        var speedup: Double?
        var ppTps: Double?
        var ppTpsPerReq: Double?
        var ttftMs: Double?
        var e2eS: Double?
        var error: String?
    }

    struct Result: Codable, Hashable {
        var model: String
        var started: String
        var exactSizing: Bool
        var context: Int?
        var skipped: [Int]?
        var single: [Single]
        var batch: [Batch]
        var batchPp: Int?
    }

    static let marker = "__SPARK_BENCH_RESULT__"

    static func parse(_ line: String) -> Result? {
        guard line.hasPrefix(marker) else { return nil }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try? d.decode(Result.self, from: Data(line.dropFirst(marker.count).utf8))
    }

    static let dir = "$HOME/.local/share/spark-control/bench"

    /// Writes the script, starts it detached and prints its pid. `keyExpr` is a shell expression for the
    /// backend's API key, or nil.
    static func launchScript(port: Int, model: String, keyExpr: String?) -> String {
        """
        D="\(dir)"; mkdir -p "$D"
        cat > "$D/bench.py" <<'SPARK_BENCH_PY'
        \(script)
        SPARK_BENCH_PY
        \(keyExpr.map { "export BENCH_API_KEY=\($0)" } ?? "unset BENCH_API_KEY")
        nohup python3 -u "$D/bench.py" --base http://127.0.0.1:\(port)\(model.isEmpty ? "" : " --model " + SSH.quote(model)) > "$D/run.log" 2>&1 < /dev/null &
        echo $!
        """
    }

    static let script = #"""
#!/usr/bin/env python3
"""
spark-omlx-bench (Spark Control edition): the oMLX benchmark methodology against an
OpenAI-compatible server.

Single request : pp N / tg 128 for N in 32768, 65536, 131072, 200000 (sizes past the context are skipped)
Batching       : pp 1024 / tg 128 at 1x (baseline), 2x, 4x concurrent

Prompts are synthetic Python code with a unique nonce at the very start (cold prefix).
Prompt length is exact when the server has /tokenize (vLLM, TensorFold): token IDs are sent.
Output length is forced with ignore_eos. BENCH_API_KEY is sent as a bearer token when set.
"""
import argparse, json, os, random, socket, sys, threading, time, urllib.request, uuid
from datetime import datetime
from urllib.parse import urlparse

MARKER = "__SPARK_BENCH_RESULT__"

def headers():
    h = {"Content-Type": "application/json"}
    if os.environ.get("BENCH_API_KEY"):
        h["Authorization"] = "Bearer " + os.environ["BENCH_API_KEY"]
    return h

def http_json(url, payload=None, timeout=120):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=headers())
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

def http_error(e):
    if isinstance(e, urllib.error.HTTPError):
        try:
            body = e.read().decode("utf-8", "replace")
            msg = json.loads(body).get("error", {})
            return f"HTTP {e.code}: {msg.get('message', body) if isinstance(msg, dict) else msg}"[:300]
        except Exception:
            return f"HTTP {e.code}"
    return str(e)[:300]

def model_info(base, model):
    data = http_json(f"{base}/v1/models")["data"]
    entry = next((m for m in data if m.get("id") == model), data[0])
    ctx = entry.get("max_model_len") or entry.get("context_length")
    return entry["id"], int(ctx) if ctx else None

WORDS = ["user", "order", "cache", "token", "buffer", "stream", "config", "record",
         "item", "batch", "queue", "index", "value", "node", "graph", "layer",
         "weight", "score", "table", "event", "shard", "route", "frame", "chunk"]

def py_block(rng, i):
    a, b, c = rng.sample(WORDS, 3)
    n = rng.randint(2, 9)
    return (f"def {a}_{b}_{i}({c}s, limit={n}):\n"
            f"    \"\"\"Process {c}s for the {a} {b} pass number {i}.\"\"\"\n"
            f"    result = []\n"
            f"    for idx, {c} in enumerate({c}s):\n"
            f"        if idx >= limit * {rng.randint(10, 99)}:\n"
            f"            break\n"
            f"        result.append(({c}, idx % {n}, hash(str({c})) & 0x{rng.randint(0, 0xffff):04x}))\n"
            f"    return sorted(result, key=lambda t: t[1])\n\n")

class PromptBuilder:
    def __init__(self, base, model):
        self.base, self.model = base, model
        self.can_tokenize = True
        self.chars_per_tok = 3.2
        try:
            sample = "".join(py_block(random.Random(0), i) for i in range(50))
            n = self._tokenize(sample)["count"]
            self.chars_per_tok = len(sample) / n
        except Exception as e:
            print(f"! /tokenize unavailable ({http_error(e)}); falling back to approximate sizing")
            self.can_tokenize = False

    def _tokenize(self, text):
        return http_json(f"{self.base}/tokenize", {"model": self.model, "prompt": text}, timeout=600)

    def build(self, target):
        nonce = uuid.uuid4().hex
        rng = random.Random(nonce)
        text = f"# benchmark run {nonce}\n# Python module under review\n\n"
        i = 0
        margin = 1.10
        while True:
            while len(text) / self.chars_per_tok < target * margin:
                text += py_block(rng, i); i += 1
            if not self.can_tokenize:
                return text, False
            toks = self._tokenize(text)["tokens"]
            if len(toks) >= target:
                return toks[:target], True
            margin += 0.10

def stream_completion(base, model, prompt, max_tokens, timeout):
    payload = {"model": model, "prompt": prompt, "max_tokens": max_tokens,
               "ignore_eos": True, "temperature": 0,
               "stream": True, "stream_options": {"include_usage": True}}
    req = urllib.request.Request(f"{base}/v1/completions", data=json.dumps(payload).encode(), headers=headers())
    t0 = time.perf_counter()
    t_first, usage = None, None
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            obj = json.loads(data)
            if obj.get("error"):
                raise RuntimeError(str(obj["error"])[:300])
            if obj.get("usage"):
                usage = obj["usage"]
            ch = obj.get("choices") or []
            if t_first is None and ch and ch[0].get("text"):
                t_first = time.perf_counter()
    t_end = time.perf_counter()
    if t_first is None:
        t_first = t_end
    usage = usage or {}
    return {"t0": t0, "t_first": t_first, "t_end": t_end,
            "ttft": t_first - t0, "e2e": t_end - t0,
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens") or max_tokens}

class MemSampler(threading.Thread):
    """Unified memory on GB10: host MemTotal - MemAvailable is the honest number."""
    def __init__(self):
        super().__init__(daemon=True)
        self.peak, self._stop = 0.0, threading.Event()
    @staticmethod
    def used_gb():
        info = {}
        with open("/proc/meminfo") as f:
            for l in f:
                k, v = l.split(":", 1)
                info[k] = int(v.split()[0])
        return (info["MemTotal"] - info["MemAvailable"]) / 1024 / 1024
    def reset(self):
        self.peak = self.used_gb()
    def run(self):
        while not self._stop.is_set():
            self.peak = max(self.peak, self.used_gb())
            time.sleep(0.2)
    def stop(self):
        self._stop.set()

def is_local(base):
    host = urlparse(base).hostname or ""
    return host in ("127.0.0.1", "localhost", "::1", socket.gethostname(),
                    socket.gethostname() + ".local")

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="http://127.0.0.1:18300")
    ap.add_argument("--model", help="default: first model from /v1/models")
    ap.add_argument("--pp", default="32768,65536,131072,200000")
    ap.add_argument("--tg", type=int, default=128)
    ap.add_argument("--batch", default="2,4")
    ap.add_argument("--batch-pp", type=int, default=1024)
    ap.add_argument("--no-mem", action="store_true")
    ap.add_argument("--timeout", type=int, default=1800)
    args = ap.parse_args()

    base = args.base.rstrip("/")
    if base.endswith("/v1"):
        base = base[:-3]
    model, ctx = model_info(base, args.model)
    tg = args.tg
    pps = [int(x) for x in args.pp.split(",") if x]
    skipped = [n for n in pps if ctx and n + tg > ctx]
    pps = [n for n in pps if n not in skipped]
    fit = (ctx - tg) // 1024 * 1024 if ctx else 0
    if skipped and fit > 0 and fit not in pps:
        pps.append(fit)  # the largest prompt the context holds
    batches = [int(x) for x in args.batch.split(",") if x]

    mem = None
    if not args.no_mem and os.path.exists("/proc/meminfo") and is_local(base):
        mem = MemSampler(); mem.start()

    builder = PromptBuilder(base, model)
    results = {"model": model, "base": base, "started": datetime.now().isoformat(timespec="seconds"),
               "exact_sizing": builder.can_tokenize, "context": ctx, "skipped": skipped,
               "batch_pp": args.batch_pp, "single": [], "batch": []}

    print(f"Benchmark Model: {model}")
    print(f"Server: {base}   context: {ctx or 'unknown'}")
    print(f"Context: Code (Python)   sizing: {'exact (token IDs)' if builder.can_tokenize else 'approximate'}")
    if skipped:
        print(f"Skipping prompts past the {ctx}-token context: {', '.join(map(str, skipped))}")
    print("=" * 96)

    print("Warming up")
    w, _ = builder.build(256)
    stream_completion(base, model, w, 8, args.timeout)

    print("\nSingle Request Results")
    print("-" * 96)
    print(f"{'Test':<18}{'TTFT(ms)':>10}{'TPOT(ms)':>10}{'pp TPS':>14}{'tg TPS':>12}"
          f"{'E2E(s)':>10}{'Throughput':>14}{'Peak Mem':>11}")
    for n in pps:
        print(f"pp{n}/tg{tg} …")
        try:
            prompt, _ = builder.build(n)
            if mem: mem.reset()
            r = stream_completion(base, model, prompt, tg, args.timeout)
        except Exception as e:
            results["single"].append({"pp": n, "error": http_error(e)})
            print(f"pp{n}/tg{tg} failed: {http_error(e)}")
            continue
        p = r["prompt_tokens"] or n
        c = r["completion_tokens"]
        tpot = (r["e2e"] - r["ttft"]) / max(c - 1, 1)
        row = {"pp": p, "tg": c, "ttft_ms": r["ttft"] * 1000, "tpot_ms": tpot * 1000,
               "pp_tps": p / r["ttft"], "tg_tps": 1 / tpot, "e2e_s": r["e2e"],
               "throughput": (p + c) / r["e2e"], "peak_mem_gb": mem.peak if mem else None}
        results["single"].append(row)
        memtxt = f"{row['peak_mem_gb']:.2f} GB" if mem else "-"
        print(f"{f'pp{p}/tg{c}':<18}{row['ttft_ms']:>10.1f}{row['tpot_ms']:>10.2f}"
              f"{row['pp_tps']:>10.1f} t/s{row['tg_tps']:>8.1f} t/s{row['e2e_s']:>10.3f}"
              f"{row['throughput']:>10.1f} t/s{memtxt:>11}")

    if batches:
        print(f"\nContinuous Batching\npp{args.batch_pp} / tg{tg}")
        print("-" * 96)
        print(f"{'Batch':<8}{'tg TPS':>12}{'Speedup':>10}{'pp TPS':>14}{'pp TPS/req':>14}"
              f"{'TTFT(ms)':>11}{'E2E(s)':>9}")
        single_tg = None
        for b in [1] + batches:
            try:
                prompts = [builder.build(args.batch_pp)[0] for _ in range(b)]
                out, errs, barrier = [None] * b, [], threading.Barrier(b)
                def worker(k):
                    barrier.wait()
                    try:
                        out[k] = stream_completion(base, model, prompts[k], tg, args.timeout)
                    except Exception as e:
                        errs.append(http_error(e))
                ths = [threading.Thread(target=worker, args=(k,)) for k in range(b)]
                for t in ths: t.start()
                for t in ths: t.join()
                if errs:
                    raise RuntimeError(errs[0])
            except Exception as e:
                results["batch"].append({"batch": b, "error": http_error(e)})
                print(f"{b}x failed: {http_error(e)}")
                continue
            start = min(o["t0"] for o in out)
            first = min(o["t_first"] for o in out)
            end = max(o["t_end"] for o in out)
            tot_p = sum(o["prompt_tokens"] or args.batch_pp for o in out)
            tot_c = sum(o["completion_tokens"] for o in out)
            agg_tg = (tot_c - b) / max(end - first, 1e-9)
            pp_tps = tot_p / max(o["ttft"] for o in out)
            if b == 1:
                single_tg = agg_tg
            row = {"batch": b, "tg_tps": agg_tg, "speedup": agg_tg / single_tg if single_tg else None,
                   "pp_tps": pp_tps, "pp_tps_per_req": pp_tps / b,
                   "ttft_ms": sum(o["ttft"] for o in out) / b * 1000, "e2e_s": end - start}
            results["batch"].append(row)
            print(f"{f'{b}x':<8}{agg_tg:>8.1f} t/s{(row['speedup'] or 0):>9.2f}x{pp_tps:>10.1f} t/s"
                  f"{row['pp_tps_per_req']:>10.1f} t/s{row['ttft_ms']:>11.1f}{row['e2e_s']:>9.3f}")

    if mem: mem.stop()
    outdir = os.path.expanduser("~/spark-bench-results")
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, f"omlx-style-{datetime.now():%Y%m%d-%H%M%S}.json")
    with open(path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nSaved: {path}")
    print(MARKER + json.dumps(results))

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"Benchmark failed: {http_error(e)}")
        sys.exit(1)
"""#
}
