"""Tests for archive admission, pruning, sampling, and the Pareto frontier."""

import from rl.ir { VersionStore, Stores }


def stored(store: VersionStore, tag: str) -> WorkflowVersion {
    wf = WorkflowVersion(label=tag, config_hash=tag);
    store +>:Stores:+> wf;
    return wf;
}


test "admitting a version records its metrics" {
    store = VersionStore();
    archive = Archive(capacity=4);
    admit(archive, stored(store, "aaa"), 0.5, 0.8, 0.02, 1000.0);

    found = find_entry(archive, "aaa");
    assert found is not None;
    if found is not None {
        assert abs(found.score - 0.5) < 1e-9;
        assert abs(found.quality - 0.8) < 1e-9;
    }
}


test "the same configuration is never archived twice" {
    store = VersionStore();
    archive = Archive(capacity=4);
    wf = stored(store, "aaa");
    admit(archive, wf, 0.5, 0.8, 0.02, 1000.0);
    admit(archive, wf, 0.9, 0.9, 0.01, 900.0);

    assert len(entries_of(archive)) == 1, "content addressing makes de-duplication free";
    found = find_entry(archive, "aaa");
    assert found is not None;
    if found is not None {
        assert abs(found.score - 0.9) < 1e-9, "the entry must be updated in place";
    }
}


test "entries come back best-first" {
    store = VersionStore();
    archive = Archive(capacity=8);
    admit(archive, stored(store, "low"), 0.1, 0.7, 0.03, 1200.0);
    admit(archive, stored(store, "high"), 0.9, 0.9, 0.01, 800.0);
    admit(archive, stored(store, "mid"), 0.5, 0.8, 0.02, 1000.0);

    order = [e.config_hash for e in entries_of(archive)];
    assert order == ["high", "mid", "low"], f"got {order}";

    best = best_entry(archive);
    assert best is not None;
    if best is not None {
        assert best.config_hash == "high";
    }
}


test "pruning drops the weakest beyond capacity" {
    store = VersionStore();
    archive = Archive(capacity=2);
    admit(archive, stored(store, "a"), 0.9, 0.9, 0.01, 800.0);
    admit(archive, stored(store, "b"), 0.5, 0.8, 0.02, 900.0);
    admit(archive, stored(store, "c"), 0.1, 0.7, 0.03, 1000.0);

    assert prune(archive) == 1;
    remaining = [e.config_hash for e in entries_of(archive)];
    assert remaining == ["a", "b"], f"got {remaining}";
    assert prune(archive) == 0, "pruning at capacity is a no-op";
}


test "a version can be recovered from its archive entry" {
    store = VersionStore();
    archive = Archive(capacity=4);
    wf = stored(store, "aaa");
    item = admit(archive, wf, 0.5, 0.8, 0.02, 1000.0);
    recovered = version_of(item);
    assert recovered is not None;
    if recovered is not None {
        assert recovered.config_hash == "aaa";
    }
}


test "domination requires being no worse everywhere and better somewhere" {
    strong = ArchiveEntry(config_hash="s", score=1.0, quality=0.9, cost_usd=0.01, latency_ms=500.0);
    weak = ArchiveEntry(config_hash="w", score=0.1, quality=0.8, cost_usd=0.02, latency_ms=900.0);
    tradeoff = ArchiveEntry(config_hash="t", score=0.5, quality=0.95, cost_usd=0.09, latency_ms=1500.0);

    assert dominates(strong, weak);
    assert not dominates(weak, strong);
    assert not dominates(strong, tradeoff), "higher quality at higher cost is a trade, not a loss";
    assert not dominates(tradeoff, strong);
}


test "the frontier keeps trade-offs and drops dominated points" {
    store = VersionStore();
    archive = Archive(capacity=8);
    # 'dominated' is worse than 'balanced' on every axis.
    admit(archive, stored(store, "cheap"), 0.6, 0.75, 0.005, 400.0);
    admit(archive, stored(store, "balanced"), 0.8, 0.85, 0.020, 900.0);
    admit(archive, stored(store, "accurate"), 0.7, 0.95, 0.090, 1600.0);
    admit(archive, stored(store, "dominated"), 0.2, 0.80, 0.050, 1200.0);

    front = sorted([e.config_hash for e in pareto_frontier(archive)]);
    assert front == ["accurate", "balanced", "cheap"], f"got {front}";
}


test "operating points name the four choices a user makes" {
    store = VersionStore();
    archive = Archive(capacity=8);
    admit(archive, stored(store, "cheap"), 0.6, 0.75, 0.005, 400.0);
    admit(archive, stored(store, "balanced"), 0.8, 0.85, 0.020, 900.0);
    admit(archive, stored(store, "accurate"), 0.7, 0.95, 0.090, 1600.0);

    points = operating_points(archive);
    assert points.best_quality == "accurate";
    assert points.best_cost == "cheap";
    assert points.best_latency == "cheap";
    assert points.best_overall == "balanced", "best overall follows the scalarized score";
}


test "sampling can reach beyond the single best entry" {
    store = VersionStore();
    archive = Archive(capacity=8);
    admit(archive, stored(store, "a"), 0.9, 0.9, 0.01, 800.0);
    admit(archive, stored(store, "b"), 0.8, 0.88, 0.012, 850.0);
    admit(archive, stored(store, "c"), 0.7, 0.86, 0.014, 900.0);

    picked: list[str] = [];
    for seed in range(40) {
        chosen = sample_parent(archive, seed, 1.0);
        if chosen is not None {
            picked.append(chosen.config_hash);
        }
    }
    assert len(set(picked)) > 1, "always returning the best reduces the archive to one incumbent";
    assert picked.count("a") > picked.count("c"), "sampling must still favour higher scores";
}


test "zero temperature collapses to the greedy choice" {
    store = VersionStore();
    archive = Archive(capacity=8);
    admit(archive, stored(store, "a"), 0.9, 0.9, 0.01, 800.0);
    admit(archive, stored(store, "b"), 0.8, 0.88, 0.012, 850.0);

    for seed in range(10) {
        chosen = sample_parent(archive, seed, 0.0);
        assert chosen is not None;
        if chosen is not None {
            assert chosen.config_hash == "a";
        }
    }
}


test "an empty archive yields nothing rather than failing" {
    archive = Archive(capacity=4);
    assert sample_parent(archive, 1, 1.0) is None;
    assert best_entry(archive) is None;
    assert pareto_frontier(archive) == [];
}
