"""The optimization loop: budget, successive halving, and acceptance.

Spec: docs/rl-optimization.md sections 14.3, 15, 16, 17.

One round is: sample a parent from the archive, pick a family from the unlocked
arms, target it with trace evidence, propose, eliminate the broken cheaply,
score the survivors with PAIRED deltas, gate on effect size, then re-check the
winner on a rotated validation slice at a stricter threshold before accepting.

Two rules that are easy to get wrong and expensive to get wrong:

  - Stage A never eliminates on quality. Four tasks is far below the noise
    floor; it is a correctness filter and nothing more.
  - If the budget runs out mid-round, the ROUND IS ABANDONED. A candidate
    scored on a truncated batch has a standard error the gate does not expect,
    and accepting it would make the least-validated change of the run the last
    one applied.
"""

import from rl.ir { WorkflowVersion, Constraints, VersionStore, validate }
import from rl.dataset { Dataset, Task, batch_prefix, validation_subset }
import from rl.trace { TraceStore, RunRoot, runs_for }
import from rl.runtime { ExecConfig, RunContext, execute }
import from rl.stats {
    TaskScore, PairedResult, Objective, Baseline, BatchSummary,
    paired_value_delta, paired_delta, passes_gate, summarize,
    satisfies_constraints, batch_value, detectable_effect
}
import from rl.evaluate { EvalMode, EvaluatorVersion, evaluator_key, score_run }
import from rl.credit { aggregate_agents, aggregate_tools, rank_targets }
import from rl.mutate { Mutation, apply_mutation, link_lineage, describe, family_name }
import from rl.propose { propose, schema_gate }
import from rl.bandit { BanditState, select_family, record_pull, apply_phase, max_phase }
import from rl.archive { Archive, ArchiveEntry, admit, prune, sample_parent, version_of, best_entry, find_entry }


node TrainingRun {
    has label: str = "training";
    has max_rounds: int = 12;
    has budget_usd: float = 25.0;
    has spent_usd: float = 0.0;
    has round_no: int = 0;
    has stalled_rounds: int = 0;
    has patience: int = 3;
    has phase: int = 1;
    has accepted_count: int = 0;
    has stop_reason: str = "";
}


obj SearchConfig {
    has stage_a_tasks: int = 4;
    has stage_b_tasks: int = 20;
    has stage_c_tasks: int = 40;
    has candidates_per_round: int = 6;
    has stage_b_survivors: int = 4;
    has gate_k: float = 1.5;
    has gate_floor: float = 0.02;
    has val_gate_k: float = 2.0;
    has val_attempts: int = 3;
    has archive_temperature: float = 1.0;
    has seed: int = 13;
    has use_llm: bool = False;
}


node ScoreCache {
    has hits: int = 0;
    has misses: int = 0;
}


node ScoreEntry {
    has cache_key: str;
    has quality: float;
    has cost_usd: float;
    has latency_ms: float;
    has failed: bool = False;
    has schema_ok: bool = True;
}


edge Scored: ScoreCache --> ScoreEntry {
    has note: str = "";
}


"""Cache key from section 16.1.

The evaluator version is in the key so that changing the judge invalidates
cached scores instead of silently mixing two scales and calling the difference
a reward.
"""
def score_key(config_hash: str, task_id: str, version: EvaluatorVersion) -> str {
    return f"{config_hash}|{task_id}|{evaluator_key(version)}";
}


def cache_get(cache: ScoreCache, key: str) -> ScoreEntry | None {
    for e in [cache ->:Scored:->] {
        if e.cache_key == key {
            return e;
        }
    }
    return None;
}


def cache_put(cache: ScoreCache, key: str, s: TaskScore) -> ScoreEntry {
    entry = ScoreEntry(
        cache_key=key,
        quality=s.quality,
        cost_usd=s.cost_usd,
        latency_ms=s.latency_ms,
        failed=s.failed,
        schema_ok=s.schema_ok
    );
    cache +>:Scored:+> entry;
    return entry;
}


obj SearchContext {
    has run: TrainingRun;
    # The user's original workflow, kept for the cumulative drift guard.
    has origin: WorkflowVersion;
    has ds: Dataset;
    has archive: Archive;
    has bandit: BanditState;
    has store: TraceStore;
    has cache: ScoreCache;
    has versions: VersionStore;
    has constraints: Constraints;
    has goal: Objective;
    has ref: Baseline;
    has cfg: SearchConfig;
    has exec_cfg: ExecConfig;
    has version: EvaluatorVersion;
    has mode: EvalMode = EvalMode.SIMULATED;
}


def budget_remaining(run: TrainingRun) -> float {
    return run.budget_usd - run.spent_usd;
}


"""Evaluate one workflow on a task batch, honoring cache and budget.

Cost is charged HERE, per execution, as the runtime completes it - never
estimated by the optimizer, which would let an uncounted retry escape
accounting.
"""
def evaluate_on(
    ctx: SearchContext,
    wf: WorkflowVersion,
    tasks: list[Task]
) -> list[TaskScore] {
    scores: list[TaskScore] = [];

    for t in tasks {
        key = score_key(wf.config_hash, t.task_id, ctx.version);
        cached = cache_get(ctx.cache, key);
        if cached is not None {
            ctx.cache.hits += 1;
            scores.append(TaskScore(
                task_id=t.task_id,
                quality=cached.quality,
                cost_usd=cached.cost_usd,
                latency_ms=cached.latency_ms,
                failed=cached.failed,
                schema_ok=cached.schema_ok
            ));
            continue;
        }

        ctx.cache.misses += 1;
        if budget_remaining(ctx.run) <= 0.0 {
            # Out of budget mid-batch: return what we have and let the caller
            # abandon the round rather than gate on a truncated sample.
            return scores;
        }

        run_ctx = RunContext(
            task_id=t.task_id,
            task_input=t.prompt,
            category=t.category,
            difficulty=t.difficulty,
            expected_output=t.expected_output
        );
        completed = execute(wf, ctx.store, run_ctx, ctx.exec_cfg);
        ctx.run.spent_usd += completed.total_cost_usd;

        scored = score_run(completed, t, ctx.mode);
        cache_put(ctx.cache, key, scored);
        scores.append(scored);
    }

    return scores;
}


"""Stage A - correctness filter only (section 16.2).

Deliberately does NOT rank on quality: four tasks is far below the noise floor,
so any quality ordering here would be an artifact.
"""
def survives_stage_a(scores: list[TaskScore], expected: int) -> bool {
    if len(scores) < expected {
        return False;
    }
    for s in scores {
        if s.failed or not s.schema_ok {
            return False;
        }
    }
    return True;
}


obj Candidate {
    has wf: WorkflowVersion;
    has mutation: Mutation;
    has train: PairedResult;
    has summary: BatchSummary;
    has value: float = 0.0;
}


obj RoundResult {
    has round_no: int;
    has family_key: str = "";
    has proposed: int = 0;
    has valid: int = 0;
    has survived_a: int = 0;
    has gated: int = 0;
    has accepted: bool = False;
    has abandoned: bool = False;
    has reason: str = "";
    has best_hash: str = "";
    has description: str = "";
    has train_delta: float = 0.0;
    has train_se: float = 0.0;
    has val_delta: float = 0.0;
    has val_se: float = 0.0;
    has spent_usd: float = 0.0;
}


def candidate_value_key(c: Candidate) -> float {
    return -c.value;
}


"""Advance the phase when the current one stops producing (section 18).

Called on every round that actually explored - including rounds that failed
before validation. Advancing only from the accept/reject branch would leave the
search stuck in phase 1 forever whenever early stages keep rejecting.
"""
def finish_round(ctx: SearchContext, result: RoundResult) -> RoundResult {
    if ctx.run.stalled_rounds >= ctx.run.patience and ctx.run.phase < max_phase() {
        ctx.run.phase += 1;
        apply_phase(ctx.bandit, ctx.run.phase);
        ctx.run.stalled_rounds = 0;
    }
    return result;
}


"""One optimization round (section 14.3)."""
def run_round(ctx: SearchContext) -> RoundResult {
    ctx.run.round_no += 1;
    spent_at_start = ctx.run.spent_usd;
    result = RoundResult(round_no=ctx.run.round_no);

    if budget_remaining(ctx.run) <= 0.0 {
        result.abandoned = True;
        result.reason = "budget exhausted before the round began";
        return result;
    }

    parent_entry = sample_parent(ctx.archive, ctx.cfg.seed + ctx.run.round_no, ctx.cfg.archive_temperature);
    if parent_entry is None {
        result.abandoned = True;
        result.reason = "archive is empty";
        return result;
    }
    parent = version_of(parent_entry);
    if parent is None {
        result.abandoned = True;
        result.reason = "archive entry has no workflow";
        return result;
    }

    family_key = select_family(ctx.bandit);
    result.family_key = family_key;
    if family_key == "" {
        result.abandoned = True;
        result.reason = "no unlocked mutation families";
        return result;
    }

    # Targeting from trace evidence (section 10).
    parent_runs = runs_for(ctx.store, parent.config_hash);
    stats = aggregate_agents(parent_runs);
    tools = aggregate_tools(parent_runs);
    targets = rank_targets(stats);

    mutations = propose(parent, family_key, ctx.constraints, stats, tools, targets, ctx.cfg.use_llm);
    result.proposed = len(mutations);

    candidates: list[Candidate] = [];
    for m in mutations[:ctx.cfg.candidates_per_round] {
        child = apply_mutation(parent, m, ctx.constraints, ctx.versions);
        # Content addressing makes de-duplication free: a configuration the
        # archive already holds has already been paid for.
        if child is not None and find_entry(ctx.archive, child.config_hash) is None {
            child.round_no = ctx.run.round_no;
            candidates.append(Candidate(
                wf=child,
                mutation=m,
                train=PairedResult(n=0, mean_delta=0.0, se=0.0),
                summary=summarize([])
            ));
        }
    }
    result.valid = len(candidates);

    if len(candidates) == 0 {
        record_pull(ctx.bandit, family_key, 0.0);
        ctx.run.stalled_rounds += 1;
        result.reason = "no valid candidates produced";
        result.spent_usd = ctx.run.spent_usd - spent_at_start;
        return finish_round(ctx, result);
    }

    # ---- Stage A: eliminate broken candidates cheaply -------------------
    stage_a_tasks = batch_prefix(ctx.ds, "train", ctx.cfg.stage_a_tasks);
    survivors: list[Candidate] = [];
    for c in candidates {
        scores = evaluate_on(ctx, c.wf, stage_a_tasks);
        if budget_remaining(ctx.run) <= 0.0 {
            result.abandoned = True;
            result.reason = "budget exhausted during stage A";
            result.spent_usd = ctx.run.spent_usd - spent_at_start;
            return result;
        }
        if survives_stage_a(scores, len(stage_a_tasks)) {
            survivors.append(c);
        }
    }
    result.survived_a = len(survivors);

    if len(survivors) == 0 {
        record_pull(ctx.bandit, family_key, 0.0);
        ctx.run.stalled_rounds += 1;
        result.reason = "every candidate failed the correctness filter";
        result.spent_usd = ctx.run.spent_usd - spent_at_start;
        return finish_round(ctx, result);
    }

    # ---- Stage B: paired scoring on the shared batch --------------------
    stage_b_tasks = batch_prefix(ctx.ds, "train", ctx.cfg.stage_b_tasks);
    parent_scores = evaluate_on(ctx, parent, stage_b_tasks);
    if len(parent_scores) < len(stage_b_tasks) {
        result.abandoned = True;
        result.reason = "budget exhausted scoring the parent";
        result.spent_usd = ctx.run.spent_usd - spent_at_start;
        return result;
    }

    gated: list[Candidate] = [];
    for c in survivors[:ctx.cfg.stage_b_survivors] {
        cand_scores = evaluate_on(ctx, c.wf, stage_b_tasks);
        if len(cand_scores) < len(stage_b_tasks) {
            result.abandoned = True;
            result.reason = "budget exhausted during stage B";
            result.spent_usd = ctx.run.spent_usd - spent_at_start;
            return result;
        }

        # The schema gate runs BEFORE scoring is allowed to matter, so a
        # format break is a discard rather than a quality regression.
        if not schema_gate(cand_scores) {
            continue;
        }

        c.train = paired_value_delta(parent_scores, cand_scores, ctx.goal, ctx.ref);
        c.summary = summarize(cand_scores);
        c.value = c.train.mean_delta;

        # Paired quality guard, evaluated on the SAME tasks as the parent.
        if paired_delta(parent_scores, cand_scores).mean_delta < -ctx.goal.max_quality_drop {
            continue;
        }
        if not satisfies_constraints(c.summary, ctx.goal) {
            continue;
        }
        if passes_gate(c.train, ctx.cfg.gate_k, ctx.cfg.gate_floor) {
            gated.append(c);
        }
    }
    result.gated = len(gated);

    if len(gated) == 0 {
        record_pull(ctx.bandit, family_key, 0.0);
        ctx.run.stalled_rounds += 1;
        best_se = survivors[0].train.se;
        result.reason = f"no candidate cleared the gate (needed > {detectable_effect(survivors[0].train, ctx.cfg.gate_k, ctx.cfg.gate_floor):.3f}, se {best_se:.3f})";
        result.spent_usd = ctx.run.spent_usd - spent_at_start;
        return finish_round(ctx, result);
    }

    ranked = sorted(gated, key=candidate_value_key);

    # ---- Stage C: validation at a stricter threshold (section 15) --------
    # Walk the ranked candidates rather than validating only the best one. The
    # top candidate by training value is frequently the one that trades away
    # the most quality, and stopping at its rejection wastes the whole round
    # when a lower-ranked candidate would have been accepted.
    val_tasks = validation_subset(ctx.ds, ctx.run.round_no, ctx.cfg.stage_c_tasks);
    parent_val = evaluate_on(ctx, parent, val_tasks);
    if len(parent_val) < len(val_tasks) {
        result.abandoned = True;
        result.reason = "budget exhausted scoring the parent on validation";
        result.spent_usd = ctx.run.spent_usd - spent_at_start;
        return result;
    }

    origin_val = evaluate_on(ctx, ctx.origin, val_tasks);
    blocker = "no candidate reached validation";
    for candidate in ranked[:ctx.cfg.val_attempts] {
        result.best_hash = candidate.wf.config_hash;
        result.description = describe(candidate.mutation);
        result.train_delta = candidate.train.mean_delta;
        result.train_se = candidate.train.se;

        cand_val = evaluate_on(ctx, candidate.wf, val_tasks);
        if len(cand_val) < len(val_tasks) {
            result.abandoned = True;
            result.reason = "budget exhausted during validation";
            result.spent_usd = ctx.run.spent_usd - spent_at_start;
            return result;
        }

        val = paired_value_delta(parent_val, cand_val, ctx.goal, ctx.ref);
        result.val_delta = val.mean_delta;
        result.val_se = val.se;

        val_summary = summarize(cand_val);
        val_quality = paired_delta(parent_val, cand_val);
        gate_ok = passes_gate(val, ctx.cfg.val_gate_k, ctx.cfg.gate_floor);
        quality_ok = val_quality.mean_delta >= -ctx.goal.max_quality_drop;

        # Cumulative guard against the ORIGINAL workflow, not just the parent.
        # Without it, a chain of individually-acceptable regressions walks the
        # workflow somewhere the user never agreed to go.
        drift_ok = True;
        drift = paired_delta(origin_val, cand_val);
        if len(origin_val) == len(val_tasks) {
            drift_ok = drift.mean_delta >= -ctx.goal.max_cumulative_quality_drop;
        }
        constraints_ok = satisfies_constraints(val_summary, ctx.goal);
        still_valid = len(validate(candidate.wf, ctx.constraints)) == 0;

        # Name the condition that actually blocked it. Reporting the gate
        # arithmetic when the quality floor was the blocker produces messages
        # that contradict themselves.
        if not gate_ok {
            blocker = f"effect too small (delta {val.mean_delta:+.3f}, needed > {ctx.cfg.val_gate_k * val.se:.3f})";
        } elif not quality_ok {
            blocker = f"quality drop {val_quality.mean_delta:+.3f} +/- {val_quality.se:.3f} exceeds the {ctx.goal.max_quality_drop:.3f} per-step allowance";
        } elif not drift_ok {
            blocker = f"cumulative drift {drift.mean_delta:+.3f} from the original exceeds the {ctx.goal.max_cumulative_quality_drop:.3f} allowance";
        } elif not constraints_ok {
            blocker = f"violates objective constraints (quality {val_summary.quality:.3f} vs floor {ctx.goal.quality_floor:.3f}, cost {val_summary.cost_usd:.5f})";
        } elif not still_valid {
            blocker = "candidate no longer validates";
        }

        if gate_ok and quality_ok and drift_ok and constraints_ok and still_valid {
            # The bandit is rewarded on the POST-VALIDATION delta (section 13).
            record_pull(ctx.bandit, family_key, val.mean_delta);
            candidate.wf.accepted = True;
            link_lineage(
                candidate.wf, parent, candidate.mutation,
                candidate.train.mean_delta, candidate.train.se,
                val.mean_delta, val.se
            );
            admit(
                ctx.archive,
                candidate.wf,
                batch_value(cand_val, ctx.goal, ctx.ref),
                val_summary.quality,
                val_summary.cost_usd,
                val_summary.latency_ms
            );
            prune(ctx.archive);
            ctx.run.accepted_count += 1;
            ctx.run.stalled_rounds = 0;
            result.accepted = True;
            result.reason = "validated improvement";
            result.spent_usd = ctx.run.spent_usd - spent_at_start;
            return finish_round(ctx, result);
        }
    }

    record_pull(ctx.bandit, family_key, 0.0);
    ctx.run.stalled_rounds += 1;
    result.reason = f"rejected on validation: {blocker}";
    result.spent_usd = ctx.run.spent_usd - spent_at_start;
    return finish_round(ctx, result);
}


def should_stop(run: TrainingRun) -> str {
    if run.round_no >= run.max_rounds {
        return "max rounds reached";
    }
    if run.budget_usd - run.spent_usd <= 0.0 {
        return "budget exhausted";
    }
    if run.phase >= max_phase() and run.stalled_rounds >= run.patience * 2 {
        return "no improvement across every unlocked family";
    }
    return "";
}


"""Run rounds until a stop condition fires."""
def train(ctx: SearchContext) -> list[RoundResult] {
    history: list[RoundResult] = [];
    while True {
        reason = should_stop(ctx.run);
        if reason != "" {
            ctx.run.stop_reason = reason;
            break;
        }
        history.append(run_round(ctx));
    }
    return history;
}


"""Seed the archive with the user's original workflow (section 4)."""
def establish_baseline(ctx: SearchContext, wf: WorkflowVersion) -> list[TaskScore] {
    tasks = batch_prefix(ctx.ds, "train", ctx.cfg.stage_b_tasks);
    scores = evaluate_on(ctx, wf, tasks);
    s = summarize(scores);

    # Cost and latency normalization is relative to THIS baseline, so it has to
    # be recorded before any candidate is scored (section 8.1).
    ctx.ref.cost_usd = s.cost_usd if s.cost_usd > 0.0 else 1.0;
    ctx.ref.latency_ms = s.latency_ms if s.latency_ms > 0.0 else 1.0;

    admit(ctx.archive, wf, batch_value(scores, ctx.goal, ctx.ref), s.quality, s.cost_usd, s.latency_ms);
    return scores;
}
