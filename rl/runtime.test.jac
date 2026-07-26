"""Tests for the workflow runtime: caps, routing, determinism, and confidence."""

import from rl.ir { reseal }


def support_workflow(classifier_model: str, support_prompt: str, review_cond: str) -> WorkflowVersion {
    wf = WorkflowVersion(label="support");
    classifier = AgentSpec(
        agent_id="classifier",
        role="Classify support requests",
        model=classifier_model,
        prompt="Classify the request.",
        max_tokens=300
    );
    support = AgentSpec(
        agent_id="support",
        role="Resolve customer problems",
        model="large",
        prompt=support_prompt,
        tools=["doc_search", "web_search"],
        max_tokens=1500
    );
    reviewer = AgentSpec(
        agent_id="reviewer",
        role="Review responses for correctness",
        model="large",
        prompt="Review the answer.",
        max_tokens=600
    );
    wf +>:Entry:+> classifier;
    classifier +>:FlowsTo(to_agent="support"):+> support;
    support +>:FlowsTo(to_agent="reviewer", condition=review_cond):+> reviewer;
    return reseal(wf);
}


def run_one(wf: WorkflowVersion, task_id: str, category: str, difficulty: str) -> RunRoot {
    store = TraceStore();
    ctx = RunContext(
        task_id=task_id,
        task_input="my api key returns 401",
        category=category,
        difficulty=difficulty
    );
    return execute(wf, store, ctx, ExecConfig());
}


test "a baseline workflow runs every agent in order" {
    wf = support_workflow("large", "Resolve the problem.", "");
    run = run_one(wf, "t1", "technical", "medium");
    ids = [s.agent_id for s in spans_of(run)];
    assert ids == ["classifier", "support", "reviewer"], f"got {ids}";
    assert run.ok and run.stop_reason == "complete";
}


test "execution is deterministic for the same config and task" {
    wf = support_workflow("large", "Resolve the problem.", "");
    a = run_one(wf, "t1", "technical", "medium");
    b = run_one(wf, "t1", "technical", "medium");
    assert abs(a.total_cost_usd - b.total_cost_usd) < 1e-12;
    assert abs(a.critical_path_ms - b.critical_path_ms) < 1e-9;
}


test "different tasks give different difficulty, same config" {
    wf = support_workflow("large", "Resolve the problem.", "");
    a = run_one(wf, "t1", "technical", "hard");
    b = run_one(wf, "t2", "technical", "hard");
    assert a.run_id != b.run_id;
}


test "the step cap stops a runaway workflow and marks it failed" {
    wf = WorkflowVersion(label="loop");
    a = AgentSpec(agent_id="a", role="worker", model="small", prompt="p");
    b = AgentSpec(agent_id="b", role="worker", model="small", prompt="p");
    wf +>:Entry:+> a;
    a +>:FlowsTo(to_agent="b"):+> b;
    b +>:FlowsTo(to_agent="a"):+> a;
    reseal(wf);

    store = TraceStore();
    ctx = RunContext(task_id="t1", task_input="x");
    run = execute(wf, store, ctx, ExecConfig(step_cap=5));

    assert not run.ok;
    assert run.stop_reason == "step_cap";
    assert len(spans_of(run)) <= 5, "the cap must bound work actually done";
}


test "the cost cap stops an expensive workflow" {
    wf = support_workflow("large", "Resolve the problem.", "");
    store = TraceStore();
    ctx = RunContext(task_id="t1", task_input="x", category="technical", difficulty="hard");
    run = execute(wf, store, ctx, ExecConfig(cost_cap_usd=0.001));

    assert not run.ok;
    assert run.stop_reason == "cost_cap";
}


test "an unconditional reviewer always runs" {
    wf = support_workflow("large", "Resolve the problem.", "");
    run = run_one(wf, "t5", "billing", "easy");
    ids = [s.agent_id for s in spans_of(run)];
    assert "reviewer" in ids;
}


test "a never condition removes the reviewer from the path" {
    wf = support_workflow("large", "Resolve the problem.", "never");
    run = run_one(wf, "t5", "billing", "easy");
    ids = [s.agent_id for s in spans_of(run)];
    assert "reviewer" not in ids;
    assert run.ok, "skipping an optional node is not a failure";
}


test "a conditional reviewer runs only when confidence is low" {
    conditional = support_workflow("large", "Resolve the problem.", "low_confidence");
    # An easy billing task with doc coverage produces high confidence.
    easy = run_one(conditional, "t9", "billing", "easy");
    ran_on_easy = "reviewer" in [s.agent_id for s in spans_of(easy)];

    # Strip the docs tool so coverage - and therefore confidence - collapses.
    stripped = support_workflow("large", "Resolve the problem.", "low_confidence");
    for a in [stripped ->:Entry:-> ->:FlowsTo:->] {
        if a.agent_id == "support" {
            a.tools = [];
        }
    }
    weak = run_one(stripped, "t9", "billing", "easy");
    ran_on_weak = "reviewer" in [s.agent_id for s in spans_of(weak)];

    assert ran_on_weak, "low confidence must invoke the reviewer";
    assert not ran_on_easy, "high confidence must skip it";
}


test "confidence is driven by doc coverage, not self-report" {
    ctx = RunContext(task_id="t", task_input="x");
    ctx.doc_coverage = 0.85;
    ctx.quality = 0.8;
    high = update_confidence(ctx);

    ctx2 = RunContext(task_id="t", task_input="x");
    ctx2.doc_coverage = 0.0;
    ctx2.quality = 0.8;
    low = update_confidence(ctx2);

    assert high > low;
    assert low < 0.72, "no retrieval evidence must fall below the routing threshold";
}


test "a tool error depresses confidence" {
    ctx = RunContext(task_id="t", task_input="x");
    ctx.doc_coverage = 0.85;
    ctx.quality = 0.9;
    clean = update_confidence(ctx);

    ctx.tool_error = True;
    broken = update_confidence(ctx);
    assert broken < clean - 0.25;
}


test "unknown conditions fail open rather than silently dropping a path" {
    wf = support_workflow("large", "Resolve the problem.", "some_unrecognized_condition");
    run = run_one(wf, "t5", "billing", "easy");
    assert "reviewer" in [s.agent_id for s in spans_of(run)];
}


test "ground truth - a small classifier costs less at equal quality" {
    big = support_workflow("large", "Resolve the problem.", "");
    small = support_workflow("small", "Resolve the problem.", "");

    big_run = run_one(big, "t3", "billing", "easy");
    small_run = run_one(small, "t3", "billing", "easy");

    big_spans = spans_of(big_run);
    small_spans = spans_of(small_run);
    assert small_spans[0].cost_usd < big_spans[0].cost_usd, "cheaper model, cheaper call";
    assert small_run.total_cost_usd < big_run.total_cost_usd;
}


test "ground truth - docs-first avoids a pointless web call" {
    plain = support_workflow("large", "Resolve the problem.", "");
    instructed = support_workflow(
        "large",
        "Search internal documentation before using external web search.",
        ""
    );

    # A billing task does not need recent external information.
    plain_run = run_one(plain, "t7", "billing", "easy");
    instructed_run = run_one(instructed, "t7", "billing", "easy");

    plain_tools = spans_of(plain_run)[1].tools_invoked;
    instructed_tools = spans_of(instructed_run)[1].tools_invoked;

    assert "web_search" in plain_tools;
    assert "web_search" not in instructed_tools, "docs-first must suppress the wasted call";
}


test "ground truth - web search still fires when the task needs it" {
    instructed = support_workflow(
        "large",
        "Search internal documentation before using external web search.",
        ""
    );
    run = run_one(instructed, "t7", "technical", "hard");
    tools = spans_of(run)[1].tools_invoked;
    assert "web_search" in tools, "recency-sensitive tasks must still reach the web";
}


test "critical path tracks output tokens, not wall clock" {
    wf = support_workflow("large", "Resolve the problem.", "");
    run = run_one(wf, "t1", "technical", "medium");
    total_out = 0;
    for s in spans_of(run) {
        total_out += s.output_tokens;
    }
    assert abs(run.critical_path_ms - total_out * 8.0) < 1e-9;
}
