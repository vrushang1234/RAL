"""Execution traces and the tool record/replay cache.

Spec: docs/rl-optimization.md sections 5 and 6.

Spans are persisted as nodes hung off a run root, so the whole execution
history is queryable with ordinary graph reads - that is what makes the credit
assignment in section 10 cheap.

The tool cache is the highest-leverage single mechanism in the system: it cuts
cost, latency, and variance at the same time. External tools are the largest
uncontrolled variance source, and an unpinned web search makes a mutation
effect indistinguishable from the hour of the day.
"""

import json;


node TraceStore {
    has name: str = "traces";
}


node RunRoot {
    has run_id: str;
    has config_hash: str;
    has task_id: str;
    has started_at: str = "";
    has ok: bool = True;
    has stop_reason: str = "complete";
    has total_cost_usd: float = 0.0;
    has total_latency_ms: float = 0.0;
    has critical_path_ms: float = 0.0;
    has output_text: str = "";
    has schema_ok: bool = True;
    # Ground-truth quality, only populated on the simulated path. The live path
    # leaves this at 0.0 and gets its quality from an evaluator in evaluate.jac.
    has final_quality: float = 0.0;
}


node Span {
    has agent_id: str;
    has model: str;
    # Ordering lives on the span, not only the edge: Jac edge objects cannot be
    # correlated back to their endpoints, so sorting by an edge field would
    # depend on undocumented iteration order.
    has seq: int = 0;
    has output_text: str = "";
    has prompt_version: str = "";
    has tools_available: list[str] = [];
    has tools_invoked: list[str] = [];
    has tool_influenced_output: bool = False;
    has input_tokens: int = 0;
    has output_tokens: int = 0;
    has latency_ms: float = 0.0;
    has cost_usd: float = 0.0;
    has retry_count: int = 0;
    has edited_upstream: bool = False;
    # Whether an edit signal is meaningful for this agent at all. Without this,
    # "edit_rate == 0" cannot be distinguished from "edits are not measured
    # here", and the topology proposer reads every worker as inert.
    has measures_edits: bool = False;
    has error: str = "";
}


edge Recorded: RunRoot --> Span {
    has seq: int = 0;
}


edge Logged: TraceStore --> RunRoot {
    has note: str = "";
}


node ToolCacheStore {
    has epoch: str = "e1";
    has hits: int = 0;
    has misses: int = 0;
}


node ToolCacheEntry {
    has cache_key: str;
    has tool_name: str;
    has result_json: str;
    has recorded_at: str = "";
}


edge CachedAs: ToolCacheStore --> ToolCacheEntry {
    has note: str = "";
}


def record_run(store: TraceStore, run: RunRoot) -> RunRoot {
    store +>:Logged:+> run;
    return run;
}


def add_span(run: RunRoot, span: Span, seq: int) -> Span {
    span.seq = seq;
    run +>:Recorded(seq=seq):+> span;
    run.total_cost_usd += span.cost_usd;
    run.total_latency_ms += span.latency_ms;
    return span;
}


"""Sort key for spans. A named def, not a lambda: a lambda inside a `def` does
not bind when the module is imported elsewhere (NameError on __jac_lambda_N)."""
def span_seq(s: Span) -> int {
    return s.seq;
}


"""Spans of a run in execution order."""
def spans_of(run: RunRoot) -> list[Span] {
    return sorted([run ->:Recorded:->], key=span_seq);
}


def runs_for(store: TraceStore, wanted_hash: str) -> list[RunRoot] {
    return [r for r in [store ->:Logged:->] if r.config_hash == wanted_hash];
}


"""Canonical argument encoding so equivalent calls share a cache entry."""
def normalize_args(args: dict[str, str]) -> str {
    ordered: list[list[str]] = [];
    for k in sorted(args.keys()) {
        ordered.append([k, args[k].strip().lower()]);
    }
    return json.dumps(ordered, separators=(",", ":"));
}


"""Cache key from section 6.1.

`dataset_epoch` is in the key so the recorded environment can be deliberately
refreshed as a unit, rather than silently mixing observations captured months
apart.
"""
def tool_cache_key(tool_name: str, normalized: str, dataset_epoch: str) -> str {
    return f"{tool_name}|{normalized}|{dataset_epoch}";
}


def cache_lookup(store: ToolCacheStore, key: str) -> ToolCacheEntry | None {
    for entry in [store ->:CachedAs:->] {
        if entry.cache_key == key {
            return entry;
        }
    }
    return None;
}


def cache_record(store: ToolCacheStore, key: str, tool_name: str, result: str) -> ToolCacheEntry {
    entry = ToolCacheEntry(cache_key=key, tool_name=tool_name, result_json=result);
    store +>:CachedAs:+> entry;
    return entry;
}


"""Replay a recorded tool result, or None on a miss.

A miss is the normal and correct outcome when a mutation changes which tool is
called or with what arguments - the caller falls through to a live call and
records the result, so the cache converges on whatever the search actually
explores.
"""
def replay_or_miss(
    store: ToolCacheStore,
    tool_name: str,
    args: dict[str, str],
    epoch: str
) -> str | None {
    key = tool_cache_key(tool_name, normalize_args(args), epoch);
    entry = cache_lookup(store, key);
    if entry is None {
        store.misses += 1;
        return None;
    }
    store.hits += 1;
    return entry.result_json;
}


def remember(
    store: ToolCacheStore,
    tool_name: str,
    args: dict[str, str],
    epoch: str,
    result: str
) -> ToolCacheEntry {
    key = tool_cache_key(tool_name, normalize_args(args), epoch);
    existing = cache_lookup(store, key);
    if existing is not None {
        existing.result_json = result;
        return existing;
    }
    return cache_record(store, key, tool_name, result);
}


def cache_hit_rate(store: ToolCacheStore) -> float {
    total = store.hits + store.misses;
    if total == 0 {
        return 0.0;
    }
    return store.hits / total;
}


"""Critical-path latency estimate (section 6.3).

Wall-clock is dominated by provider queueing at these batch sizes, so it is
recorded but not scored. This estimate is deterministic given the trace and
still responds to the mutations that genuinely move latency - parallelization,
model swaps, shorter prompts, conditional skips.
"""
def critical_path_ms(run: RunRoot, ms_per_output_token: float) -> float {
    total = 0.0;
    for s in spans_of(run) {
        total += s.output_tokens * ms_per_output_token;
    }
    return total;
}
