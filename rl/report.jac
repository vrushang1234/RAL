"""Explainability and the final before/after comparison.

Spec: docs/rl-optimization.md sections 20 and 21.

The lineage DAG built in `mutate.link_lineage` IS the explanation - every
accepted change already carries its mutation kind, target, before/after values,
train delta with standard error, and rationale. Reporting is a traversal, not a
separate bookkeeping system.

Every stated change carries its uncertainty. Reporting a bare delta is what
lets a 16-point swing that is not statistically significant get presented as a
result, and section 21.2 exists specifically to stop that.
"""

import from rl.ir { WorkflowVersion, DerivedFrom }
import from rl.stats {
    TaskScore, PairedResult, McNemarResult,
    paired_delta, with_ci, mcnemar, summarize
}
import from rl.archive { Archive, ArchiveEntry, pareto_frontier, operating_points, OperatingPoints }
import from rl.bandit { BanditState, report_arms, ArmReport }


obj ChangeRecord {
    has family: str;
    has kind: str;
    has target: str;
    has before: str;
    has after: str;
    has train_delta: float;
    has train_se: float;
    has val_delta: float;
    has rationale: str;
}


def parent_of(wf: WorkflowVersion) -> WorkflowVersion | None {
    parents = [wf ->:DerivedFrom:->];
    if len(parents) == 0 {
        return None;
    }
    return parents[0];
}


def change_into(wf: WorkflowVersion) -> ChangeRecord | None {
    edges = [edge wf ->:DerivedFrom:->];
    if len(edges) == 0 {
        return None;
    }
    e = edges[0];
    return ChangeRecord(
        family=e.family,
        kind=e.mutation_kind,
        target=e.target,
        before=e.before,
        after=e.after,
        train_delta=e.train_delta,
        train_se=e.train_se,
        val_delta=e.val_delta,
        rationale=e.rationale
    );
}


"""Every accepted change from the original workflow to this one, oldest first."""
def lineage(wf: WorkflowVersion) -> list[ChangeRecord] {
    chain: list[ChangeRecord] = [];
    current: WorkflowVersion | None = wf;
    guard = 0;

    while current is not None and guard < 256 {
        record = change_into(current);
        if record is None {
            break;
        }
        chain.append(record);
        current = parent_of(current);
        guard += 1;
    }

    chain.reverse();
    return chain;
}


def origin_of(wf: WorkflowVersion) -> WorkflowVersion {
    current = wf;
    guard = 0;
    while guard < 256 {
        up = parent_of(current);
        if up is None {
            return current;
        }
        current = up;
        guard += 1;
    }
    return current;
}


"""Render one change with its uncertainty, as section 20 requires."""
def explain(record: ChangeRecord) -> str {
    headline = f"{record.kind} on [{record.target}]";
    if record.before != "" or record.after != "" {
        headline = f"{headline}: {record.before} -> {record.after}";
    }
    stats_line = f"train delta {record.train_delta:+.3f} +/- {record.train_se:.3f}, validation {record.val_delta:+.3f}";
    if record.rationale != "" {
        return f"{headline}\n  {record.rationale}\n  {stats_line}";
    }
    return f"{headline}\n  {stats_line}";
}


obj ComparisonRow {
    has metric: str;
    has original: float;
    has optimized: float;
    has delta: float;
}


obj FinalReport {
    has rows: list[ComparisonRow];
    has quality: PairedResult;
    has success: McNemarResult;
    has n_tasks: int;
    has significant: bool;
    has caveat: str;
}


"""Compare the original and optimized workflows on the held-out test set.

Paired throughout, with a bootstrap interval on quality and McNemar on binary
success. The `caveat` field is not decoration: at hackathon-sized test sets a
visually impressive swing routinely fails to reach significance, and the report
must say so rather than let the point estimate speak alone.
"""
def final_report(
    base_scores: list[TaskScore],
    opt_scores: list[TaskScore],
    success_threshold: float,
    seed: int
) -> FinalReport {
    base = summarize(base_scores);
    opt = summarize(opt_scores);

    quality = with_ci(base_scores, opt_scores, 2000, seed);
    success = mcnemar(base_scores, opt_scores, success_threshold);

    rows: list[ComparisonRow] = [
        ComparisonRow(
            metric="task success",
            original=1.0 - base.failure_rate,
            optimized=1.0 - opt.failure_rate,
            delta=base.failure_rate - opt.failure_rate
        ),
        ComparisonRow(
            metric="quality",
            original=base.quality,
            optimized=opt.quality,
            delta=opt.quality - base.quality
        ),
        ComparisonRow(
            metric="cost per task (usd)",
            original=base.cost_usd,
            optimized=opt.cost_usd,
            delta=opt.cost_usd - base.cost_usd
        ),
        ComparisonRow(
            metric="latency, critical path (ms)",
            original=base.latency_ms,
            optimized=opt.latency_ms,
            delta=opt.latency_ms - base.latency_ms
        ),
        ComparisonRow(
            metric="format compliance",
            original=base.schema_ok_rate,
            optimized=opt.schema_ok_rate,
            delta=opt.schema_ok_rate - base.schema_ok_rate
        )
    ];

    # Three outcomes, not two. An interval entirely below zero is a
    # SIGNIFICANT REGRESSION, and reporting that as "not significant" would be
    # the exact failure this module exists to prevent.
    improved = quality.ci_low > 0.0;
    regressed = quality.ci_high < 0.0;
    significant = improved;

    caveat = "";
    if regressed {
        caveat = (
            f"QUALITY REGRESSED. The interval [{quality.ci_low:+.3f}, {quality.ci_high:+.3f}] "
            f"on n={quality.n} lies entirely below zero, so this is a real loss, not noise. "
            "The optimizer traded quality for the other objectives within the limits it was "
            "given - if that is not wanted, raise the quality floor."
        );
    } elif not improved {
        caveat = (
            f"Inconclusive. The quality interval [{quality.ci_low:+.3f}, {quality.ci_high:+.3f}] "
            f"spans zero and McNemar p={success.p_value:.3f} on n={quality.n} does not clear a "
            "conventional threshold. Treat the point estimates as directional; a larger test "
            "set is the only thing that fixes this."
        );
    }

    return FinalReport(
        rows=rows,
        quality=quality,
        success=success,
        n_tasks=quality.n,
        significant=significant,
        caveat=caveat
    );
}


def format_report(summary_of: FinalReport) -> str {
    lines: list[str] = [
        f"{'metric':<32}{'original':>14}{'optimized':>14}{'delta':>12}",
        "-" * 72
    ];
    for r in summary_of.rows {
        lines.append(f"{r.metric:<32}{r.original:>14.4f}{r.optimized:>14.4f}{r.delta:>+12.4f}");
    }
    lines.append("");
    lines.append(
        f"paired quality delta: {summary_of.quality.mean_delta:+.4f} "
        f"(95% CI [{summary_of.quality.ci_low:+.4f}, {summary_of.quality.ci_high:+.4f}], n={summary_of.n_tasks})"
    );
    lines.append(
        f"McNemar on task success: b={summary_of.success.b} c={summary_of.success.c} p={summary_of.success.p_value:.4f}"
    );
    if summary_of.caveat != "" {
        lines.append("");
        lines.append(f"CAVEAT: {summary_of.caveat}");
    }
    return "\n".join(lines);
}


obj FrontierRow {
    has config_hash: str;
    has label: str;
    has quality: float;
    has cost_usd: float;
    has latency_ms: float;
}


"""The operating points a user chooses between (section 14.1)."""
def frontier_rows(archive: Archive) -> list[FrontierRow] {
    out: list[FrontierRow] = [];
    for e in pareto_frontier(archive) {
        out.append(FrontierRow(
            config_hash=e.config_hash,
            label=e.label,
            quality=e.quality,
            cost_usd=e.cost_usd,
            latency_ms=e.latency_ms
        ));
    }
    return out;
}


def format_frontier(archive: Archive) -> str {
    points = operating_points(archive);
    lines: list[str] = [
        f"{'config':<20}{'quality':>10}{'cost':>12}{'latency':>12}",
        "-" * 54
    ];
    for r in frontier_rows(archive) {
        lines.append(f"{r.config_hash:<20}{r.quality:>10.4f}{r.cost_usd:>12.5f}{r.latency_ms:>12.1f}");
    }
    lines.append("");
    lines.append(f"best quality : {points.best_quality}");
    lines.append(f"best cost    : {points.best_cost}");
    lines.append(f"best latency : {points.best_latency}");
    lines.append(f"best overall : {points.best_overall}");
    return "\n".join(lines);
}


"""Bandit arm summary - presented as exploration history, not learned policy."""
def format_arms(state: BanditState) -> str {
    lines: list[str] = [
        f"{'family':<12}{'pulls':>8}{'mean reward':>14}{'unlocked':>10}",
        "-" * 44
    ];
    for a in report_arms(state) {
        lines.append(f"{a.family_key:<12}{a.pulls:>8}{a.mean_reward:>14.4f}{str(a.unlocked):>10}");
    }
    lines.append("");
    lines.append(
        "Arm statistics are an exploration record. At these pull counts they are "
        "not a converged estimate of which family works."
    );
    return "\n".join(lines);
}
