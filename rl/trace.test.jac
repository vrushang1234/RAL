"""Tests for trace ordering and the tool record/replay cache."""

def build_run(hash_val: str) -> RunRoot {
    store = TraceStore();
    run = RunRoot(run_id="r1", config_hash=hash_val, task_id="t0");
    record_run(store, run);
    return run;
}


test "spans come back in execution order regardless of insertion order" {
    run = build_run("h1");
    add_span(run, Span(agent_id="reviewer", model="large"), 3);
    add_span(run, Span(agent_id="classifier", model="small"), 1);
    add_span(run, Span(agent_id="support", model="large"), 2);

    ids = [s.agent_id for s in spans_of(run)];
    assert ids == ["classifier", "support", "reviewer"], f"got {ids}";
}


test "adding a span accumulates run totals" {
    run = build_run("h2");
    add_span(run, Span(agent_id="a", model="m", cost_usd=0.05, latency_ms=800.0), 1);
    add_span(run, Span(agent_id="b", model="m", cost_usd=0.07, latency_ms=1200.0), 2);
    assert abs(run.total_cost_usd - 0.12) < 1e-9;
    assert abs(run.total_latency_ms - 2000.0) < 1e-9;
}


test "runs are retrievable by config hash" {
    store = TraceStore();
    record_run(store, RunRoot(run_id="r1", config_hash="aaa", task_id="t0"));
    record_run(store, RunRoot(run_id="r2", config_hash="bbb", task_id="t0"));
    record_run(store, RunRoot(run_id="r3", config_hash="aaa", task_id="t1"));

    assert len(runs_for(store, "aaa")) == 2;
    assert len(runs_for(store, "bbb")) == 1;
    assert len(runs_for(store, "ccc")) == 0;
}


test "argument normalization is order and whitespace insensitive" {
    a = normalize_args({"q": "API 401", "limit": "5"});
    b = normalize_args({"limit": "5", "q": "  api 401  "});
    assert a == b, "equivalent calls must share one cache entry";
}


test "different arguments produce different keys" {
    a = tool_cache_key("web_search", normalize_args({"q": "401"}), "e1");
    b = tool_cache_key("web_search", normalize_args({"q": "403"}), "e1");
    assert a != b;
}


test "the dataset epoch partitions the cache" {
    args = {"q": "401"};
    a = tool_cache_key("web_search", normalize_args(args), "e1");
    b = tool_cache_key("web_search", normalize_args(args), "e2");
    assert a != b, "refreshing the epoch must not mix old and new recordings";
}


test "first call misses, then replays" {
    store = ToolCacheStore(epoch="e1");
    args = {"q": "api key 401"};

    assert replay_or_miss(store, "doc_search", args, "e1") is None;
    assert store.misses == 1 and store.hits == 0;

    remember(store, "doc_search", args, "e1", "{\"doc\": \"auth-guide\"}");

    replayed = replay_or_miss(store, "doc_search", args, "e1");
    assert replayed is not None;
    assert store.hits == 1;
    if replayed is not None {
        assert "auth-guide" in replayed;
    }
}


test "a changed argument is a miss - which is the correct behavior" {
    store = ToolCacheStore(epoch="e1");
    remember(store, "web_search", {"q": "401"}, "e1", "old");
    # A mutation that changes what the agent searches for must go live.
    assert replay_or_miss(store, "web_search", {"q": "403"}, "e1") is None;
}


test "remembering twice updates rather than duplicating" {
    store = ToolCacheStore(epoch="e1");
    args = {"q": "x"};
    remember(store, "doc_search", args, "e1", "first");
    remember(store, "doc_search", args, "e1", "second");

    entries = [store ->:CachedAs:->];
    assert len(entries) == 1, f"expected one entry, got {len(entries)}";
    got = replay_or_miss(store, "doc_search", args, "e1");
    assert got == "second";
}


test "hit rate reflects replay effectiveness" {
    store = ToolCacheStore(epoch="e1");
    args = {"q": "x"};
    assert cache_hit_rate(store) == 0.0;

    _ = replay_or_miss(store, "t", args, "e1");
    remember(store, "t", args, "e1", "v");
    _ = replay_or_miss(store, "t", args, "e1");
    _ = replay_or_miss(store, "t", args, "e1");

    assert abs(cache_hit_rate(store) - (2.0 / 3.0)) < 1e-9;
}


test "critical path is deterministic and token-driven" {
    run = build_run("h3");
    add_span(run, Span(agent_id="a", model="m", output_tokens=100, latency_ms=5000.0), 1);
    add_span(run, Span(agent_id="b", model="m", output_tokens=300, latency_ms=200.0), 2);

    # 400 output tokens at 8ms/token - independent of the noisy wall-clock above.
    assert abs(critical_path_ms(run, 8.0) - 3200.0) < 1e-9;
}


test "shortening output shortens the critical path estimate" {
    long_run = build_run("h4");
    add_span(long_run, Span(agent_id="a", model="m", output_tokens=1500), 1);

    short_run = build_run("h5");
    add_span(short_run, Span(agent_id="a", model="m", output_tokens=400), 1);

    assert critical_path_ms(short_run, 8.0) < critical_path_ms(long_run, 8.0);
}
