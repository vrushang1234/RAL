"""Scoring, paired deltas, and the significance gate.

Spec: docs/rl-optimization.md sections 4, 8, 9, 21.

This is the load-bearing module. The whole optimizer is only as good as its
ability to tell a real improvement from noise, and that ability lives here.

The one rule everything else follows: diff per task, THEN aggregate. Candidates
are always evaluated on the same tasks, so the comparison is naturally paired
and task difficulty - the dominant variance component - cancels. Aggregating
first throws that away and roughly doubles the standard error for free.
"""

import math;
import random;


obj TaskScore {
    has task_id: str;
    has quality: float;
    has cost_usd: float = 0.0;
    has latency_ms: float = 0.0;
    has failed: bool = False;
    has schema_ok: bool = True;
}


obj PairedResult {
    has n: int;
    has mean_delta: float;
    has se: float;
    has ci_low: float = 0.0;
    has ci_high: float = 0.0;
}


obj BatchSummary {
    has n: int;
    has quality: float;
    has cost_usd: float;
    has latency_ms: float;
    has failure_rate: float;
    has schema_ok_rate: float;
}


"""Reference values for normalizing cost and latency (section 8.1)."""
obj Baseline {
    has cost_usd: float = 1.0;
    has latency_ms: float = 1.0;
}


enum ObjectiveKind { MAX_QUALITY, MIN_COST, MIN_LATENCY, BALANCED, CUSTOM }


"""What the user is optimizing for (section 8.2).

Weights apply to BASELINE-RELATIVE ratios, never raw dollars or milliseconds,
so `w_cost` reads as 'how much quality one baseline-cost-unit is worth'.

`max_cost_usd` / `max_latency_ms` of 0.0 mean unconstrained. Preferring these
constraints over pure scalarization is what stops a large cost saving from
buying a quality loss the user would never have approved.
"""
obj Objective {
    has kind: ObjectiveKind = ObjectiveKind.BALANCED;
    has w_quality: float = 0.70;
    has w_cost: float = 0.05;
    has w_latency: float = 0.03;
    has w_failure: float = 0.15;
    has quality_floor: float = 0.0;
    # Maximum tolerated PAIRED quality drop against the parent on the same
    # tasks. This is the constraint that actually binds. An absolute floor is
    # calibrated on one sample and applied to another, so on a rotated
    # validation slice it measures task difficulty as much as quality.
    has max_quality_drop: float = 0.02;
    # Maximum tolerated drop against the ORIGINAL workflow. Per-step guards are
    # parent-relative, so a sequence of individually-tolerable regressions
    # composes into an intolerable one; observed in the demo as four accepted
    # steps each within 0.02 that summed to -0.029 against baseline.
    has max_cumulative_quality_drop: float = 0.03;
    has max_cost_usd: float = 0.0;
    has max_latency_ms: float = 0.0;
}


def objective_preset(kind: ObjectiveKind, quality_floor: float) -> Objective {
    if kind == ObjectiveKind.MAX_QUALITY {
        return Objective(
            kind=kind, w_quality=0.90, w_cost=0.01, w_latency=0.01,
            w_failure=0.15, quality_floor=quality_floor
        );
    }
    if kind == ObjectiveKind.MIN_COST {
        return Objective(
            kind=kind, w_quality=0.40, w_cost=0.35, w_latency=0.02,
            w_failure=0.15, quality_floor=quality_floor
        );
    }
    if kind == ObjectiveKind.MIN_LATENCY {
        return Objective(
            kind=kind, w_quality=0.40, w_cost=0.02, w_latency=0.35,
            w_failure=0.15, quality_floor=quality_floor
        );
    }
    return Objective(kind=kind, quality_floor=quality_floor);
}


def summarize(scores: list[TaskScore]) -> BatchSummary {
    n = len(scores);
    if n == 0 {
        return BatchSummary(
            n=0, quality=0.0, cost_usd=0.0, latency_ms=0.0,
            failure_rate=0.0, schema_ok_rate=1.0
        );
    }
    total_q = 0.0;
    total_c = 0.0;
    total_l = 0.0;
    fails = 0;
    schema_ok = 0;
    for s in scores {
        total_q += s.quality;
        total_c += s.cost_usd;
        total_l += s.latency_ms;
        if s.failed {
            fails += 1;
        }
        if s.schema_ok {
            schema_ok += 1;
        }
    }
    return BatchSummary(
        n=n,
        quality=total_q / n,
        cost_usd=total_c / n,
        latency_ms=total_l / n,
        failure_rate=fails / n,
        schema_ok_rate=schema_ok / n
    );
}


"""Composite score for one task, with cost and latency normalized to baseline."""
def task_value(s: TaskScore, goal: Objective, base: Baseline) -> float {
    cost_ratio = s.cost_usd / base.cost_usd if base.cost_usd > 0.0 else 0.0;
    latency_ratio = s.latency_ms / base.latency_ms if base.latency_ms > 0.0 else 0.0;
    failure = 1.0 if s.failed else 0.0;
    return (
        goal.w_quality * s.quality
        - goal.w_cost * cost_ratio
        - goal.w_latency * latency_ratio
        - goal.w_failure * failure
    );
}


def batch_value(scores: list[TaskScore], goal: Objective, base: Baseline) -> float {
    if len(scores) == 0 {
        return 0.0;
    }
    total = 0.0;
    for s in scores {
        total += task_value(s, goal, base);
    }
    return total / len(scores);
}


"""Hard constraints from section 8.2, plus the quality floor from 8.3.

The floor is a cliff by design: a candidate at floor+e dominates one at
floor-e regardless of cost. That is the intended safety behavior, which is
exactly why the floor is a deliberate setting and not a silent default.
"""
def satisfies_constraints(s: BatchSummary, goal: Objective) -> bool {
    if s.quality < goal.quality_floor {
        return False;
    }
    if goal.max_cost_usd > 0.0 and s.cost_usd > goal.max_cost_usd {
        return False;
    }
    if goal.max_latency_ms > 0.0 and s.latency_ms > goal.max_latency_ms {
        return False;
    }
    return True;
}


def paired_from_maps(base_map: dict[str, float], cand_map: dict[str, float]) -> PairedResult {
    deltas: list[float] = [];
    for k in sorted(cand_map.keys()) {
        if k in base_map {
            deltas.append(cand_map[k] - base_map[k]);
        }
    }

    n = len(deltas);
    if n < 2 {
        mean_one = deltas[0] if n == 1 else 0.0;
        return PairedResult(n=n, mean_delta=mean_one, se=0.0);
    }

    mean = sum(deltas) / n;
    variance = sum([(d - mean) ** 2 for d in deltas]) / (n - 1);
    se = math.sqrt(variance / n);
    return PairedResult(n=n, mean_delta=mean, se=se);
}


"""Paired delta on raw quality - the number shown to users in section 20."""
def paired_delta(base: list[TaskScore], cand: list[TaskScore]) -> PairedResult {
    base_map: dict[str, float] = {};
    for s in base {
        base_map[s.task_id] = s.quality;
    }
    cand_map: dict[str, float] = {};
    for s in cand {
        cand_map[s.task_id] = s.quality;
    }
    return paired_from_maps(base_map, cand_map);
}


"""Paired delta on the composite objective - the number the gate acts on."""
def paired_value_delta(
    base: list[TaskScore],
    cand: list[TaskScore],
    goal: Objective,
    ref: Baseline
) -> PairedResult {
    base_map: dict[str, float] = {};
    for s in base {
        base_map[s.task_id] = task_value(s, goal, ref);
    }
    cand_map: dict[str, float] = {};
    for s in cand {
        cand_map[s.task_id] = task_value(s, goal, ref);
    }
    return paired_from_maps(base_map, cand_map);
}


"""The significance gate (section 9.3).

Acceptance requires the effect to clear BOTH a multiple of its own standard
error and an absolute floor. Gating on sign alone accepts a true-null mutation
about half the time, which is the single fastest way to make this whole system
produce confident nonsense.

At k=1.5 and n=20 paired, the detectable effect is roughly 0.06 - that is the
honest resolution of the instrument, and it belongs in the UI. The way to buy
resolution is more tasks per comparison, never a looser k.
"""
def passes_gate(r: PairedResult, k: float, floor: float) -> bool {
    if r.n < 2 {
        return False;
    }
    if r.mean_delta < floor {
        return False;
    }
    if r.se <= 0.0 {
        return r.mean_delta > 0.0;
    }
    return r.mean_delta > k * r.se;
}


"""Smallest delta this comparison could have accepted - report alongside a rejection."""
def detectable_effect(r: PairedResult, k: float, floor: float) -> float {
    return max(k * r.se, floor);
}


"""Percentile bootstrap CI over paired deltas (section 21.1).

Seeded so a report regenerated from the same scores is identical.
"""
def bootstrap_ci(deltas: list[float], iters: int, alpha: float, seed: int) -> list[float] {
    n = len(deltas);
    if n < 2 {
        return [0.0, 0.0];
    }
    rng = random.Random(seed);
    means: list[float] = [];
    for _i in range(iters) {
        total = 0.0;
        for _j in range(n) {
            total += deltas[rng.randrange(n)];
        }
        means.append(total / n);
    }
    means.sort();
    lo_idx = int((alpha / 2.0) * iters);
    hi_idx = int((1.0 - alpha / 2.0) * iters) - 1;
    return [means[max(lo_idx, 0)], means[min(hi_idx, iters - 1)]];
}


def with_ci(
    base: list[TaskScore],
    cand: list[TaskScore],
    iters: int,
    seed: int
) -> PairedResult {
    r = paired_delta(base, cand);
    base_map: dict[str, float] = {};
    for s in base {
        base_map[s.task_id] = s.quality;
    }
    deltas: list[float] = [];
    for s in cand {
        if s.task_id in base_map {
            deltas.append(s.quality - base_map[s.task_id]);
        }
    }
    bounds = bootstrap_ci(deltas, iters, 0.05, seed);
    r.ci_low = bounds[0];
    r.ci_high = bounds[1];
    return r;
}


obj McNemarResult {
    has b: int;
    has c: int;
    has p_value: float;
}


"""Exact two-sided McNemar test for binary task success (section 21.1).

What matters is the discordant pairs (b, c), not the marginal success rates.
A 72% -> 88% swing on 25 tasks looks impressive and is not significant; this
is the function that says so.
"""
def mcnemar(base: list[TaskScore], cand: list[TaskScore], threshold: float) -> McNemarResult {
    base_map: dict[str, bool] = {};
    for s in base {
        base_map[s.task_id] = (not s.failed) and s.quality >= threshold;
    }

    b = 0;
    c = 0;
    for s in cand {
        if s.task_id in base_map {
            cand_ok = (not s.failed) and s.quality >= threshold;
            base_ok = base_map[s.task_id];
            if base_ok and not cand_ok {
                b += 1;
            }
            if cand_ok and not base_ok {
                c += 1;
            }
        }
    }

    n = b + c;
    if n == 0 {
        return McNemarResult(b=b, c=c, p_value=1.0);
    }

    lo = min(b, c);
    tail = 0.0;
    for i in range(lo + 1) {
        tail += math.comb(n, i);
    }
    p = 2.0 * tail / (2.0 ** n);
    return McNemarResult(b=b, c=c, p_value=min(p, 1.0));
}


"""Standard error of a paired difference at given per-task sd and correlation.

Planning helper: answers 'how many tasks do I need to detect an effect of X?'
without spending a single API call. Section 9.1's table comes from this.
"""
def paired_se_estimate(sd: float, rho: float, n: int) -> float {
    if n < 2 {
        return 0.0;
    }
    sd_diff = sd * math.sqrt(2.0 * (1.0 - rho));
    return sd_diff / math.sqrt(n);
}


"""Smallest batch size at which `effect` would clear the k-sigma gate."""
def required_n(sd: float, rho: float, effect: float, k: float) -> int {
    if effect <= 0.0 {
        return 0;
    }
    sd_diff = sd * math.sqrt(2.0 * (1.0 - rho));
    n = ((k * sd_diff) / effect) ** 2;
    return max(int(math.ceil(n)), 2);
}
