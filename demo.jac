"""End-to-end optimization run on the support workflow from spec section 22.

Runs entirely against the deterministic simulator in `rl/simulate.jac`, so it
needs no API keys and produces the same result every time. What it demonstrates
is the loop itself: baseline, targeted proposals, paired scoring, the
significance gate, validation, and an explainable diff.

    jac run demo.jac
"""

import from rl.ir { AgentSpec, WorkflowVersion, Entry, FlowsTo, Constraints, VersionStore, reseal, validate }
import from rl.dataset { Dataset, Task, add_task, stratified_split, split_tasks, batch_prefix }
import from rl.trace { TraceStore }
import from rl.runtime { ExecConfig }
import from rl.stats { TaskScore, Objective, Baseline, ObjectiveKind, objective_preset, summarize }
import from rl.evaluate { EvalMode, EvaluatorVersion }
import from rl.bandit { BanditState, init_bandit }
import from rl.archive { Archive, best_entry, version_of }
import from rl.search {
    TrainingRun, SearchConfig, SearchContext, ScoreCache,
    establish_baseline, train, evaluate_on
}
import from rl.report { lineage, explain, final_report, format_report, format_frontier, format_arms }


def build_workflow -> WorkflowVersion {
    wf = WorkflowVersion(label="support-v1");
    classifier = AgentSpec(
        agent_id="classifier",
        role="Classify support requests",
        model="large",
        prompt="Classify the request as billing, technical, or account.",
        max_tokens=1200
    );
    support = AgentSpec(
        agent_id="support",
        role="Resolve customer problems",
        model="large",
        prompt="Resolve the customer's problem using the tools available.",
        tools=["doc_search", "web_search"],
        max_tokens=1500
    );
    reviewer = AgentSpec(
        agent_id="reviewer",
        role="Review responses for correctness",
        model="large",
        prompt="Review the answer for correctness.",
        max_tokens=600
    );

    root ++> wf;
    wf +>:Entry:+> classifier;
    classifier +>:FlowsTo(to_agent="support"):+> support;
    support +>:FlowsTo(to_agent="reviewer"):+> reviewer;
    return reseal(wf);
}


"""Score the optimized workflow, falling back to the baseline when nothing was
accepted. Early-return narrowing keeps the optional out of the call site."""
def scores_for_optimized(
    ctx: SearchContext,
    optimized: WorkflowVersion | None,
    tasks: list[Task],
    fallback: list[TaskScore]
) -> list[TaskScore] {
    if optimized is None {
        return fallback;
    }
    return evaluate_on(ctx, optimized, tasks);
}


def describe_changes(optimized: WorkflowVersion | None) -> list[str] {
    if optimized is None {
        return [];
    }
    return [explain(ch) for ch in lineage(optimized)];
}


def build_dataset -> Dataset {
    ds = Dataset(name="support-tickets", seed=7);
    root ++> ds;
    cats = ["billing", "technical", "account"];
    diffs = ["easy", "hard"];
    n = 0;
    for c in cats {
        for d in diffs {
            for _i in range(15) {
                add_task(ds, Task(
                    task_id=f"task-{n:03d}",
                    prompt=f"[{c}/{d}] customer request {n}",
                    category=c,
                    difficulty=d,
                    rubric="correctness, completeness, grounding"
                ));
                n += 1;
            }
        }
    }
    return ds;
}


with entry:__main__ {
    print("=" * 72);
    print("Multi-agent workflow optimization - simulated environment");
    print("=" * 72);

    constraints = Constraints(
        approved_tools=["doc_search", "web_search"],
        # Ordered cheapest-first: the model family reads 'cheaper' as 'earlier'.
        approved_models=["small", "large"],
        max_retries=3
    );

    wf = build_workflow();
    issues = validate(wf, constraints);
    if len(issues) > 0 {
        print("initial workflow is invalid:");
        for i in issues {
            print(f"  {i.code}: {i.detail}");
        }
    }

    ds = build_dataset();
    counts = stratified_split(ds, 0.5, 0.3);
    print(f"\ndataset: {counts['train']} train / {counts['validation']} validation / {counts['test']} test");

    # Attach every container to root BEFORE populating it. Connecting a node to
    # root after it already has outgoing edges drops those edges silently, so
    # `init_bandit` on a detached state would produce an armless bandit.
    training = TrainingRun(label="demo", max_rounds=12, budget_usd=5.0, patience=2);
    archive = Archive(capacity=8);
    store = TraceStore();
    cache = ScoreCache();
    bandit_state = BanditState(seed=5);
    versions = VersionStore();
    root ++> training;
    root ++> versions;
    root ++> archive;
    root ++> store;
    root ++> cache;
    root ++> bandit_state;
    bandit = init_bandit(bandit_state, 1);

    ctx = SearchContext(
        run=training,
        origin=wf,
        ds=ds,
        archive=archive,
        bandit=bandit,
        store=store,
        cache=cache,
        versions=versions,
        constraints=constraints,
        # MIN_COST with a binding quality floor: the honest framing of what
        # this workload has to gain. Every ground-truth improvement in the
        # simulated world (cheaper classifier, fewer wasted web calls,
        # conditional reviewer) is a cost win at constant quality, and BALANCED
        # weights price a 9% cost saving at 0.005 - below any sane gate floor.
        # 0.55 is an absolute safety floor. The constraint that actually binds
        # is Objective.max_quality_drop, a PAIRED comparison against the parent
        # on identical tasks - an absolute floor on a rotated validation slice
        # would measure that slice's difficulty as much as the candidate.
        goal=objective_preset(ObjectiveKind.MIN_COST, 0.55),
        ref=Baseline(),
        cfg=SearchConfig(stage_b_tasks=20, stage_c_tasks=27, seed=13),
        exec_cfg=ExecConfig(),
        version=EvaluatorVersion(mode="simulated"),
        mode=EvalMode.SIMULATED
    );

    baseline_scores = establish_baseline(ctx, wf);
    base_summary = summarize(baseline_scores);
    print(
        f"baseline: quality {base_summary.quality:.4f}, "
        f"cost ${base_summary.cost_usd:.5f}/task, "
        f"critical path {base_summary.latency_ms:.0f}ms"
    );

    print("\n" + "-" * 72);
    print("training");
    print("-" * 72);

    history = train(ctx);
    for r in history {
        status = "ACCEPT" if r.accepted else ("ABANDON" if r.abandoned else "reject");
        detail = r.description if r.description != "" else r.family_key;
        print(
            f"round {r.round_no:>2}  {status:<8} {detail:<38} "
            f"train {r.train_delta:+.4f}+/-{r.train_se:.4f}  val {r.val_delta:+.4f}"
        );
        if not r.accepted {
            print(f"            {r.reason}");
        }
    }
    print(f"\nstopped: {training.stop_reason}");
    print(f"rounds: {training.round_no}, accepted: {training.accepted_count}, spent: ${training.spent_usd:.4f}");
    print(f"score cache: {cache.hits} hits / {cache.misses} misses");

    winner_entry = best_entry(archive);
    optimized = version_of(winner_entry) if winner_entry is not None else None;

    print("\n" + "-" * 72);
    print("accepted changes");
    print("-" * 72);
    changes = describe_changes(optimized);
    if len(changes) == 0 {
        print("no change cleared both the training gate and validation.");
    }
    for ch in changes {
        print(ch);
        print("");
    }

    print("-" * 72);
    print("final comparison on the held-out test set");
    print("-" * 72);
    test_tasks = split_tasks(ds, "test");
    original_test = evaluate_on(ctx, wf, test_tasks);
    optimized_test = scores_for_optimized(ctx, optimized, test_tasks, original_test);
    print(format_report(final_report(original_test, optimized_test, 0.5, 42)));

    print("\n" + "-" * 72);
    print("pareto frontier");
    print("-" * 72);
    print(format_frontier(archive));

    print("\n" + "-" * 72);
    print("mutation family exploration");
    print("-" * 72);
    print(format_arms(bandit));
}
