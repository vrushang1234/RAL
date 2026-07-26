"""Tests for scoring, pairing, and the significance gate.

Several of these pin numbers quoted in docs/rl-optimization.md. If the spec's
tables and the code ever disagree, these fail.
"""

def scores_from(quals: list[float], prefix: str) -> list[TaskScore] {
    out: list[TaskScore] = [];
    for i in range(len(quals)) {
        out.append(TaskScore(task_id=f"{prefix}{i}", quality=quals[i]));
    }
    return out;
}


def binary_scores(oks: list[bool]) -> list[TaskScore] {
    out: list[TaskScore] = [];
    for i in range(len(oks)) {
        out.append(TaskScore(
            task_id=f"t{i}",
            quality=1.0 if oks[i] else 0.0,
            failed=not oks[i]
        ));
    }
    return out;
}


test "paired delta computes the mean of per-task differences" {
    base = scores_from([0.5, 0.6, 0.7, 0.8], "t");
    cand = scores_from([0.6, 0.7, 0.8, 0.9], "t");
    r = paired_delta(base, cand);
    assert r.n == 4;
    assert abs(r.mean_delta - 0.1) < 1e-9, f"got {r.mean_delta}";
    assert r.se < 1e-9, "a constant shift has zero variance in the differences";
}


test "pairing cancels task difficulty" {
    # Task difficulty spans the whole range; the candidate is uniformly +0.05.
    quals = [0.10, 0.95, 0.30, 0.80, 0.20, 0.90, 0.40, 0.70];
    base = scores_from(quals, "t");
    cand = scores_from([q + 0.05 for q in quals], "t");

    paired = paired_delta(base, cand);
    assert abs(paired.mean_delta - 0.05) < 1e-9;
    assert paired.se < 1e-9, "paired SE collapses because difficulty cancels";

    # Unpaired, the same data carries the full spread of task difficulty.
    unpaired_se = paired_se_estimate(0.3, 0.0, len(quals));
    assert unpaired_se > 0.14, f"unpaired SE should stay large, got {unpaired_se}";
}


test "section 9.1 standard-error table" {
    # Unpaired is the rho=0 case of the same formula.
    assert abs(paired_se_estimate(0.3, 0.0, 5) - 0.190) < 0.001;
    assert abs(paired_se_estimate(0.3, 0.0, 20) - 0.095) < 0.001;
    assert abs(paired_se_estimate(0.3, 0.0, 40) - 0.067) < 0.001;

    assert abs(paired_se_estimate(0.3, 0.8, 5) - 0.085) < 0.001;
    assert abs(paired_se_estimate(0.3, 0.8, 20) - 0.042) < 0.001;
    assert abs(paired_se_estimate(0.3, 0.8, 40) - 0.030) < 0.001;
}


test "the gate rejects the doc's coin-flip reward" {
    # +0.09 against an unpaired SE of 0.19 at n=5 - half a standard error.
    r = PairedResult(n=5, mean_delta=0.09, se=0.19);
    assert not passes_gate(r, 1.5, 0.02), "must not accept noise on sign alone";
}


test "the gate accepts a real effect at n=20" {
    r = PairedResult(n=20, mean_delta=0.09, se=0.042);
    assert passes_gate(r, 1.5, 0.02);
}


test "the gate enforces an absolute floor as well as significance" {
    # Statistically clean but too small to be worth accepting.
    r = PairedResult(n=200, mean_delta=0.005, se=0.0005);
    assert not passes_gate(r, 1.5, 0.02), "significance alone is not enough";
}


test "detectable effect reports the instrument's resolution" {
    r = PairedResult(n=20, mean_delta=0.0, se=0.042);
    assert abs(detectable_effect(r, 1.5, 0.02) - 0.063) < 0.001;
}


test "required_n answers the planning question" {
    # To detect a 0.05 effect at k=1.5, sd=0.3, rho=0.8.
    n = required_n(0.3, 0.8, 0.05, 1.5);
    assert n > 30 and n < 40, f"got {n}";
    got = paired_se_estimate(0.3, 0.8, n);
    assert 1.5 * got <= 0.05 + 1e-9, "n must actually clear the gate";
}


test "section 21.2 - a 72 to 88 percent swing is not significant" {
    # 25 tasks: 17 both-ok, 1 regressed, 5 improved, 2 both-fail.
    base_oks: list[bool] = [];
    cand_oks: list[bool] = [];
    for i in range(25) {
        if i < 17 {
            base_oks.append(True);
            cand_oks.append(True);
        } elif i == 17 {
            base_oks.append(True);
            cand_oks.append(False);
        } elif i < 23 {
            base_oks.append(False);
            cand_oks.append(True);
        } else {
            base_oks.append(False);
            cand_oks.append(False);
        }
    }

    base = binary_scores(base_oks);
    cand = binary_scores(cand_oks);

    assert abs(summarize(base).quality - 0.72) < 1e-9;
    assert abs(summarize(cand).quality - 0.88) < 1e-9;

    m = mcnemar(base, cand, 0.5);
    assert m.b == 1 and m.c == 5, f"discordant pairs b={m.b} c={m.c}";
    assert abs(m.p_value - 0.21875) < 1e-6, f"got p={m.p_value}";
    assert m.p_value > 0.05, "the headline number does not survive a paired test";
}


test "mcnemar with no discordant pairs is p=1" {
    base = binary_scores([True, True, False, False]);
    cand = binary_scores([True, True, False, False]);
    m = mcnemar(base, cand, 0.5);
    assert m.b == 0 and m.c == 0;
    assert m.p_value == 1.0;
}


test "bootstrap CI is seeded and brackets the mean" {
    deltas = [0.02, 0.05, 0.09, 0.01, 0.07, 0.04, 0.06, 0.03];
    a = bootstrap_ci(deltas, 500, 0.05, 42);
    b = bootstrap_ci(deltas, 500, 0.05, 42);
    assert a == b, "same seed must reproduce the interval";

    mean = sum(deltas) / len(deltas);
    assert a[0] < mean and mean < a[1], f"mean {mean} outside {a}";
}


test "cost and latency are normalized against baseline" {
    goal = Objective();
    ref = Baseline(cost_usd=0.20, latency_ms=10000.0);
    s = TaskScore(task_id="t", quality=1.0, cost_usd=0.20, latency_ms=10000.0);
    # At exactly baseline, both ratios are 1.0.
    expected = 0.70 * 1.0 - 0.05 * 1.0 - 0.03 * 1.0;
    assert abs(task_value(s, goal, ref) - expected) < 1e-9;
}


test "halving the cost improves the composite score" {
    goal = Objective();
    ref = Baseline(cost_usd=0.20, latency_ms=10000.0);
    dear = TaskScore(task_id="t", quality=0.8, cost_usd=0.20, latency_ms=10000.0);
    cheap = TaskScore(task_id="t", quality=0.8, cost_usd=0.10, latency_ms=10000.0);
    assert task_value(cheap, goal, ref) > task_value(dear, goal, ref);
}


test "the quality floor is a hard rejection regardless of cost" {
    goal = Objective(quality_floor=0.70);
    cheap_and_wrong = summarize([
        TaskScore(task_id="a", quality=0.69, cost_usd=0.001),
        TaskScore(task_id="b", quality=0.69, cost_usd=0.001)
    ]);
    assert not satisfies_constraints(cheap_and_wrong, goal);
}


test "cost and latency constraints bind independently" {
    goal = Objective(max_cost_usd=0.15, max_latency_ms=8000.0);
    over_cost = summarize([TaskScore(task_id="a", quality=0.9, cost_usd=0.20, latency_ms=1000.0)]);
    over_latency = summarize([TaskScore(task_id="a", quality=0.9, cost_usd=0.05, latency_ms=9000.0)]);
    ok = summarize([TaskScore(task_id="a", quality=0.9, cost_usd=0.05, latency_ms=1000.0)]);
    assert not satisfies_constraints(over_cost, goal);
    assert not satisfies_constraints(over_latency, goal);
    assert satisfies_constraints(ok, goal);
}


test "objective presets shift the weights they claim to" {
    q = objective_preset(ObjectiveKind.MAX_QUALITY, 0.0);
    c = objective_preset(ObjectiveKind.MIN_COST, 0.7);
    l = objective_preset(ObjectiveKind.MIN_LATENCY, 0.7);
    assert q.w_quality > c.w_quality;
    assert c.w_cost > q.w_cost;
    assert l.w_latency > q.w_latency;
    assert c.quality_floor == 0.7, "min-cost must keep a binding quality floor";
}


test "paired value delta accounts for cost, not just quality" {
    goal = Objective();
    ref = Baseline(cost_usd=0.20, latency_ms=1000.0);
    base = [
        TaskScore(task_id="a", quality=0.80, cost_usd=0.20, latency_ms=1000.0),
        TaskScore(task_id="b", quality=0.80, cost_usd=0.20, latency_ms=1000.0)
    ];
    # Same quality, half the cost - invisible to paired_delta, visible here.
    cand = [
        TaskScore(task_id="a", quality=0.80, cost_usd=0.10, latency_ms=1000.0),
        TaskScore(task_id="b", quality=0.80, cost_usd=0.10, latency_ms=1000.0)
    ];
    assert abs(paired_delta(base, cand).mean_delta) < 1e-9;
    assert paired_value_delta(base, cand, goal, ref).mean_delta > 0.0;
}


test "empty and single-task batches never pass the gate" {
    empty: list[TaskScore] = [];
    assert paired_delta(empty, empty).n == 0;
    assert not passes_gate(paired_delta(empty, empty), 1.5, 0.02);

    one_base = scores_from([0.5], "t");
    one_cand = scores_from([0.9], "t");
    r = paired_delta(one_base, one_cand);
    assert r.n == 1;
    assert not passes_gate(r, 1.5, 0.02), "n=1 has no variance estimate";
}
